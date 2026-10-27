// Price quotes. A quote is an order in QUOTED status with a USDC price
// that is held until quoteExpiresAt.
import { randomInt } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { normalizeNigerianPhone } from "../auth/phone";
import { getActivePlan, isNetwork } from "../catalog/plans";
import { db } from "../db";
import { isUniqueViolation } from "../db/errors";
import { dataPlans, orders } from "../db/schema";
import { env } from "../env";
import { getCurrentRate } from "./rates";

export const AIRTIME_MIN_NGN = 50;
export const AIRTIME_MAX_NGN = 50_000;

export class QuoteError extends Error {}

type Order = typeof orders.$inferSelect;

// All money is whole numbers: kobo for naira, micro USDC (6 decimals) for USDC.
// Rounding always goes up, so the platform never sells below cost.
export function priceInUsdc(ngnKobo: number, koboPerUsdc: number, marginBps: number) {
  const marginKobo = Math.ceil((ngnKobo * marginBps) / 10_000);
  const usdcMicro = Math.ceil(((ngnKobo + marginKobo) * 1_000_000) / koboPerUsdc);
  return { marginKobo, usdcMicro };
}

export function microToUsdc(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

function present(order: Order, planName: string | null) {
  return {
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    expiresAt: order.quoteExpiresAt.toISOString(),
  };
}

export async function createQuote(userId: string, body: unknown) {
  const input = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;

  const serviceType = input.serviceType;
  if (serviceType !== "airtime" && serviceType !== "data") throw new QuoteError("Choose airtime or data.");
  const network = input.network;
  if (!isNetwork(network)) throw new QuoteError("Choose a network: MTN, Airtel, Glo or 9mobile.");
  const phone = normalizeNigerianPhone(String(input.phone ?? ""));
  if (!phone) throw new QuoteError("Enter a valid Nigerian phone number, for example 08012345678.");

  let ngnKobo: number;
  let planId: string | null = null;
  let planName: string | null = null;
  if (serviceType === "data") {
    const plan = await getActivePlan(String(input.planId ?? ""), network);
    if (!plan) throw new QuoteError("That data plan is not available. Please choose another one.");
    ngnKobo = plan.priceKobo;
    planId = plan.id;
    planName = plan.name;
  } else {
    const amount = Number(input.amountNgn);
    if (!Number.isInteger(amount) || amount < AIRTIME_MIN_NGN || amount > AIRTIME_MAX_NGN) {
      throw new QuoteError(
        `Airtime must be a whole naira amount from ₦${AIRTIME_MIN_NGN} to ₦${AIRTIME_MAX_NGN.toLocaleString("en-NG")}.`,
      );
    }
    ngnKobo = amount * 100;
  }

  const rate = await getCurrentRate();
  const { marginKobo, usdcMicro } = priceInUsdc(ngnKobo, rate.koboPerUsdc, env.PRICING_MARGIN_BPS);
  const quoteExpiresAt = new Date(Date.now() + env.QUOTE_TTL_MINUTES * 60_000);

  for (let attempt = 0; attempt < 5; attempt++) {
    const reference = `ARC${randomInt(10_000_000, 100_000_000)}`;
    try {
      const [order] = await db
        .insert(orders)
        .values({
          reference,
          userId,
          serviceType,
          network,
          planId,
          phone,
          ngnAmountKobo: ngnKobo,
          marginKobo,
          usdcAmountMicro: usdcMicro,
          exchangeRateId: rate.id,
          status: "QUOTED",
          quoteExpiresAt,
        })
        .returning();
      if (!order) throw new Error("Could not save the quote");
      return {
        ...present(order, planName),
        rate: rate.koboPerUsdc / 100,
        marginPercent: env.PRICING_MARGIN_BPS / 100,
      };
    } catch (err) {
      if (isUniqueViolation(err, "reference") && attempt < 4) continue;
      throw err;
    }
  }
  throw new Error("Could not create a quote reference");
}

export async function getQuote(userId: string, reference: string) {
  const [row] = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.reference, reference), eq(orders.userId, userId)))
    .limit(1);
  if (!row) return null;

  let order = row.order;
  if (order.status === "QUOTED" && order.quoteExpiresAt.getTime() < Date.now()) {
    const [updated] = await db
      .update(orders)
      .set({ status: "EXPIRED" })
      .where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")))
      .returning();
    order = updated ?? { ...order, status: "EXPIRED" };
  }
  return present(order, row.planName ?? null);
}
