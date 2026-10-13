// Naira per USDC, stored as kobo per 1 USDC.
// Live rate from ExchangeRate API (USD to NGN), refreshed hourly,
// or a fixed rate when NGN_PER_USDC is set.
import { and, desc, eq } from "drizzle-orm";
import { db } from "../db";
import { exchangeRates } from "../db/schema";
import { env } from "../env";

const LIVE_SOURCE = "open.er-api.com";
const REFRESH_AFTER_MS = 60 * 60 * 1000;
const STILL_USABLE_MS = 24 * 60 * 60 * 1000;

export type Rate = typeof exchangeRates.$inferSelect;

async function latest(source: string): Promise<Rate | undefined> {
  const [row] = await db
    .select()
    .from(exchangeRates)
    .where(eq(exchangeRates.source, source))
    .orderBy(desc(exchangeRates.fetchedAt))
    .limit(1);
  return row;
}

async function save(source: string, koboPerUsdc: number): Promise<Rate> {
  const [row] = await db
    .insert(exchangeRates)
    .values({ source, koboPerUsdc, fetchedAt: new Date() })
    .returning();
  if (!row) throw new Error("Could not save the exchange rate");
  return row;
}

async function fetchLiveKoboPerUsdc(): Promise<number> {
  const res = await fetch("https://open.er-api.com/v6/latest/USD", { signal: AbortSignal.timeout(15_000) });
  const body = (await res.json()) as { result?: string; rates?: Record<string, number> };
  const ngn = body.rates?.NGN;
  if (body.result !== "success" || typeof ngn !== "number" || ngn <= 0) {
    throw new Error(`Rate service gave no NGN rate: ${JSON.stringify(body).slice(0, 200)}`);
  }
  return Math.round(ngn * 100);
}

export async function getCurrentRate(): Promise<Rate> {
  if (env.NGN_PER_USDC) {
    const kobo = Math.round(env.NGN_PER_USDC * 100);
    const [same] = await db
      .select()
      .from(exchangeRates)
      .where(and(eq(exchangeRates.source, "manual"), eq(exchangeRates.koboPerUsdc, kobo)))
      .orderBy(desc(exchangeRates.fetchedAt))
      .limit(1);
    return same ?? save("manual", kobo);
  }

  const last = await latest(LIVE_SOURCE);
  const age = last ? Date.now() - last.fetchedAt.getTime() : Infinity;
  if (last && age < REFRESH_AFTER_MS) return last;

  try {
    return await save(LIVE_SOURCE, await fetchLiveKoboPerUsdc());
  } catch (err) {
    console.error("[rates] live rate failed:", err);
    if (last && age < STILL_USABLE_MS) return last;
    throw new Error("No exchange rate available right now. Please try again shortly.");
  }
}
