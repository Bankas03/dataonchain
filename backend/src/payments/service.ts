// Paying for an order with USDC, and verifying the payment.
//
// Order:   QUOTED -> PAYMENT_PENDING -> PAYMENT_CONFIRMED   (or FAILED / FLAGGED)
// Payment: INITIATED -> PENDING -> CONFIRMED                (or FAILED / MISMATCH)
//
// Every status change is conditional ("only if it is still X"), so two
// requests at the same time can never pay twice or confirm twice.
import { createHash, randomUUID } from "node:crypto";
import { and, count, desc, eq, gte, inArray, isNotNull, isNull, lt, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { isUniqueViolation } from "../db/errors";
import { auditLogs, dataPlans, ledgerEntries, orders, payments, wallets } from "../db/schema";
import { env } from "../env";
import { fulfilOrder, getDeliveryView, reconcileOrder } from "../fulfilment/service";
import { microToUsdc } from "../pricing/quote";
import { advanceRefund, getRefundView, startRefund } from "../refunds/service";
import { ensureUserWallet, previousWallet } from "../wallets/service";

export class PaymentError extends Error {
  constructor(message: string, public status: 400 | 402 | 404 | 409 = 400) {
    super(message);
  }
}

type Order = typeof orders.$inferSelect;
type Payment = typeof payments.$inferSelect;

const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
const STARTED = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"] as const;

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

// "0.075189" -> 75189. Returns null when the text is not an exact USDC amount.
export function usdcToMicro(amount: string): number | null {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return null;
  const frac = (m[2] ?? "").padEnd(6, "0");
  if (/[1-9]/.test(frac.slice(6))) return null;
  return Number(m[1]) * 1_000_000 + Number(frac.slice(0, 6));
}

// Same, but rounds down extra digits (for balances).
function usdcToMicroFloor(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

export type TransferFacts = {
  state?: string;
  destinationAddress?: string;
  amounts?: string[];
  tokenId?: string;
  blockchain?: string;
  txHash?: string;
  errorReason?: string;
};

// Everything that must be true before a payment counts. Returns the problems found.
export function checkTransfer(
  tx: TransferFacts,
  expected: { destination: string; amountMicro: number; tokenId: string; blockchain: string },
): string[] {
  const problems: string[] = [];
  if (tx.state !== "COMPLETE") problems.push(`transfer state is ${tx.state ?? "unknown"}`);
  if ((tx.destinationAddress ?? "").toLowerCase() !== expected.destination.toLowerCase()) {
    problems.push("sent to the wrong address");
  }
  const sent = tx.amounts?.[0] !== undefined ? usdcToMicro(tx.amounts[0]) : null;
  if (sent !== expected.amountMicro) problems.push(`amount ${tx.amounts?.[0] ?? "missing"} does not match`);
  if (tx.tokenId && tx.tokenId !== expected.tokenId) problems.push("wrong token");
  if (tx.blockchain && tx.blockchain !== expected.blockchain) problems.push("wrong network");
  if (!tx.txHash) problems.push("no transaction hash");
  return problems;
}

async function usdcOf(circleWalletId: string): Promise<{ tokenId: string; balanceMicro: number } | null> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!usdc?.token?.id) return null;
  return { tokenId: usdc.token.id, balanceMicro: usdcToMicroFloor(usdc.amount) };
}

async function findOrder(userId: string, reference: string): Promise<Order | undefined> {
  const [order] = await db
    .select()
    .from(orders)
    .where(and(eq(orders.reference, reference), eq(orders.userId, userId)))
    .limit(1);
  return order;
}

async function audit(action: string, targetId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId, details });
}

export async function payOrder(userId: string, reference: string) {
  const order = await findOrder(userId, reference);
  if (!order) throw new PaymentError("Order not found.", 404);

  if ((STARTED as readonly string[]).includes(order.status)) return getOrderView(userId, reference);
  if (order.status !== "QUOTED") {
    throw new PaymentError(`This order can no longer be paid (it is ${order.status.toLowerCase().replace(/_/g, " ")}).`, 409);
  }
  if (order.quoteExpiresAt.getTime() < Date.now()) {
    await db.update(orders).set({ status: "EXPIRED" }).where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")));
    throw new PaymentError("This price has expired. Please get a new price.", 409);
  }

  const wallet = await ensureUserWallet(userId);
  const usdc = await usdcOf(wallet.circleWalletId);
  // Smart contract wallets: Circle Gas Station pays the network fee
  const gasFree = wallet.accountType === "SCA";
  const buffer = gasFree ? 0 : Math.round(env.PAYMENT_FEE_BUFFER_USDC * 1_000_000);
  const needed = order.usdcAmountMicro + buffer;
  if (!usdc || usdc.balanceMicro < needed) {
    const old = await previousWallet(userId);
    const oldBalance = old ? await usdcOf(old.circleWalletId) : null;
    if (oldBalance && oldBalance.balanceMicro >= 20_000) {
      throw new PaymentError(
        "Your USDC is being moved to your upgraded wallet. This takes about a minute. Please try again shortly.",
        409,
      );
    }
    throw new PaymentError(
      `Not enough USDC. You need ${microToUsdc(needed)} USDC${gasFree ? "" : " (price plus network fee)"}. Your balance is ${microToUsdc(usdc?.balanceMicro ?? 0)} USDC.`,
      402,
    );
  }

  // Claim the order. Only one request can win this.
  const [claimed] = await db
    .update(orders)
    .set({ status: "PAYMENT_PENDING" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")))
    .returning();
  if (!claimed) return getOrderView(userId, reference);

  const [payment] = await db
    .insert(payments)
    .values({
      orderId: order.id,
      walletId: wallet.id,
      fromAddress: wallet.address,
      toAddress: env.TREASURY_ADDRESS,
      token: usdc.tokenId,
      blockchain: wallet.blockchain,
      amountMicro: order.usdcAmountMicro,
      status: "INITIATED",
    })
    .returning();
  if (!payment) throw new Error("Could not save the payment");

  const amount = microToUsdc(order.usdcAmountMicro);
  const input = {
    walletId: wallet.circleWalletId,
    tokenId: usdc.tokenId,
    destinationAddress: env.TREASURY_ADDRESS,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    // Same key for the same order: a retry can never send a second transfer.
    idempotencyKey: uuidFrom(`pay:${order.id}`),
    refId: order.reference,
  };

  let transactionId: string | undefined;
  for (let attempt = 0; attempt < 2 && !transactionId; attempt++) {
    try {
      const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
      transactionId = res.data?.id;
    } catch (err) {
      const detail = (err as { response?: { data?: unknown } }).response?.data;
      console.error(`[pay] ${order.reference} attempt ${attempt + 1} failed:`, err instanceof Error ? err.message : err, detail ?? "");
    }
  }

  if (!transactionId) {
    // Circle may have taken the transfer even though its answer was lost: look for it
    try {
      transactionId = (await findCircleTransfer(order, { ...payment, walletId: wallet.id })) ?? undefined;
    } catch (err) {
      console.error(`[pay] ${order.reference} lookup failed:`, err instanceof Error ? err.message : err);
    }
  }
  if (!transactionId) {
    await db.update(payments).set({ status: "FAILED" }).where(eq(payments.id, payment.id));
    await db.update(orders).set({ status: "QUOTED" }).where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    throw new PaymentError(
      "We could not start the payment. Please try again. If any USDC did leave your wallet, it is matched to this order automatically within a few minutes.",
      409,
    );
  }

  await db
    .update(payments)
    .set({ circleTransactionId: transactionId, status: "PENDING" })
    .where(eq(payments.id, payment.id));
  return getOrderView(userId, reference);
}

// Looks on Circle for the transfer of this order (by its reference), in case
// Circle took it but its answer never reached us. Returns the Circle id or null.
async function findCircleTransfer(order: Order, payment: Pick<Payment, "walletId" | "createdAt">): Promise<string | null> {
  if (!payment.walletId) return null;
  const [w] = await db.select({ circleWalletId: wallets.circleWalletId }).from(wallets).where(eq(wallets.id, payment.walletId)).limit(1);
  if (!w) return null;
  const res = await circle.listTransactions({
    walletIds: [w.circleWalletId],
    from: new Date(payment.createdAt.getTime() - 5 * 60_000).toISOString(),
    pageSize: 50,
  } as unknown as Parameters<typeof circle.listTransactions>[0]);
  const list = (res.data?.transactions ?? []) as unknown as { id?: string; refId?: string }[];
  return list.find((t) => t.refId === order.reference)?.id ?? null;
}

// Worker step (every few minutes): payments whose start was interrupted (server
// restart, or Circle's answer was lost). If Circle has the transfer, it is linked
// and the order continues as normal (delivered, or refunded). If Circle never got
// it, an interrupted payment is closed so the customer can simply pay again.
const RECOVER_AFTER_MS = 2 * 60_000;
const RECOVER_WINDOW_MS = 24 * 60 * 60_000;

export async function recoverInterruptedPayments(): Promise<number> {
  const now = Date.now();
  const rows = await db
    .select({ payment: payments, order: orders })
    .from(payments)
    .innerJoin(orders, eq(payments.orderId, orders.id))
    .where(
      and(
        isNull(payments.circleTransactionId),
        inArray(payments.status, ["INITIATED", "FAILED"]),
        lt(payments.createdAt, new Date(now - RECOVER_AFTER_MS)),
        gte(payments.createdAt, new Date(now - RECOVER_WINDOW_MS)),
        inArray(orders.status, ["QUOTED", "EXPIRED", "PAYMENT_PENDING"]),
      ),
    )
    .orderBy(desc(payments.createdAt))
    .limit(20);
  let linked = 0;
  for (const { payment, order } of rows) {
    // Another payment of this order already holds the Circle transfer: nothing to recover
    const [other] = await db
      .select({ id: payments.id })
      .from(payments)
      .where(and(eq(payments.orderId, order.id), isNotNull(payments.circleTransactionId)))
      .limit(1);
    if (other) {
      if (payment.status === "INITIATED") {
        await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "INITIATED")));
      }
      continue;
    }
    let circleId: string | null;
    try {
      circleId = await findCircleTransfer(order, payment);
    } catch (err) {
      console.error(`[pay] recovery lookup for ${order.reference} failed:`, err instanceof Error ? err.message : err);
      continue;
    }
    if (circleId) {
      let done: Payment | undefined;
      try {
        [done] = await db
          .update(payments)
          .set({ circleTransactionId: circleId, status: "PENDING" })
          .where(and(eq(payments.id, payment.id), isNull(payments.circleTransactionId)))
          .returning();
      } catch (err) {
        if (isUniqueViolation(err)) continue; // linked elsewhere already
        throw err;
      }
      if (!done) continue;
      await db
        .update(orders)
        .set({ status: "PAYMENT_PENDING", failureReason: null })
        .where(and(eq(orders.id, order.id), inArray(orders.status, ["QUOTED", "EXPIRED", "PAYMENT_PENDING"])));
      await audit("payment.recovered", order.id, { paymentId: payment.id, circleTransactionId: circleId });
      console.log(`[pay] ${order.reference}: found its transfer on Circle (${circleId}), continuing`);
      linked++;
    } else if (payment.status === "INITIATED") {
      // Circle never received it: nothing left the wallet. Let the customer pay again.
      await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "INITIATED")));
      await db
        .update(orders)
        .set({ status: order.quoteExpiresAt.getTime() < now ? "EXPIRED" : "QUOTED" })
        .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    }
  }
  return linked;
}

// Checks a pending payment with Circle and moves the order forward.
export async function refreshPayment(order: Order): Promise<void> {
  if (order.status !== "PAYMENT_PENDING") return;
  const [payment] = await db
    .select()
    .from(payments)
    .where(and(eq(payments.orderId, order.id), eq(payments.status, "PENDING")))
    .orderBy(desc(payments.createdAt))
    .limit(1);
  if (!payment?.circleTransactionId) return;

  const res = await circle.getTransaction({ id: payment.circleTransactionId });
  const tx = res.data?.transaction as unknown as TransferFacts | undefined;
  if (!tx?.state) return;

  if (FAILED_STATES.includes(tx.state)) {
    await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "PENDING")));
    await db
      .update(orders)
      .set({ status: "FAILED", failureReason: `Payment ${tx.state.toLowerCase()}${tx.errorReason ? `: ${tx.errorReason}` : ""}. No money left your wallet.` })
      .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    return;
  }
  if (tx.state !== "COMPLETE") return;

  const problems = checkTransfer(tx, {
    destination: env.TREASURY_ADDRESS,
    amountMicro: order.usdcAmountMicro,
    tokenId: payment.token,
    blockchain: payment.blockchain,
  });
  if (problems.length > 0) {
    await flag(order, payment, problems.join("; "), tx);
    return;
  }

  let confirmed: Payment | undefined;
  try {
    [confirmed] = await db
      .update(payments)
      .set({ status: "CONFIRMED", txHash: tx.txHash, confirmedAt: new Date() })
      .where(and(eq(payments.id, payment.id), eq(payments.status, "PENDING")))
      .returning();
  } catch (err) {
    if (isUniqueViolation(err)) {
      await flag(order, payment, "transaction hash was already used by another payment", tx);
      return;
    }
    throw err;
  }
  if (!confirmed) return; // another request confirmed it first

  await db
    .update(orders)
    .set({ status: "PAYMENT_CONFIRMED" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));

  const journalId = randomUUID();
  await db.insert(ledgerEntries).values([
    { journalId, account: "treasury:usdc", orderId: order.id, currency: "USDC", debit: order.usdcAmountMicro, memo: `Payment ${order.reference}` },
    { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", credit: order.usdcAmountMicro, memo: `Payment ${order.reference}` },
  ]);

  // Paid: deliver right away (the worker picks it up too if this fails)
  void fulfilOrder(order.id).catch((err) => console.error(`[deliver] ${order.reference} failed:`, err));
}

async function flag(order: Order, payment: Payment, reason: string, tx: TransferFacts) {
  await db.update(payments).set({ status: "MISMATCH", txHash: null }).where(eq(payments.id, payment.id));
  await db
    .update(orders)
    .set({ status: "FLAGGED", failureReason: `Payment needs review: ${reason}` })
    .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
  await audit("payment.flagged", order.id, { reason, transaction: tx });
  console.error(`[pay] ${order.reference} FLAGGED: ${reason}`);
}

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

export async function getOrderView(userId: string, reference: string) {
  let order = await findOrder(userId, reference);
  if (!order) return null;

  if (order.status === "PAYMENT_PENDING") {
    try {
      await refreshPayment(order);
    } catch (err) {
      console.error(`[pay] refresh ${reference} failed:`, err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FLAGGED"].includes(order.status)) {
    try {
      if (order.status === "PAYMENT_CONFIRMED") await fulfilOrder(order.id);
      else await reconcileOrder(order.id);
    } catch (err) {
      console.error(`[deliver] check ${reference} failed:`, err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (order.status === "FAILED" || order.status === "REFUND_PENDING") {
    try {
      if (order.status === "FAILED") await startRefund(order.id);
      else await advanceRefund(order.id);
    } catch (err) {
      console.error(`[refund] check ${reference} failed:`, err instanceof Error ? err.message : err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (order.status === "QUOTED" && order.quoteExpiresAt.getTime() < Date.now()) {
    await db.update(orders).set({ status: "EXPIRED" }).where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")));
    order = { ...order, status: "EXPIRED" };
  }

  const [plan] = order.planId
    ? await db.select({ name: dataPlans.name }).from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1)
    : [];
  const [payment] = await db
    .select()
    .from(payments)
    .where(eq(payments.orderId, order.id))
    .orderBy(desc(payments.createdAt))
    .limit(1);

  return {
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName: plan?.name ?? null,
    planId: order.planId,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    expiresAt: order.quoteExpiresAt.toISOString(),
    createdAt: order.createdAt.toISOString(),
    failureReason: order.failureReason,
    delivery: await getDeliveryView(order.id),
    refund: await getRefundView(order.id),
    payment: payment
      ? {
          status: payment.status,
          txHash: payment.txHash,
          explorerUrl: payment.txHash ? `${env.EXPLORER_TX_URL}${payment.txHash}` : null,
        }
      : null,
  };
}

export async function listOrders(userId: string) {
  const rows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.userId, userId), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(20);
  return rows.map(({ order, planName }) => ({
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName: planName ?? null,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    createdAt: order.createdAt.toISOString(),
  }));
}

// Full order history for the History page: 25 per page, optional status filter.
const HISTORY_PAGE = 25;
const HISTORY_GROUPS: Record<string, readonly Order["status"][]> = {
  delivered: ["FULFILLED"],
  refunded: ["REFUNDED", "REFUND_PENDING"],
  failed: ["FAILED"],
  open: ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FLAGGED"],
};

export async function orderHistory(userId: string, page: number, group?: string) {
  const statuses = group && HISTORY_GROUPS[group] ? [...HISTORY_GROUPS[group]!] : null;
  const where = and(
    eq(orders.userId, userId),
    notInArray(orders.status, ["QUOTED", "EXPIRED"]),
    statuses ? inArray(orders.status, statuses) : undefined,
  );
  const [total] = await db.select({ n: count() }).from(orders).where(where);
  const rows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(where)
    .orderBy(desc(orders.createdAt))
    .limit(HISTORY_PAGE)
    .offset((page - 1) * HISTORY_PAGE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: HISTORY_PAGE,
    orders: rows.map(({ order, planName }) => ({
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: microToUsdc(order.usdcAmountMicro),
      createdAt: order.createdAt.toISOString(),
    })),
  };
}

// Every order as a CSV file (up to 5,000), for the "Download CSV" button.
export async function orderHistoryCsv(userId: string): Promise<string> {
  const rows = await db
    .select({ order: orders, planName: dataPlans.name, txHash: payments.txHash })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .leftJoin(payments, and(eq(payments.orderId, orders.id), eq(payments.status, "CONFIRMED")))
    .where(and(eq(orders.userId, userId), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(5000);
  const cell = (v: string | number | null) => {
    const t = v === null ? "" : String(v);
    // Quote every cell; a leading = + - @ is neutralised so spreadsheets never run it as a formula
    return `"${(/^[=+\-@]/.test(t) ? `'${t}` : t).replace(/"/g, '""')}"`;
  };
  const lines = [
    ["Date (Lagos)", "Reference", "Type", "Network", "Plan", "Phone", "Naira value", "USDC paid", "Status", "Payment transaction"].map(cell).join(","),
    ...rows.map(({ order, planName, txHash }) =>
      [
        order.createdAt.toLocaleString("en-GB", { timeZone: "Africa/Lagos" }),
        order.reference,
        order.serviceType,
        order.network,
        planName,
        localPhone(order.phone),
        (order.ngnAmountKobo / 100).toFixed(2),
        microToUsdc(order.usdcAmountMicro),
        order.status,
        txHash,
      ]
        .map(cell)
        .join(","),
    ),
  ];
  return `${lines.join("\r\n")}\r\n`;
}

// Used by the background worker later: every order still waiting for its payment.
export async function pendingPaymentOrders(): Promise<Order[]> {
  return db.select().from(orders).where(inArray(orders.status, ["PAYMENT_PENDING"])).limit(100);
}
