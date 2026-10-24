// Bridging out as a real user, on testnet and the development database:
//   - a test user with a funded Arc smart wallet sends 0.2 USDC to the approved
//     test provider on Base Sepolia, exactly as the website does it
//   - limits, approvals, balance and "one at a time" rules are checked
// Exit code 3 means the treasury needs more test USDC.
// Run with: BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 npx tsx scripts/bridge-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { approvedDestinations, auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { BridgeUserError, driving, getBridgeView, listDestinations, quoteBridge, startBridge } from "../src/bridge/user";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND_MICRO = 400_000; // 0.4 USDC: 0.2 to send plus Circle's fee

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
  return { tokenId: b?.token?.id, micro: b ? Math.round(Number(b.amount) * 1_000_000) : 0 };
}

async function expectRefused(label: string, fn: () => Promise<unknown>, pattern: RegExp) {
  try {
    await fn();
    check(false, label);
  } catch (err) {
    check(err instanceof BridgeUserError && pattern.test(err.message), label, err instanceof Error ? err.message : err);
  }
}

async function main() {
  if (!env.BRIDGE_ENABLED) throw new Error("Run with BRIDGE_ENABLED=true");
  const recipient = process.env.GATEWAY_PROBE_RECIPIENT_ADDRESS;
  const recipientWalletId = process.env.GATEWAY_PROBE_RECIPIENT_WALLET_ID;
  if (!recipient || !recipientWalletId) throw new Error("Run script 15 first (it creates the test provider wallet)");

  const treasury = await usdcOf(env.TREASURY_WALLET_ID);
  if (!treasury.tokenId || treasury.micro < FUND_MICRO + 100_000) {
    console.log(`NEEDS_FUNDING: treasury has ${show(treasury.micro)} USDC`);
    process.exit(3);
  }

  await db
    .insert(approvedDestinations)
    .values({ label: "Test provider (Base Sepolia)", chain: "base", address: recipient.toLowerCase(), note: "testnet only" })
    .onConflictDoUpdate({ target: [approvedDestinations.chain, approvedDestinations.address], set: { label: "Test provider (Base Sepolia)", active: true } });
  const dests = await listDestinations();
  const dest = dests.find((d) => d.address === recipient.toLowerCase());
  check(Boolean(dest), "the test provider is listed for users");

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Bridge Smoke Test", email: `bridgesmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  let transferId: string | undefined;
  try {
    const wallet = await ensureUserWallet(userId);

    await expectRefused("an unknown destination is refused", () => startBridge(userId, { destinationId: randomUUID(), amount: "0.2" }), /listed/);
    await expectRefused("an amount below the minimum is refused", () => startBridge(userId, { destinationId: dest!.id, amount: "0.01" }), /minimum/);
    await expectRefused("an amount above the maximum is refused", () => startBridge(userId, { destinationId: dest!.id, amount: String(env.BRIDGE_MAX_USDC + 1) }), /maximum/);
    await expectRefused("a nonsense amount is refused", () => startBridge(userId, { destinationId: dest!.id, amount: "abc" }), /amount/);
    await expectRefused("an empty wallet cannot send", () => startBridge(userId, { destinationId: dest!.id, amount: "0.2" }), /Not enough/);

    console.log(`Funding the test user's smart wallet with ${show(FUND_MICRO)} USDC from the treasury...`);
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: treasury.tokenId,
      destinationAddress: wallet.address,
      amount: [show(FUND_MICRO)],
      amounts: [show(FUND_MICRO)],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`bridge-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const t = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((t.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check((await usdcOf(wallet.circleWalletId)).micro >= FUND_MICRO, "test wallet funded");

    const quote = await quoteBridge(userId, { destinationId: dest!.id, amount: "0.2" });
    console.log(`Quote: send 0.2, Circle fee up to ${quote.fee}, total ${quote.total}, they receive ${quote.receives}`);
    check(quote.receives === "0.200000" && quote.allowed, "the quote shows the exact amount received");

    const recipientBefore = (await usdcOf(recipientWalletId)).micro;
    const started = await startBridge(userId, { destinationId: dest!.id, amount: "0.2" });
    transferId = started?.id;
    check(Boolean(transferId), `transfer started (${transferId})`);
    await expectRefused("a second transfer waits until the first is done", () => startBridge(userId, { destinationId: dest!.id, amount: "0.2" }), /in progress/);

    let view = started;
    let last = "";
    const t0 = Date.now();
    while (view && !["COMPLETE", "FAILED"].includes(view.status) && Date.now() - t0 < 15 * 60_000) {
      if (view.status !== last) {
        console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view.status}`);
        last = view.status;
      }
      await sleep(4_000);
      view = await getBridgeView(userId, transferId!);
    }
    console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""}`);
    check(view?.status === "COMPLETE", `transfer complete in ${Math.round((Date.now() - t0) / 1000)} seconds`);
    check(Boolean(view?.mintUrl), `mint recorded: ${view?.mintUrl}`);

    let after = recipientBefore;
    for (let i = 0; i < 30 && after < recipientBefore + 200_000; i++) {
      await sleep(3_000);
      after = (await usdcOf(recipientWalletId)).micro;
    }
    check(after - recipientBefore === 200_000, "the provider received exactly 0.2 USDC on Base Sepolia");
    check((view?.steps ?? []).some((s) => s.step === "deposit" && s.url) && (view?.steps ?? []).some((s) => s.step === "minted" && s.url),
      "the steps shown to the user include the deposit and the mint, with links");
    const lines = await db.select().from(ledgerEntries).where(inArray(ledgerEntries.journalId,
      (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j)));
    check(lines.length === 2 && lines.reduce((s, l) => s + l.debit - l.credit, 0) === 0, "ledger entries written and balanced");
  } finally {
    while (transferId && driving.has(transferId)) await sleep(1_000);
    const ts = await db.select({ id: bridgeTransfers.id }).from(bridgeTransfers).where(eq(bridgeTransfers.userId, userId));
    const ids = ts.map((t) => t.id);
    if (ids.length) {
      await db.delete(bridgeEvents).where(inArray(bridgeEvents.transferId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ids));
    }
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId));
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws.map((w) => w.id)));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All bridge checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
