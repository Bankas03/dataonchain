#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 13: smart contract (SCA) wallets with sponsored gas
#
# What this does:
#   - every user gets a smart contract account (SCA) wallet on Arc; Circle
#     Gas Station pays the network fee, so users pay exactly the price
#   - existing users are upgraded automatically by the background worker
#     (10 users every 30 seconds): a new SCA wallet is created, the old wallet
#     is retired, and its USDC is moved into the new wallet
#   - USDC sent to an old address later is also moved across (checked every
#     10 minutes); the old wallet keeps 0.01 USDC for its own network fee
#   - refunds now go to the user's current (SCA) wallet
#   - dashboard shows the new address, "no network fees", and a note about
#     the old address; the buy page no longer mentions a network fee
#
# Before running: in console.circle.com (Testnet) > Gas Station, check that
# the default Arc Testnet policy exists and is active.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/13_smart_wallets.sh
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
[[ -f backend/src/refunds/service.ts ]] || fail "Run this from ~/dataonchain after script 12 (refunds)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/13_smart_wallets.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

step "Circle Gas Station"
echo "Open https://console.circle.com, make sure the top left says Testnet,"
echo "then open Gas Station. There should be an ACTIVE default policy for Arc Testnet."
read -r -p "Is the Arc Testnet policy there and active? (y/n) " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Activate the Arc Testnet policy in Gas Station (or tell Claude what you see), then run again."
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing backend and frontend files"
mkdir -p backend/src/wallets
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
// EOA: plain wallet that pays its own gas. SCA: smart contract account, gas sponsored by Circle Gas Station.
export const ACCOUNT_TYPES = ["EOA", "SCA"] as const;
export const SWEEP_STATUSES = ["PENDING", "SENT", "CONFIRMED", "FAILED"] as const;
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
    accountType: text("account_type", { enum: ACCOUNT_TYPES }).notNull().default("EOA"),
    // Set when the user moved to a newer wallet; its USDC is swept to the new one
    retiredAt: integer("retired_at", { mode: "timestamp_ms" }),
    // Last time a retired wallet was checked for USDC to sweep
    checkedAt: integer("checked_at", { mode: "timestamp_ms" }),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    uniqueIndex("wallets_user_chain_type_idx").on(t.userId, t.blockchain, t.accountType),
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
// Wallet sweeps: USDC moved from a user's old (retired) wallet to their
// current wallet. open_key holds the old wallet id while a sweep is in
// progress, so only one sweep per old wallet can be open at a time.
// ---------------------------------------------------------------------------
export const walletSweeps = sqliteTable(
  "wallet_sweeps",
  {
    id: id(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id),
    fromWalletId: text("from_wallet_id")
      .notNull()
      .references(() => wallets.id),
    toWalletId: text("to_wallet_id")
      .notNull()
      .references(() => wallets.id),
    toAddress: text("to_address").notNull(),
    token: text("token").notNull(),
    amountMicro: integer("amount_micro").notNull(),
    openKey: text("open_key").unique(),
    circleTransactionId: text("circle_transaction_id").unique(),
    txHash: text("tx_hash").unique(),
    status: text("status", { enum: SWEEP_STATUSES }).notNull().default("PENDING"),
    lastError: text("last_error"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("wallet_sweeps_status_idx").on(t.status)],
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

cat > "backend/src/wallets/service.ts" <<'DOC_EOF'
// User wallets: one active Circle wallet per user per blockchain.
//
// New and existing users get a smart contract account (SCA). Its network
// fees are paid by Circle Gas Station, so users never need extra USDC for gas.
// Users who had a plain (EOA) wallet before keep it as a retired wallet; the
// worker moves its USDC into the SCA wallet (see wallets/sweep.ts).
import { createHash } from "node:crypto";
import { and, eq, isNull } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { wallets } from "../db/schema";
import { env } from "../env";

export type UserWallet = typeof wallets.$inferSelect;

export const NETWORK_NAMES: Record<string, string> = {
  "ARC-TESTNET": "Arc Testnet",
  ARC: "Arc",
};

// The same input always gives the same key, so a retry can never create a
// second wallet on Circle.
export function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function findWallet(userId: string, accountType: "EOA" | "SCA"): Promise<UserWallet | undefined> {
  const rows = await db
    .select()
    .from(wallets)
    .where(
      and(eq(wallets.userId, userId), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN), eq(wallets.accountType, accountType)),
    )
    .limit(1);
  return rows[0];
}

// The user's active wallet (always an SCA). Creates it on first use and
// retires any older EOA wallet the user had.
export async function ensureUserWallet(userId: string): Promise<UserWallet> {
  const existing = await findWallet(userId, "SCA");
  if (existing) return existing;

  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
    count: 1,
    accountType: "SCA",
    idempotencyKey: uuidFrom(`wallet:sca:${userId}:${env.CIRCLE_BLOCKCHAIN}`),
  });
  const created = res.data?.wallets?.[0];
  if (!created?.id || !created.address) {
    throw new Error("Circle did not return a wallet");
  }

  await db
    .insert(wallets)
    .values({
      userId,
      purpose: "user",
      circleWalletId: created.id,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER",
      blockchain: env.CIRCLE_BLOCKCHAIN,
      address: created.address,
      accountType: "SCA",
    })
    .onConflictDoNothing();

  const saved = await findWallet(userId, "SCA");
  if (!saved) throw new Error("Wallet was created on Circle but could not be saved");

  // The old wallet stops being used. Its USDC is moved across by the worker.
  await db
    .update(wallets)
    .set({ retiredAt: new Date() })
    .where(
      and(
        eq(wallets.userId, userId),
        eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN),
        eq(wallets.accountType, "EOA"),
        isNull(wallets.retiredAt),
      ),
    );
  return saved;
}

// The user's old wallet, if they had one before smart accounts.
export async function previousWallet(userId: string): Promise<UserWallet | undefined> {
  return findWallet(userId, "EOA");
}

// USDC balance as a decimal string, for example "12.5". "0" when empty.
export async function getUsdcBalance(circleWalletId: string): Promise<string> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const balances = res.data?.tokenBalances ?? [];
  const usdc = balances.find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc?.amount ?? "0";
}
DOC_EOF

cat > "backend/src/wallets/sweep.ts" <<'DOC_EOF'
// Moves USDC from a user's retired (old EOA) wallet into their current SCA wallet.
//
// Sweep: PENDING -> SENT -> CONFIRMED   (or FAILED, then tried again later)
//
// Safety:
//   - only one open sweep per old wallet (unique open_key)
//   - the Circle transfer uses an idempotency key made from the sweep id, so a
//     retry after a crash can never send twice
//   - never sweeps while a payment from the old wallet is still in progress
//   - the old wallet pays its own small Arc fee, so a little USDC is left for it
import { and, eq, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, payments, walletSweeps, wallets } from "../db/schema";
import { ensureUserWallet, uuidFrom } from "./service";

// Keep this much in the old wallet for the Arc network fee of the sweep itself
const FEE_RESERVE_MICRO = 10_000; // 0.01 USDC
// Do not bother moving less than this
const MIN_SWEEP_MICRO = 20_000; // 0.02 USDC
// How often a retired wallet is checked for new USDC
const RECHECK_MS = 10 * 60_000;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

type Wallet = typeof wallets.$inferSelect;
type Sweep = typeof walletSweeps.$inferSelect;
export type SweepResult = "nothing" | "busy" | "sent" | "waiting" | "confirmed" | "failed";

const text = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;

function microFrom(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

async function usdcOf(circleWalletId: string): Promise<{ tokenId?: string; micro: number }> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: b ? microFrom(b.amount) : 0 };
}

async function audit(action: string, walletId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "wallet", targetId: walletId, details });
}

// One step for one retired wallet. Safe to call as often as you like.
export async function sweepWallet(oldWalletId: string): Promise<SweepResult> {
  const [old] = await db.select().from(wallets).where(eq(wallets.id, oldWalletId)).limit(1);
  if (!old || old.accountType !== "EOA" || !old.retiredAt || !old.userId) return "nothing";

  const [open] = await db.select().from(walletSweeps).where(eq(walletSweeps.openKey, old.id)).limit(1);
  if (open) return open.status === "PENDING" ? sendSweep(old, open) : checkSweep(old, open);

  // A payment from the old wallet still in progress: leave its USDC alone for now
  const [busy] = await db
    .select({ id: payments.id })
    .from(payments)
    .where(and(eq(payments.walletId, old.id), inArray(payments.status, ["INITIATED", "PENDING"])))
    .limit(1);
  if (busy) return "busy";

  const balance = await usdcOf(old.circleWalletId);
  await db.update(wallets).set({ checkedAt: new Date() }).where(eq(wallets.id, old.id));
  if (!balance.tokenId || balance.micro < MIN_SWEEP_MICRO) return "nothing";

  const target = await ensureUserWallet(old.userId);
  await db
    .insert(walletSweeps)
    .values({
      userId: old.userId,
      fromWalletId: old.id,
      toWalletId: target.id,
      toAddress: target.address,
      token: balance.tokenId,
      amountMicro: balance.micro - FEE_RESERVE_MICRO,
      openKey: old.id,
      status: "PENDING",
    })
    .onConflictDoNothing();
  const [created] = await db.select().from(walletSweeps).where(eq(walletSweeps.openKey, old.id)).limit(1);
  return created ? sendSweep(old, created) : "busy";
}

async function sendSweep(old: Wallet, sweep: Sweep): Promise<SweepResult> {
  const amount = text(sweep.amountMicro);
  const input = {
    walletId: old.circleWalletId,
    tokenId: sweep.token,
    destinationAddress: sweep.toAddress,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`sweep:${sweep.id}`),
    refId: `SWEEP-${sweep.id.slice(0, 8)}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const transactionId = res.data?.id;
    if (!transactionId) return "waiting";
    await db
      .update(walletSweeps)
      .set({ circleTransactionId: transactionId, status: "SENT", lastError: null })
      .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "PENDING")));
    console.log(`[sweep] moving ${amount} USDC from old wallet ${old.address} to ${sweep.toAddress}`);
    return "sent";
  } catch (err) {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[sweep] ${old.address} not accepted yet:`, message, detail ?? "");
    await db.update(walletSweeps).set({ lastError: message.slice(0, 500) }).where(eq(walletSweeps.id, sweep.id));
    return "waiting";
  }
}

async function checkSweep(old: Wallet, sweep: Sweep): Promise<SweepResult> {
  if (!sweep.circleTransactionId) return "waiting";
  const res = await circle.getTransaction({ id: sweep.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (!tx?.state) return "waiting";

  if (FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`;
    // Nothing moved. Close it; the wallet is checked again later with a new sweep.
    await db
      .update(walletSweeps)
      .set({ status: "FAILED", openKey: null, lastError: reason })
      .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "SENT")));
    await audit("wallet.sweep_failed", old.id, { reason });
    console.error(`[sweep] ${old.address} failed: ${reason}`);
    return "failed";
  }
  if (tx.state !== "COMPLETE") return "waiting";

  const [done] = await db
    .update(walletSweeps)
    .set({ status: "CONFIRMED", txHash: tx.txHash ?? null, openKey: null })
    .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "SENT")))
    .returning();
  if (done) await audit("wallet.swept", old.id, { amountMicro: sweep.amountMicro, to: sweep.toAddress, txHash: tx.txHash });
  return "confirmed";
}

// Worker step: upgrade a few users still on an old wallet, then sweep retired
// wallets that have an open sweep or are due for a check.
export async function runWalletUpgrades(): Promise<void> {
  const notUpgraded = await db
    .select({ userId: wallets.userId })
    .from(wallets)
    .where(and(eq(wallets.accountType, "EOA"), isNull(wallets.retiredAt), isNotNull(wallets.userId)))
    .limit(10);
  for (const row of notUpgraded) {
    try {
      if (row.userId) await ensureUserWallet(row.userId);
    } catch (err) {
      console.error(`[sweep] could not upgrade user ${row.userId}:`, err instanceof Error ? err.message : err);
    }
  }

  const openSweeps = await db
    .select({ walletId: walletSweeps.fromWalletId })
    .from(walletSweeps)
    .where(isNotNull(walletSweeps.openKey))
    .limit(20);
  const due = await db
    .select({ walletId: wallets.id })
    .from(wallets)
    .where(
      and(
        eq(wallets.accountType, "EOA"),
        isNotNull(wallets.retiredAt),
        or(isNull(wallets.checkedAt), lt(wallets.checkedAt, new Date(Date.now() - RECHECK_MS))),
      ),
    )
    .limit(20);
  const ids = new Set([...openSweeps.map((r) => r.walletId), ...due.map((r) => r.walletId)]);
  for (const id of ids) {
    try {
      await sweepWallet(id);
    } catch (err) {
      console.error(`[sweep] wallet ${id}:`, err instanceof Error ? err.message : err);
    }
  }
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
import { ensureUserWallet } from "../wallets/service";

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
  if (!payment) return undefined;
  // Refunds go to the user's current wallet (old wallets are retired)
  const wallet = await ensureUserWallet(order.userId);
  await db
    .insert(refunds)
    .values({
      orderId: order.id,
      paymentId: payment.id,
      toAddress: wallet.address,
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

cat > "backend/src/worker.ts" <<'DOC_EOF'
// Background worker: every 30 seconds, moves unfinished orders forward
//   PAYMENT_PENDING    -> check the payment with Circle
//   PAYMENT_CONFIRMED  -> send to VTpass
//   FULFILMENT_PENDING -> ask VTpass about it (requery)
//   FLAGGED            -> keep asking VTpass (every 5 minutes) if the delivery was unclear
//   FAILED (paid)      -> start the refund
//   REFUND_PENDING     -> send and confirm the refund
// and upgrades users to smart contract wallets, moving USDC from old wallets.
// so nothing stays stuck when a customer closes their browser.
import { and, eq, inArray } from "drizzle-orm";
import { db } from "./db";
import { orders, payments, vtuTransactions } from "./db/schema";
import { fulfilOrder, reconcileOrder } from "./fulfilment/service";
import { refreshPayment } from "./payments/service";
import { advanceRefund, startRefund } from "./refunds/service";
import { runWalletUpgrades } from "./wallets/sweep";

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
  try {
    await runWalletUpgrades();
  } catch (err) {
    console.error("[worker] wallet upgrades failed:", err instanceof Error ? err.message : err);
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
import { NETWORK_NAMES, ensureUserWallet, getUsdcBalance, previousWallet } from "./wallets/service";

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
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true }));

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
  const old = await previousWallet(user.id);
  return c.json({
    wallet: {
      address: wallet.address,
      blockchain: wallet.blockchain,
      network: NETWORK_NAMES[wallet.blockchain] ?? wallet.blockchain,
      testnet: wallet.blockchain.endsWith("TESTNET"),
      gasFree: wallet.accountType === "SCA",
      previousAddress: old?.address ?? null,
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

cat > "backend/scripts/sca-smoke.ts" <<'DOC_EOF'
// Smart contract wallets end to end on Arc Testnet and the development database:
//   1. a user with an old (EOA) wallet holding USDC is upgraded to an SCA wallet
//   2. the old wallet's USDC is swept into the new one automatically
//   3. a real order is paid from the SCA wallet with zero gas (Circle Gas Station)
//   4. the leftover test USDC goes back to the treasury
// It also upgrades the payment test user so the other tests keep working.
// Exit code 3 means the treasury wallet needs more test USDC.
// Run with: npx tsx scripts/sca-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, payments, refunds, users, vtuTransactions, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { getOrderView, payOrder, usdcToMicro } from "../src/payments/service";
import { createQuote } from "../src/pricing/quote";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";
import { sweepWallet } from "../src/wallets/sweep";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";
const FUND_MICRO = 100_000; // 0.1 USDC

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const show = (micro: number) => (micro / 1_000_000).toFixed(6);

async function usdcOf(walletId: string) {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: b ? (usdcToMicro(b.amount) ?? Math.floor(Number(b.amount) * 1_000_000)) : 0 };
}

async function transfer(fromWalletId: string, tokenId: string, to: string, micro: number, key: string) {
  const amount = show(micro);
  const res = await circle.createTransaction({
    walletId: fromWalletId,
    tokenId,
    destinationAddress: to,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(key),
  } as unknown as Parameters<typeof circle.createTransaction>[0]);
  const id = res.data?.id;
  if (!id) throw new Error("Circle did not accept the transfer");
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const t = await circle.getTransaction({ id });
    const tx = t.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
    if (tx?.state === "COMPLETE") return tx;
    if (tx?.state && ["FAILED", "DENIED", "CANCELLED"].includes(tx.state)) {
      throw new Error(`transfer ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
    }
  }
  throw new Error("transfer did not complete in 3 minutes");
}

async function waitForBalance(walletId: string, ok: (micro: number) => boolean) {
  let micro = (await usdcOf(walletId)).micro;
  for (let i = 0; i < 20 && !ok(micro); i++) {
    await sleep(3_000);
    micro = (await usdcOf(walletId)).micro;
  }
  return micro;
}

async function sweepUntilDone(oldWalletId: string) {
  let result = await sweepWallet(oldWalletId);
  for (let i = 0; i < 60 && !["confirmed", "nothing", "failed"].includes(result); i++) {
    await sleep(3_000);
    result = await sweepWallet(oldWalletId);
    process.stdout.write(".");
  }
  console.log("");
  return result;
}

async function main() {
  const treasury = await usdcOf(env.TREASURY_WALLET_ID);
  console.log(`Treasury holds ${show(treasury.micro)} USDC`);
  if (!treasury.tokenId || treasury.micro < FUND_MICRO + 100_000) {
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }
  const tokenId = treasury.tokenId;

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId, name: "SCA Smoke Test", email: `scasmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111",
  });
  let orderId: string | undefined;

  try {
    // 1. An "existing user": old style EOA wallet with some USDC
    const created = await circle.createWallets({
      walletSetId: env.CIRCLE_WALLET_SET_ID,
      blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
      count: 1,
      accountType: "EOA",
      idempotencyKey: uuidFrom(`wallet:${userId}:${env.CIRCLE_BLOCKCHAIN}`),
    });
    const w = created.data?.wallets?.[0];
    if (!w?.id || !w.address) throw new Error("Circle did not create the test EOA wallet");
    const [eoa] = await db.insert(wallets).values({
      userId, purpose: "user", circleWalletId: w.id, circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER", blockchain: env.CIRCLE_BLOCKCHAIN, address: w.address, accountType: "EOA",
    }).returning();
    if (!eoa) throw new Error("could not save the test EOA wallet");
    console.log(`Funding the old style wallet ${eoa.address} with ${show(FUND_MICRO)} USDC from the treasury...`);
    await transfer(env.TREASURY_WALLET_ID, tokenId, eoa.address, FUND_MICRO, `scasmoke:fund:${userId}`);
    const funded = await waitForBalance(eoa.circleWalletId, (m) => m >= FUND_MICRO);
    check(funded >= FUND_MICRO, `old wallet funded (${show(funded)} USDC)`);

    // 2. Upgrade: a new SCA wallet, the old one retired
    const sca = await ensureUserWallet(userId);
    check(sca.accountType === "SCA" && sca.address.toLowerCase() !== eoa.address.toLowerCase(), `SCA wallet created (${sca.address})`);
    const again = await ensureUserWallet(userId);
    check(again.id === sca.id, "the same SCA wallet is reused, never a second one");
    const [retired] = await db.select().from(wallets).where(eq(wallets.id, eoa.id));
    check(Boolean(retired?.retiredAt), "the old wallet is retired");

    // 3. Sweep the old wallet's USDC into the SCA wallet
    process.stdout.write("Moving the USDC from the old wallet ");
    const result = await sweepUntilDone(eoa.id);
    check(result === "confirmed", `sweep confirmed on Arc (result ${result})`);
    const [sweep] = await db.select().from(walletSweeps).where(eq(walletSweeps.fromWalletId, eoa.id));
    check(sweep?.status === "CONFIRMED" && Boolean(sweep.txHash) && sweep.openKey === null, `sweep recorded: ${env.EXPLORER_TX_URL}${sweep?.txHash}`);
    const scaBalance = await waitForBalance(sca.circleWalletId, (m) => m >= (sweep?.amountMicro ?? 1));
    check(scaBalance === sweep?.amountMicro, `the SCA wallet received ${show(scaBalance)} USDC`);
    check((await sweepWallet(eoa.id)) === "nothing", "an emptied old wallet is not swept again");

    // 4. Pay a real order from the SCA wallet: the user pays exactly the price, no gas
    const quote = await createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "08011111111" });
    const price = usdcToMicro(quote.usdcAmount) ?? 0;
    check(price > 0 && price <= scaBalance, `quote ${quote.reference}: ${quote.usdcAmount} USDC`);
    await payOrder(userId, quote.reference);
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    orderId = row?.id;
    let view = await getOrderView(userId, quote.reference);
    process.stdout.write("Waiting for the payment and delivery ");
    for (let i = 0; i < 60 && !["FULFILLED", "FAILED", "FLAGGED", "REFUNDED", "REFUND_PENDING"].includes(view?.status ?? ""); i++) {
      await sleep(3_000);
      view = await getOrderView(userId, quote.reference);
      process.stdout.write(".");
    }
    console.log("");
    check(view?.payment?.status === "CONFIRMED", `payment from the SCA wallet confirmed on Arc (${view?.payment?.explorerUrl})`);
    check(view?.status === "FULFILLED", `airtime delivered (status ${view?.status})`);
    const afterPay = await waitForBalance(sca.circleWalletId, (m) => m <= scaBalance - price);
    check(afterPay === scaBalance - price, `gas was sponsored: the wallet paid exactly the price (${show(scaBalance)} -> ${show(afterPay)})`);

    // 5. Give the leftover test USDC back to the treasury (also gas free)
    if (afterPay > 0) {
      await transfer(sca.circleWalletId, tokenId, env.TREASURY_ADDRESS, afterPay, `scasmoke:return:${userId}`);
      const empty = await waitForBalance(sca.circleWalletId, (m) => m === 0);
      check(empty === 0, "leftover returned to the treasury with no gas taken from the wallet");
    }
  } finally {
    if (orderId) {
      await db.delete(vtuTransactions).where(eq(vtuTransactions.orderId, orderId));
      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, orderId));
      await db.delete(refunds).where(eq(refunds.orderId, orderId));
      await db.delete(payments).where(eq(payments.orderId, orderId));
      await db.delete(auditLogs).where(eq(auditLogs.targetId, orderId));
      await db.delete(orders).where(eq(orders.id, orderId));
    }
    await db.delete(orders).where(eq(orders.userId, userId));
    const ws = await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId));
    if (ws.length) {
      await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws.map((x) => x.id)));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ws.map((x) => x.id)));
    }
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }

  // 6. Upgrade the payment test user too, so the payment test can keep running
  const [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (payer) {
    await ensureUserWallet(payer.id);
    const [old] = await db.select().from(wallets).where(eq(wallets.userId, payer.id)).then((rows) => rows.filter((r) => r.accountType === "EOA"));
    if (old) {
      process.stdout.write("Upgrading the payment test wallet ");
      const r = await sweepUntilDone(old.id);
      console.log(`Payment test wallet: ${r === "confirmed" ? "USDC moved to its new SCA wallet" : "nothing to move"}`);
    }
  }
}

main()
  .then(() => {
    console.log("All smart wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/wallets-report.ts" <<'DOC_EOF'
// Read only report: how far the upgrade to smart contract wallets has got.
// Changes nothing. Point it at production with TURSO_DATABASE_URL and TURSO_AUTH_TOKEN.
// Run with: npx tsx scripts/wallets-report.ts
import { desc } from "drizzle-orm";
import { db } from "../src/db";
import { walletSweeps, wallets } from "../src/db/schema";

async function main() {
  const all = await db.select().from(wallets);
  const sca = all.filter((w) => w.accountType === "SCA").length;
  const oldActive = all.filter((w) => w.accountType === "EOA" && !w.retiredAt).length;
  const retired = all.filter((w) => w.accountType === "EOA" && w.retiredAt).length;
  console.log(`Smart (SCA) wallets: ${sca}`);
  console.log(`Old wallets still to upgrade: ${oldActive}`);
  console.log(`Old wallets retired (USDC swept to the new wallet): ${retired}`);

  const sweeps = await db.select().from(walletSweeps).orderBy(desc(walletSweeps.createdAt)).limit(20);
  if (sweeps.length === 0) {
    console.log("No USDC moves yet (old wallets with less than 0.02 USDC are not moved).");
    return;
  }
  console.log("\nLatest USDC moves from old wallets:");
  for (const s of sweeps) {
    console.log(`  ${(s.amountMicro / 1_000_000).toFixed(6)} USDC -> ${s.toAddress}  ${s.status}${s.txHash ? `  ${s.txHash}` : ""}${s.lastError ? `  (${s.lastError})` : ""}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/wallet-smoke.ts" <<'DOC_EOF'
// Creates a wallet for a temporary test user on Circle (testnet),
// checks it is reused on the second call, reads the balance, then removes
// the test user from the database. The empty testnet wallet stays on Circle.
// Run with: npx tsx scripts/wallet-smoke.ts
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { users, wallets } from "../src/db/schema";
import { ensureUserWallet, getUsdcBalance } from "../src/wallets/service";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  const userId = randomUUID();
  await db.insert(users).values({
    id: userId,
    name: "Wallet Smoke Test",
    email: `walletsmoke+${Date.now()}@example.com`,
    emailVerified: true,
    phone: "+2348012345678",
  });

  try {
    const first = await ensureUserWallet(userId);
    check(/^0x[0-9a-fA-F]{40}$/.test(first.address), "a wallet with a valid address was created", first);
    check(first.accountType === "SCA", "new wallets are smart contract accounts (gas sponsored)");

    const second = await ensureUserWallet(userId);
    check(second.id === first.id && second.address === first.address, "the same wallet is reused, never a second one");

    const balance = await getUsdcBalance(first.circleWalletId);
    check(!Number.isNaN(Number(balance)), `the USDC balance can be read (${balance})`);
  } finally {
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/db-check.ts" <<'DOC_EOF'
// Checks the database is reachable and every expected table exists.
// Run with: npm run db:check
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const EXPECTED_TABLES = [
  "accounts",
  "audit_logs",
  "data_plans",
  "exchange_rates",
  "ledger_entries",
  "orders",
  "payments",
  "refunds",
  "sessions",
  "treasury_movements",
  "users",
  "verifications",
  "vtu_transactions",
  "wallet_sweeps",
  "wallets",
  "webhook_events",
];

async function main() {
  const url = process.env.TURSO_DATABASE_URL;
  if (!url) throw new Error("TURSO_DATABASE_URL is not set");

  const client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
  const result = await client.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  );
  const found = new Set(result.rows.map((row) => String(row.name)));
  client.close();

  const missing = EXPECTED_TABLES.filter((t) => !found.has(t));
  console.log(`Database: ${new URL(url.replace("libsql://", "https://")).host}`);
  console.log(`Tables found: ${EXPECTED_TABLES.length - missing.length} of ${EXPECTED_TABLES.length}`);

  if (missing.length > 0) {
    console.error(`MISSING: ${missing.join(", ")}`);
    process.exit(1);
  }
  console.log("All tables present.");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
DOC_EOF

cat > "frontend/src/components/WalletCard.tsx" <<'DOC_EOF'
"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean; gasFree?: boolean; previousAddress?: string | null };
  balance: { usdc: string | null };
};

function formatUsdc(amount: string | null): string {
  if (amount === null) return "unavailable";
  const n = Number(amount);
  if (Number.isNaN(n)) return amount;
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

export function WalletCard() {
  const [data, setData] = useState<WalletResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await api<WalletResponse>("/wallet"));
    } catch {
      setError("We could not load your wallet. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function copy() {
    if (!data) return;
    await navigator.clipboard.writeText(data.wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium text-zinc-500">Your USDC wallet</h2>
        {data ? (
          <span className="rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
            {data.wallet.network}
          </span>
        ) : null}
      </div>

      {loading && !data ? (
        <p className="mt-4 text-sm text-zinc-500">Setting up your wallet...</p>
      ) : null}

      {error ? (
        <div className="mt-4 space-y-3">
          <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          <button onClick={load} className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Try again
          </button>
        </div>
      ) : null}

      {data ? (
        <div className="mt-4 space-y-5">
          <div>
            <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
              {formatUsdc(data.balance.usdc)} <span className="text-lg font-medium text-zinc-500">USDC</span>
            </p>
            <button
              onClick={load}
              disabled={loading}
              className="mt-1 text-sm font-medium text-emerald-700 hover:underline disabled:opacity-60 dark:text-emerald-400"
            >
              {loading ? "Refreshing..." : "Refresh balance"}
            </button>
          </div>

          <div>
            <p className="text-sm text-zinc-500">Wallet address (to receive USDC on {data.wallet.network} only)</p>
            <div className="mt-1 flex items-center gap-2">
              <code className="min-w-0 flex-1 truncate rounded-lg bg-zinc-100 px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100">
                {data.wallet.address}
              </code>
              <button
                onClick={copy}
                className="shrink-0 rounded-lg border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          </div>

          {data.wallet.gasFree ? (
            <p className="text-sm text-emerald-800 dark:text-emerald-300">No network fees: Arc gas is covered for you.</p>
          ) : null}

          {data.wallet.previousAddress ? (
            <p className="rounded-lg bg-zinc-100 px-3 py-2 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
              Your wallet was upgraded. Please use the address above from now on. Any USDC in or sent to your old address (
              <span className="font-mono">{data.wallet.previousAddress.slice(0, 6)}...{data.wallet.previousAddress.slice(-4)}</span>) is moved
              here automatically within a few minutes, minus a tiny network fee.
            </p>
          ) : null}

          {data.wallet.testnet ? (
            <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
              Test network: this USDC has no real value. Get free test USDC at{" "}
              <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                faucet.circle.com
              </a>{" "}
              (choose Arc Testnet and paste your address).
            </p>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
DOC_EOF

cat > "frontend/src/app/buy/page.tsx" <<'DOC_EOF'
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

  async function pay() {
    if (!quote) return;
    setError(null);
    setBusy(true);
    try {
      await api(`/orders/${quote.reference}/pay`, { method: "POST" });
      router.push(`/orders/${quote.reference}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Payment could not start. Please try again.");
      setBusy(false);
    }
  }

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

            <p className="text-xs text-zinc-500">
              No network fee: the Arc gas for your payment is covered by dataonchain.
            </p>

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
                onClick={() => void pay()}
                disabled={busy || notEnough}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Sending payment..." : `Pay ${usdc(quote.usdcAmount)} USDC`}
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
DOC_EOF

grep -q 'walletSweeps' backend/src/db/schema.ts || fail "Could not write backend/src/db/schema.ts"
grep -q 'runWalletUpgrades' backend/src/worker.ts || fail "Could not write backend/src/worker.ts"
green "OK: files written"

# --- 2. Database --------------------------------------------------------------------
step "Database: wallet types and the wallet_sweeps table"
if ! grep -rqs 'CREATE TABLE `wallet_sweeps`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name smart_wallets)
fi
grep -rqs 'CREATE TABLE `wallet_sweeps`' backend/drizzle/*.sql || fail "The wallet_sweeps migration was not created"
grep -rqs 'account_type' backend/drizzle/*.sql || fail "The account_type column is missing from the migration"
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Smart wallets: real test on Arc Testnet (uses about 0.02 test USDC from the treasury)"
set +e
(cd backend && npx tsx scripts/sca-smoke.ts)
code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury wallet needs at least 0.2 test USDC. Send some to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Smart wallet test failed (details above). Nothing was committed."
fi

step "Delivery, refunds, payments, pricing, wallets and auth: make sure they still work"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
set +e
(cd backend && npx tsx scripts/refund-smoke.ts)
code=$?
set -e
[[ $code -eq 0 || $code -eq 3 ]] || fail "Refund test failed (details above). Nothing was committed."
ADDR_FILE="$(mktemp)"
set +e
(cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE")
code=$?
set -e
rm -f "$ADDR_FILE"
if [[ $code -eq 3 ]]; then
  yellow "The payment test wallet has less than 0.5 test USDC, so the live payment test was skipped."
  yellow "(The smart wallet test above already paid a real order gas free.)"
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

# --- 4. Production database ---------------------------------------------------------
step "Production database: wallet types and the wallet_sweeps table"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1h 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$PROD_TOKEN" == eyJ* ]] || PROD_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the production database. Nothing was committed."
green "OK: production database updated (the live site keeps working: existing wallets are marked EOA)"

# --- 5. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub (no new Render settings are needed)"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Smart contract wallets with sponsored gas, automatic upgrade and USDC sweep"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"sca":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
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

step "Giving the worker 3 minutes to upgrade users and move their USDC"
for _ in $(seq 1 18); do printf '.'; curl -s --max-time 20 "$PROD_API/health" >/dev/null || true; sleep 10; done
echo
step "Live wallet upgrade progress"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx tsx scripts/wallets-report.ts) \
  | tee "$HOME/dataonchain-wallets-report.txt" || yellow "Could not read the live wallets."
unset PROD_TOKEN

echo
green "Done. Every user now has a gas free smart wallet on Arc."
echo "  Report saved: ~/dataonchain-wallets-report.txt"
echo "  Render logs: search [sweep] to watch USDC being moved from old wallets."
echo "  Circle console > Gas Station shows every transaction Circle paid gas for."
echo "  Tell your testers: their wallet address changed. The dashboard shows the new one."
