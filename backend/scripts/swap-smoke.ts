// Swaps on Arc Testnet with the development database:
//   a test user swaps 0.5 USDC to EURC, then the EURC back to USDC.
// Exit code 3: the treasury needs more test USDC.
// Exit code 4: Arc Testnet had no liquidity or price for the swap (Circle's side).
// Run with: SWAP_ENABLED=true npx tsx scripts/swap-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, swaps, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { SwapError, executeSwap, quoteSwap, tokenBalances } from "../src/swap/service";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function refused(label: string, fn: () => Promise<unknown>, pattern: RegExp) {
  try {
    await fn();
    check(false, label);
  } catch (err) {
    check(err instanceof SwapError && pattern.test(err.message), label, err instanceof Error ? err.message : err);
  }
}

class NoLiquidity extends Error {}

async function main() {
  if (!env.SWAP_ENABLED) throw new Error("Run with SWAP_ENABLED=true");
  const tRes = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (tRes.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!t?.token?.id || Number(t.amount) < 1.2) {
    console.log(`NEEDS_FUNDING: treasury has ${t?.amount ?? 0} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Swap Smoke Test", email: `swapsmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  try {
    const wallet = await ensureUserWallet(userId);
    await refused("swapping a token for itself is refused", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "USDC", amount: "1" }), /different/);
    await refused("an amount below the minimum is refused", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.1" }), /minimum/);
    await refused("an unknown token is refused", () => executeSwap(userId, { tokenIn: "USDT", tokenOut: "EURC", amount: "1" }), /Choose/);
    await refused("an empty wallet cannot swap", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" }), /Not enough/);

    console.log("Funding the test user's Arc wallet with 1 USDC from the treasury...");
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID, tokenId: t.token.id, destinationAddress: wallet.address,
      amount: ["1.000000"], amounts: ["1.000000"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`swap-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check(Number((await tokenBalances(wallet.circleWalletId)).USDC) >= 1, "test wallet funded");

    // One swap at a time
    await db.insert(swaps).values({ userId, walletAddress: wallet.address, tokenIn: "USDC", tokenOut: "EURC", amountIn: "0.5", feeBps: 50, slippageBps: 100, openKey: userId });
    await refused("a second swap waits for the first", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" }), /in progress/);
    await db.delete(swaps).where(eq(swaps.userId, userId));

    // USDC -> EURC
    let quote;
    try {
      quote = await quoteSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" });
    } catch (err) {
      throw new NoLiquidity(err instanceof Error ? err.message : String(err));
    }
    console.log(`Quote: 0.5 USDC -> about ${quote.estimatedOut} EURC, at least ${quote.minOut}`);
    check(Number(quote.estimatedOut) > 0, "a price is available for USDC -> EURC");

    let swap;
    try {
      swap = await executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" });
    } catch (err) {
      if (err instanceof SwapError && err.status === 502) throw new NoLiquidity(err.message);
      throw err;
    }
    check(swap?.status === "COMPLETE" && Boolean(swap.txHash), `swap complete: ${swap?.explorerUrl}`, swap);
    let eurc = "0";
    for (let i = 0; i < 20 && Number(eurc) === 0; i++) {
      await sleep(3_000);
      eurc = (await tokenBalances(wallet.circleWalletId)).EURC;
    }
    check(Number(eurc) > 0 && (!swap?.minOut || Number(eurc) >= Number(swap.minOut)), `received ${eurc} EURC (at least ${swap?.minOut ?? "?"} promised)`);

    // EURC -> USDC (everything back)
    const back = eurc.includes(".") ? eurc.slice(0, eurc.indexOf(".") + 7) : eurc;
    if (Number(back) >= 0.5) {
      const usdcBefore = Number((await tokenBalances(wallet.circleWalletId)).USDC);
      let swapBack;
      try {
        swapBack = await executeSwap(userId, { tokenIn: "EURC", tokenOut: "USDC", amount: back });
      } catch (err) {
        if (err instanceof SwapError && err.status === 502) throw new NoLiquidity(err.message);
        throw err;
      }
      check(swapBack?.status === "COMPLETE", `swapped ${back} EURC back to USDC: ${swapBack?.explorerUrl}`);
      let usdcAfter = usdcBefore;
      for (let i = 0; i < 20 && usdcAfter <= usdcBefore; i++) {
        await sleep(3_000);
        usdcAfter = Number((await tokenBalances(wallet.circleWalletId)).USDC);
      }
      check(usdcAfter > usdcBefore, `USDC balance went up (${usdcBefore} -> ${usdcAfter})`);
    } else {
      console.log(`Skipped swapping back: ${eurc} EURC is below the 0.5 minimum.`);
    }
    const rows = await db.select().from(swaps).where(eq(swaps.userId, userId));
    check(rows.every((r) => r.openKey === null && ["COMPLETE"].includes(r.status)), "every swap is recorded as complete and released");
  } finally {
    const ids = (await db.select({ id: swaps.id }).from(swaps).where(eq(swaps.userId, userId))).map((r) => r.id);
    if (ids.length) await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
    await db.delete(swaps).where(eq(swaps.userId, userId));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All swap checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    if (err instanceof NoLiquidity) {
      console.error(`NO_LIQUIDITY: ${err.message}`);
      process.exit(4);
    }
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
