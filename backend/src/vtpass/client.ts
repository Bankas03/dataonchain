// VTpass API (airtime and data). Sandbox or live, set by VTPASS_BASE_URL.
import { randomBytes } from "node:crypto";
import type { NETWORKS } from "../db/schema";
import { env } from "../env";

export type Network = (typeof NETWORKS)[number];

export const SERVICE_IDS = {
  airtime: { mtn: "mtn", airtel: "airtel", glo: "glo", "9mobile": "etisalat" },
  data: { mtn: "mtn-data", airtel: "airtel-data", glo: "glo-data", "9mobile": "etisalat-data" },
} as const;

export type Variation = {
  variation_code: string;
  name: string;
  variation_amount: string;
  fixedPrice?: string;
};

async function vtGet<T>(path: string): Promise<T> {
  const res = await fetch(`${env.VTPASS_BASE_URL}${path}`, {
    headers: { "api-key": env.VTPASS_API_KEY, "public-key": env.VTPASS_PUBLIC_KEY },
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`VTpass answered ${res.status}: ${text.slice(0, 200)}`);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`VTpass sent something that is not JSON: ${text.slice(0, 200)}`);
  }
}

export async function getDataVariations(network: Network): Promise<Variation[]> {
  const body = await vtGet<{ response_description?: string; content?: { variations?: Variation[] } }>(
    `/service-variations?serviceID=${SERVICE_IDS.data[network]}`,
  );
  const list = body.content?.variations;
  if (!Array.isArray(list)) {
    throw new Error(`VTpass returned no plans for ${network}: ${JSON.stringify(body).slice(0, 200)}`);
  }
  return list;
}

// VTpass request ids start with the Lagos date and time (YYYYMMDDHHII).
// Used when buying (Phase 9). Each purchase gets exactly one.
export function makeRequestId(): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone: "Africa/Lagos",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  );
  return `${parts.year}${parts.month}${parts.day}${parts.hour}${parts.minute}${randomBytes(6).toString("hex")}`;
}
