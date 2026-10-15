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

// ---------------------------------------------------------------------------
// Buying (POST requests use the secret key)
// ---------------------------------------------------------------------------
export type VtOutcome = {
  result: "DELIVERED" | "FAILED" | "PENDING";
  code: string;
  message: string;
  providerReference?: string;
  token?: string;
  // Requery only: VTpass has no record of this request id (code 015)
  notFound?: boolean;
  raw: unknown;
};

// Codes where VTpass did not complete the purchase (and does not charge).
// 011 bad input, 012 no such product, 013/017 amount limits, 016 failed,
// 018 VTpass wallet too low, 021/022/024 account problems, 027 IP not
// whitelisted, 028 product not whitelisted, 030 biller unreachable,
// 031/032 quantity limits, 034/035 service off, 040 reversed (refunded to
// the VTpass wallet), 085 bad request id, 087 bad keys, 091 not processed.
const FAILED_CODES = new Set([
  "011", "012", "013", "016", "017", "018", "021", "022", "024", "027", "028",
  "030", "031", "032", "034", "035", "040", "085", "087", "091",
]);

async function vtPost(path: string, body: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${env.VTPASS_BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "api-key": env.VTPASS_API_KEY,
      "secret-key": env.VTPASS_SECRET_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`VTpass answered ${res.status} with something that is not JSON: ${text.slice(0, 200)}`);
  }
}

// Turns any VTpass answer into DELIVERED, FAILED or PENDING.
// Anything unclear is PENDING: it is asked about again, never resent.
export function classify(body: unknown): VtOutcome {
  const b = (body && typeof body === "object" ? body : {}) as {
    code?: string | number;
    response_description?: string;
    purchased_code?: string;
    content?: { transactions?: { status?: string; transactionId?: string | number } };
  };
  const code = String(b.code ?? "");
  const status = String(b.content?.transactions?.status ?? "").toLowerCase();
  const id = b.content?.transactions?.transactionId;
  const base = {
    code,
    message: b.response_description || `VTpass code ${code || "none"}`,
    providerReference: id !== undefined && id !== null && id !== "" ? String(id) : undefined,
    token: b.purchased_code ? String(b.purchased_code) : undefined,
    raw: body,
  };
  if (code === "000" && status === "delivered") return { result: "DELIVERED", ...base };
  if (status === "failed" || status === "reversed" || FAILED_CODES.has(code)) return { result: "FAILED", ...base };
  return { result: "PENDING", ...base };
}

function noAnswer(err: unknown): VtOutcome {
  const message = `No clear answer from VTpass: ${err instanceof Error ? err.message : String(err)}`;
  return { result: "PENDING", code: "", message, raw: { error: message } };
}

export async function purchase(payload: Record<string, unknown>): Promise<VtOutcome> {
  try {
    return classify(await vtPost("/pay", payload));
  } catch (err) {
    return noAnswer(err);
  }
}

// Asks VTpass what happened to a request. Never buys anything.
export async function requery(requestId: string): Promise<VtOutcome> {
  try {
    const outcome = classify(await vtPost("/requery", { request_id: requestId }));
    if (outcome.result === "PENDING" && outcome.code === "015") return { ...outcome, notFound: true };
    return outcome;
  } catch (err) {
    return noAnswer(err);
  }
}
