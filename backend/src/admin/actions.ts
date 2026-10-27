// Things the admin can do from the dashboard. Each one is small, safe to
// repeat, and written to the audit log with the admin as the actor.
import { and, eq } from "drizzle-orm";
import { db } from "../db";
import { approvedDestinations, orders, payments, refunds, sessions, users } from "../db/schema";
import { reconcileOrder } from "../fulfilment/service";
import { advanceRefund, startRefund } from "../refunds/service";
import { setPause, type PauseKey } from "../settings";
import { adminAudit } from "./auth";

export class AdminActionError extends Error {
  constructor(message: string, public status: 400 | 404 | 409 = 400) {
    super(message);
  }
}

async function findOrder(key: string) {
  const [order] = await db.select().from(orders).where(eq(orders.id, key)).limit(1);
  if (order) return order;
  const [byRef] = await db.select().from(orders).where(eq(orders.reference, key.toUpperCase())).limit(1);
  if (!byRef) throw new AdminActionError("Order not found.", 404);
  return byRef;
}

async function statusOf(orderId: string): Promise<string> {
  const [o] = await db.select({ status: orders.status }).from(orders).where(eq(orders.id, orderId)).limit(1);
  return o?.status ?? "UNKNOWN";
}

// Ask VTpass about the order right now (normally the worker waits between checks).
export async function recheckOrder(adminId: string, key: string) {
  const order = await findOrder(key);
  if (order.status !== "FULFILMENT_PENDING" && order.status !== "FLAGGED") {
    throw new AdminActionError("This order is not waiting for VTpass.", 409);
  }
  await reconcileOrder(order.id, true);
  const after = await statusOf(order.id);
  await adminAudit("admin.order_recheck", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// Start or push a refund. A refund that failed 3 times gets a new attempt:
// Circle never sent it (each attempt has its own idempotency key), so this
// cannot pay twice.
export async function retryRefund(adminId: string, key: string) {
  const order = await findOrder(key);
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);

  if (order.status === "FAILED") {
    const [paid] = await db
      .select({ id: payments.id })
      .from(payments)
      .where(and(eq(payments.orderId, order.id), eq(payments.status, "CONFIRMED")))
      .limit(1);
    if (!paid) throw new AdminActionError("This order was never paid, so there is nothing to refund.", 409);
    await startRefund(order.id);
  } else if (order.status === "REFUND_PENDING") {
    await advanceRefund(order.id);
  } else if (order.status === "FLAGGED" && refund?.status === "FAILED") {
    const [reopened] = await db
      .update(refunds)
      .set({ status: "PENDING", attempt: refund.attempt + 1, circleTransactionId: null, lastError: "Retried by the admin" })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "FAILED")))
      .returning();
    if (!reopened) throw new AdminActionError("The refund changed in the meantime. Reload and try again.", 409);
    await db
      .update(orders)
      .set({ status: "REFUND_PENDING" })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FLAGGED")));
    await advanceRefund(order.id);
  } else {
    throw new AdminActionError("There is no refund to retry for this order.", 409);
  }
  const after = await statusOf(order.id);
  await adminAudit("admin.refund_retry", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// Suspended users cannot log in to anything new (orders, bridge, swaps).
// Their orders already in progress still finish, and refunds still go out.
export async function setUserStatus(adminId: string, userId: string, status: unknown, reason: unknown) {
  if (status !== "active" && status !== "suspended") throw new AdminActionError("Choose active or suspended.");
  const note = typeof reason === "string" ? reason.trim().slice(0, 300) : "";
  if (status === "suspended" && !note) throw new AdminActionError("Write a short reason for the suspension.");
  const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
  if (!user) throw new AdminActionError("User not found.", 404);
  if (user.status === status) return { status };
  await db.update(users).set({ status }).where(eq(users.id, userId));
  if (status === "suspended") await db.delete(sessions).where(eq(sessions.userId, userId));
  await adminAudit(
    status === "suspended" ? "admin.user_suspended" : "admin.user_restored",
    { email: user.email, reason: note || null },
    adminId,
    { type: "user", id: userId },
  );
  return { status };
}

export async function setProviderActive(adminId: string, id: string, active: unknown) {
  if (typeof active !== "boolean") throw new AdminActionError("Choose on or off.");
  const [row] = await db.update(approvedDestinations).set({ active }).where(eq(approvedDestinations.id, id)).returning();
  if (!row) throw new AdminActionError("Provider not found.", 404);
  await adminAudit(active ? "admin.provider_enabled" : "admin.provider_disabled", { label: row.label, chain: row.chain, address: row.address }, adminId, {
    type: "destination",
    id,
  });
  return { active };
}

export async function setPauseSwitch(adminId: string, key: PauseKey, paused: unknown) {
  if (typeof paused !== "boolean") throw new AdminActionError("Choose paused or open.");
  await setPause(key, paused);
  await adminAudit(paused ? "admin.paused" : "admin.resumed", { what: key }, adminId, { type: "setting", id: key });
  return { [key]: paused };
}
