// Delivering paid orders through VTpass.
//
// Order: PAYMENT_CONFIRMED -> FULFILMENT_PENDING -> FULFILLED  (or FAILED / FLAGGED)
// VTU:   SENT -> DELIVERED                                     (or PENDING / FAILED)
//
// Golden rule: each order is sent to VTpass at most ONCE, with one request id.
// When the answer is unclear we ask VTpass again (requery). We never resend,
// so a customer can never receive twice.
//
// A FAILED order (money taken, nothing delivered) is refunded automatically.
import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray } from "drizzle-orm";
import { db } from "../db";
import { auditLogs, dataPlans, ledgerEntries, orders, vtuTransactions } from "../db/schema";
import { sendOrderEmail } from "../email/receipts";
import { startRefund } from "../refunds/service";
import { SERVICE_IDS, makeRequestId, purchase, requery, type VtOutcome } from "../vtpass/client";

// How long to wait before asking VTpass again about an unclear purchase
const REQUERY_AFTER_MS = 8_000;
// Orders under review are asked about less often, for up to 3 days
const FLAGGED_REQUERY_AFTER_MS = 5 * 60_000;
const FLAGGED_GIVE_UP_MS = 3 * 24 * 60 * 60_000;
// VTpass says it never received the request (code 015) for this long: it failed
const NOT_FOUND_FAIL_AFTER_MS = 5 * 60_000;
// Still unclear after this long: put the order under review
const FLAG_AFTER_MS = 30 * 60_000;

const OPEN_VTU = ["SENT", "PENDING", "UNKNOWN"] as const;
// Orders whose delivery can still be settled by VTpass
const OPEN_ORDER = ["FULFILMENT_PENDING", "FLAGGED"] as const;

type Order = typeof orders.$inferSelect;
type VtuTx = typeof vtuTransactions.$inferSelect;

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

function usdcText(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

async function audit(action: string, orderId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId: orderId, details });
}

export async function fulfilOrder(orderId: string): Promise<void> {
  // Claim the order. Only one caller (web request or worker) can win.
  const [order] = await db
    .update(orders)
    .set({ status: "FULFILMENT_PENDING" })
    .where(and(eq(orders.id, orderId), eq(orders.status, "PAYMENT_CONFIRMED")))
    .returning();
  if (!order) return;

  const phone = localPhone(order.phone);
  let payload: Record<string, unknown>;
  if (order.serviceType === "data") {
    const [plan] = order.planId
      ? await db.select().from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1)
      : [];
    if (!plan) {
      await failOrder(order, "the data plan is no longer available");
      return;
    }
    payload = {
      serviceID: SERVICE_IDS.data[order.network],
      billersCode: phone,
      variation_code: plan.planCode,
      amount: Math.round(plan.priceKobo / 100),
      phone,
    };
  } else {
    payload = {
      serviceID: SERVICE_IDS.airtime[order.network],
      amount: Math.round(order.ngnAmountKobo / 100),
      phone,
    };
  }

  const requestId = makeRequestId();
  payload = { request_id: requestId, ...payload };
  const [tx] = await db
    .insert(vtuTransactions)
    .values({ orderId: order.id, provider: "vtpass", requestId, status: "SENT", requestPayload: payload })
    .returning();
  if (!tx) throw new Error("Could not save the VTpass request");

  const started = Date.now();
  const outcome = await purchase(payload);
  console.log(`[vtpass] ${order.reference} pay -> ${outcome.result} ${outcome.code} ${outcome.message} (${Date.now() - started} ms)`);
  await applyOutcome(order, tx, outcome);
}

async function applyOutcome(order: Order, tx: VtuTx, outcome: VtOutcome): Promise<void> {
  if (outcome.result === "DELIVERED") {
    const [done] = await db
      .update(vtuTransactions)
      .set({ status: "DELIVERED", providerReference: outcome.providerReference ?? null, responsePayload: outcome.raw })
      .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])))
      .returning();
    if (!done) return;
    const [fulfilled] = await db
      .update(orders)
      .set({ status: "FULFILLED", failureReason: null })
      .where(and(eq(orders.id, order.id), inArray(orders.status, [...OPEN_ORDER])))
      .returning();
    if (!fulfilled) return;
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      // The customer's payment becomes a completed sale
      { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", debit: order.usdcAmountMicro, memo: `Delivered ${order.reference}` },
      { journalId, account: "revenue:sales", orderId: order.id, currency: "USDC", credit: order.usdcAmountMicro, memo: `Delivered ${order.reference}` },
      // VTpass took the naira cost from our float
      { journalId, account: "cost:vtu", orderId: order.id, currency: "NGN", debit: order.ngnAmountKobo, memo: `VTpass ${tx.requestId}` },
      { journalId, account: "vtpass:float", orderId: order.id, currency: "NGN", credit: order.ngnAmountKobo, memo: `VTpass ${tx.requestId}` },
    ]);
    sendOrderEmail(order, "delivered");
    return;
  }

  if (outcome.result === "FAILED") {
    const [closed] = await db
      .update(vtuTransactions)
      .set({ status: "FAILED", providerReference: outcome.providerReference ?? null, responsePayload: outcome.raw })
      .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])))
      .returning();
    if (!closed) return;
    if (outcome.code === "018") console.error("[vtpass] code 018: the VTpass wallet balance is too low. Fund it.");
    if (outcome.code === "027") console.error("[vtpass] code 027: this server's IP address is not whitelisted on VTpass");
    if (outcome.code === "028") console.error("[vtpass] code 028: this product is not whitelisted on the VTpass account (Account Settings > Whitelist Products)");
    await failOrder(order, outcome.message);
    return;
  }

  // PENDING: keep the order waiting; it will be asked about again.
  await db
    .update(vtuTransactions)
    .set({
      status: "PENDING",
      providerReference: outcome.providerReference ?? tx.providerReference,
      responsePayload: outcome.raw ?? tx.responsePayload,
      attempt: tx.attempt + 1,
    })
    .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])));
}

async function failOrder(order: Order, reason: string) {
  const [failed] = await db
    .update(orders)
    .set({
      status: "FAILED",
      failureReason: `Delivery failed (${reason}). Your ${usdcText(order.usdcAmountMicro)} USDC is being refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), inArray(orders.status, [...OPEN_ORDER])))
    .returning();
  if (!failed) return;
  await audit("delivery.failed", order.id, { reason });
  try {
    await startRefund(order.id);
  } catch (err) {
    // The worker tries again in 30 seconds
    console.error(`[refund] ${order.reference} could not start yet:`, err instanceof Error ? err.message : err);
  }
}

// Moves an unsettled order forward by asking VTpass about it.
// Works for FULFILMENT_PENDING orders and for FLAGGED orders that were
// flagged because VTpass gave no clear answer.
// force: an admin asked to check now, so the waiting times are skipped.
export async function reconcileOrder(orderId: string, force = false): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || !(OPEN_ORDER as readonly string[]).includes(order.status)) return;

  const [tx] = await db
    .select()
    .from(vtuTransactions)
    .where(eq(vtuTransactions.orderId, order.id))
    .orderBy(desc(vtuTransactions.createdAt))
    .limit(1);

  if (!tx) {
    // Claimed but nothing was ever sent (for example the server restarted).
    // Safe to hand back for a first and only attempt.
    if (order.status === "FULFILMENT_PENDING" && Date.now() - order.updatedAt.getTime() > 60_000) {
      await db
        .update(orders)
        .set({ status: "PAYMENT_CONFIRMED" })
        .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")));
    }
    return;
  }
  if (!(OPEN_VTU as readonly string[]).includes(tx.status)) return;

  const age = Date.now() - tx.createdAt.getTime();
  const sinceLastAsk = Date.now() - tx.updatedAt.getTime();
  if (force) {
    // checked right away
  } else if (order.status === "FLAGGED") {
    if (age > FLAGGED_GIVE_UP_MS || sinceLastAsk < FLAGGED_REQUERY_AFTER_MS) return;
  } else if (sinceLastAsk < REQUERY_AFTER_MS) {
    return;
  }

  let outcome = await requery(tx.requestId);
  if (outcome.result !== "PENDING" || outcome.notFound) {
    console.log(`[vtpass] ${order.reference} requery -> ${outcome.result} ${outcome.code} ${outcome.message}`);
  }
  if (outcome.notFound && age > NOT_FOUND_FAIL_AFTER_MS) {
    // VTpass never received this purchase, so nothing was delivered.
    outcome = { ...outcome, result: "FAILED", message: "VTpass did not receive the purchase" };
  }
  await applyOutcome(order, tx, outcome);

  if (outcome.result === "PENDING" && order.status === "FULFILMENT_PENDING" && age > FLAG_AFTER_MS) {
    const [flagged] = await db
      .update(orders)
      .set({
        status: "FLAGGED",
        failureReason: "Your purchase is taking longer than usual. We are checking with the network and will deliver or refund it automatically.",
      })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")))
      .returning();
    if (flagged) await audit("delivery.flagged", order.id, { requestId: tx.requestId, last: outcome.message });
  }
}

export async function getDeliveryView(orderId: string) {
  const [tx] = await db
    .select()
    .from(vtuTransactions)
    .where(eq(vtuTransactions.orderId, orderId))
    .orderBy(desc(vtuTransactions.createdAt))
    .limit(1);
  if (!tx) return null;
  const raw = (tx.responsePayload ?? {}) as { purchased_code?: string; response_description?: string };
  return {
    status: tx.status,
    providerReference: tx.providerReference,
    requestId: tx.requestId,
    token: raw.purchased_code ? String(raw.purchased_code) : null,
    message: raw.response_description ?? null,
  };
}
