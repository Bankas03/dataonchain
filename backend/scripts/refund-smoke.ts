// Refunds end to end on Arc Testnet and the development database:
// a paid order fails at VTpass, and the USDC really goes back to the payer.
// Exit code 3 means the treasury wallet needs more test USDC.
// Run with: npx tsx scripts/refund-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, payments, refunds, users, vtuTransactions } from "../src/db/schema";
import { env } from "../src/env";
import { fulfilOrder } from "../src/fulfilment/service";
import { getCurrentRate } from "../src/pricing/rates";
import { advanceRefund, startRefund } from "../src/refunds/service";
import { ensureUserWallet } from "../src/wallets/service";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";
const AMOUNT_MICRO = 10_000; // 0.01 USDC

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
  return { tokenId: b?.token?.id, micro: Math.round(Number(b?.amount ?? 0) * 1_000_000) };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const treasury = await usdcOf(env.TREASURY_WALLET_ID);
  console.log(`Treasury holds ${(treasury.micro / 1_000_000).toFixed(6)} USDC`);
  if (!treasury.tokenId || treasury.micro < 100_000) {
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }

  let [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (!payer) {
    [payer] = await db
      .insert(users)
      .values({ name: "Payment Test", email: PAYER_EMAIL, emailVerified: true, phone: "+2348011111111" })
      .returning();
  }
  if (!payer) throw new Error("Could not create the test payer");
  const wallet = await ensureUserWallet(payer.id);
  const before = (await usdcOf(wallet.circleWalletId)).micro;
  console.log(`Test wallet ${wallet.address} holds ${(before / 1_000_000).toFixed(6)} USDC`);

  const rate = await getCurrentRate();
  const ids: string[] = [];
  async function paidOrder(paymentStatus: "CONFIRMED" | "FAILED") {
    const [o] = await db
      .insert(orders)
      .values({
        reference: `TESTREF${Date.now()}${ids.length}`,
        userId: payer!.id,
        serviceType: "airtime",
        network: "mtn",
        phone: "+2348022222222", // any number except 08011111111 fails in the VTpass sandbox
        ngnAmountKobo: 10_000,
        marginKobo: 200,
        usdcAmountMicro: AMOUNT_MICRO,
        exchangeRateId: rate.id,
        status: "PAYMENT_CONFIRMED",
        quoteExpiresAt: new Date(Date.now() + 600_000),
      })
      .returning();
    if (!o) throw new Error("could not create test order");
    ids.push(o.id);
    await db.insert(payments).values({
      orderId: o.id,
      walletId: wallet.id,
      circleTransactionId: `smoke-${randomUUID()}`,
      txHash: `smoke-${randomUUID()}`,
      fromAddress: wallet.address,
      toAddress: env.TREASURY_ADDRESS,
      token: treasury.tokenId!,
      blockchain: wallet.blockchain,
      amountMicro: AMOUNT_MICRO,
      status: paymentStatus,
    });
    return o;
  }
  const orderOf = async (id: string) => (await db.select().from(orders).where(eq(orders.id, id)).limit(1))[0];

  try {
    // 1. A paid order that VTpass cannot deliver is refunded automatically
    const o = await paidOrder("CONFIRMED");
    await fulfilOrder(o.id);
    let now = await orderOf(o.id);
    check(["REFUND_PENDING", "REFUNDED"].includes(now?.status ?? ""), `failed delivery started a refund right away (status ${now?.status})`, now?.failureReason);

    // Asking again many times must not send a second transfer
    await startRefund(o.id);
    await advanceRefund(o.id);
    await advanceRefund(o.id);
    const rows = await db.select().from(refunds).where(eq(refunds.orderId, o.id));
    check(rows.length === 1 && rows[0]?.status !== "PENDING", "exactly one refund transfer was sent", rows);
    const firstTx = rows[0]?.circleTransactionId;

    process.stdout.write("Waiting for Arc to confirm the refund ");
    for (let i = 0; i < 60 && now?.status !== "REFUNDED"; i++) {
      await sleep(3_000);
      await advanceRefund(o.id);
      now = await orderOf(o.id);
      process.stdout.write(".");
    }
    console.log("");
    check(now?.status === "REFUNDED", `order is Refunded (${now?.failureReason})`);
    const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, o.id));
    check(refund?.status === "CONFIRMED" && Boolean(refund.txHash) && refund.circleTransactionId === firstTx, `refund confirmed on Arc: ${env.EXPLORER_TX_URL}${refund?.txHash}`);

    let after = before;
    for (let i = 0; i < 20 && after < before + AMOUNT_MICRO; i++) {
      await sleep(3_000);
      after = (await usdcOf(wallet.circleWalletId)).micro;
    }
    check(after >= before + AMOUNT_MICRO, `the 0.01 USDC arrived back in the customer's wallet (${(before / 1e6).toFixed(6)} -> ${(after / 1e6).toFixed(6)})`);

    const lines = (await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, o.id))).filter((l) => (l.memo ?? "").startsWith("Refund"));
    check(lines.length === 2 && lines.reduce((s, l) => s + l.debit - l.credit, 0) === 0, "refund ledger entries written and balanced");

    await startRefund(o.id);
    await advanceRefund(o.id);
    check((await orderOf(o.id))?.status === "REFUNDED", "a refunded order is never refunded twice");

    // 2. A failed order whose payment never completed is NOT refunded (no money was taken)
    const unpaid = await paidOrder("FAILED");
    await db.update(orders).set({ status: "FAILED" }).where(eq(orders.id, unpaid.id));
    await startRefund(unpaid.id);
    const u = await orderOf(unpaid.id);
    const uRefunds = await db.select().from(refunds).where(eq(refunds.orderId, unpaid.id));
    check(u?.status === "FAILED" && uRefunds.length === 0, "an order whose payment failed gets no refund");
  } finally {
    if (ids.length) {
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, ids));
      await db.delete(refunds).where(inArray(refunds.orderId, ids));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
      await db.delete(payments).where(inArray(payments.orderId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(orders).where(inArray(orders.id, ids));
    }
    console.log("Cleaned up the test orders");
  }
}

main()
  .then(() => {
    console.log("All refund checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
