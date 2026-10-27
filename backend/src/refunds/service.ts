// Automatic refunds: when a paid order cannot be delivered, the USDC goes
// back from the treasury wallet to the customer's wallet.
//
// Order:  FAILED -> REFUND_PENDING -> REFUNDED   (or FLAGGED if Circle keeps refusing)
// Refund: PENDING -> SENT -> CONFIRMED           (or FAILED)
//
// Safety:
//   - only orders whose payment was CONFIRMED on Arc are refunded
//   - claiming FAILED -> REFUND_PENDING is conditional, so only one caller wins
//   - one refund row per order (unique order_id)
//   - every Circle transfer uses an idempotency key made from the order id and
//     the attempt number, so a retry can never send the money twice
import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, ledgerEntries, orders, payments, refunds } from "../db/schema";
import { env } from "../env";
import { sendOrderEmail } from "../email/receipts";
import { ensureUserWallet } from "../wallets/service";

const MAX_ATTEMPTS = 3;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// The treasury pays the Arc network fee for refunds, so keep a little extra
const FEE_RESERVE_MICRO = 50_000;

type Order = typeof orders.$inferSelect;
type Refund = typeof refunds.$inferSelect;

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export function microText(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

function microFrom(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

async function audit(action: string, orderId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId: orderId, details });
}

async function treasuryBalanceMicro(): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc ? microFrom(usdc.amount) : 0;
}

async function confirmedPayment(orderId: string) {
  const [payment] = await db
    .select()
    .from(payments)
    .where(and(eq(payments.orderId, orderId), eq(payments.status, "CONFIRMED")))
    .orderBy(desc(payments.createdAt))
    .limit(1);
  return payment;
}

// Makes sure the refund row exists. Returns it, or nothing if the order was never paid.
async function ensureRefundRow(order: Order): Promise<Refund | undefined> {
  const [existing] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  if (existing) return existing;
  const payment = await confirmedPayment(order.id);
  if (!payment) return undefined;
  // Refunds go to the user's current wallet (old wallets are retired)
  const wallet = await ensureUserWallet(order.userId);
  await db
    .insert(refunds)
    .values({
      orderId: order.id,
      paymentId: payment.id,
      toAddress: wallet.address,
      token: payment.token,
      blockchain: payment.blockchain,
      amountMicro: payment.amountMicro,
      status: "PENDING",
    })
    .onConflictDoNothing();
  const [row] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  return row;
}

// Starts the refund for a FAILED order. Safe to call many times.
export async function startRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "FAILED") return;
  // A payment that never completed took no money, so there is nothing to refund
  if (!(await confirmedPayment(order.id))) return;

  const [claimed] = await db
    .update(orders)
    .set({ status: "REFUND_PENDING" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "FAILED")))
    .returning();
  if (!claimed) return;
  await audit("refund.started", order.id, { amountMicro: order.usdcAmountMicro });
  await advanceRefund(order.id);
}

// Moves a REFUND_PENDING order forward: sends the transfer, then confirms it.
export async function advanceRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "REFUND_PENDING") return;
  const refund = await ensureRefundRow(order);
  if (!refund) {
    // Should never happen: no confirmed payment. Put it in front of a person.
    await db
      .update(orders)
      .set({ status: "FLAGGED", failureReason: "Refund needs review: no confirmed payment was found." })
      .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
    return;
  }
  if (refund.status === "PENDING") await sendRefund(order, refund);
  else if (refund.status === "SENT") await checkRefund(order, refund);
}

async function sendRefund(order: Order, refund: Refund): Promise<void> {
  const balance = await treasuryBalanceMicro();
  if (balance < refund.amountMicro + FEE_RESERVE_MICRO) {
    console.error(`[refund] ${order.reference}: treasury has ${microText(balance)} USDC, needs ${microText(refund.amountMicro)} plus fees. Will retry.`);
    return;
  }
  const amount = microText(refund.amountMicro);
  const input = {
    walletId: env.TREASURY_WALLET_ID,
    tokenId: refund.token,
    destinationAddress: refund.toAddress,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    // Same order and attempt: same key, so Circle never sends it twice
    idempotencyKey: uuidFrom(`refund:${order.id}:${refund.attempt}`),
    refId: `REFUND-${order.reference}`,
  };
  let transactionId: string | undefined;
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    transactionId = res.data?.id;
  } catch (err) {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[refund] ${order.reference} transfer not accepted yet:`, message, detail ?? "");
    await db.update(refunds).set({ lastError: message.slice(0, 500) }).where(eq(refunds.id, refund.id));
    return;
  }
  if (!transactionId) return;
  await db
    .update(refunds)
    .set({ circleTransactionId: transactionId, status: "SENT", lastError: null })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "PENDING")));
  console.log(`[refund] ${order.reference}: sent ${amount} USDC back to ${refund.toAddress}`);
}

async function checkRefund(order: Order, refund: Refund): Promise<void> {
  if (!refund.circleTransactionId) return;
  const res = await circle.getTransaction({ id: refund.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (!tx?.state) return;

  if (FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`;
    if (refund.attempt >= MAX_ATTEMPTS) {
      await db.update(refunds).set({ status: "FAILED", lastError: reason }).where(eq(refunds.id, refund.id));
      await db
        .update(orders)
        .set({ status: "FLAGGED", failureReason: "Your refund needs a manual check. Our team has been alerted." })
        .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
      await audit("refund.failed", order.id, { reason, attempts: refund.attempt });
      console.error(`[refund] ${order.reference} FAILED after ${refund.attempt} attempts: ${reason}`);
      return;
    }
    // Nothing moved. Try again with the next attempt number (a new idempotency key).
    await db
      .update(refunds)
      .set({ status: "PENDING", circleTransactionId: null, attempt: refund.attempt + 1, lastError: reason })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")));
    return;
  }
  if (tx.state !== "COMPLETE") return;

  const [done] = await db
    .update(refunds)
    .set({ status: "CONFIRMED", txHash: tx.txHash ?? null, confirmedAt: new Date() })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")))
    .returning();
  if (!done) return;
  await db
    .update(orders)
    .set({
      status: "REFUNDED",
      failureReason: `This order could not be delivered. ${microText(refund.amountMicro)} USDC was refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
  const journalId = randomUUID();
  await db.insert(ledgerEntries).values([
    // The customer's money goes back to them out of the treasury
    { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", debit: refund.amountMicro, memo: `Refund ${order.reference}` },
    { journalId, account: "treasury:usdc", orderId: order.id, currency: "USDC", credit: refund.amountMicro, memo: `Refund ${order.reference}` },
  ]);
  await audit("refund.confirmed", order.id, { txHash: tx.txHash, amountMicro: refund.amountMicro });
  sendOrderEmail(order, "refunded", tx.txHash ?? null);
}

export async function getRefundView(orderId: string) {
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, orderId)).limit(1);
  if (!refund) return null;
  return {
    status: refund.status,
    amount: microText(refund.amountMicro),
    txHash: refund.txHash,
    explorerUrl: refund.txHash ? `${env.EXPLORER_TX_URL}${refund.txHash}` : null,
  };
}
