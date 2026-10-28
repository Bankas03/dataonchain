// Switches the admin can flip from the dashboard, without a redeploy.
// Pausing only stops NEW purchases, transfers or swaps. Anything already
// started (payments, deliveries, refunds, bridge transfers) keeps going.
import { db } from "./db";
import { appSettings } from "./db/schema";
import { env } from "./env";

export const PAUSE_KEYS = ["purchasesPaused", "bridgePaused", "swapPaused", "sendPaused"] as const;
export type PauseKey = (typeof PAUSE_KEYS)[number];
export type Pauses = Record<PauseKey, boolean>;

const TESTNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data is paused for a short maintenance. Please try again later.",
  bridgePaused: "Sending to other networks is paused for a short maintenance. Please try again later.",
  swapPaused: "Swaps are paused for a short maintenance. Please try again later.",
  sendPaused: "Sending to other wallets is paused for a short maintenance. Please try again later.",
};
// On mainnet a paused part is one that has not opened yet
const MAINNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data with real USDC is coming soon. Until then you can add USDC to your wallet.",
  bridgePaused: "Sending to other networks opens soon on Arc mainnet.",
  swapPaused: "Swaps open soon on Arc mainnet.",
  sendPaused: "Sending to other wallets opens soon on Arc mainnet.",
};
export const PAUSE_MESSAGES: Record<PauseKey, string> = env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? TESTNET_MESSAGES : MAINNET_MESSAGES;

const CACHE_MS = 10_000;
let cache: { at: number; value: Pauses } | null = null;

export function isPauseKey(value: unknown): value is PauseKey {
  return typeof value === "string" && (PAUSE_KEYS as readonly string[]).includes(value);
}

export async function getPauses(): Promise<Pauses> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.value;
  // A switch never set is open, except sending to other wallets on mainnet:
  // it starts paused until the admin opens it after a live check
  const value: Pauses = { purchasesPaused: false, bridgePaused: false, swapPaused: false, sendPaused: !env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") };
  try {
    const rows = await db.select().from(appSettings);
    for (const key of PAUSE_KEYS) {
      const row = rows.find((r) => r.key === key);
      if (row) value[key] = row.value === "true";
    }
  } catch (err) {
    // Never block users because the settings could not be read
    console.error("[settings] could not read switches:", err instanceof Error ? err.message : err);
    return value;
  }
  cache = { at: Date.now(), value };
  return value;
}

// The messages for every paused part, for the dashboard notice
export async function pauseNotices(): Promise<string[]> {
  const p = await getPauses();
  // Bridge and swaps only matter where they are switched on
  const on: Record<PauseKey, boolean> = { purchasesPaused: true, bridgePaused: env.BRIDGE_ENABLED, swapPaused: env.SWAP_ENABLED, sendPaused: true };
  return PAUSE_KEYS.filter((k) => p[k] && on[k]).map((k) => PAUSE_MESSAGES[k]);
}

// The message to show users when this part is paused, or null when it is open.
// Accounts in PAUSE_BYPASS_EMAILS (the admin by default) can still use the
// bridge and swaps while they are paused, for live checks. Never purchases.
export async function pausedMessage(key: PauseKey, email?: string | null): Promise<string | null> {
  if (!(await getPauses())[key]) return null;
  if (key !== "purchasesPaused" && email && env.PAUSE_BYPASS_EMAILS.includes(email.trim().toLowerCase())) return null;
  return PAUSE_MESSAGES[key];
}

export async function setPause(key: PauseKey, paused: boolean): Promise<void> {
  const value = paused ? "true" : "false";
  await db
    .insert(appSettings)
    .values({ key, value })
    .onConflictDoUpdate({ target: appSettings.key, set: { value, updatedAt: new Date() } });
  cache = null;
}
