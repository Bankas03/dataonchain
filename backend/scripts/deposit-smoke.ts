// Deposits, on testnet and the development database:
//   - USDC from the treasury (our own refunds and test funding) is not a deposit
//   - 0.1 USDC from one test user's wallet to another shows as a deposit once,
//     with the right amount, sender and chain, and a second scan adds nothing
//   - the Base wallet for "Receive on Base" is created once and reused
// Exit code 3 means the treasury needs more test USDC.
// Run with: DEPOSIT_SETTLE_MS=15000 BRIDGE_ENABLED=true npx tsx scripts/deposit-smoke.ts
import { randomUUID } from "node:crypto";
import { inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { deposits, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { listDeposits, scanDeposits } from "../src/deposits/service";
import { ensureChainWallet } from "../src/bridge/wallets";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function usdcOf(walletId: string) {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { amount: b ? Number(b.amount) : 0, tokenId: b?.token?.id };
}

async function waitTx(id: string) {
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const tx = await circle.getTransaction({ id });
    const state = (tx.data?.transaction as unknown as { state?: string })?.state;
    if (state === "COMPLETE") return;
    if (state && ["FAILED", "DENIED", "CANCELLED"].includes(state)) throw new Error(`transfer ${state}`);
  }
  throw new Error("transfer did not finish");
}

async function main() {
  const t = await usdcOf(env.TREASURY_WALLET_ID);
  if (!t.tokenId || t.amount < 0.4) {
    console.log(`NEEDS_FUNDING: treasury has ${t.amount} USDC`);
    process.exit(3);
  }
  const a = randomUUID();
  const b = randomUUID();
  const stamp = Date.now();
  await db.insert(users).values([
    { id: a, name: "Deposit Sender", email: `depsmoke-a+${stamp}@example.com`, emailVerified: true, phone: "+2348011111111" },
    { id: b, name: "Deposit Receiver", email: `depsmoke-b+${stamp}@example.com`, emailVerified: true, phone: "+2348011111111" },
  ]);
  try {
    const wa = await ensureUserWallet(a);
    const wb = await ensureUserWallet(b);
    console.log("Funding the sender with 0.3 USDC from the treasury...");
    const fund = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID, tokenId: t.tokenId, destinationAddress: wa.address,
      amount: ["0.3"], amounts: ["0.3"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`dep-smoke:fund:${a}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    await waitTx(fund.data?.id ?? "");
    for (let i = 0; i < 20 && !(await usdcOf(wa.circleWalletId)).tokenId; i++) await sleep(3_000);
    console.log("Sending 0.1 USDC from the sender to the receiver...");
    const send = await circle.createTransaction({
      walletId: wa.circleWalletId, tokenId: (await usdcOf(wa.circleWalletId)).tokenId, destinationAddress: wb.address,
      amount: ["0.1"], amounts: ["0.1"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`dep-smoke:send:${a}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    await waitTx(send.data?.id ?? "");

    console.log("Waiting for Circle to list it, then scanning...");
    let mine: Awaited<ReturnType<typeof listDeposits>> = [];
    for (let i = 0; i < 12 && mine.length === 0; i++) {
      await sleep(10_000);
      await scanDeposits();
      mine = await listDeposits(b);
    }
    check(mine.length === 1 && mine[0]!.token === "USDC" && Number(mine[0]!.amount) === 0.1, "the 0.1 USDC from another wallet shows as a deposit", mine);
    check(mine[0]!.sourceAddress?.toLowerCase() === wa.address.toLowerCase() && mine[0]!.chain === "arc", "with the sender's address, on Arc");
    check((await listDeposits(a)).length === 0, "USDC from the treasury is not shown as a deposit");
    await scanDeposits();
    check((await listDeposits(b)).length === 1, "a second scan adds nothing");

    if (env.BRIDGE_ENABLED) {
      const base1 = await ensureChainWallet(b, "base");
      const base2 = await ensureChainWallet(b, "base");
      check(base1.address === base2.address && /^0x[0-9a-fA-F]{40}$/.test(base1.address), `the Base wallet is created once and reused (${base1.address})`);
    }
  } finally {
    await db.delete(deposits).where(inArray(deposits.userId, [a, b]));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(inArray(wallets.userId, [a, b]))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(inArray(wallets.userId, [a, b]));
    await db.delete(users).where(inArray(users.id, [a, b]));
    console.log("Cleaned up the test users");
  }
}

main()
  .then(() => {
    console.log("All deposit checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
