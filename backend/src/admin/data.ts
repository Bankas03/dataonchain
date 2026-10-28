// Read only views for the admin dashboard. Nothing here changes data.
import { and, count, desc, eq, gte, inArray, isNull, like, notInArray, or, sql, type SQL, type SQLWrapper } from "drizzle-orm";
import { db } from "../db";
import {
  ORDER_STATUSES,
  approvedDestinations,
  auditLogs,
  bridgeEvents,
  bridgeTransfers,
  dataPlans,
  exchangeRates,
  ledgerEntries,
  orders,
  payments,
  refunds,
  sends,
  swaps,
  users,
  vtuTransactions,
  walletSweeps,
  wallets,
  BRIDGE_STATUSES,
  REFUND_STATUSES,
  SWAP_STATUSES,
  SEND_STATUSES,
} from "../db/schema";
import { env } from "../env";
import { chainByKey, openChains, type BridgeChain } from "../bridge/chains";
import { findStuck } from "../bridge/monitor";
import { listChainWallets } from "../bridge/wallets";
import { tokenBalances } from "../swap/service";
import { getVtpassBalance } from "../vtpass/client";
import { getPauses } from "../settings";

export const PAGE_SIZE = 50;
const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;

// Alerts on the overview when balances run low
const LOW_TREASURY_USDC = 5;
const LOW_VTPASS_NGN = 5_000;

export const OPEN_ORDER_STATUSES = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"] as const;
const OPEN_BRIDGE_STATUSES = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"] as const;

export function pageOf(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 && n < 100_000 ? n : 1;
}

export const usdcText = (micro: number) =>
  `${micro < 0 ? "-" : ""}${Math.floor(Math.abs(micro) / 1_000_000)}.${String(Math.abs(micro) % 1_000_000).padStart(6, "0")}`;
const iso = (d: Date | null | undefined) => (d ? d.toISOString() : null);
const arcTx = (hash: string | null | undefined) => (hash ? `${env.EXPLORER_TX_URL}${hash}` : null);
const arcAddress = (address: string) => `${env.EXPLORER_TX_URL.replace(/\/tx\/?$/, "/address/")}${address}`;
const localPhone = (phone: string) => (phone.startsWith("+234") ? `0${phone.slice(4)}` : phone);

function safeChain(key: string | null | undefined): BridgeChain | null {
  if (!key) return null;
  try {
    return chainByKey(key);
  } catch {
    return null;
  }
}

function withTimeout<T>(p: Promise<T>, ms = 8_000): Promise<T> {
  return Promise.race([p, new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), ms))]);
}

// Turns what the admin typed into a LIKE pattern. "08031234567" also finds "+2348031234567".
function searchTerms(q: string): string[] {
  const t = q.trim().slice(0, 100);
  const out = [`%${t}%`];
  if (/^0\d{6,}$/.test(t)) out.push(`%+234${t.slice(1)}%`);
  return out;
}

function sumSince(column: SQLWrapper, createdAt: SQLWrapper, since: number) {
  return sql<number>`coalesce(sum(case when ${createdAt} >= ${since} then ${column} else 0 end), 0)`.mapWith(Number);
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------
export async function overview() {
  const now = Date.now();
  const d1 = now - DAY;
  const d7 = now - 7 * DAY;
  const d30 = now - 30 * DAY;
  const one = sql`1`;

  const [u] = await db
    .select({
      total: count(),
      verified: sql<number>`coalesce(sum(case when ${users.emailVerified} = 1 then 1 else 0 end), 0)`.mapWith(Number),
      suspended: sql<number>`coalesce(sum(case when ${users.status} = 'suspended' then 1 else 0 end), 0)`.mapWith(Number),
      new1: sumSince(one, users.createdAt, d1),
      new7: sumSince(one, users.createdAt, d7),
      new30: sumSince(one, users.createdAt, d30),
    })
    .from(users);

  const [v] = await db
    .select({
      count: count(),
      usdc: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(${orders.ngnAmountKobo}), 0)`.mapWith(Number),
      margin: sql<number>`coalesce(sum(${orders.marginKobo}), 0)`.mapWith(Number),
      count1: sumSince(one, orders.createdAt, d1),
      count7: sumSince(one, orders.createdAt, d7),
      count30: sumSince(one, orders.createdAt, d30),
      usdc1: sumSince(orders.usdcAmountMicro, orders.createdAt, d1),
      usdc7: sumSince(orders.usdcAmountMicro, orders.createdAt, d7),
      usdc30: sumSince(orders.usdcAmountMicro, orders.createdAt, d30),
      ngn1: sumSince(orders.ngnAmountKobo, orders.createdAt, d1),
      ngn7: sumSince(orders.ngnAmountKobo, orders.createdAt, d7),
      ngn30: sumSince(orders.ngnAmountKobo, orders.createdAt, d30),
      margin30: sumSince(orders.marginKobo, orders.createdAt, d30),
    })
    .from(orders)
    .where(eq(orders.status, "FULFILLED"));

  const byStatus = await db
    .select({ status: orders.status, n: count() })
    .from(orders)
    .groupBy(orders.status);

  const refundRows = await db
    .select({ status: refunds.status, n: count(), micro: sql<number>`coalesce(sum(${refunds.amountMicro}), 0)`.mapWith(Number) })
    .from(refunds)
    .groupBy(refunds.status);

  const [b] = await db
    .select({
      complete: count(),
      micro: sql<number>`coalesce(sum(${bridgeTransfers.amountMicro}), 0)`.mapWith(Number),
      complete30: sumSince(one, bridgeTransfers.createdAt, d30),
      micro30: sumSince(bridgeTransfers.amountMicro, bridgeTransfers.createdAt, d30),
    })
    .from(bridgeTransfers)
    .where(eq(bridgeTransfers.status, "COMPLETE"));
  const [bOpen] = await db.select({ n: count() }).from(bridgeTransfers).where(inArray(bridgeTransfers.status, [...OPEN_BRIDGE_STATUSES]));
  let stuck = 0;
  try {
    stuck = (await findStuck()).length;
  } catch {
    stuck = 0;
  }

  const swapRows = await db.select().from(swaps).where(and(eq(swaps.status, "COMPLETE"), gte(swaps.createdAt, new Date(d30))));
  const swapFees: Record<string, number> = {};
  const swapVolume: Record<string, number> = {};
  for (const s of swapRows) {
    const amount = Number(s.amountIn);
    if (!Number.isFinite(amount)) continue;
    swapVolume[s.tokenIn] = (swapVolume[s.tokenIn] ?? 0) + amount;
    swapFees[s.tokenIn] = (swapFees[s.tokenIn] ?? 0) + (amount * s.feeBps) / 10_000;
  }
  const [sAll] = await db.select({ n: count() }).from(swaps).where(eq(swaps.status, "COMPLETE"));
  const [sUnknown] = await db.select({ n: count() }).from(swaps).where(eq(swaps.status, "UNKNOWN"));

  // Last 14 days, by Lagos date
  const since14 = now - 14 * DAY;
  const lagosDay = (col: SQLWrapper) => sql<string>`date(${col} / 1000 + 3600, 'unixepoch')`;
  const orderDays = await db
    .select({
      day: lagosDay(orders.createdAt),
      n: count(),
      usdc: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(${orders.ngnAmountKobo}), 0)`.mapWith(Number),
    })
    .from(orders)
    .where(and(eq(orders.status, "FULFILLED"), gte(orders.createdAt, new Date(since14))))
    .groupBy(lagosDay(orders.createdAt));
  const userDays = await db
    .select({ day: lagosDay(users.createdAt), n: count() })
    .from(users)
    .where(gte(users.createdAt, new Date(since14)))
    .groupBy(lagosDay(users.createdAt));
  const days = [];
  for (let i = 13; i >= 0; i--) {
    const day = new Date(now - i * DAY + HOUR).toISOString().slice(0, 10);
    const o = orderDays.find((r) => r.day === day);
    const n = userDays.find((r) => r.day === day);
    days.push({ day, orders: o?.n ?? 0, usdc: usdcText(o?.usdc ?? 0), ngn: (o?.ngn ?? 0) / 100, newUsers: n?.n ?? 0 });
  }

  // Live balances (slow services must not hold the page)
  const [treasury, vtpass] = await Promise.allSettled([
    withTimeout(tokenBalances(env.TREASURY_WALLET_ID)),
    withTimeout(getVtpassBalance()),
  ]);
  const treasuryBalances = treasury.status === "fulfilled" ? treasury.value : null;
  const vtpassBalance = vtpass.status === "fulfilled" ? vtpass.value : null;

  const statusCount = (s: string) => byStatus.find((r) => r.status === s)?.n ?? 0;
  const refundCount = (s: string) => refundRows.find((r) => r.status === s)?.n ?? 0;

  const issues: { text: string; href: string }[] = [];
  if (statusCount("FLAGGED")) issues.push({ text: `${statusCount("FLAGGED")} order(s) need review (flagged)`, href: "/orders?status=FLAGGED" });
  if (refundCount("FAILED")) issues.push({ text: `${refundCount("FAILED")} refund(s) failed and need a retry`, href: "/refunds?status=FAILED" });
  if (statusCount("REFUND_PENDING")) issues.push({ text: `${statusCount("REFUND_PENDING")} refund(s) in progress`, href: "/orders?status=REFUND_PENDING" });
  if (stuck) issues.push({ text: `${stuck} bridge transfer(s) stuck`, href: "/bridge?status=open" });
  if (sUnknown?.n) issues.push({ text: `${sUnknown.n} swap(s) interrupted, check onchain`, href: "/swaps?status=UNKNOWN" });
  if (treasuryBalances && Number(treasuryBalances.USDC) < LOW_TREASURY_USDC) {
    issues.push({ text: `Treasury is low: ${treasuryBalances.USDC} USDC (refunds need USDC)`, href: "/settings" });
  }
  if (treasury.status === "rejected") issues.push({ text: "Could not read the treasury balance from Circle", href: "/settings" });
  if (vtpassBalance !== null && vtpassBalance < LOW_VTPASS_NGN) {
    issues.push({ text: `VTpass wallet is low: ₦${vtpassBalance.toLocaleString("en-NG")}`, href: "/settings" });
  }
  if (vtpass.status === "rejected") issues.push({ text: "Could not read the VTpass balance", href: "/settings" });

  return {
    generatedAt: new Date().toISOString(),
    testnet: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET"),
    vtpassSandbox: env.VTPASS_BASE_URL.includes("sandbox"),
    pauses: await getPauses(),
    users: { total: u?.total ?? 0, verified: u?.verified ?? 0, suspended: u?.suspended ?? 0, new1: u?.new1 ?? 0, new7: u?.new7 ?? 0, new30: u?.new30 ?? 0 },
    volume: {
      orders: { all: v?.count ?? 0, d1: v?.count1 ?? 0, d7: v?.count7 ?? 0, d30: v?.count30 ?? 0 },
      usdc: { all: usdcText(v?.usdc ?? 0), d1: usdcText(v?.usdc1 ?? 0), d7: usdcText(v?.usdc7 ?? 0), d30: usdcText(v?.usdc30 ?? 0) },
      ngn: { all: (v?.ngn ?? 0) / 100, d1: (v?.ngn1 ?? 0) / 100, d7: (v?.ngn7 ?? 0) / 100, d30: (v?.ngn30 ?? 0) / 100 },
      marginNgn: { all: (v?.margin ?? 0) / 100, d30: (v?.margin30 ?? 0) / 100 },
    },
    ordersByStatus: Object.fromEntries(byStatus.map((r) => [r.status, r.n])),
    refunds: Object.fromEntries(refundRows.map((r) => [r.status, { count: r.n, usdc: usdcText(r.micro) }])),
    bridge: {
      enabled: env.BRIDGE_ENABLED,
      complete: b?.complete ?? 0,
      usdc: usdcText(b?.micro ?? 0),
      complete30: b?.complete30 ?? 0,
      usdc30: usdcText(b?.micro30 ?? 0),
      open: bOpen?.n ?? 0,
      stuck,
    },
    swaps: { enabled: env.SWAP_ENABLED, complete: sAll?.n ?? 0, complete30: swapRows.length, volume30: swapVolume, fees30: swapFees, unknown: sUnknown?.n ?? 0 },
    balances: {
      treasuryAddress: env.TREASURY_ADDRESS,
      treasuryUrl: arcAddress(env.TREASURY_ADDRESS),
      treasury: treasuryBalances,
      vtpassNgn: vtpassBalance,
    },
    days,
    issues,
  };
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------
export async function listUsers(q: string | undefined, status: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (q?.trim()) {
    const terms = searchTerms(q);
    conds.push(or(eq(users.id, q.trim()), ...terms.flatMap((t) => [like(users.email, t), like(users.name, t), like(users.phone, t)])));
  }
  if (status === "active" || status === "suspended") conds.push(eq(users.status, status));
  if (status === "unverified") conds.push(eq(users.emailVerified, false));
  const where = conds.length ? and(...conds) : undefined;

  const [total] = await db.select({ n: count() }).from(users).where(where);
  const rows = await db
    .select()
    .from(users)
    .where(where)
    .orderBy(desc(users.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  const ids = rows.map((r) => r.id);
  const stats = ids.length
    ? await db
        .select({
          userId: orders.userId,
          n: count(),
          micro: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.usdcAmountMicro} else 0 end), 0)`.mapWith(Number),
          last: sql<number>`max(${orders.createdAt})`.mapWith(Number),
        })
        .from(orders)
        .where(and(inArray(orders.userId, ids), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
        .groupBy(orders.userId)
    : [];
  const arc = ids.length
    ? await db
        .select({ userId: wallets.userId, address: wallets.address })
        .from(wallets)
        .where(and(inArray(wallets.userId, ids), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN), eq(wallets.accountType, "SCA"), isNull(wallets.retiredAt)))
    : [];

  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    users: rows.map((r) => {
      const s = stats.find((x) => x.userId === r.id);
      return {
        id: r.id,
        name: r.name,
        email: r.email,
        phone: r.phone ? localPhone(r.phone) : null,
        emailVerified: r.emailVerified,
        status: r.status,
        createdAt: r.createdAt.toISOString(),
        orders: s?.n ?? 0,
        spentUsdc: usdcText(s?.micro ?? 0),
        lastOrderAt: s?.last ? new Date(s.last).toISOString() : null,
        walletAddress: arc.find((w) => w.userId === r.id)?.address ?? null,
      };
    }),
  };
}

export async function getUser(id: string) {
  const [user] = await db.select().from(users).where(eq(users.id, id)).limit(1);
  if (!user) return null;

  const walletRows = await db.select().from(wallets).where(eq(wallets.userId, id)).orderBy(desc(wallets.createdAt));
  const arc = walletRows.find((w) => w.blockchain === env.CIRCLE_BLOCKCHAIN && w.accountType === "SCA" && !w.retiredAt);
  let balances: Record<string, string> | null = null;
  if (arc) {
    try {
      balances = await withTimeout(tokenBalances(arc.circleWalletId));
    } catch {
      balances = null;
    }
  }
  let otherChains: { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null }[] = [];
  if (env.BRIDGE_ENABLED) {
    try {
      otherChains = (await withTimeout(listChainWallets(id), 15_000)).map((w) => ({
        chain: w.chain,
        chainLabel: w.chainLabel,
        address: w.address,
        explorerUrl: w.explorerUrl,
        balance: w.balanceMicro === null ? null : usdcText(w.balanceMicro),
      }));
    } catch {
      otherChains = [];
    }
  }

  const orderRows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.userId, id), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(50);
  const [totals] = await db
    .select({
      n: count(),
      micro: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.usdcAmountMicro} else 0 end), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.ngnAmountKobo} else 0 end), 0)`.mapWith(Number),
    })
    .from(orders)
    .where(and(eq(orders.userId, id), notInArray(orders.status, ["QUOTED", "EXPIRED"])));
  const bridgeRows = await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.userId, id)).orderBy(desc(bridgeTransfers.createdAt)).limit(20);
  const swapRows = await db.select().from(swaps).where(eq(swaps.userId, id)).orderBy(desc(swaps.createdAt)).limit(20);
  const sendRows = await db
    .select()
    .from(sends)
    .where(and(eq(sends.userId, id), notInArray(sends.status, ["AWAITING_CODE"])))
    .orderBy(desc(sends.createdAt))
    .limit(20);
  const sweepRows = await db.select().from(walletSweeps).where(eq(walletSweeps.userId, id)).orderBy(desc(walletSweeps.createdAt)).limit(10);
  const activity = await db
    .select()
    .from(auditLogs)
    .where(and(eq(auditLogs.targetType, "user"), eq(auditLogs.targetId, id)))
    .orderBy(desc(auditLogs.createdAt))
    .limit(30);

  return {
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      phone: user.phone ? localPhone(user.phone) : null,
      emailVerified: user.emailVerified,
      status: user.status,
      createdAt: user.createdAt.toISOString(),
    },
    totals: { orders: totals?.n ?? 0, spentUsdc: usdcText(totals?.micro ?? 0), spentNgn: (totals?.ngn ?? 0) / 100 },
    arcWallet: arc ? { address: arc.address, explorerUrl: arcAddress(arc.address), balances } : null,
    wallets: walletRows.map((w) => ({
      address: w.address,
      blockchain: w.blockchain,
      accountType: w.accountType,
      retiredAt: iso(w.retiredAt),
      createdAt: w.createdAt.toISOString(),
    })),
    otherChains,
    orders: orderRows.map(({ order, planName }) => ({
      id: order.id,
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      createdAt: order.createdAt.toISOString(),
    })),
    bridges: bridgeRows.map(bridgeRow),
    swaps: swapRows.map(swapRow),
    sends: sendRows.map(sendRow),
    sweeps: sweepRows.map((s) => ({
      id: s.id,
      status: s.status,
      amount: usdcText(s.amountMicro),
      toAddress: s.toAddress,
      txUrl: arcTx(s.txHash),
      createdAt: s.createdAt.toISOString(),
    })),
    activity: activity.map(activityRow),
  };
}

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------
export async function listOrders(status: string | undefined, q: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (status === "open") conds.push(inArray(orders.status, [...OPEN_ORDER_STATUSES]));
  else if (status && (ORDER_STATUSES as readonly string[]).includes(status)) conds.push(eq(orders.status, status as (typeof ORDER_STATUSES)[number]));
  else if (status !== "all") conds.push(notInArray(orders.status, ["QUOTED", "EXPIRED"]));
  if (q?.trim()) {
    const terms = searchTerms(q);
    conds.push(or(eq(orders.reference, q.trim().toUpperCase()), ...terms.flatMap((t) => [like(orders.reference, t), like(orders.phone, t), like(users.email, t)])));
  }
  const where = conds.length ? and(...conds) : undefined;
  const [total] = await db.select({ n: count() }).from(orders).innerJoin(users, eq(orders.userId, users.id)).where(where);
  const rows = await db
    .select({ order: orders, email: users.email, planName: dataPlans.name })
    .from(orders)
    .innerJoin(users, eq(orders.userId, users.id))
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(where)
    .orderBy(desc(orders.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    orders: rows.map(({ order, email, planName }) => ({
      id: order.id,
      reference: order.reference,
      status: order.status,
      userId: order.userId,
      email,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      failureReason: order.failureReason,
      createdAt: order.createdAt.toISOString(),
    })),
  };
}

export async function getOrder(key: string) {
  const [row] = await db
    .select({ order: orders, user: users, planName: dataPlans.name, rate: exchangeRates.koboPerUsdc, rateSource: exchangeRates.source })
    .from(orders)
    .innerJoin(users, eq(orders.userId, users.id))
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .leftJoin(exchangeRates, eq(orders.exchangeRateId, exchangeRates.id))
    .where(or(eq(orders.id, key), eq(orders.reference, key.toUpperCase())))
    .limit(1);
  if (!row) return null;
  const { order, user } = row;
  const paymentRows = await db.select().from(payments).where(eq(payments.orderId, order.id)).orderBy(desc(payments.createdAt));
  const vtuRows = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, order.id)).orderBy(desc(vtuTransactions.createdAt));
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  const ledger = await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, order.id)).orderBy(ledgerEntries.createdAt);
  const activity = await db
    .select()
    .from(auditLogs)
    .where(and(eq(auditLogs.targetType, "order"), eq(auditLogs.targetId, order.id)))
    .orderBy(desc(auditLogs.createdAt))
    .limit(50);

  const confirmedPayment = paymentRows.some((p) => p.status === "CONFIRMED");
  const openVtu = vtuRows.some((t) => ["SENT", "PENDING", "UNKNOWN"].includes(t.status));
  return {
    order: {
      id: order.id,
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: row.planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      marginNgn: order.marginKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      rateNgnPerUsdc: row.rate ? row.rate / 100 : null,
      rateSource: row.rateSource ?? null,
      failureReason: order.failureReason,
      quoteExpiresAt: order.quoteExpiresAt.toISOString(),
      createdAt: order.createdAt.toISOString(),
      updatedAt: order.updatedAt.toISOString(),
    },
    user: { id: user.id, name: user.name, email: user.email, status: user.status },
    payments: paymentRows.map((p) => ({
      id: p.id,
      status: p.status,
      amount: usdcText(p.amountMicro),
      fromAddress: p.fromAddress,
      toAddress: p.toAddress,
      txHash: p.txHash,
      txUrl: arcTx(p.txHash),
      circleTransactionId: p.circleTransactionId,
      confirmedAt: iso(p.confirmedAt),
      createdAt: p.createdAt.toISOString(),
    })),
    deliveries: vtuRows.map((t) => ({
      id: t.id,
      provider: t.provider,
      requestId: t.requestId,
      providerReference: t.providerReference,
      attempt: t.attempt,
      status: t.status,
      request: t.requestPayload,
      response: t.responsePayload,
      createdAt: t.createdAt.toISOString(),
      updatedAt: t.updatedAt.toISOString(),
    })),
    refund: refund
      ? {
          status: refund.status,
          amount: usdcText(refund.amountMicro),
          toAddress: refund.toAddress,
          attempt: refund.attempt,
          txHash: refund.txHash,
          txUrl: arcTx(refund.txHash),
          lastError: refund.lastError,
          confirmedAt: iso(refund.confirmedAt),
          createdAt: refund.createdAt.toISOString(),
        }
      : null,
    ledger: ledger.map((l) => ({
      account: l.account,
      currency: l.currency,
      debit: l.currency === "USDC" ? usdcText(l.debit) : String(l.debit / 100),
      credit: l.currency === "USDC" ? usdcText(l.credit) : String(l.credit / 100),
      memo: l.memo,
      createdAt: l.createdAt.toISOString(),
    })),
    activity: activity.map(activityRow),
    actions: {
      requery: ["FULFILMENT_PENDING", "FLAGGED"].includes(order.status) && openVtu,
      retryRefund:
        (order.status === "FAILED" && confirmedPayment) ||
        order.status === "REFUND_PENDING" ||
        (order.status === "FLAGGED" && refund?.status === "FAILED"),
      failAndRefund: order.status === "FLAGGED" && confirmedPayment && !refund,
    },
  };
}

// ---------------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------------
export async function listRefunds(status: string | undefined, page: number) {
  const where = status && (REFUND_STATUSES as readonly string[]).includes(status) ? eq(refunds.status, status as (typeof REFUND_STATUSES)[number]) : undefined;
  const [total] = await db.select({ n: count() }).from(refunds).where(where);
  const rows = await db
    .select({ refund: refunds, reference: orders.reference, orderId: orders.id, orderStatus: orders.status, email: users.email, userId: users.id })
    .from(refunds)
    .innerJoin(orders, eq(refunds.orderId, orders.id))
    .innerJoin(users, eq(orders.userId, users.id))
    .where(where)
    .orderBy(desc(refunds.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    refunds: rows.map(({ refund, reference, orderId, orderStatus, email, userId }) => ({
      id: refund.id,
      status: refund.status,
      amount: usdcText(refund.amountMicro),
      attempt: refund.attempt,
      lastError: refund.lastError,
      txUrl: arcTx(refund.txHash),
      reference,
      orderId,
      orderStatus,
      email,
      userId,
      createdAt: refund.createdAt.toISOString(),
      confirmedAt: iso(refund.confirmedAt),
    })),
  };
}

// ---------------------------------------------------------------------------
// Bridge transfers
// ---------------------------------------------------------------------------
function bridgeRow(t: typeof bridgeTransfers.$inferSelect) {
  return {
    id: t.id,
    direction: t.direction,
    status: t.status,
    from: safeChain(t.sourceChain)?.label ?? t.sourceChain,
    to: safeChain(t.destinationChain)?.label ?? t.destinationChain,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    maxFee: t.maxFeeMicro === null ? null : usdcText(t.maxFeeMicro),
    failureReason: t.failureReason,
    createdAt: t.createdAt.toISOString(),
    updatedAt: t.updatedAt.toISOString(),
  };
}

export async function listBridge(status: string | undefined, q: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (status === "open") conds.push(inArray(bridgeTransfers.status, [...OPEN_BRIDGE_STATUSES]));
  else if (status && (BRIDGE_STATUSES as readonly string[]).includes(status)) conds.push(eq(bridgeTransfers.status, status as (typeof BRIDGE_STATUSES)[number]));
  if (q?.trim()) {
    const t = `%${q.trim().slice(0, 100)}%`;
    conds.push(or(eq(bridgeTransfers.id, q.trim()), like(users.email, t), like(bridgeTransfers.recipientAddress, t)));
  }
  const where = conds.length ? and(...conds) : undefined;
  const [total] = await db.select({ n: count() }).from(bridgeTransfers).leftJoin(users, eq(bridgeTransfers.userId, users.id)).where(where);
  const rows = await db
    .select({ t: bridgeTransfers, email: users.email })
    .from(bridgeTransfers)
    .leftJoin(users, eq(bridgeTransfers.userId, users.id))
    .where(where)
    .orderBy(desc(bridgeTransfers.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    transfers: rows.map(({ t, email }) => ({ ...bridgeRow(t), userId: t.userId, email: email ?? null })),
  };
}

export async function getBridge(id: string) {
  const [row] = await db
    .select({ t: bridgeTransfers, email: users.email })
    .from(bridgeTransfers)
    .leftJoin(users, eq(bridgeTransfers.userId, users.id))
    .where(eq(bridgeTransfers.id, id))
    .limit(1);
  if (!row) return null;
  const { t } = row;
  const events = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(bridgeEvents.createdAt);
  const destination = safeChain(t.destinationChain);
  return {
    transfer: {
      ...bridgeRow(t),
      userId: t.userId,
      email: row.email ?? null,
      depositorAddress: t.depositorAddress,
      forwardingFee: t.forwardingFeeMicro === null ? null : usdcText(t.forwardingFeeMicro),
      gatewayTransferId: t.gatewayTransferId,
      mintTxHash: t.mintTxHash,
      mintUrl: destination && t.mintTxHash ? `${destination.explorerTx}${t.mintTxHash}` : null,
    },
    events: events.map((e) => {
      const chain = safeChain(e.chain);
      return {
        step: e.step,
        chain: chain?.label ?? e.chain,
        txHash: e.txHash,
        txUrl: chain && e.txHash ? `${chain.explorerTx}${e.txHash}` : null,
        details: e.details,
        at: e.createdAt.toISOString(),
      };
    }),
  };
}

// ---------------------------------------------------------------------------
// Sends to other wallets on Arc
// ---------------------------------------------------------------------------
function sendRow(s: typeof sends.$inferSelect) {
  return {
    id: s.id,
    status: s.status,
    token: s.token,
    amount: s.amount,
    toAddress: s.toAddress,
    txUrl: arcTx(s.txHash),
    error: s.error,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSendsAdmin(status: string | undefined, page: number) {
  const where =
    status && (SEND_STATUSES as readonly string[]).includes(status)
      ? eq(sends.status, status as (typeof SEND_STATUSES)[number])
      : notInArray(sends.status, ["AWAITING_CODE"]);
  const [total] = await db.select({ n: count() }).from(sends).where(where);
  const rows = await db
    .select({ s: sends, email: users.email })
    .from(sends)
    .innerJoin(users, eq(sends.userId, users.id))
    .where(where)
    .orderBy(desc(sends.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    sends: rows.map(({ s, email }) => ({ ...sendRow(s), userId: s.userId, email })),
  };
}

// ---------------------------------------------------------------------------
// Swaps
// ---------------------------------------------------------------------------
function swapRow(s: typeof swaps.$inferSelect) {
  return {
    id: s.id,
    status: s.status,
    tokenIn: s.tokenIn,
    tokenOut: s.tokenOut,
    amountIn: s.amountIn,
    estimatedOut: s.estimatedOut,
    minOut: s.minOut,
    amountOut: s.amountOut,
    feePercent: s.feeBps / 100,
    txUrl: arcTx(s.txHash),
    error: s.error,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSwapsAdmin(status: string | undefined, page: number) {
  const where = status && (SWAP_STATUSES as readonly string[]).includes(status) ? eq(swaps.status, status as (typeof SWAP_STATUSES)[number]) : undefined;
  const [total] = await db.select({ n: count() }).from(swaps).where(where);
  const rows = await db
    .select({ s: swaps, email: users.email })
    .from(swaps)
    .innerJoin(users, eq(swaps.userId, users.id))
    .where(where)
    .orderBy(desc(swaps.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    swaps: rows.map(({ s, email }) => ({ ...swapRow(s), userId: s.userId, email })),
  };
}

// ---------------------------------------------------------------------------
// Providers (approved bridge destinations)
// ---------------------------------------------------------------------------
export async function listProviders() {
  const rows = await db.select().from(approvedDestinations).orderBy(desc(approvedDestinations.createdAt));
  return rows.map((d) => {
    const chain = safeChain(d.chain);
    return {
      id: d.id,
      label: d.label,
      chain: chain?.label ?? d.chain,
      address: d.address,
      explorerUrl: chain ? `${chain.explorerTx.replace(/\/tx\/?$/, "/address/")}${d.address}` : null,
      active: d.active,
      note: d.note,
      createdAt: d.createdAt.toISOString(),
    };
  });
}

// ---------------------------------------------------------------------------
// Activity (audit log)
// ---------------------------------------------------------------------------
function activityRow(a: typeof auditLogs.$inferSelect) {
  return {
    id: a.id,
    actorType: a.actorType,
    action: a.action,
    targetType: a.targetType,
    targetId: a.targetId,
    details: a.details,
    at: a.createdAt.toISOString(),
  };
}

export async function listActivity(actor: string | undefined, page: number) {
  const where = actor === "admin" || actor === "system" || actor === "user" ? eq(auditLogs.actorType, actor) : undefined;
  const [total] = await db.select({ n: count() }).from(auditLogs).where(where);
  const rows = await db
    .select()
    .from(auditLogs)
    .where(where)
    .orderBy(desc(auditLogs.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return { total: total?.n ?? 0, page, pageSize: PAGE_SIZE, activity: rows.map(activityRow) };
}

// ---------------------------------------------------------------------------
// Settings page: switches and the server's current (non secret) setup
// ---------------------------------------------------------------------------
export async function settingsView() {
  return {
    pauses: await getPauses(),
    setup: {
      network: env.CIRCLE_BLOCKCHAIN,
      testnet: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET"),
      vtpass: env.VTPASS_BASE_URL.includes("sandbox") ? "sandbox" : "live",
      pricingMarginPercent: env.PRICING_MARGIN_BPS / 100,
      quoteMinutes: env.QUOTE_TTL_MINUTES,
      fixedRate: env.NGN_PER_USDC ?? null,
      treasuryAddress: env.TREASURY_ADDRESS,
      treasuryUrl: arcAddress(env.TREASURY_ADDRESS),
      bridgeEnabled: env.BRIDGE_ENABLED,
      bridgeLimits: { min: env.BRIDGE_MIN_USDC, max: env.BRIDGE_MAX_USDC, daily: env.BRIDGE_DAILY_USDC, maxFee: env.BRIDGE_MAX_FEE_USDC },
      bridgeChains: env.BRIDGE_ENABLED ? openChains().map((c) => c.label) : [],
      swapEnabled: env.SWAP_ENABLED,
      swapFeePercent: env.SWAP_FEE_BPS / 100,
      swapSlippagePercent: env.SWAP_SLIPPAGE_BPS / 100,
      swapDailyCount: env.SWAP_DAILY_COUNT,
      alertEmail: Boolean(env.ALERT_EMAIL),
      worker: env.WORKER_ENABLED,
    },
  };
}
