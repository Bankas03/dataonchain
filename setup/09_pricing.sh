#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 09 (Phase 7): products, prices and quotes
#
# What this adds:
#   - VTpass connection (sandbox): data plans for MTN, Airtel, Glo, 9mobile,
#     refreshed automatically every 6 hours
#   - Naira to USDC rate (ExchangeRate API, refreshed hourly), or a fixed
#     rate you set yourself with NGN_PER_USDC
#   - Your margin on every sale (PRICING_MARGIN_BPS, 200 = 2%)
#   - Price quotes: an order is created with a USDC price held for 10 minutes
#   - A Buy page: airtime or data, network, plan or amount, phone number,
#     price in USDC with a countdown (paying comes in Phase 8)
#
# Before running: on https://sandbox.vtpass.com > Profile > API Keys,
# have your api key, public key and secret key ready.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/09_pricing.sh
# =============================================================================
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }
pause()  { read -r -p "$* Press Enter to continue... " _; }

ENV_FILE="backend/.env"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
to_clipboard() { command -v clip.exe >/dev/null 2>&1 && printf '%s' "$1" | clip.exe; }

# Refuses to commit if any secret value from backend/.env appears in the commit.
secret_scan() {
  local key val found=""
  while IFS='=' read -r key val; do
    [[ "$key" =~ (SECRET|TOKEN|KEY)$ ]] || continue
    [[ ${#val} -ge 12 ]] || continue
    if git diff --cached -- . ':(exclude)*package-lock.json' | grep -qF -- "$val"; then
      found="$found $key"
    fi
  done < <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  if [[ -n "$found" ]]; then
    git diff --cached --name-only
    git reset -q
    fail "The value of$found is inside one of the files above. Nothing was committed. Delete that file or remove the secret, then run again."
  fi
}

# Reads a key without showing it, trims spaces, and catches double pastes.
read_key() { # prompt varname
  local value half
  read -r -s -p "$1: " value; echo
  value="$(printf '%s' "$value" | tr -d '[:space:]')"
  half=$(( ${#value} / 2 ))
  if [[ ${#value} -gt 20 && $(( ${#value} % 2 )) -eq 0 && "${value:0:$half}" == "${value:$half}" ]]; then
    yellow "That looked pasted twice. Keeping one copy."
    value="${value:0:$half}"
  fi
  [[ ${#value} -ge 8 ]] || fail "That key looks too short"
  printf -v "$2" '%s' "$value"
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
[[ -f backend/src/wallets/service.ts ]] || fail "Run this from ~/dataonchain after Phase 6 (script 08)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/09_pricing.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Settings ----------------------------------------------------------------
step "VTpass sandbox keys (from sandbox.vtpass.com > Profile > API Keys)"
if [[ -z "$(env_get VTPASS_API_KEY)" ]]; then
  echo "Paste each key when asked. Nothing shows on screen. Use right click to paste, once."
  read_key "VTpass api key" VT_API
  read_key "VTpass public key" VT_PUB
  read_key "VTpass secret key" VT_SEC
  printf '\n# VTpass (sandbox)\n' >> "$ENV_FILE"
  env_set VTPASS_BASE_URL "https://sandbox.vtpass.com/api"
  env_set VTPASS_API_KEY "$VT_API"
  env_set VTPASS_PUBLIC_KEY "$VT_PUB"
  env_set VTPASS_SECRET_KEY "$VT_SEC"
  unset VT_API VT_PUB VT_SEC
fi
green "OK: VTpass keys saved in $ENV_FILE"

if [[ -z "$(env_get PRICING_MARGIN_BPS)" ]]; then
  printf '\n# Pricing\n' >> "$ENV_FILE"
  read -r -p "Your margin on each sale, in percent [2]: " MARGIN
  MARGIN="${MARGIN:-2}"; MARGIN="${MARGIN%\%}"
  [[ "$MARGIN" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || fail "Enter a number like 2 or 2.5"
  BPS="$(python3 -c "print(round(float('$MARGIN') * 100))")"
  (( BPS <= 2000 )) || fail "That margin is above 20%. Please check it."
  env_set PRICING_MARGIN_BPS "$BPS"
  env_set QUOTE_TTL_MINUTES "10"
fi
green "OK: margin $(python3 -c "print($(env_get PRICING_MARGIN_BPS) / 100)")% (PRICING_MARGIN_BPS=$(env_get PRICING_MARGIN_BPS))"

# --- 2. Backend code ------------------------------------------------------------
step "Writing backend files"

cat >> backend/.env.example <<'EOF'

# VTpass (run setup/09_pricing.sh to fill these)
VTPASS_BASE_URL=https://sandbox.vtpass.com/api
VTPASS_API_KEY=your-api-key
VTPASS_PUBLIC_KEY=your-public-key
VTPASS_SECRET_KEY=your-secret-key

# Pricing. 200 = 2% margin. Set NGN_PER_USDC to use a fixed rate instead of the live one.
PRICING_MARGIN_BPS=200
QUOTE_TTL_MINUTES=10
# NGN_PER_USDC=1500
EOF
awk '!(/^# VTpass \(run/ && a++) && !(/^VTPASS_BASE_URL=/ && b++) && !(/^VTPASS_API_KEY=/ && c++) && !(/^VTPASS_PUBLIC_KEY=/ && d++) && !(/^VTPASS_SECRET_KEY=/ && e++) && !(/^# Pricing\. 200/ && f++) && !(/^PRICING_MARGIN_BPS=/ && g++) && !(/^QUOTE_TTL_MINUTES=/ && h++) && !(/^# NGN_PER_USDC=/ && i++)' \
  backend/.env.example > backend/.env.example.tmp && mv backend/.env.example.tmp backend/.env.example

cat > backend/src/env.ts <<'EOF'
// Reads and checks backend settings once, at startup.
// Locally they come from backend/.env; on Render from the dashboard.
import { config } from "dotenv";

config({ path: ".env", quiet: true });

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set. Check backend/.env`);
  return value;
}

function optionalNumber(name: string): number | undefined {
  const raw = process.env[name];
  if (!raw) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive number`);
  return value;
}

const NODE_ENV = process.env.NODE_ENV ?? "development";

export const env = {
  NODE_ENV,
  PORT: Number(process.env.PORT ?? 4000),
  FRONTEND_URLS: (process.env.FRONTEND_URL ?? "http://localhost:3000")
    .split(",")
    .map((url) => url.trim().replace(/\/$/, ""))
    .filter(Boolean),
  TURSO_DATABASE_URL: required("TURSO_DATABASE_URL"),
  TURSO_AUTH_TOKEN: process.env.TURSO_AUTH_TOKEN,
  BETTER_AUTH_SECRET: required("BETTER_AUTH_SECRET"),
  BETTER_AUTH_URL: required("BETTER_AUTH_URL").replace(/\/$/, ""),
  // Email: required in production, optional locally (emails print to the terminal)
  RESEND_API_KEY: NODE_ENV === "production" ? required("RESEND_API_KEY") : process.env.RESEND_API_KEY,
  EMAIL_FROM: NODE_ENV === "production"
    ? required("EMAIL_FROM")
    : (process.env.EMAIL_FROM ?? "dataonchain <onboarding@resend.dev>"),
  // Circle developer controlled wallets
  CIRCLE_API_KEY: required("CIRCLE_API_KEY"),
  CIRCLE_ENTITY_SECRET: required("CIRCLE_ENTITY_SECRET"),
  CIRCLE_WALLET_SET_ID: required("CIRCLE_WALLET_SET_ID"),
  CIRCLE_BLOCKCHAIN: process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET",
  // VTpass
  VTPASS_BASE_URL: (process.env.VTPASS_BASE_URL ?? "https://sandbox.vtpass.com/api").replace(/\/$/, ""),
  VTPASS_API_KEY: required("VTPASS_API_KEY"),
  VTPASS_PUBLIC_KEY: required("VTPASS_PUBLIC_KEY"),
  VTPASS_SECRET_KEY: required("VTPASS_SECRET_KEY"),
  // Pricing
  PRICING_MARGIN_BPS: optionalNumber("PRICING_MARGIN_BPS") ?? 200,
  QUOTE_TTL_MINUTES: optionalNumber("QUOTE_TTL_MINUTES") ?? 10,
  NGN_PER_USDC: optionalNumber("NGN_PER_USDC"),
};
EOF

mkdir -p backend/src/vtpass backend/src/catalog backend/src/pricing
cat > backend/src/vtpass/client.ts <<'EOF'
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
EOF

cat > backend/src/catalog/plans.ts <<'EOF'
// Data plans, copied from VTpass into our database and refreshed every 6 hours.
import { and, asc, eq, lt, max } from "drizzle-orm";
import { db } from "../db";
import { NETWORKS, dataPlans } from "../db/schema";
import { getDataVariations, type Network } from "../vtpass/client";

const REFRESH_AFTER_MS = 6 * 60 * 60 * 1000;
const syncing = new Map<Network, Promise<void>>();

export type DataPlan = typeof dataPlans.$inferSelect;

export function isNetwork(value: unknown): value is Network {
  return typeof value === "string" && (NETWORKS as readonly string[]).includes(value);
}

export async function syncDataPlans(network: Network): Promise<number> {
  const startedAt = new Date();
  const variations = await getDataVariations(network);
  let saved = 0;
  for (const v of variations) {
    const priceKobo = Math.round(Number.parseFloat(v.variation_amount) * 100);
    const name = String(v.name ?? "").trim();
    if (!v.variation_code || !name || !Number.isFinite(priceKobo) || priceKobo <= 0) continue;
    await db
      .insert(dataPlans)
      .values({
        provider: "vtpass",
        serviceType: "data",
        network,
        planCode: v.variation_code,
        name,
        priceKobo,
        active: true,
        syncedAt: startedAt,
      })
      .onConflictDoUpdate({
        target: [dataPlans.provider, dataPlans.network, dataPlans.planCode],
        set: { name, priceKobo, active: true, syncedAt: startedAt },
      });
    saved++;
  }
  // Plans VTpass no longer offers are hidden, never deleted (old orders point at them).
  await db
    .update(dataPlans)
    .set({ active: false })
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network), lt(dataPlans.syncedAt, startedAt)));
  return saved;
}

async function refreshIfStale(network: Network): Promise<void> {
  const [row] = await db
    .select({ last: max(dataPlans.syncedAt) })
    .from(dataPlans)
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network)));
  const last = row?.last ? new Date(row.last).getTime() : 0;
  if (Date.now() - last < REFRESH_AFTER_MS) return;

  let running = syncing.get(network);
  if (!running) {
    running = syncDataPlans(network)
      .then(() => undefined)
      .finally(() => syncing.delete(network));
    syncing.set(network, running);
  }
  try {
    await running;
  } catch (err) {
    // Keep selling with the plans we already have; only fail if we have none.
    console.error(`[plans] refresh for ${network} failed:`, err);
    if (!last) throw err;
  }
}

export async function listDataPlans(network: Network): Promise<DataPlan[]> {
  await refreshIfStale(network);
  return db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .orderBy(asc(dataPlans.priceKobo));
}

export async function getActivePlan(planId: string, network: Network): Promise<DataPlan | undefined> {
  const [plan] = await db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.id, planId), eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .limit(1);
  return plan;
}
EOF

cat > backend/src/pricing/rates.ts <<'EOF'
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
EOF

cat > backend/src/pricing/quote.ts <<'EOF'
// Price quotes. A quote is an order in QUOTED status with a USDC price
// that is held until quoteExpiresAt.
import { randomInt } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { normalizeNigerianPhone } from "../auth/phone";
import { getActivePlan, isNetwork } from "../catalog/plans";
import { db } from "../db";
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
      if (err instanceof Error && /UNIQUE/i.test(err.message) && attempt < 4) continue;
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
EOF

cat > backend/scripts/pricing-smoke.ts <<'EOF'
// Checks pricing end to end against the development database and the
// VTpass sandbox, using a temporary user. Cleans up after itself.
// Run with: npx tsx scripts/pricing-smoke.ts
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { listDataPlans } from "../src/catalog/plans";
import { db } from "../src/db";
import { orders, users } from "../src/db/schema";
import { getCurrentRate } from "../src/pricing/rates";
import { QuoteError, createQuote, getQuote, priceInUsdc } from "../src/pricing/quote";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function rejects(fn: () => Promise<unknown>, label: string) {
  try {
    await fn();
  } catch (err) {
    check(err instanceof QuoteError, label, err instanceof Error ? err.message : err);
    return;
  }
  check(false, label, "it was accepted");
}

async function main() {
  // Pure maths: the price always covers cost plus margin, never a micro USDC more than needed.
  const { marginKobo, usdcMicro } = priceInUsdc(100_000, 133_017, 200);
  check(marginKobo === 2_000, "2% margin on ₦1,000 is ₦20");
  check(usdcMicro * 133_017 >= 102_000 * 1_000_000 && (usdcMicro - 1) * 133_017 < 102_000 * 1_000_000,
    "USDC price is rounded up, by less than 0.000001 USDC");

  const rate = await getCurrentRate();
  check(rate.koboPerUsdc > 50_000 && rate.koboPerUsdc < 5_000_000,
    `exchange rate looks sensible (₦${(rate.koboPerUsdc / 100).toLocaleString("en-NG")} per USDC, from ${rate.source})`);

  const plans = await listDataPlans("mtn");
  check(plans.length > 0, `VTpass sandbox MTN data plans loaded (${plans.length} plans)`);
  check(plans.every((p) => p.priceKobo > 0), "every plan has a price");

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId,
    name: "Pricing Smoke Test",
    email: `pricingsmoke+${Date.now()}@example.com`,
    emailVerified: true,
    phone: "+2348012345678",
  });

  try {
    const plan = plans[0]!;
    const dataQuote = await createQuote(userId, {
      serviceType: "data", network: "mtn", planId: plan.id, phone: "08011111111",
    });
    check(dataQuote.status === "QUOTED" && /^ARC\d{8}$/.test(dataQuote.reference), `data quote created (${dataQuote.reference})`);
    check(dataQuote.ngnAmount === plan.priceKobo / 100, "data quote uses the plan price");
    check(Number(dataQuote.usdcAmount) > 0, `data quote has a USDC price (${dataQuote.usdcAmount} USDC)`);
    check(new Date(dataQuote.expiresAt).getTime() > Date.now(), "the price is held for a while");

    const airtime = await createQuote(userId, {
      serviceType: "airtime", network: "glo", amountNgn: 500, phone: "+234 801 111 1111",
    });
    check(airtime.ngnAmount === 500 && airtime.phone === "08011111111", "airtime quote created and phone saved in one format");

    const again = await getQuote(userId, dataQuote.reference);
    check(again?.reference === dataQuote.reference, "a quote can be read back");
    const stranger = await getQuote(randomUUID(), dataQuote.reference);
    check(stranger === null, "nobody else can read your quote");

    await rejects(() => createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 10, phone: "08011111111" }),
      "airtime below ₦50 is refused");
    await rejects(() => createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "12345" }),
      "an invalid phone number is refused");
    await rejects(() => createQuote(userId, { serviceType: "data", network: "mtn", planId: "no-such-plan", phone: "08011111111" }),
      "an unknown data plan is refused");
    await rejects(() => createQuote(userId, { serviceType: "data", network: "starcomms", planId: plan.id, phone: "08011111111" }),
      "an unknown network is refused");
  } finally {
    await db.delete(orders).where(eq(orders.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user and quotes");
  }
}

main()
  .then(() => {
    console.log("All pricing checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
EOF

python3 - <<'PY'
import re, sys
p = "backend/src/app.ts"
s = open(p).read()
if "createQuote" not in s:
    s = s.replace(
        'import { env } from "./env";',
        'import { env } from "./env";\n'
        'import { isNetwork, listDataPlans } from "./catalog/plans";\n'
        'import { QuoteError, createQuote, getQuote } from "./pricing/quote";',
        1,
    )
    routes = '''// Data plans for one network (refreshed from VTpass every 6 hours)
app.get("/api/plans", requireAuth, async (c) => {
  const network = c.req.query("network");
  if (!isNetwork(network)) {
    return c.json({ error: "Choose a network: mtn, airtel, glo or 9mobile" }, 400);
  }
  const plans = await listDataPlans(network);
  return c.json({
    plans: plans.map((p) => ({ id: p.id, name: p.name, ngnAmount: p.priceKobo / 100, validity: p.validity })),
  });
});

// A price in USDC, held for a few minutes
app.post("/api/quotes", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) {
    return c.json({ error: "Please confirm your email first" }, 403);
  }
  const body = await c.req.json().catch(() => null);
  try {
    return c.json({ quote: await createQuote(user.id, body) });
  } catch (err) {
    if (err instanceof QuoteError) return c.json({ error: err.message }, 400);
    throw err;
  }
});

app.get("/api/quotes/:reference", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const quote = await getQuote(user.id, c.req.param("reference"));
  if (!quote) return c.json({ error: "Quote not found" }, 404);
  return c.json({ quote });
});

'''
    marker = "app.notFound("
    if marker not in s:
        sys.exit("could not find app.notFound in app.ts")
    s = s.replace(marker, routes + marker, 1)
s = re.sub(r'c\.json\(\{ ok: true[^}]*\}\)',
           'c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true })', s, count=1)
open(p, "w").write(s)
PY
grep -q 'pricing: true' backend/src/app.ts || fail "Could not update /api/status in backend/src/app.ts"
grep -q '"/api/quotes"' backend/src/app.ts || fail "Could not add the quote routes to backend/src/app.ts"
green "OK: backend files written"

# --- 3. Frontend code -----------------------------------------------------------
step "Writing frontend files"

cat > frontend/src/lib/api.ts <<'EOF'
// Calls the backend through the website's /api pass through.
// Errors carry the backend's own message, ready to show to the user.
export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`/api${path}`, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  const body: unknown = await res.json().catch(() => null);
  if (!res.ok) {
    const message =
      body && typeof body === "object" && "error" in body
        ? String((body as { error: unknown }).error)
        : `Something went wrong (${res.status}). Please try again.`;
    throw new Error(message);
  }
  return body as T;
}
EOF

mkdir -p frontend/src/app/buy
cat > frontend/src/app/buy/page.tsx <<'EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Network = "mtn" | "airtel" | "glo" | "9mobile";
type Service = "data" | "airtime";
type Plan = { id: string; name: string; ngnAmount: number; validity: string | null };
type Quote = {
  reference: string;
  status: string;
  serviceType: Service;
  network: Network;
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  expiresAt: string;
  rate?: number;
  marginPercent?: number;
};

const NETWORKS: { id: Network; label: string }[] = [
  { id: "mtn", label: "MTN" },
  { id: "airtel", label: "Airtel" },
  { id: "glo", label: "Glo" },
  { id: "9mobile", label: "9mobile" },
];
const QUICK_AMOUNTS = [100, 200, 500, 1000, 2000];

const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
const localPhone = (p?: string | null) => (p ? (p.startsWith("+234") ? `0${p.slice(4)}` : p) : "");
const networkLabel = (id: Network) => NETWORKS.find((n) => n.id === id)?.label ?? id;

function choiceClass(active: boolean) {
  return `rounded-lg border px-3 py-2 text-sm font-medium transition ${
    active
      ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
  }`;
}

export default function BuyPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [service, setService] = useState<Service>("data");
  const [network, setNetwork] = useState<Network>("mtn");
  const [plans, setPlans] = useState<Plan[]>([]);
  const [plansLoading, setPlansLoading] = useState(false);
  const [planId, setPlanId] = useState("");
  const [amount, setAmount] = useState("");
  const [phone, setPhone] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [balance, setBalance] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  // Start with the user's own number; they can change it.
  useEffect(() => {
    if (session) setPhone((p) => p || localPhone((session.user as { phone?: string }).phone));
  }, [session]);

  useEffect(() => {
    if (!session) return;
    api<{ balance: { usdc: string | null } }>("/wallet")
      .then((r) => setBalance(r.balance.usdc))
      .catch(() => setBalance(null));
  }, [session]);

  useEffect(() => {
    if (!session || service !== "data") return;
    let cancelled = false;
    setPlansLoading(true);
    setPlanId("");
    setError(null);
    api<{ plans: Plan[] }>(`/plans?network=${network}`)
      .then((r) => !cancelled && setPlans(r.plans))
      .catch((e: Error) => !cancelled && setError(e.message))
      .finally(() => !cancelled && setPlansLoading(false));
    return () => {
      cancelled = true;
    };
  }, [session, service, network]);

  useEffect(() => {
    if (!quote) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [quote]);

  async function getPrice(event?: FormEvent<HTMLFormElement>) {
    event?.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const body =
        service === "data"
          ? { serviceType: "data", network, planId, phone }
          : { serviceType: "airtime", network, amountNgn: Number(amount), phone };
      const r = await api<{ quote: Quote }>("/quotes", { method: "POST", body: JSON.stringify(body) });
      setQuote(r.quote);
      setNow(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not get a price. Please try again.");
    } finally {
      setBusy(false);
    }
  }

  if (isPending || !session) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const secondsLeft = quote ? Math.max(0, Math.floor((new Date(quote.expiresAt).getTime() - now) / 1000)) : 0;
  const expired = quote !== null && secondsLeft === 0;
  const notEnough = quote !== null && balance !== null && Number(balance) < Number(quote.usdcAmount);

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-xl">
        <header className="flex items-center justify-between">
          <Link href="/dashboard" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/dashboard" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Buy airtime or data</h1>
        {balance !== null ? (
          <p className="mt-1 text-sm text-zinc-500">Your balance: {usdc(balance)} USDC</p>
        ) : null}

        {!quote ? (
          <form onSubmit={getPrice} className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">What do you want?</legend>
              <div className="mt-2 grid grid-cols-2 gap-2">
                <button type="button" onClick={() => setService("data")} className={choiceClass(service === "data")}>Data</button>
                <button type="button" onClick={() => setService("airtime")} className={choiceClass(service === "airtime")}>Airtime</button>
              </div>
            </fieldset>

            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Network</legend>
              <div className="mt-2 grid grid-cols-4 gap-2">
                {NETWORKS.map((n) => (
                  <button key={n.id} type="button" onClick={() => setNetwork(n.id)} className={choiceClass(network === n.id)}>
                    {n.label}
                  </button>
                ))}
              </div>
            </fieldset>

            {service === "data" ? (
              <label className="block">
                <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Data plan</span>
                <select
                  value={planId}
                  onChange={(e) => setPlanId(e.target.value)}
                  required
                  disabled={plansLoading}
                  className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                >
                  <option value="">{plansLoading ? "Loading plans..." : "Choose a plan"}</option>
                  {plans.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} ({naira(p.ngnAmount)})
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <div>
                <label className="block">
                  <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Amount in naira</span>
                  <input
                    type="number"
                    inputMode="numeric"
                    min={50}
                    max={50000}
                    step={1}
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="500"
                    required
                    className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                  />
                </label>
                <div className="mt-2 flex flex-wrap gap-2">
                  {QUICK_AMOUNTS.map((a) => (
                    <button key={a} type="button" onClick={() => setAmount(String(a))} className={choiceClass(amount === String(a))}>
                      {naira(a)}
                    </button>
                  ))}
                </div>
              </div>
            )}

            <label className="block">
              <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Phone number to top up</span>
              <input
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="08012345678"
                required
                className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
              />
              <span className="mt-1 block text-xs text-zinc-500">
                Make sure this number is on {networkLabel(network)}.
              </span>
            </label>

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            <button
              type="submit"
              disabled={busy || (service === "data" && !planId)}
              className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white transition hover:bg-emerald-800 disabled:opacity-60"
            >
              {busy ? "Getting your price..." : "Get price in USDC"}
            </button>
          </form>
        ) : (
          <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div>
              <p className="text-sm text-zinc-500">You pay</p>
              <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
                {usdc(quote.usdcAmount)} <span className="text-lg font-medium text-zinc-500">USDC</span>
              </p>
            </div>

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">For</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {networkLabel(quote.network)} {quote.serviceType === "data" ? quote.planName : `airtime ${naira(quote.ngnAmount)}`}
              </dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(quote.ngnAmount)}</dd>
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{quote.phone}</dd>
              {quote.rate ? (
                <>
                  <dt className="text-zinc-500">Rate</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">
                    1 USDC = {naira(quote.rate)}
                    {quote.marginPercent ? ` (includes ${quote.marginPercent}% service fee)` : ""}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{quote.reference}</dd>
            </dl>

            {expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                This price has expired. Get a new one to continue.
              </p>
            ) : (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Price held for {Math.floor(secondsLeft / 60)}:{String(secondsLeft % 60).padStart(2, "0")}
              </p>
            )}

            {notEnough && !expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                Your balance is not enough for this purchase. Add USDC to your wallet first.
              </p>
            ) : null}

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            {expired ? (
              <button
                onClick={() => void getPrice()}
                disabled={busy}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a new price..." : "Get a new price"}
              </button>
            ) : (
              <button
                disabled
                title="Paying with USDC arrives in the next update"
                className="w-full cursor-not-allowed rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white opacity-60"
              >
                Pay with USDC (coming next)
              </button>
            )}

            <button
              onClick={() => {
                setQuote(null);
                setError(null);
              }}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
            >
              Change details
            </button>
          </section>
        )}
      </div>
    </main>
  );
}
EOF

python3 - <<'PY'
import sys
p = "frontend/src/app/dashboard/page.tsx"
s = open(p).read()
if 'href="/buy"' not in s:
    if 'import Link from "next/link";' not in s:
        s = 'import Link from "next/link";\n' + s if not s.startswith('"use client"') else s.replace('"use client";\n', '"use client";\n\nimport Link from "next/link";', 1)
    i = s.find("Hello, ")
    j = s.find("</h1>", i)
    if i < 0 or j < 0:
        sys.exit("could not find the greeting in dashboard/page.tsx")
    j += len("</h1>")
    button = '''

        <Link
          href="/buy"
          className="mt-4 inline-block rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
        >
          Buy airtime or data
        </Link>'''
    s = s[:j] + button + s[j:]
open(p, "w").write(s)
PY
grep -q 'href="/buy"' frontend/src/app/dashboard/page.tsx || fail "Could not add the Buy button to the dashboard"
green "OK: frontend files written"

# --- 4. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Pricing: real test with the VTpass sandbox, live rate and your development database"
(cd backend && npx tsx scripts/pricing-smoke.ts) || fail "Pricing test failed (details above). Nothing was committed."

step "Wallets and auth: make sure they still work"
(cd backend && npx tsx scripts/wallet-smoke.ts) || fail "Wallet test failed (details above). Nothing was committed."
OUTBOX="$(mktemp)"
(cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  fail "Auth test failed (details above). Nothing was committed."
fi
kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 5. Render settings -------------------------------------------------------------
step "Adding 6 settings on Render"
read -r -p "Have you already added the VTPASS_ and pricing settings on Render? (y/n) " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  echo
  bold "In your browser: Render > your API service > Environment > add these 6:"
  echo
  echo "     VTPASS_BASE_URL      $(env_get VTPASS_BASE_URL)"
  echo "     PRICING_MARGIN_BPS   $(env_get PRICING_MARGIN_BPS)"
  echo "     QUOTE_TTL_MINUTES    $(env_get QUOTE_TTL_MINUTES)"
  if command -v clip.exe >/dev/null 2>&1; then
    echo "     VTPASS_API_KEY       (clipboard, next)"
    echo "     VTPASS_PUBLIC_KEY    (clipboard, after that)"
    echo "     VTPASS_SECRET_KEY    (clipboard, last)"
    echo
    to_clipboard "$(env_get VTPASS_API_KEY)"
    pause "VTPASS_API_KEY is on your clipboard. Paste it on Render, then"
    to_clipboard "$(env_get VTPASS_PUBLIC_KEY)"
    pause "VTPASS_PUBLIC_KEY is on your clipboard. Paste it on Render, then"
    to_clipboard "$(env_get VTPASS_SECRET_KEY)"
    pause "VTPASS_SECRET_KEY is on your clipboard. Paste it on Render, then"
    to_clipboard " "
  else
    yellow "     VTPASS_API_KEY, VTPASS_PUBLIC_KEY, VTPASS_SECRET_KEY: copy them from $ENV_FILE"
  fi
  echo
  echo "  Then click 'Save, rebuild, and deploy' (or 'Save Changes')."
  pause "When all 6 are saved,"
fi
green "OK"

# --- 6. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Phase 7: VTpass plans, exchange rate, margin and USDC price quotes"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"pricing":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render (a missing VTPASS_ setting stops it starting)."
wait_for "the website" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 7 complete. Prices and quotes are live."
echo "  Open $PROD_FRONTEND/buy (or the 'Buy airtime or data' button on your dashboard)."
echo "  Choose data or airtime, a network and a plan, and click 'Get price in USDC'."
echo "  The first plan list for each network takes a few seconds to load from VTpass."
