#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 12: automatic refunds and faster delivery status
#
# Fixes from tester feedback:
#   1. Status not updating
#      - VTpass is asked again after 8 seconds (was 15)
#      - if VTpass says it never received a purchase, the order is marked
#        Failed after 5 minutes instead of waiting forever
#      - more VTpass "definitely failed" codes are recognised (for example 018,
#        VTpass wallet too low), so those fail at once
#      - orders under review keep being checked with VTpass every 5 minutes
#        and settle on their own as soon as VTpass gives a clear answer
#      - the dashboard order list now updates live
#      - every VTpass answer is written to the Render logs as [vtpass]
#   2. Refunds
#      - a paid order that cannot be delivered is refunded AUTOMATICALLY:
#        the USDC goes from the treasury back to the customer's wallet
#      - one refund per order, retried safely, never sent twice
#      - order page shows the refund step and its Arc transaction
#      - existing failed orders on the live site are refunded after deploy
#
# Also prints a read only report of recent live orders (before and after),
# saved in your home folder, so we can see exactly what VTpass answered.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/12_refunds.sh
# =============================================================================
set -euo pipefail

PROD_DB="dataonchainprod"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }

ENV_FILE="backend/.env"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

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

# Turso CLI prints "not logged in" without an error code, so check the text too.
turso_logged_in() {
  local out
  out="$(turso db list 2>&1)" || return 1
  ! grep -qi "not logged in\|please login\|auth login" <<<"$out"
}
turso_db_url() {
  local out
  out="$(turso db show "$1" --url 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$out" == libsql://* ]] && printf '%s' "$out"
  return 0
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
command -v turso >/dev/null || fail "Turso CLI not found (it was installed in script 01)"
[[ -f backend/src/fulfilment/service.ts ]] || fail "Run this from ~/dataonchain after Phase 9 (script 11)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/12_refunds.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing backend and frontend files"
mkdir -p backend/src/refunds
cat > "backend/src/db/schema.ts" <<'DOC_EOF'
/**
 * dataonchain database schema (Turso / SQLite, Drizzle ORM)
 *
 * Money rules:
 *   NGN amounts are stored in kobo   (₦1 = 100 kobo)
 *   USDC amounts are stored in micro (1 USDC = 1,000,000 micro, USDC has 6 decimals)
 *   Exchange rates are kobo per 1 USDC
 * Whole numbers only, so there are never rounding errors.
 *
 * Auth tables (users, sessions, accounts, verifications) follow the
 * Better Auth core schema so Phase 4 can plug straight in.
 *
 * No private keys or wallet secrets are stored anywhere in this database.
 */
import { randomUUID } from "node:crypto";
import {
  sqliteTable,
  text,
  integer,
  index,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------
const id = () =>
  text("id")
    .primaryKey()
    .$defaultFn(() => randomUUID());

const createdAt = () =>
  integer("created_at", { mode: "timestamp_ms" })
    .notNull()
    .$defaultFn(() => new Date());

const updatedAt = () =>
  integer("updated_at", { mode: "timestamp_ms" })
    .notNull()
    .$defaultFn(() => new Date())
    .$onUpdate(() => new Date());

// ---------------------------------------------------------------------------
// Allowed values
// ---------------------------------------------------------------------------
export const USER_ROLES = ["user", "admin"] as const;
export const USER_STATUSES = ["active", "suspended"] as const;
export const NETWORKS = ["mtn", "airtel", "glo", "9mobile"] as const;
export const SERVICE_TYPES = ["airtime", "data"] as const;
export const VTU_PROVIDERS = ["vtpass", "reloadly", "baxi"] as const;
export const WALLET_PURPOSES = ["user", "treasury", "gas"] as const;
export const CUSTODY_TYPES = ["DEVELOPER", "USER"] as const;
export const CURRENCIES = ["USDC", "NGN"] as const;

export const ORDER_STATUSES = [
  "QUOTED",
  "EXPIRED",
  "PAYMENT_PENDING",
  "PAYMENT_CONFIRMED",
  "FULFILMENT_PENDING",
  "FULFILLED",
  "FAILED",
  "FLAGGED",
  "REFUND_PENDING",
  "REFUNDED",
] as const;

export const PAYMENT_STATUSES = [
  "INITIATED",
  "PENDING",
  "CONFIRMED",
  "FAILED",
  "MISMATCH",
] as const;

export const VTU_STATUSES = [
  "SENT",
  "PENDING",
  "DELIVERED",
  "FAILED",
  "UNKNOWN",
] as const;

export const TREASURY_MOVEMENT_TYPES = [
  "USDC_TO_NGN",
  "FLOAT_TOPUP",
  "GAS_TOPUP",
  "ADJUSTMENT",
] as const;

export const REFUND_STATUSES = ["PENDING", "SENT", "CONFIRMED", "FAILED"] as const;

export const WEBHOOK_SOURCES = ["circle", "vtpass"] as const;
export const ACTOR_TYPES = ["user", "admin", "system"] as const;

// ---------------------------------------------------------------------------
// Auth (Better Auth core schema + our own fields)
// ---------------------------------------------------------------------------
export const users = sqliteTable("users", {
  id: id(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: integer("email_verified", { mode: "boolean" })
    .notNull()
    .default(false),
  image: text("image"),
  phone: text("phone"),
  role: text("role", { enum: USER_ROLES }).notNull().default("user"),
  status: text("status", { enum: USER_STATUSES }).notNull().default("active"),
  createdAt: createdAt(),
  updatedAt: updatedAt(),
});

export const sessions = sqliteTable(
  "sessions",
  {
    id: id(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    token: text("token").notNull().unique(),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("sessions_user_id_idx").on(t.userId)],
);

export const accounts = sqliteTable(
  "accounts",
  {
    id: id(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    accountId: text("account_id").notNull(),
    providerId: text("provider_id").notNull(),
    accessToken: text("access_token"),
    refreshToken: text("refresh_token"),
    idToken: text("id_token"),
    accessTokenExpiresAt: integer("access_token_expires_at", {
      mode: "timestamp_ms",
    }),
    refreshTokenExpiresAt: integer("refresh_token_expires_at", {
      mode: "timestamp_ms",
    }),
    scope: text("scope"),
    password: text("password"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("accounts_user_id_idx").on(t.userId)],
);

export const verifications = sqliteTable(
  "verifications",
  {
    id: id(),
    identifier: text("identifier").notNull(),
    value: text("value").notNull(),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("verifications_identifier_idx").on(t.identifier)],
);

// ---------------------------------------------------------------------------
// Wallets (Circle). user_id is empty for platform wallets (treasury, gas).
// ---------------------------------------------------------------------------
export const wallets = sqliteTable(
  "wallets",
  {
    id: id(),
    userId: text("user_id").references(() => users.id),
    purpose: text("purpose", { enum: WALLET_PURPOSES })
      .notNull()
      .default("user"),
    circleWalletId: text("circle_wallet_id").notNull().unique(),
    circleWalletSetId: text("circle_wallet_set_id").notNull(),
    custodyType: text("custody_type", { enum: CUSTODY_TYPES })
      .notNull()
      .default("DEVELOPER"),
    blockchain: text("blockchain").notNull(), // e.g. ARC-TESTNET
    address: text("address").notNull(),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    uniqueIndex("wallets_user_chain_idx").on(t.userId, t.blockchain),
    index("wallets_address_idx").on(t.address),
  ],
);

// ---------------------------------------------------------------------------
// Products and prices
// ---------------------------------------------------------------------------
export const dataPlans = sqliteTable(
  "data_plans",
  {
    id: id(),
    provider: text("provider", { enum: VTU_PROVIDERS }).notNull(),
    serviceType: text("service_type", { enum: SERVICE_TYPES }).notNull(),
    network: text("network", { enum: NETWORKS }).notNull(),
    planCode: text("plan_code").notNull(), // provider's variation code
    name: text("name").notNull(),
    validity: text("validity"),
    priceKobo: integer("price_kobo").notNull(),
    active: integer("active", { mode: "boolean" }).notNull().default(true),
    syncedAt: integer("synced_at", { mode: "timestamp_ms" }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    uniqueIndex("data_plans_provider_code_idx").on(
      t.provider,
      t.network,
      t.planCode,
    ),
    index("data_plans_network_idx").on(t.network, t.active),
  ],
);

export const exchangeRates = sqliteTable(
  "exchange_rates",
  {
    id: id(),
    source: text("source").notNull(),
    koboPerUsdc: integer("kobo_per_usdc").notNull(),
    fetchedAt: integer("fetched_at", { mode: "timestamp_ms" }).notNull(),
    createdAt: createdAt(),
  },
  (t) => [index("exchange_rates_fetched_at_idx").on(t.fetchedAt)],
);

// ---------------------------------------------------------------------------
// Orders: one row per purchase. Status only moves forward.
// ---------------------------------------------------------------------------
export const orders = sqliteTable(
  "orders",
  {
    id: id(),
    reference: text("reference").notNull().unique(), // e.g. ARC100023
    userId: text("user_id")
      .notNull()
      .references(() => users.id),
    serviceType: text("service_type", { enum: SERVICE_TYPES }).notNull(),
    network: text("network", { enum: NETWORKS }).notNull(),
    planId: text("plan_id").references(() => dataPlans.id), // empty for airtime
    phone: text("phone").notNull(),
    ngnAmountKobo: integer("ngn_amount_kobo").notNull(),
    marginKobo: integer("margin_kobo").notNull().default(0),
    usdcAmountMicro: integer("usdc_amount_micro").notNull(),
    exchangeRateId: text("exchange_rate_id")
      .notNull()
      .references(() => exchangeRates.id),
    status: text("status", { enum: ORDER_STATUSES })
      .notNull()
      .default("QUOTED"),
    quoteExpiresAt: integer("quote_expires_at", {
      mode: "timestamp_ms",
    }).notNull(),
    failureReason: text("failure_reason"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("orders_user_id_idx").on(t.userId),
    index("orders_status_idx").on(t.status),
  ],
);

// ---------------------------------------------------------------------------
// Payments on Arc. A transaction hash can confirm only one order.
// ---------------------------------------------------------------------------
export const payments = sqliteTable(
  "payments",
  {
    id: id(),
    orderId: text("order_id")
      .notNull()
      .references(() => orders.id),
    walletId: text("wallet_id").references(() => wallets.id),
    circleTransactionId: text("circle_transaction_id").unique(),
    txHash: text("tx_hash").unique(),
    fromAddress: text("from_address"),
    toAddress: text("to_address").notNull(),
    token: text("token").notNull().default("USDC"),
    blockchain: text("blockchain").notNull(),
    amountMicro: integer("amount_micro").notNull(),
    status: text("status", { enum: PAYMENT_STATUSES })
      .notNull()
      .default("INITIATED"),
    confirmedAt: integer("confirmed_at", { mode: "timestamp_ms" }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("payments_order_id_idx").on(t.orderId),
    index("payments_status_idx").on(t.status),
  ],
);

// ---------------------------------------------------------------------------
// VTU provider calls. request_id is sent once; retries reuse it.
// ---------------------------------------------------------------------------
export const vtuTransactions = sqliteTable(
  "vtu_transactions",
  {
    id: id(),
    orderId: text("order_id")
      .notNull()
      .references(() => orders.id),
    provider: text("provider", { enum: VTU_PROVIDERS }).notNull(),
    requestId: text("request_id").notNull().unique(),
    providerReference: text("provider_reference"),
    attempt: integer("attempt").notNull().default(1),
    status: text("status", { enum: VTU_STATUSES }).notNull().default("SENT"),
    requestPayload: text("request_payload", { mode: "json" }),
    responsePayload: text("response_payload", { mode: "json" }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("vtu_transactions_order_id_idx").on(t.orderId),
    index("vtu_transactions_status_idx").on(t.status),
  ],
);

// ---------------------------------------------------------------------------
// Ledger: every money movement, as debit and credit lines.
// Lines that belong together share one journal_id and must balance.
// Accounts look like: user:<id>, treasury:usdc, vtpass:float, revenue:margin
// ---------------------------------------------------------------------------
export const ledgerEntries = sqliteTable(
  "ledger_entries",
  {
    id: id(),
    journalId: text("journal_id").notNull(),
    account: text("account").notNull(),
    orderId: text("order_id").references(() => orders.id),
    currency: text("currency", { enum: CURRENCIES }).notNull(),
    debit: integer("debit").notNull().default(0),
    credit: integer("credit").notNull().default(0),
    memo: text("memo"),
    createdAt: createdAt(),
  },
  (t) => [
    index("ledger_entries_journal_idx").on(t.journalId),
    index("ledger_entries_account_idx").on(t.account),
  ],
);

// ---------------------------------------------------------------------------
// Treasury: USDC conversions and provider float top ups (manual for MVP)
// ---------------------------------------------------------------------------
export const treasuryMovements = sqliteTable("treasury_movements", {
  id: id(),
  type: text("type", { enum: TREASURY_MOVEMENT_TYPES }).notNull(),
  usdcAmountMicro: integer("usdc_amount_micro"),
  ngnAmountKobo: integer("ngn_amount_kobo"),
  koboPerUsdc: integer("kobo_per_usdc"),
  reference: text("reference"),
  note: text("note"),
  createdBy: text("created_by").references(() => users.id),
  createdAt: createdAt(),
});

// ---------------------------------------------------------------------------
// Refunds: USDC sent back from the treasury to the customer's wallet when a
// paid order could not be delivered. At most one refund per order.
// ---------------------------------------------------------------------------
export const refunds = sqliteTable(
  "refunds",
  {
    id: id(),
    orderId: text("order_id")
      .notNull()
      .unique()
      .references(() => orders.id),
    paymentId: text("payment_id")
      .notNull()
      .references(() => payments.id),
    toAddress: text("to_address").notNull(),
    token: text("token").notNull(),
    blockchain: text("blockchain").notNull(),
    amountMicro: integer("amount_micro").notNull(),
    attempt: integer("attempt").notNull().default(1),
    circleTransactionId: text("circle_transaction_id").unique(),
    txHash: text("tx_hash").unique(),
    status: text("status", { enum: REFUND_STATUSES }).notNull().default("PENDING"),
    lastError: text("last_error"),
    confirmedAt: integer("confirmed_at", { mode: "timestamp_ms" }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("refunds_status_idx").on(t.status)],
);

// ---------------------------------------------------------------------------
// Webhooks: each event is stored once and processed once.
// ---------------------------------------------------------------------------
export const webhookEvents = sqliteTable(
  "webhook_events",
  {
    id: id(),
    source: text("source", { enum: WEBHOOK_SOURCES }).notNull(),
    eventId: text("event_id").notNull(),
    type: text("type"),
    payload: text("payload", { mode: "json" }).notNull(),
    processedAt: integer("processed_at", { mode: "timestamp_ms" }),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("webhook_events_source_event_idx").on(t.source, t.eventId)],
);

// ---------------------------------------------------------------------------
// Audit log: admin and system actions
// ---------------------------------------------------------------------------
export const auditLogs = sqliteTable(
  "audit_logs",
  {
    id: id(),
    actorType: text("actor_type", { enum: ACTOR_TYPES }).notNull(),
    actorId: text("actor_id"),
    action: text("action").notNull(),
    targetType: text("target_type"),
    targetId: text("target_id"),
    details: text("details", { mode: "json" }),
    createdAt: createdAt(),
  },
  (t) => [index("audit_logs_target_idx").on(t.targetType, t.targetId)],
);
DOC_EOF

cat > "backend/src/vtpass/client.ts" <<'DOC_EOF'
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
DOC_EOF

cat > "backend/src/refunds/service.ts" <<'DOC_EOF'
// Automatic refunds: when a paid order cannot be delivered, the USDC goes
// back from the treasury wallet to the customer's wallet.
//
// Order:  FAILED -> REFUND_PENDING -> REFUNDED   (or FLAGGED if Circle keeps refusing)
// Refund: PENDING -> SENT -> CONFIRMED           (or FAILED)
//
// Safety:
//   - only orders whose payment was CONFIRMED on Arc are refunded
//   - claiming FAILED -> REFUND_PENDING is conditional, so only one caller wins
//   - one refund row per order (unique order_id)
//   - every Circle transfer uses an idempotency key made from the order id and
//     the attempt number, so a retry can never send the money twice
import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, ledgerEntries, orders, payments, refunds } from "../db/schema";
import { env } from "../env";

const MAX_ATTEMPTS = 3;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// The treasury pays the Arc network fee for refunds, so keep a little extra
const FEE_RESERVE_MICRO = 50_000;

type Order = typeof orders.$inferSelect;
type Refund = typeof refunds.$inferSelect;

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export function microText(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

function microFrom(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

async function audit(action: string, orderId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId: orderId, details });
}

async function treasuryBalanceMicro(): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc ? microFrom(usdc.amount) : 0;
}

async function confirmedPayment(orderId: string) {
  const [payment] = await db
    .select()
    .from(payments)
    .where(and(eq(payments.orderId, orderId), eq(payments.status, "CONFIRMED")))
    .orderBy(desc(payments.createdAt))
    .limit(1);
  return payment;
}

// Makes sure the refund row exists. Returns it, or nothing if the order was never paid.
async function ensureRefundRow(order: Order): Promise<Refund | undefined> {
  const [existing] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  if (existing) return existing;
  const payment = await confirmedPayment(order.id);
  if (!payment?.fromAddress) return undefined;
  await db
    .insert(refunds)
    .values({
      orderId: order.id,
      paymentId: payment.id,
      toAddress: payment.fromAddress,
      token: payment.token,
      blockchain: payment.blockchain,
      amountMicro: payment.amountMicro,
      status: "PENDING",
    })
    .onConflictDoNothing();
  const [row] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  return row;
}

// Starts the refund for a FAILED order. Safe to call many times.
export async function startRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "FAILED") return;
  // A payment that never completed took no money, so there is nothing to refund
  if (!(await confirmedPayment(order.id))) return;

  const [claimed] = await db
    .update(orders)
    .set({ status: "REFUND_PENDING" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "FAILED")))
    .returning();
  if (!claimed) return;
  await audit("refund.started", order.id, { amountMicro: order.usdcAmountMicro });
  await advanceRefund(order.id);
}

// Moves a REFUND_PENDING order forward: sends the transfer, then confirms it.
export async function advanceRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "REFUND_PENDING") return;
  const refund = await ensureRefundRow(order);
  if (!refund) {
    // Should never happen: no confirmed payment. Put it in front of a person.
    await db
      .update(orders)
      .set({ status: "FLAGGED", failureReason: "Refund needs review: no confirmed payment was found." })
      .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
    return;
  }
  if (refund.status === "PENDING") await sendRefund(order, refund);
  else if (refund.status === "SENT") await checkRefund(order, refund);
}

async function sendRefund(order: Order, refund: Refund): Promise<void> {
  const balance = await treasuryBalanceMicro();
  if (balance < refund.amountMicro + FEE_RESERVE_MICRO) {
    console.error(`[refund] ${order.reference}: treasury has ${microText(balance)} USDC, needs ${microText(refund.amountMicro)} plus fees. Will retry.`);
    return;
  }
  const amount = microText(refund.amountMicro);
  const input = {
    walletId: env.TREASURY_WALLET_ID,
    tokenId: refund.token,
    destinationAddress: refund.toAddress,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    // Same order and attempt: same key, so Circle never sends it twice
    idempotencyKey: uuidFrom(`refund:${order.id}:${refund.attempt}`),
    refId: `REFUND-${order.reference}`,
  };
  let transactionId: string | undefined;
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    transactionId = res.data?.id;
  } catch (err) {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[refund] ${order.reference} transfer not accepted yet:`, message, detail ?? "");
    await db.update(refunds).set({ lastError: message.slice(0, 500) }).where(eq(refunds.id, refund.id));
    return;
  }
  if (!transactionId) return;
  await db
    .update(refunds)
    .set({ circleTransactionId: transactionId, status: "SENT", lastError: null })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "PENDING")));
  console.log(`[refund] ${order.reference}: sent ${amount} USDC back to ${refund.toAddress}`);
}

async function checkRefund(order: Order, refund: Refund): Promise<void> {
  if (!refund.circleTransactionId) return;
  const res = await circle.getTransaction({ id: refund.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (!tx?.state) return;

  if (FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`;
    if (refund.attempt >= MAX_ATTEMPTS) {
      await db.update(refunds).set({ status: "FAILED", lastError: reason }).where(eq(refunds.id, refund.id));
      await db
        .update(orders)
        .set({ status: "FLAGGED", failureReason: "Your refund needs a manual check. Our team has been alerted." })
        .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
      await audit("refund.failed", order.id, { reason, attempts: refund.attempt });
      console.error(`[refund] ${order.reference} FAILED after ${refund.attempt} attempts: ${reason}`);
      return;
    }
    // Nothing moved. Try again with the next attempt number (a new idempotency key).
    await db
      .update(refunds)
      .set({ status: "PENDING", circleTransactionId: null, attempt: refund.attempt + 1, lastError: reason })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")));
    return;
  }
  if (tx.state !== "COMPLETE") return;

  const [done] = await db
    .update(refunds)
    .set({ status: "CONFIRMED", txHash: tx.txHash ?? null, confirmedAt: new Date() })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")))
    .returning();
  if (!done) return;
  await db
    .update(orders)
    .set({
      status: "REFUNDED",
      failureReason: `This order could not be delivered. ${microText(refund.amountMicro)} USDC was refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
  const journalId = randomUUID();
  await db.insert(ledgerEntries).values([
    // The customer's money goes back to them out of the treasury
    { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", debit: refund.amountMicro, memo: `Refund ${order.reference}` },
    { journalId, account: "treasury:usdc", orderId: order.id, currency: "USDC", credit: refund.amountMicro, memo: `Refund ${order.reference}` },
  ]);
  await audit("refund.confirmed", order.id, { txHash: tx.txHash, amountMicro: refund.amountMicro });
}

export async function getRefundView(orderId: string) {
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, orderId)).limit(1);
  if (!refund) return null;
  return {
    status: refund.status,
    amount: microText(refund.amountMicro),
    txHash: refund.txHash,
    explorerUrl: refund.txHash ? `${env.EXPLORER_TX_URL}${refund.txHash}` : null,
  };
}
DOC_EOF

cat > "backend/src/fulfilment/service.ts" <<'DOC_EOF'
// Delivering paid orders through VTpass.
//
// Order: PAYMENT_CONFIRMED -> FULFILMENT_PENDING -> FULFILLED  (or FAILED / FLAGGED)
// VTU:   SENT -> DELIVERED                                     (or PENDING / FAILED)
//
// Golden rule: each order is sent to VTpass at most ONCE, with one request id.
// When the answer is unclear we ask VTpass again (requery). We never resend,
// so a customer can never receive twice.
//
// A FAILED order (money taken, nothing delivered) is refunded automatically.
import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray } from "drizzle-orm";
import { db } from "../db";
import { auditLogs, dataPlans, ledgerEntries, orders, vtuTransactions } from "../db/schema";
import { startRefund } from "../refunds/service";
import { SERVICE_IDS, makeRequestId, purchase, requery, type VtOutcome } from "../vtpass/client";

// How long to wait before asking VTpass again about an unclear purchase
const REQUERY_AFTER_MS = 8_000;
// Orders under review are asked about less often, for up to 3 days
const FLAGGED_REQUERY_AFTER_MS = 5 * 60_000;
const FLAGGED_GIVE_UP_MS = 3 * 24 * 60 * 60_000;
// VTpass says it never received the request (code 015) for this long: it failed
const NOT_FOUND_FAIL_AFTER_MS = 5 * 60_000;
// Still unclear after this long: put the order under review
const FLAG_AFTER_MS = 30 * 60_000;

const OPEN_VTU = ["SENT", "PENDING", "UNKNOWN"] as const;
// Orders whose delivery can still be settled by VTpass
const OPEN_ORDER = ["FULFILMENT_PENDING", "FLAGGED"] as const;

type Order = typeof orders.$inferSelect;
type VtuTx = typeof vtuTransactions.$inferSelect;

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

function usdcText(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

async function audit(action: string, orderId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId: orderId, details });
}

export async function fulfilOrder(orderId: string): Promise<void> {
  // Claim the order. Only one caller (web request or worker) can win.
  const [order] = await db
    .update(orders)
    .set({ status: "FULFILMENT_PENDING" })
    .where(and(eq(orders.id, orderId), eq(orders.status, "PAYMENT_CONFIRMED")))
    .returning();
  if (!order) return;

  const phone = localPhone(order.phone);
  let payload: Record<string, unknown>;
  if (order.serviceType === "data") {
    const [plan] = order.planId
      ? await db.select().from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1)
      : [];
    if (!plan) {
      await failOrder(order, "the data plan is no longer available");
      return;
    }
    payload = {
      serviceID: SERVICE_IDS.data[order.network],
      billersCode: phone,
      variation_code: plan.planCode,
      amount: Math.round(plan.priceKobo / 100),
      phone,
    };
  } else {
    payload = {
      serviceID: SERVICE_IDS.airtime[order.network],
      amount: Math.round(order.ngnAmountKobo / 100),
      phone,
    };
  }

  const requestId = makeRequestId();
  payload = { request_id: requestId, ...payload };
  const [tx] = await db
    .insert(vtuTransactions)
    .values({ orderId: order.id, provider: "vtpass", requestId, status: "SENT", requestPayload: payload })
    .returning();
  if (!tx) throw new Error("Could not save the VTpass request");

  const started = Date.now();
  const outcome = await purchase(payload);
  console.log(`[vtpass] ${order.reference} pay -> ${outcome.result} ${outcome.code} ${outcome.message} (${Date.now() - started} ms)`);
  await applyOutcome(order, tx, outcome);
}

async function applyOutcome(order: Order, tx: VtuTx, outcome: VtOutcome): Promise<void> {
  if (outcome.result === "DELIVERED") {
    const [done] = await db
      .update(vtuTransactions)
      .set({ status: "DELIVERED", providerReference: outcome.providerReference ?? null, responsePayload: outcome.raw })
      .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])))
      .returning();
    if (!done) return;
    const [fulfilled] = await db
      .update(orders)
      .set({ status: "FULFILLED", failureReason: null })
      .where(and(eq(orders.id, order.id), inArray(orders.status, [...OPEN_ORDER])))
      .returning();
    if (!fulfilled) return;
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      // The customer's payment becomes a completed sale
      { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", debit: order.usdcAmountMicro, memo: `Delivered ${order.reference}` },
      { journalId, account: "revenue:sales", orderId: order.id, currency: "USDC", credit: order.usdcAmountMicro, memo: `Delivered ${order.reference}` },
      // VTpass took the naira cost from our float
      { journalId, account: "cost:vtu", orderId: order.id, currency: "NGN", debit: order.ngnAmountKobo, memo: `VTpass ${tx.requestId}` },
      { journalId, account: "vtpass:float", orderId: order.id, currency: "NGN", credit: order.ngnAmountKobo, memo: `VTpass ${tx.requestId}` },
    ]);
    return;
  }

  if (outcome.result === "FAILED") {
    const [closed] = await db
      .update(vtuTransactions)
      .set({ status: "FAILED", providerReference: outcome.providerReference ?? null, responsePayload: outcome.raw })
      .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])))
      .returning();
    if (!closed) return;
    if (outcome.code === "018") console.error("[vtpass] code 018: the VTpass wallet balance is too low. Fund it.");
    if (outcome.code === "027") console.error("[vtpass] code 027: this server's IP address is not whitelisted on VTpass");
    if (outcome.code === "028") console.error("[vtpass] code 028: this product is not whitelisted on the VTpass account (Account Settings > Whitelist Products)");
    await failOrder(order, outcome.message);
    return;
  }

  // PENDING: keep the order waiting; it will be asked about again.
  await db
    .update(vtuTransactions)
    .set({
      status: "PENDING",
      providerReference: outcome.providerReference ?? tx.providerReference,
      responsePayload: outcome.raw ?? tx.responsePayload,
      attempt: tx.attempt + 1,
    })
    .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])));
}

async function failOrder(order: Order, reason: string) {
  const [failed] = await db
    .update(orders)
    .set({
      status: "FAILED",
      failureReason: `Delivery failed (${reason}). Your ${usdcText(order.usdcAmountMicro)} USDC is being refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), inArray(orders.status, [...OPEN_ORDER])))
    .returning();
  if (!failed) return;
  await audit("delivery.failed", order.id, { reason });
  try {
    await startRefund(order.id);
  } catch (err) {
    // The worker tries again in 30 seconds
    console.error(`[refund] ${order.reference} could not start yet:`, err instanceof Error ? err.message : err);
  }
}

// Moves an unsettled order forward by asking VTpass about it.
// Works for FULFILMENT_PENDING orders and for FLAGGED orders that were
// flagged because VTpass gave no clear answer.
export async function reconcileOrder(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || !(OPEN_ORDER as readonly string[]).includes(order.status)) return;

  const [tx] = await db
    .select()
    .from(vtuTransactions)
    .where(eq(vtuTransactions.orderId, order.id))
    .orderBy(desc(vtuTransactions.createdAt))
    .limit(1);

  if (!tx) {
    // Claimed but nothing was ever sent (for example the server restarted).
    // Safe to hand back for a first and only attempt.
    if (order.status === "FULFILMENT_PENDING" && Date.now() - order.updatedAt.getTime() > 60_000) {
      await db
        .update(orders)
        .set({ status: "PAYMENT_CONFIRMED" })
        .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")));
    }
    return;
  }
  if (!(OPEN_VTU as readonly string[]).includes(tx.status)) return;

  const age = Date.now() - tx.createdAt.getTime();
  const sinceLastAsk = Date.now() - tx.updatedAt.getTime();
  if (order.status === "FLAGGED") {
    if (age > FLAGGED_GIVE_UP_MS || sinceLastAsk < FLAGGED_REQUERY_AFTER_MS) return;
  } else if (sinceLastAsk < REQUERY_AFTER_MS) {
    return;
  }

  let outcome = await requery(tx.requestId);
  if (outcome.result !== "PENDING" || outcome.notFound) {
    console.log(`[vtpass] ${order.reference} requery -> ${outcome.result} ${outcome.code} ${outcome.message}`);
  }
  if (outcome.notFound && age > NOT_FOUND_FAIL_AFTER_MS) {
    // VTpass never received this purchase, so nothing was delivered.
    outcome = { ...outcome, result: "FAILED", message: "VTpass did not receive the purchase" };
  }
  await applyOutcome(order, tx, outcome);

  if (outcome.result === "PENDING" && order.status === "FULFILMENT_PENDING" && age > FLAG_AFTER_MS) {
    const [flagged] = await db
      .update(orders)
      .set({
        status: "FLAGGED",
        failureReason: "Your purchase is taking longer than usual. We are checking with the network and will deliver or refund it automatically.",
      })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")))
      .returning();
    if (flagged) await audit("delivery.flagged", order.id, { requestId: tx.requestId, last: outcome.message });
  }
}

export async function getDeliveryView(orderId: string) {
  const [tx] = await db
    .select()
    .from(vtuTransactions)
    .where(eq(vtuTransactions.orderId, orderId))
    .orderBy(desc(vtuTransactions.createdAt))
    .limit(1);
  if (!tx) return null;
  const raw = (tx.responsePayload ?? {}) as { purchased_code?: string; response_description?: string };
  return {
    status: tx.status,
    providerReference: tx.providerReference,
    requestId: tx.requestId,
    token: raw.purchased_code ? String(raw.purchased_code) : null,
    message: raw.response_description ?? null,
  };
}
DOC_EOF

cat > "backend/src/worker.ts" <<'DOC_EOF'
// Background worker: every 30 seconds, moves unfinished orders forward
//   PAYMENT_PENDING    -> check the payment with Circle
//   PAYMENT_CONFIRMED  -> send to VTpass
//   FULFILMENT_PENDING -> ask VTpass about it (requery)
//   FLAGGED            -> keep asking VTpass (every 5 minutes) if the delivery was unclear
//   FAILED (paid)      -> start the refund
//   REFUND_PENDING     -> send and confirm the refund
// so nothing stays stuck when a customer closes their browser.
import { and, eq, inArray } from "drizzle-orm";
import { db } from "./db";
import { orders, payments, vtuTransactions } from "./db/schema";
import { fulfilOrder, reconcileOrder } from "./fulfilment/service";
import { refreshPayment } from "./payments/service";
import { advanceRefund, startRefund } from "./refunds/service";

const EVERY_MS = 30_000;

export async function runWorkerOnce(): Promise<number> {
  const active = await db
    .select()
    .from(orders)
    .where(inArray(orders.status, ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"]))
    .limit(100);
  // Failed orders where money was taken (failed payments took nothing)
  const failedPaid = await db
    .selectDistinct({ order: orders })
    .from(orders)
    .innerJoin(payments, and(eq(payments.orderId, orders.id), eq(payments.status, "CONFIRMED")))
    .where(eq(orders.status, "FAILED"))
    .limit(50);
  // Orders under review because VTpass gave no clear answer
  const flagged = await db
    .selectDistinct({ order: orders })
    .from(orders)
    .innerJoin(vtuTransactions, eq(vtuTransactions.orderId, orders.id))
    .where(and(eq(orders.status, "FLAGGED"), inArray(vtuTransactions.status, ["SENT", "PENDING", "UNKNOWN"])))
    .limit(50);

  const due = [...active, ...failedPaid.map((r) => r.order), ...flagged.map((r) => r.order)];
  for (const order of due) {
    try {
      if (order.status === "PAYMENT_PENDING") await refreshPayment(order);
      else if (order.status === "PAYMENT_CONFIRMED") await fulfilOrder(order.id);
      else if (order.status === "FULFILMENT_PENDING" || order.status === "FLAGGED") await reconcileOrder(order.id);
      else if (order.status === "FAILED") await startRefund(order.id);
      else if (order.status === "REFUND_PENDING") await advanceRefund(order.id);
    } catch (err) {
      console.error(`[worker] ${order.reference} failed:`, err instanceof Error ? err.message : err);
    }
  }
  return due.length;
}

export function startWorker(): void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      await runWorkerOnce();
    } catch (err) {
      console.error("[worker] tick failed:", err);
    } finally {
      running = false;
    }
  };
  setInterval(() => void tick(), EVERY_MS);
  void tick();
  console.log("[worker] started: checking unfinished orders every 30 seconds");
}
DOC_EOF

cat > "backend/src/payments/service.ts" <<'DOC_EOF'
// Paying for an order with USDC, and verifying the payment.
//
// Order:   QUOTED -> PAYMENT_PENDING -> PAYMENT_CONFIRMED   (or FAILED / FLAGGED)
// Payment: INITIATED -> PENDING -> CONFIRMED                (or FAILED / MISMATCH)
//
// Every status change is conditional ("only if it is still X"), so two
// requests at the same time can never pay twice or confirm twice.
import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq, inArray, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, dataPlans, ledgerEntries, orders, payments } from "../db/schema";
import { env } from "../env";
import { fulfilOrder, getDeliveryView, reconcileOrder } from "../fulfilment/service";
import { microToUsdc } from "../pricing/quote";
import { advanceRefund, getRefundView, startRefund } from "../refunds/service";
import { ensureUserWallet } from "../wallets/service";

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
  const buffer = Math.round(env.PAYMENT_FEE_BUFFER_USDC * 1_000_000);
  const needed = order.usdcAmountMicro + buffer;
  if (!usdc || usdc.balanceMicro < needed) {
    throw new PaymentError(
      `Not enough USDC. You need ${microToUsdc(needed)} USDC (price plus network fee). Your balance is ${microToUsdc(usdc?.balanceMicro ?? 0)} USDC.`,
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
    await db.update(payments).set({ status: "FAILED" }).where(eq(payments.id, payment.id));
    await db.update(orders).set({ status: "QUOTED" }).where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    throw new PaymentError("We could not start the payment. No money was taken. Please try again.", 409);
  }

  await db
    .update(payments)
    .set({ circleTransactionId: transactionId, status: "PENDING" })
    .where(eq(payments.id, payment.id));
  return getOrderView(userId, reference);
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
    if (err instanceof Error && /UNIQUE/i.test(err.message)) {
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

// Used by the background worker later: every order still waiting for its payment.
export async function pendingPaymentOrders(): Promise<Order[]> {
  return db.select().from(orders).where(inArray(orders.status, ["PAYMENT_PENDING"])).limit(100);
}
DOC_EOF

cat > "backend/src/app.ts" <<'DOC_EOF'
// The API: routes, CORS and error handling.
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { auth } from "./auth";
import { requireAuth } from "./auth/middleware";
import { client } from "./db";
import { env } from "./env";
import { PaymentError, getOrderView, listOrders, payOrder } from "./payments/service";
import { isNetwork, listDataPlans } from "./catalog/plans";
import { QuoteError, createQuote, getQuote } from "./pricing/quote";
import { NETWORK_NAMES, ensureUserWallet, getUsdcBalance } from "./wallets/service";

export const app = new Hono();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: env.FRONTEND_URLS,
    credentials: true,
    allowHeaders: ["Content-Type", "Authorization"],
    allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  }),
);

app.get("/", (c) => c.json({ name: "dataonchain api", status: "ok" }));

// Render calls this to check the server is healthy before sending traffic.
app.get("/health", async (c) => {
  try {
    await client.execute("SELECT 1");
    return c.json({ status: "ok", database: "ok", time: new Date().toISOString() });
  } catch (err) {
    console.error("Health check failed:", err);
    return c.json({ status: "error", database: "unreachable" }, 503);
  }
});

// Quick check that the API (and the website's /api pass through) is up.
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true }));

// Signup, login, logout, sessions (Better Auth)
app.all("/api/auth/*", (c) => auth.handler(c.req.raw));

// The signed in user's own profile
app.get("/api/me", requireAuth, (c) => {
  const { user } = c.get("auth");
  const extra = user as { phone?: string; role?: string; status?: string };
  return c.json({
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      emailVerified: user.emailVerified,
      phone: extra.phone ?? null,
      role: extra.role ?? "user",
      status: extra.status ?? "active",
    },
  });
});

// The signed in user's wallet. Created on first visit, then reused.
app.get("/api/wallet", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) {
    return c.json({ error: "Please confirm your email first" }, 403);
  }
  const wallet = await ensureUserWallet(user.id);
  let usdc: string | null = null;
  try {
    usdc = await getUsdcBalance(wallet.circleWalletId);
  } catch (err) {
    console.error("[wallet] balance lookup failed:", err);
  }
  return c.json({
    wallet: {
      address: wallet.address,
      blockchain: wallet.blockchain,
      network: NETWORK_NAMES[wallet.blockchain] ?? wallet.blockchain,
      testnet: wallet.blockchain.endsWith("TESTNET"),
    },
    balance: { usdc },
  });
});

// Data plans for one network (refreshed from VTpass every 6 hours)
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

// Pay for a quoted order with USDC (user's wallet -> treasury)
app.post("/api/orders/:reference/pay", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) {
    return c.json({ error: "Please confirm your email first" }, 403);
  }
  try {
    return c.json({ order: await payOrder(user.id, c.req.param("reference")) });
  } catch (err) {
    if (err instanceof PaymentError) return c.json({ error: err.message }, err.status);
    throw err;
  }
});

// One order, with its payment checked against Circle while it is pending
app.get("/api/orders/:reference", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const order = await getOrderView(user.id, c.req.param("reference"));
  if (!order) return c.json({ error: "Order not found" }, 404);
  return c.json({ order });
});

// The signed in user's recent orders
app.get("/api/orders", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ orders: await listOrders(user.id) });
});

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
DOC_EOF

cat > "backend/scripts/orders-report.ts" <<'DOC_EOF'
// Read only report of recent paid orders, with what VTpass says right now.
// Changes nothing. Point it at production with TURSO_DATABASE_URL and TURSO_AUTH_TOKEN.
// Run with: npx tsx scripts/orders-report.ts
import { desc, inArray, notInArray } from "drizzle-orm";
import { db } from "../src/db";
import { orders, payments, refunds, vtuTransactions } from "../src/db/schema";
import { requery } from "../src/vtpass/client";

const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "short", timeStyle: "short" });
const usdc = (micro: number) => (micro / 1_000_000).toFixed(6);

async function main() {
  const rows = await db
    .select()
    .from(orders)
    .where(notInArray(orders.status, ["QUOTED", "EXPIRED"]))
    .orderBy(desc(orders.createdAt))
    .limit(30);
  if (rows.length === 0) {
    console.log("No paid orders yet.");
    return;
  }
  const ids = rows.map((o) => o.id);
  const pays = await db.select().from(payments).where(inArray(payments.orderId, ids));
  const txs = await db.select().from(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
  const refs = await db.select().from(refunds).where(inArray(refunds.orderId, ids));

  const counts: Record<string, number> = {};
  for (const o of rows) counts[o.status] = (counts[o.status] ?? 0) + 1;
  console.log(`Last ${rows.length} orders by status: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ")}\n`);

  for (const o of rows) {
    const pay = pays.filter((p) => p.orderId === o.id).at(-1);
    const tx = txs.filter((t) => t.orderId === o.id).sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0];
    const refund = refs.find((r) => r.orderId === o.id);
    const raw = (tx?.responsePayload ?? {}) as { code?: string; response_description?: string; error?: string };
    console.log(`${o.reference}  ${lagos(o.createdAt)}  ${o.status}  ${o.serviceType} ${o.network} ${o.phone}  ${usdc(o.usdcAmountMicro)} USDC`);
    console.log(`   payment: ${pay?.status ?? "none"}`);
    if (tx) {
      const ageMin = Math.round((Date.now() - tx.createdAt.getTime()) / 60_000);
      console.log(`   vtpass:  ${tx.status}, asked ${tx.attempt} time(s), ${ageMin} min ago, last answer: ${raw.code ?? ""} ${raw.response_description ?? raw.error ?? "(none saved)"}`);
      if (["SENT", "PENDING", "UNKNOWN"].includes(tx.status)) {
        const now = await requery(tx.requestId);
        console.log(`   vtpass now says: ${now.result}${now.notFound ? " (no record of this request)" : ""}, code ${now.code || "none"}, ${now.message}`);
      }
    }
    if (refund) console.log(`   refund:  ${refund.status}${refund.txHash ? ` ${refund.txHash}` : ""}${refund.lastError ? ` (${refund.lastError})` : ""}`);
    if (o.failureReason) console.log(`   note:    ${o.failureReason}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/refund-smoke.ts" <<'DOC_EOF'
// Refunds end to end on Arc Testnet and the development database:
// a paid order fails at VTpass, and the USDC really goes back to the payer.
// Exit code 3 means the treasury wallet needs more test USDC.
// Run with: npx tsx scripts/refund-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, payments, refunds, users, vtuTransactions } from "../src/db/schema";
import { env } from "../src/env";
import { fulfilOrder } from "../src/fulfilment/service";
import { getCurrentRate } from "../src/pricing/rates";
import { advanceRefund, startRefund } from "../src/refunds/service";
import { ensureUserWallet } from "../src/wallets/service";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";
const AMOUNT_MICRO = 10_000; // 0.01 USDC

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function usdcOf(walletId: string) {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: Math.round(Number(b?.amount ?? 0) * 1_000_000) };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const treasury = await usdcOf(env.TREASURY_WALLET_ID);
  console.log(`Treasury holds ${(treasury.micro / 1_000_000).toFixed(6)} USDC`);
  if (!treasury.tokenId || treasury.micro < 100_000) {
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }

  let [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (!payer) {
    [payer] = await db
      .insert(users)
      .values({ name: "Payment Test", email: PAYER_EMAIL, emailVerified: true, phone: "+2348011111111" })
      .returning();
  }
  if (!payer) throw new Error("Could not create the test payer");
  const wallet = await ensureUserWallet(payer.id);
  const before = (await usdcOf(wallet.circleWalletId)).micro;
  console.log(`Test wallet ${wallet.address} holds ${(before / 1_000_000).toFixed(6)} USDC`);

  const rate = await getCurrentRate();
  const ids: string[] = [];
  async function paidOrder(paymentStatus: "CONFIRMED" | "FAILED") {
    const [o] = await db
      .insert(orders)
      .values({
        reference: `TESTREF${Date.now()}${ids.length}`,
        userId: payer!.id,
        serviceType: "airtime",
        network: "mtn",
        phone: "+2348022222222", // any number except 08011111111 fails in the VTpass sandbox
        ngnAmountKobo: 10_000,
        marginKobo: 200,
        usdcAmountMicro: AMOUNT_MICRO,
        exchangeRateId: rate.id,
        status: "PAYMENT_CONFIRMED",
        quoteExpiresAt: new Date(Date.now() + 600_000),
      })
      .returning();
    if (!o) throw new Error("could not create test order");
    ids.push(o.id);
    await db.insert(payments).values({
      orderId: o.id,
      walletId: wallet.id,
      circleTransactionId: `smoke-${randomUUID()}`,
      txHash: `smoke-${randomUUID()}`,
      fromAddress: wallet.address,
      toAddress: env.TREASURY_ADDRESS,
      token: treasury.tokenId!,
      blockchain: wallet.blockchain,
      amountMicro: AMOUNT_MICRO,
      status: paymentStatus,
    });
    return o;
  }
  const orderOf = async (id: string) => (await db.select().from(orders).where(eq(orders.id, id)).limit(1))[0];

  try {
    // 1. A paid order that VTpass cannot deliver is refunded automatically
    const o = await paidOrder("CONFIRMED");
    await fulfilOrder(o.id);
    let now = await orderOf(o.id);
    check(["REFUND_PENDING", "REFUNDED"].includes(now?.status ?? ""), `failed delivery started a refund right away (status ${now?.status})`, now?.failureReason);

    // Asking again many times must not send a second transfer
    await startRefund(o.id);
    await advanceRefund(o.id);
    await advanceRefund(o.id);
    const rows = await db.select().from(refunds).where(eq(refunds.orderId, o.id));
    check(rows.length === 1 && rows[0]?.status !== "PENDING", "exactly one refund transfer was sent", rows);
    const firstTx = rows[0]?.circleTransactionId;

    process.stdout.write("Waiting for Arc to confirm the refund ");
    for (let i = 0; i < 60 && now?.status !== "REFUNDED"; i++) {
      await sleep(3_000);
      await advanceRefund(o.id);
      now = await orderOf(o.id);
      process.stdout.write(".");
    }
    console.log("");
    check(now?.status === "REFUNDED", `order is Refunded (${now?.failureReason})`);
    const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, o.id));
    check(refund?.status === "CONFIRMED" && Boolean(refund.txHash) && refund.circleTransactionId === firstTx, `refund confirmed on Arc: ${env.EXPLORER_TX_URL}${refund?.txHash}`);

    let after = before;
    for (let i = 0; i < 20 && after < before + AMOUNT_MICRO; i++) {
      await sleep(3_000);
      after = (await usdcOf(wallet.circleWalletId)).micro;
    }
    check(after >= before + AMOUNT_MICRO, `the 0.01 USDC arrived back in the customer's wallet (${(before / 1e6).toFixed(6)} -> ${(after / 1e6).toFixed(6)})`);

    const lines = (await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, o.id))).filter((l) => (l.memo ?? "").startsWith("Refund"));
    check(lines.length === 2 && lines.reduce((s, l) => s + l.debit - l.credit, 0) === 0, "refund ledger entries written and balanced");

    await startRefund(o.id);
    await advanceRefund(o.id);
    check((await orderOf(o.id))?.status === "REFUNDED", "a refunded order is never refunded twice");

    // 2. A failed order whose payment never completed is NOT refunded (no money was taken)
    const unpaid = await paidOrder("FAILED");
    await db.update(orders).set({ status: "FAILED" }).where(eq(orders.id, unpaid.id));
    await startRefund(unpaid.id);
    const u = await orderOf(unpaid.id);
    const uRefunds = await db.select().from(refunds).where(eq(refunds.orderId, unpaid.id));
    check(u?.status === "FAILED" && uRefunds.length === 0, "an order whose payment failed gets no refund");
  } finally {
    if (ids.length) {
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, ids));
      await db.delete(refunds).where(inArray(refunds.orderId, ids));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
      await db.delete(payments).where(inArray(payments.orderId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(orders).where(inArray(orders.id, ids));
    }
    console.log("Cleaned up the test orders");
  }
}

main()
  .then(() => {
    console.log("All refund checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/delivery-smoke.ts" <<'DOC_EOF'
// Delivery end to end against the VTpass sandbox and the development database.
// Uses VTpass sandbox test numbers:
//   08011111111 -> delivered, 201000000000 -> pending, any other number -> failed
// Run with: npx tsx scripts/delivery-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { listDataPlans } from "../src/catalog/plans";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, users, vtuTransactions } from "../src/db/schema";
import { fulfilOrder, getDeliveryView } from "../src/fulfilment/service";
import { getCurrentRate } from "../src/pricing/rates";
import { classify } from "../src/vtpass/client";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  // How VTpass answers are read
  check(classify({ code: "000", content: { transactions: { status: "delivered", transactionId: 1 } } }).result === "DELIVERED", "000 + delivered counts as delivered");
  check(classify({ code: "000", content: { transactions: { status: "pending" } } }).result === "PENDING", "000 + pending is asked about again, not resent");
  check(classify({ code: "099" }).result === "PENDING", "099 (processing) is asked about again");
  check(classify({ code: "016" }).result === "FAILED", "016 counts as failed");
  check(classify({ code: "040" }).result === "FAILED", "040 (reversed) counts as failed");
  check(classify({ code: "028" }).result === "FAILED", "028 (product not whitelisted) counts as failed");
  check(classify({ code: "018" }).result === "FAILED", "018 (VTpass wallet too low) counts as failed, so the customer is refunded");
  check(classify({ code: "015" }).result === "PENDING", "015 (no record yet) is asked about again before giving up");
  check(classify(null).result === "PENDING", "no answer at all is asked about again, never resent");

  const rate = await getCurrentRate();
  const [plan] = await listDataPlans("mtn");
  if (!plan) throw new Error("No MTN plans");

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId, name: "Delivery Smoke Test", email: `deliverysmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111",
  });

  const ids: string[] = [];
  async function paidOrder(over: Partial<typeof orders.$inferInsert>) {
    const [o] = await db.insert(orders).values({
      reference: `TEST${Date.now()}${ids.length}`,
      userId,
      serviceType: "airtime",
      network: "mtn",
      phone: "+2348011111111",
      ngnAmountKobo: 10_000,
      marginKobo: 200,
      usdcAmountMicro: 80_000,
      exchangeRateId: rate.id,
      status: "PAYMENT_CONFIRMED",
      quoteExpiresAt: new Date(Date.now() + 600_000),
      ...over,
    }).returning();
    if (!o) throw new Error("could not create test order");
    ids.push(o.id);
    return o;
  }
  const statusOf = async (id: string) => (await db.select().from(orders).where(eq(orders.id, id)).limit(1))[0];

  try {
    const data = await paidOrder({ serviceType: "data", planId: plan.id, ngnAmountKobo: plan.priceKobo });
    await fulfilOrder(data.id);
    const view = await getDeliveryView(data.id);
    check((await statusOf(data.id))?.status === "FULFILLED", `MTN data (${plan.name}) delivered by the VTpass sandbox`, view);
    check(view?.status === "DELIVERED" && Boolean(view.providerReference), `VTpass reference saved (${view?.providerReference})`);

    await fulfilOrder(data.id);
    const sent = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, data.id));
    check(sent.length === 1, "a delivered order is never sent to VTpass a second time");
    const lines = await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, data.id));
    const bal = (cur: string) => lines.filter((l) => l.currency === cur).reduce((s, l) => s + l.debit - l.credit, 0);
    check(lines.length === 4 && bal("USDC") === 0 && bal("NGN") === 0, "delivery ledger entries written and balanced");

    const airtime = await paidOrder({ serviceType: "airtime", network: "glo", ngnAmountKobo: 10_000 });
    await fulfilOrder(airtime.id);
    check((await statusOf(airtime.id))?.status === "FULFILLED", "Glo ₦100 airtime delivered by the VTpass sandbox", await getDeliveryView(airtime.id));

    const bad = await paidOrder({ phone: "+2348022222222" });
    await fulfilOrder(bad.id);
    const badOrder = await statusOf(bad.id);
    check(badOrder?.status === "FAILED" && /refunded/.test(badOrder.failureReason ?? ""), "a failed delivery marks the order Failed, waiting for a refund", await getDeliveryView(bad.id));

    const slow = await paidOrder({ phone: "201000000000" });
    await fulfilOrder(slow.id);
    const slowOrder = await statusOf(slow.id);
    check(slowOrder?.status === "FULFILMENT_PENDING", "a pending delivery waits (it is asked about again, not resent)", await getDeliveryView(slow.id));
  } finally {
    if (ids.length) {
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, ids));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(orders).where(inArray(orders.id, ids));
    }
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test orders");
  }
}

main()
  .then(() => {
    console.log("All delivery checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "frontend/src/lib/orders.ts" <<'DOC_EOF'
// Shared order types and labels for the website.
export type OrderView = {
  reference: string;
  status: string;
  serviceType: "airtime" | "data";
  network: "mtn" | "airtel" | "glo" | "9mobile";
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  createdAt: string;
  expiresAt?: string;
  failureReason?: string | null;
  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;
  delivery?: { status: string; providerReference: string | null; requestId: string; token: string | null; message: string | null } | null;
  refund?: { status: string; amount: string; txHash: string | null; explorerUrl: string | null } | null;
};

export const NETWORK_LABELS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };

export const STATUS_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Not paid", tone: "wait" },
  EXPIRED: { text: "Price expired", tone: "bad" },
  PAYMENT_PENDING: { text: "Payment in progress", tone: "wait" },
  PAYMENT_CONFIRMED: { text: "Paid, delivering", tone: "wait" },
  FULFILMENT_PENDING: { text: "Delivering", tone: "wait" },
  FULFILLED: { text: "Delivered", tone: "good" },
  FAILED: { text: "Failed, refunding", tone: "bad" },
  FLAGGED: { text: "Checking", tone: "wait" },
  REFUND_PENDING: { text: "Refunding", tone: "wait" },
  REFUNDED: { text: "Refunded", tone: "good" },
};

// Orders that can still change on their own (the page keeps checking them)
export function stillMoving(o: Pick<OrderView, "status" | "payment">) {
  if (["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"].includes(o.status)) return true;
  // A failed delivery after a confirmed payment is about to be refunded
  return o.status === "FAILED" && o.payment?.status === "CONFIRMED";
}

export function toneClass(tone: "wait" | "good" | "bad") {
  return tone === "good"
    ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "bad"
      ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
      : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200";
}

export const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
export const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

export function describe(o: OrderView) {
  const net = NETWORK_LABELS[o.network] ?? o.network;
  return o.serviceType === "data" ? `${net} ${o.planName ?? "data"}` : `${net} airtime ${naira(o.ngnAmount)}`;
}
DOC_EOF

cat > "frontend/src/app/orders/[reference]/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, stillMoving, toneClass, usdc, type OrderView } from "@/lib/orders";

export default function OrderPage() {
  const router = useRouter();
  const params = useParams<{ reference: string }>();
  const reference = params.reference;
  const { data: session, isPending } = authClient.useSession();
  const [order, setOrder] = useState<OrderView | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session || !reference) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ order: OrderView }>(`/orders/${reference}`);
        if (stop) return;
        setOrder(r.order);
        setError(null);
        if (stillMoving(r.order)) timer = setTimeout(load, r.order.status === "FLAGGED" ? 15000 : 3000);
      } catch (e) {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this order.");
        timer = setTimeout(load, 5000);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session, reference]);

  const label = order ? (STATUS_LABELS[order.status] ?? { text: order.status, tone: "wait" as const }) : null;
  const paid = order?.payment?.status === "CONFIRMED";
  const refunding = order ? paid && ["FAILED", "REFUND_PENDING", "REFUNDED"].includes(order.status) : false;
  const what = order?.serviceType === "data" ? "Data" : "Airtime";
  const steps: { text: string; state: "done" | "todo" | "failed" }[] = order
    ? [
        { text: "Payment sent", state: order.payment ? "done" : "todo" },
        { text: "Payment confirmed on Arc", state: paid ? "done" : "todo" },
        refunding
          ? { text: `${what} could not be delivered`, state: "failed" }
          : { text: `${what} delivered`, state: order.status === "FULFILLED" ? "done" : "todo" },
        ...(refunding
          ? [{ text: "USDC refunded to your wallet", state: order.status === "REFUNDED" ? ("done" as const) : ("todo" as const) }]
          : []),
      ]
    : [];

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Order {reference}</h1>

        {error && !order ? (
          <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
        ) : null}
        {!order && !error ? <p className="mt-6 text-zinc-500">Loading...</p> : null}

        {order && label ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between gap-3">
              <p className="text-lg font-medium text-zinc-900 dark:text-zinc-50">{describe(order)}</p>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
            </div>

            <ol className="space-y-3">
              {steps.map((s) => (
                <li key={s.text} className="flex items-center gap-3 text-sm">
                  <span
                    className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                      s.state === "done"
                        ? "bg-emerald-700 text-white"
                        : s.state === "failed"
                          ? "bg-red-600 text-white"
                          : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                    }`}
                  >
                    {s.state === "done" ? "✓" : s.state === "failed" ? "✕" : ""}
                  </span>
                  <span className={s.state === "todo" ? "text-zinc-500" : "text-zinc-900 dark:text-zinc-100"}>{s.text}</span>
                </li>
              ))}
            </ol>

            {order.status === "PAYMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Confirming your payment on Arc. This usually takes a few seconds...</p>
            ) : null}
            {order.status === "PAYMENT_CONFIRMED" || order.status === "FULFILMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Payment received. Sending your {order.serviceType} to {order.phone}...
                {order.delivery?.message ? <span className="mt-1 block text-xs text-zinc-500">Network status: {order.delivery.message}</span> : null}
              </p>
            ) : null}
            {order.status === "REFUND_PENDING" || (order.status === "FAILED" && paid) ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Sending your USDC back to your wallet. This usually takes under a minute...</p>
            ) : null}
            {order.status === "FULFILLED" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Done. Your {order.serviceType} has been sent to {order.phone}.
              </p>
            ) : null}
            {order.failureReason ? (
              <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{order.failureReason}</p>
            ) : null}

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{order.phone}</dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(order.ngnAmount)}</dd>
              <dt className="text-zinc-500">Paid</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{usdc(order.usdcAmount)} USDC</dd>
              <dt className="text-zinc-500">Date</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{new Date(order.createdAt).toLocaleString("en-NG")}</dd>
              {order.delivery?.providerReference ? (
                <>
                  <dt className="text-zinc-500">VTpass ref</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.providerReference}</dd>
                </>
              ) : null}
              {order.delivery?.token ? (
                <>
                  <dt className="text-zinc-500">Token / PIN</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.token}</dd>
                </>
              ) : null}
              {order.refund?.txHash ? (
                <>
                  <dt className="text-zinc-500">Refund</dt>
                  <dd className="min-w-0">
                    {order.refund.explorerUrl ? (
                      <a href={order.refund.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.refund.amount} USDC · {order.refund.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.refund.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              {order.payment?.txHash ? (
                <>
                  <dt className="text-zinc-500">Transaction</dt>
                  <dd className="min-w-0">
                    {order.payment.explorerUrl ? (
                      <a href={order.payment.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.payment.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.payment.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.reference}</dd>
            </dl>

            {order.status === "FULFILLED" ? (
              <button
                onClick={() => window.print()}
                className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                Print or save receipt
              </button>
            ) : null}
            <Link href="/buy" className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
              Buy something else
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF

cat > "frontend/src/components/RecentOrders.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { STATUS_LABELS, describe, toneClass, usdc, type OrderView } from "@/lib/orders";

export function RecentOrders() {
  const [orders, setOrders] = useState<OrderView[] | null>(null);

  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ orders: OrderView[] }>("/orders");
        if (stop) return;
        setOrders(r.orders);
        // Keep the list live while any order is still changing
        const recent = Date.now() - 15 * 60_000;
        const moving = r.orders.some(
          (o) =>
            ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"].includes(o.status) ||
            (o.status === "FAILED" && new Date(o.createdAt).getTime() > recent),
        );
        if (moving) timer = setTimeout(load, 5000);
      } catch {
        if (!stop) setOrders((prev) => prev ?? []);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, []);

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="text-sm font-medium text-zinc-500">Recent orders</h2>
      {orders === null ? <p className="mt-4 text-sm text-zinc-500">Loading...</p> : null}
      {orders && orders.length === 0 ? <p className="mt-4 text-sm text-zinc-500">No orders yet.</p> : null}
      {orders && orders.length > 0 ? (
        <ul className="mt-3 divide-y divide-zinc-100 dark:divide-zinc-800">
          {orders.map((o) => {
            const label = STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" as const };
            return (
              <li key={o.reference}>
                <Link href={`/orders/${o.reference}`} className="flex items-center justify-between gap-3 py-3 hover:opacity-80">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{describe(o)}</p>
                    <p className="text-xs text-zinc-500">
                      {o.phone} · {usdc(o.usdcAmount)} USDC · {new Date(o.createdAt).toLocaleString("en-NG")}
                    </p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
DOC_EOF

grep -q 'REFUND_PENDING' backend/src/db/schema.ts || fail "Could not write backend/src/db/schema.ts"
grep -q 'startRefund' backend/src/fulfilment/service.ts || fail "Could not write the delivery service"
green "OK: files written"

# --- 2. Database: new refunds table ------------------------------------------------
step "Database: adding the refunds table"
if ! grep -rqs 'CREATE TABLE `refunds`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name refunds)
fi
grep -rqs 'CREATE TABLE `refunds`' backend/drizzle/*.sql || fail "The refunds migration was not created"
(cd backend && npx drizzle-kit migrate) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Delivery: real tests with the VTpass sandbox"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."

step "Refunds: a real refund on Arc Testnet (0.01 test USDC from the treasury)"
set +e
(cd backend && npx tsx scripts/refund-smoke.ts)
code=$?
set -e
if [[ $code -eq 3 ]]; then
  yellow "The treasury wallet has less than 0.1 test USDC, so the live refund test was skipped."
  yellow "Send test USDC to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet) and run this again."
  read -r -p "Continue without the live refund test? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Nothing was committed."
elif [[ $code -ne 0 ]]; then
  fail "Refund test failed (details above). Nothing was committed."
fi

step "Payments, pricing, wallets and auth: make sure they still work"
ADDR_FILE="$(mktemp)"
set +e
(cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE")
code=$?
set -e
rm -f "$ADDR_FILE"
if [[ $code -eq 3 ]]; then
  yellow "The payment test wallet is out of test USDC, so the live payment test was skipped."
elif [[ $code -ne 0 ]]; then
  fail "Payment test failed (details above). Nothing was committed."
fi
(cd backend && npx tsx scripts/pricing-smoke.ts) || fail "Pricing test failed (details above). Nothing was committed."
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

# --- 4. Production database and report ----------------------------------------------
step "Production database: adding the refunds table"
# A short lived token, only for this computer, deleted from memory at the end.
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1h 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$PROD_TOKEN" == eyJ* ]] || PROD_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate) \
  || fail "Could not update the production database. Nothing was committed."
green "OK: production database updated (the live site keeps working; the new table is unused until the new code is live)"

prod_report() { # file
  (cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx tsx scripts/orders-report.ts) | tee "$1"
}

step "Live orders right now (read only, nothing is changed)"
prod_report "$HOME/dataonchain-orders-before.txt" || yellow "Could not read the live orders (the fix still goes ahead)."

# --- 5. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub (no new Render settings are needed)"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Automatic refunds, faster delivery status, live order list"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"refunds":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render."
wait_for "the website" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

step "Giving the worker 2 minutes to refund the old failed orders"
for _ in $(seq 1 12); do printf '.'; curl -s --max-time 20 "$PROD_API/health" >/dev/null || true; sleep 10; done
echo
step "Live orders after the fix"
prod_report "$HOME/dataonchain-orders-after.txt" || yellow "Could not read the live orders."
unset PROD_TOKEN

echo
green "Done. Failed orders are now refunded automatically and statuses update live."
echo "  Reports saved in your home folder:"
echo "    ~/dataonchain-orders-before.txt   and   ~/dataonchain-orders-after.txt"
echo "  Render logs: search [vtpass] to see every VTpass answer, [refund] for refunds."
echo "  Remember: in the VTpass sandbox only 08011111111 is delivered. Any other number fails and is refunded."
