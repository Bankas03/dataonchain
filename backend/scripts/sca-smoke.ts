// Smart contract wallets end to end on Arc Testnet and the development database:
//   1. a user with an old (EOA) wallet holding USDC is upgraded to an SCA wallet
//   2. the old wallet's USDC is swept into the new one automatically
//   3. a real order is paid from the SCA wallet with zero gas (Circle Gas Station)
//   4. the leftover test USDC goes back to the treasury
// It also upgrades the payment test user so the other tests keep working.
// Exit code 3 means the treasury wallet needs more test USDC.
// Run with: npx tsx scripts/sca-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, payments, refunds, users, vtuTransactions, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { getOrderView, payOrder, usdcToMicro } from "../src/payments/service";
import { createQuote } from "../src/pricing/quote";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";
import { sweepWallet } from "../src/wallets/sweep";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";
const FUND_MICRO = 100_000; // 0.1 USDC

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const show = (micro: number) => (micro / 1_000_000).toFixed(6);

async function usdcOf(walletId: string) {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: b ? (usdcToMicro(b.amount) ?? Math.floor(Number(b.amount) * 1_000_000)) : 0 };
}

async function transfer(fromWalletId: string, tokenId: string, to: string, micro: number, key: string) {
  const amount = show(micro);
  const res = await circle.createTransaction({
    walletId: fromWalletId,
    tokenId,
    destinationAddress: to,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(key),
  } as unknown as Parameters<typeof circle.createTransaction>[0]);
  const id = res.data?.id;
  if (!id) throw new Error("Circle did not accept the transfer");
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const t = await circle.getTransaction({ id });
    const tx = t.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
    if (tx?.state === "COMPLETE") return tx;
    if (tx?.state && ["FAILED", "DENIED", "CANCELLED"].includes(tx.state)) {
      throw new Error(`transfer ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
    }
  }
  throw new Error("transfer did not complete in 3 minutes");
}

async function waitForBalance(walletId: string, ok: (micro: number) => boolean) {
  let micro = (await usdcOf(walletId)).micro;
  for (let i = 0; i < 20 && !ok(micro); i++) {
    await sleep(3_000);
    micro = (await usdcOf(walletId)).micro;
  }
  return micro;
}

async function sweepUntilDone(oldWalletId: string) {
  let result = await sweepWallet(oldWalletId);
  for (let i = 0; i < 60 && !["confirmed", "nothing", "failed"].includes(result); i++) {
    await sleep(3_000);
    result = await sweepWallet(oldWalletId);
    process.stdout.write(".");
  }
  console.log("");
  return result;
}

async function main() {
  const treasury = await usdcOf(env.TREASURY_WALLET_ID);
  console.log(`Treasury holds ${show(treasury.micro)} USDC`);
  if (!treasury.tokenId || treasury.micro < FUND_MICRO + 100_000) {
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }
  const tokenId = treasury.tokenId;

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId, name: "SCA Smoke Test", email: `scasmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111",
  });
  let orderId: string | undefined;

  try {
    // 1. An "existing user": old style EOA wallet with some USDC
    const created = await circle.createWallets({
      walletSetId: env.CIRCLE_WALLET_SET_ID,
      blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
      count: 1,
      accountType: "EOA",
      idempotencyKey: uuidFrom(`wallet:${userId}:${env.CIRCLE_BLOCKCHAIN}`),
    });
    const w = created.data?.wallets?.[0];
    if (!w?.id || !w.address) throw new Error("Circle did not create the test EOA wallet");
    const [eoa] = await db.insert(wallets).values({
      userId, purpose: "user", circleWalletId: w.id, circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER", blockchain: env.CIRCLE_BLOCKCHAIN, address: w.address, accountType: "EOA",
    }).returning();
    if (!eoa) throw new Error("could not save the test EOA wallet");
    console.log(`Funding the old style wallet ${eoa.address} with ${show(FUND_MICRO)} USDC from the treasury...`);
    await transfer(env.TREASURY_WALLET_ID, tokenId, eoa.address, FUND_MICRO, `scasmoke:fund:${userId}`);
    const funded = await waitForBalance(eoa.circleWalletId, (m) => m >= FUND_MICRO);
    check(funded >= FUND_MICRO, `old wallet funded (${show(funded)} USDC)`);

    // 2. Upgrade: a new SCA wallet, the old one retired
    const sca = await ensureUserWallet(userId);
    check(sca.accountType === "SCA" && sca.address.toLowerCase() !== eoa.address.toLowerCase(), `SCA wallet created (${sca.address})`);
    const again = await ensureUserWallet(userId);
    check(again.id === sca.id, "the same SCA wallet is reused, never a second one");
    const [retired] = await db.select().from(wallets).where(eq(wallets.id, eoa.id));
    check(Boolean(retired?.retiredAt), "the old wallet is retired");

    // 3. Sweep the old wallet's USDC into the SCA wallet
    process.stdout.write("Moving the USDC from the old wallet ");
    const result = await sweepUntilDone(eoa.id);
    check(result === "confirmed", `sweep confirmed on Arc (result ${result})`);
    const [sweep] = await db.select().from(walletSweeps).where(eq(walletSweeps.fromWalletId, eoa.id));
    check(sweep?.status === "CONFIRMED" && Boolean(sweep.txHash) && sweep.openKey === null, `sweep recorded: ${env.EXPLORER_TX_URL}${sweep?.txHash}`);
    const scaBalance = await waitForBalance(sca.circleWalletId, (m) => m >= (sweep?.amountMicro ?? 1));
    check(scaBalance === sweep?.amountMicro, `the SCA wallet received ${show(scaBalance)} USDC`);
    check((await sweepWallet(eoa.id)) === "nothing", "an emptied old wallet is not swept again");

    // 4. Pay a real order from the SCA wallet: the user pays exactly the price, no gas
    const quote = await createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "08011111111" });
    const price = usdcToMicro(quote.usdcAmount) ?? 0;
    check(price > 0 && price <= scaBalance, `quote ${quote.reference}: ${quote.usdcAmount} USDC`);
    await payOrder(userId, quote.reference);
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    orderId = row?.id;
    let view = await getOrderView(userId, quote.reference);
    process.stdout.write("Waiting for the payment and delivery ");
    for (let i = 0; i < 60 && !["FULFILLED", "FAILED", "FLAGGED", "REFUNDED", "REFUND_PENDING"].includes(view?.status ?? ""); i++) {
      await sleep(3_000);
      view = await getOrderView(userId, quote.reference);
      process.stdout.write(".");
    }
    console.log("");
    check(view?.payment?.status === "CONFIRMED", `payment from the SCA wallet confirmed on Arc (${view?.payment?.explorerUrl})`);
    check(view?.status === "FULFILLED", `airtime delivered (status ${view?.status})`);
    const afterPay = await waitForBalance(sca.circleWalletId, (m) => m <= scaBalance - price);
    check(afterPay === scaBalance - price, `gas was sponsored: the wallet paid exactly the price (${show(scaBalance)} -> ${show(afterPay)})`);

    // 5. Give the leftover test USDC back to the treasury (also gas free)
    if (afterPay > 0) {
      await transfer(sca.circleWalletId, tokenId, env.TREASURY_ADDRESS, afterPay, `scasmoke:return:${userId}`);
      const empty = await waitForBalance(sca.circleWalletId, (m) => m === 0);
      check(empty === 0, "leftover returned to the treasury with no gas taken from the wallet");
    }
  } finally {
    if (orderId) {
      await db.delete(vtuTransactions).where(eq(vtuTransactions.orderId, orderId));
      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, orderId));
      await db.delete(refunds).where(eq(refunds.orderId, orderId));
      await db.delete(payments).where(eq(payments.orderId, orderId));
      await db.delete(auditLogs).where(eq(auditLogs.targetId, orderId));
      await db.delete(orders).where(eq(orders.id, orderId));
    }
    await db.delete(orders).where(eq(orders.userId, userId));
    const ws = await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId));
    if (ws.length) {
      await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws.map((x) => x.id)));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ws.map((x) => x.id)));
    }
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }

  // 6. Upgrade the payment test user too, so the payment test can keep running
  const [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (payer) {
    await ensureUserWallet(payer.id);
    const [old] = await db.select().from(wallets).where(eq(wallets.userId, payer.id)).then((rows) => rows.filter((r) => r.accountType === "EOA"));
    if (old) {
      process.stdout.write("Upgrading the payment test wallet ");
      const r = await sweepUntilDone(old.id);
      console.log(`Payment test wallet: ${r === "confirmed" ? "USDC moved to its new SCA wallet" : "nothing to move"}`);
    }
  }
}

main()
  .then(() => {
    console.log("All smart wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
