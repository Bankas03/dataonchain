// Switches the admin can flip from the dashboard, without a redeploy.
// Pausing only stops NEW purchases, transfers or swaps. Anything already
// started (payments, deliveries, refunds, bridge transfers) keeps going.
import { db } from "./db";
import { appSettings } from "./db/schema";

export const PAUSE_KEYS = ["purchasesPaused", "bridgePaused", "swapPaused"] as const;
export type PauseKey = (typeof PAUSE_KEYS)[number];
export type Pauses = Record<PauseKey, boolean>;

export const PAUSE_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data is paused for a short maintenance. Please try again later.",
  bridgePaused: "Sending to other networks is paused for a short maintenance. Please try again later.",
  swapPaused: "Swaps are paused for a short maintenance. Please try again later.",
};

const CACHE_MS = 10_000;
let cache: { at: number; value: Pauses } | null = null;

export function isPauseKey(value: unknown): value is PauseKey {
  return typeof value === "string" && (PAUSE_KEYS as readonly string[]).includes(value);
}

export async function getPauses(): Promise<Pauses> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.value;
  const value: Pauses = { purchasesPaused: false, bridgePaused: false, swapPaused: false };
  try {
    const rows = await db.select().from(appSettings);
    for (const key of PAUSE_KEYS) value[key] = rows.find((r) => r.key === key)?.value === "true";
  } catch (err) {
    // Never block users because the settings could not be read
    console.error("[settings] could not read switches:", err instanceof Error ? err.message : err);
    return value;
  }
  cache = { at: Date.now(), value };
  return value;
}

// The message to show users when this part is paused, or null when it is open.
export async function pausedMessage(key: PauseKey): Promise<string | null> {
  return (await getPauses())[key] ? PAUSE_MESSAGES[key] : null;
}

export async function setPause(key: PauseKey, paused: boolean): Promise<void> {
  const value = paused ? "true" : "false";
  await db
    .insert(appSettings)
    .values({ key, value })
    .onConflictDoUpdate({ target: appSettings.key, set: { value, updatedAt: new Date() } });
  cache = null;
}
