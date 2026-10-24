#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 15: bridge foundation (Circle Gateway)
#
# What this adds (nothing changes for users yet; the bridge stays switched off):
#   - the list of supported chains: Arc, Base, Arbitrum, Ethereum, Avalanche,
#     OP, Polygon and Unichain (testnets), with Circle domains, USDC and
#     Gateway contract addresses
#   - database tables:
#       bridge_transfers       one row per crosschain transfer
#       bridge_events          every step: approve, deposit, finality, signing,
#                              submission, mint, each with time and tx hash
#       approved_destinations  the only addresses USDC may be bridged OUT to
#   - a Circle Gateway client (balances, fee estimates, transfers, status)
#   - the transfer engine: deposit into Gateway, sign the burn intent with the
#     smart wallet, submit with Circle forwarding (Circle pays destination gas),
#     track until minted; fees capped per chain (0.5 USDC, Ethereum 2)
#   - a live test: fee estimates to all 7 chains, then a real 0.5 USDC
#     transfer Arc Testnet -> Base Sepolia, recorded step by step
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/15_bridge_foundation.sh
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
[[ -f backend/src/wallets/sweep.ts ]] || fail "Run this from ~/dataonchain after script 13 (smart wallets)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/15_bridge_foundation.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing backend files"
mkdir -p backend/src/bridge
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
// Crosschain transfers through Circle Gateway (see src/bridge)
export const BRIDGE_DIRECTIONS = ["OUT", "IN"] as const;
export const BRIDGE_STATUSES = [
  "QUOTED",        // fee estimated, nothing moved yet
  "DEPOSITING",    // approve + deposit into the Gateway Wallet sent
  "DEPOSITED",     // deposit confirmed onchain, waiting for Gateway finality
  "FINALIZED",     // amount + fee available in the Gateway balance
  "INTENT_SIGNED", // burn intent signed by the depositor wallet
  "SUBMITTED",     // accepted by the Gateway API, waiting for the mint
  "MINTED",        // USDC minted on the destination chain
  "COMPLETE",      // checked and recorded
  "EXPIRED",       // attestation expired before the mint: nothing burned, retry
  "FAILED",        // stopped; see failure_reason
] as const;
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
// Bridge (Circle Gateway): one row per crosschain transfer, and every step it
// went through in bridge_events, from the deposit to the final mint.
// ---------------------------------------------------------------------------
export const bridgeTransfers = sqliteTable(
  "bridge_transfers",
  {
    id: id(),
    userId: text("user_id").references(() => users.id),
    direction: text("direction", { enum: BRIDGE_DIRECTIONS }).notNull(),
    sourceChain: text("source_chain").notNull(), // registry key, e.g. arc
    destinationChain: text("destination_chain").notNull(),
    sourceDomain: integer("source_domain").notNull(),
    destinationDomain: integer("destination_domain").notNull(),
    depositorWalletId: text("depositor_wallet_id").notNull(), // Circle wallet id
    depositorAddress: text("depositor_address").notNull(),
    recipientAddress: text("recipient_address").notNull(),
    amountMicro: integer("amount_micro").notNull(), // what the recipient receives
    maxFeeMicro: integer("max_fee_micro"),          // the most Circle may take
    forwardingFeeMicro: integer("forwarding_fee_micro"),
    salt: text("salt").notNull().unique(),
    burnIntent: text("burn_intent", { mode: "json" }),
    signature: text("signature"),
    gatewayTransferId: text("gateway_transfer_id").unique(),
    mintTxHash: text("mint_tx_hash"),
    status: text("status", { enum: BRIDGE_STATUSES }).notNull().default("QUOTED"),
    failureReason: text("failure_reason"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("bridge_transfers_status_idx").on(t.status),
    index("bridge_transfers_user_idx").on(t.userId),
  ],
);

export const bridgeEvents = sqliteTable(
  "bridge_events",
  {
    id: id(),
    transferId: text("transfer_id")
      .notNull()
      .references(() => bridgeTransfers.id),
    step: text("step").notNull(), // e.g. approve, deposit, finalized, signed, submitted, minted
    chain: text("chain"),
    txHash: text("tx_hash"),
    circleTransactionId: text("circle_transaction_id"),
    details: text("details", { mode: "json" }),
    createdAt: createdAt(),
  },
  (t) => [index("bridge_events_transfer_idx").on(t.transferId)],
);

// Addresses USDC may be bridged OUT to (VTU providers). Nothing else is allowed.
export const approvedDestinations = sqliteTable(
  "approved_destinations",
  {
    id: id(),
    label: text("label").notNull(),
    chain: text("chain").notNull(), // registry key, e.g. base
    address: text("address").notNull(), // stored lowercase
    active: integer("active", { mode: "boolean" }).notNull().default(true),
    note: text("note"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [uniqueIndex("approved_destinations_chain_address_idx").on(t.chain, t.address)],
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

cat > "backend/src/env.ts" <<'DOC_EOF'
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
  // Payments
  TREASURY_WALLET_ID: required("TREASURY_WALLET_ID"),
  TREASURY_ADDRESS: required("TREASURY_ADDRESS"),
  PAYMENT_FEE_BUFFER_USDC: optionalNumber("PAYMENT_FEE_BUFFER_USDC") ?? 0.02,
  EXPLORER_TX_URL: process.env.EXPLORER_TX_URL ?? "https://explorer.testnet.arc.io/tx/",
  // Bridge (Circle Gateway). Off until the user facing bridge ships.
  BRIDGE_ENABLED: (process.env.BRIDGE_ENABLED ?? "false") === "true",
  GATEWAY_API_URL: (process.env.GATEWAY_API_URL ??
    ((process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET").endsWith("TESTNET")
      ? "https://gateway-api-testnet.circle.com"
      : "https://gateway-api.circle.com")).replace(/\/$/, ""),
  // The most Circle may take in fees for one bridge transfer (safety cap)
  BRIDGE_MAX_FEE_USDC: optionalNumber("BRIDGE_MAX_FEE_USDC") ?? 0.5,
  // Background worker: on in production unless WORKER_ENABLED=false
  WORKER_ENABLED: (process.env.WORKER_ENABLED ?? (NODE_ENV === "production" ? "true" : "false")) === "true",
};
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
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true }));

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

cat > "backend/src/bridge/chains.ts" <<'DOC_EOF'
// Chains the bridge supports, with everything Circle Gateway needs for each.
// Sources: developers.circle.com (Gateway contract addresses, USDC contract
// addresses, Wallets supported blockchains). Testnet only for now; mainnet is
// added before launch, after the same live checks.
import { env } from "../env";

export type BridgeChain = {
  key: string;              // our name, used in the database and the API
  label: string;            // shown to users
  circleBlockchain: string; // Circle Wallets blockchain code
  domain: number;           // Circle domain id (same as CCTP)
  usdc: `0x${string}`;      // USDC token contract
  gatewayWallet: `0x${string}`;
  gatewayMinter: `0x${string}`;
  explorerTx: string;       // + tx hash
  // Safety cap on Circle's fee for transfers TO this chain (USDC). Ethereum gas
  // is expensive, so forwarding there costs more (about 1.3 USDC on testnet).
  maxFeeUsdc?: number;
};

const GATEWAY_WALLET_TESTNET: `0x${string}` = "0x0077777d7EBA4688BDeF3E311b846F25870A19B9";
const GATEWAY_MINTER_TESTNET: `0x${string}` = "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B";

const TESTNET: BridgeChain[] = ([
  { key: "arc", label: "Arc Testnet", circleBlockchain: "ARC-TESTNET", domain: 26,
    usdc: "0x3600000000000000000000000000000000000000", explorerTx: "https://explorer.testnet.arc.io/tx/" },
  { key: "base", label: "Base Sepolia", circleBlockchain: "BASE-SEPOLIA", domain: 6,
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", explorerTx: "https://sepolia.basescan.org/tx/" },
  { key: "arbitrum", label: "Arbitrum Sepolia", circleBlockchain: "ARB-SEPOLIA", domain: 3,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", explorerTx: "https://sepolia.arbiscan.io/tx/" },
  { key: "ethereum", label: "Ethereum Sepolia", circleBlockchain: "ETH-SEPOLIA", domain: 0,
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", explorerTx: "https://sepolia.etherscan.io/tx/", maxFeeUsdc: 2 },
  { key: "avalanche", label: "Avalanche Fuji", circleBlockchain: "AVAX-FUJI", domain: 1,
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65", explorerTx: "https://testnet.snowtrace.io/tx/" },
  { key: "optimism", label: "OP Sepolia", circleBlockchain: "OP-SEPOLIA", domain: 2,
    usdc: "0x5fd84259d66Cd46123540766Be93DFE6D43130D7", explorerTx: "https://sepolia-optimism.etherscan.io/tx/" },
  { key: "polygon", label: "Polygon Amoy", circleBlockchain: "MATIC-AMOY", domain: 7,
    usdc: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582", explorerTx: "https://amoy.polygonscan.com/tx/" },
  { key: "unichain", label: "Unichain Sepolia", circleBlockchain: "UNI-SEPOLIA", domain: 10,
    usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F", explorerTx: "https://sepolia.uniscan.xyz/tx/" },
] as Omit<BridgeChain, "gatewayWallet" | "gatewayMinter">[]).map((c) => ({ ...c, gatewayWallet: GATEWAY_WALLET_TESTNET, gatewayMinter: GATEWAY_MINTER_TESTNET }));

function registry(): BridgeChain[] {
  if (env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) return TESTNET;
  throw new Error("The bridge has no mainnet chain list yet. Add it (and test it) before launch.");
}

export function bridgeChains(): BridgeChain[] {
  return registry();
}

export function chainByKey(key: string): BridgeChain {
  const chain = registry().find((c) => c.key === key);
  if (!chain) throw new Error(`Unknown bridge chain: ${key}`);
  return chain;
}

// Arc is home: user balances live there.
export function homeChain(): BridgeChain {
  return chainByKey("arc");
}

// The most Circle may take in fees for one transfer to this chain, in micro USDC.
// BRIDGE_MAX_FEE_USDC is the default; a chain can set a higher cap.
export function feeCapMicro(destination: BridgeChain): number {
  return Math.round((destination.maxFeeUsdc ?? env.BRIDGE_MAX_FEE_USDC) * 1_000_000);
}

export function isEvmAddress(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}
DOC_EOF

cat > "backend/src/bridge/gateway.ts" <<'DOC_EOF'
// Circle Gateway API client and burn intent helpers.
// Docs: developers.circle.com/gateway (technical guide, forwarding service,
// ERC-1271 transfers). Amounts are in micro USDC (6 decimals) everywhere.
import { randomBytes } from "node:crypto";
import { env } from "../env";
import type { BridgeChain } from "./chains";

const MAX_UINT256 = ((1n << 256n) - 1n).toString();
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export class GatewayError extends Error {
  constructor(message: string, public status?: number, public body?: string) {
    super(message);
  }
}

export function toBytes32(address: string): `0x${string}` {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
}

export function microFromDecimal(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) throw new Error(`Not a USDC amount: ${amount}`);
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

const json = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v));

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${env.GATEWAY_API_URL}${path}`, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : json(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new GatewayError(`Gateway ${method} ${path} answered ${res.status}: ${text.slice(0, 300)}`, res.status, text);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new GatewayError(`Gateway ${path} sent something that is not JSON: ${text.slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------------------
// Balances and deposits
// ---------------------------------------------------------------------------
// Available (finalized) Gateway balance of a depositor on one chain, in micro USDC
export async function gatewayBalanceMicro(depositor: string, domain: number): Promise<number> {
  const res = await call<{ balances?: { domain: number; depositor: string; balance: string }[] }>("POST", "/v1/balances", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  const row = (res.balances ?? []).find((b) => b.domain === domain);
  return row ? microFromDecimal(row.balance) : 0;
}

// Deposits seen onchain but not final yet
export async function pendingDeposits(depositor: string, domain: number) {
  const res = await call<{ deposits?: { transactionHash: string; amount: string; status: string }[] }>("POST", "/v1/deposits", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  return res.deposits ?? [];
}

// ---------------------------------------------------------------------------
// Burn intents
// ---------------------------------------------------------------------------
export type TransferSpec = {
  version: 1;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: `0x${string}`;
  destinationContract: `0x${string}`;
  sourceToken: `0x${string}`;
  destinationToken: `0x${string}`;
  sourceDepositor: `0x${string}`;
  destinationRecipient: `0x${string}`;
  sourceSigner: `0x${string}`;
  destinationCaller: `0x${string}`;
  value: string;
  salt: `0x${string}`;
  hookData: `0x${string}`;
};

export type BurnIntent = { maxBlockHeight: string; maxFee: string; spec: TransferSpec };

export function newSalt(): `0x${string}` {
  return `0x${randomBytes(32).toString("hex")}`;
}

// The depositor wallet both holds the Gateway balance and signs (ERC-1271 for SCA wallets).
export function buildSpec(p: {
  source: BridgeChain;
  destination: BridgeChain;
  depositor: string;
  recipient: string;
  amountMicro: number;
  salt: `0x${string}`;
}): TransferSpec {
  return {
    version: 1,
    sourceDomain: p.source.domain,
    destinationDomain: p.destination.domain,
    sourceContract: toBytes32(p.source.gatewayWallet),
    destinationContract: toBytes32(p.destination.gatewayMinter),
    sourceToken: toBytes32(p.source.usdc),
    destinationToken: toBytes32(p.destination.usdc),
    sourceDepositor: toBytes32(p.depositor),
    destinationRecipient: toBytes32(p.recipient),
    sourceSigner: toBytes32(p.depositor),
    destinationCaller: toBytes32(ZERO_ADDRESS),
    value: String(p.amountMicro),
    salt: p.salt,
    hookData: "0x",
  };
}

export type Estimate = { burnIntent: BurnIntent; maxFeeMicro: number; forwardingFeeMicro: number | null; raw: unknown };

// Asks Gateway for the fee. Forwarding: Circle submits the mint on the destination chain.
export async function estimate(spec: TransferSpec, forward = true): Promise<Estimate> {
  const res = await call<{
    body?: { burnIntent?: { maxFee: string | number; maxBlockHeight: string | number } }[];
    fees?: { forwardingFee?: string; token?: string; total?: string };
  }>("POST", `/v1/estimate?enableForwarder=${forward}`, [{ spec }]);
  const est = res.body?.[0]?.burnIntent;
  if (!est) throw new GatewayError(`Gateway estimate returned no burn intent: ${json(res).slice(0, 300)}`);
  const maxFee = String(est.maxFee);
  return {
    burnIntent: { maxBlockHeight: String(est.maxBlockHeight ?? MAX_UINT256), maxFee, spec },
    maxFeeMicro: Number(maxFee),
    forwardingFeeMicro: res.fees?.forwardingFee ? microFromDecimal(String(res.fees.forwardingFee)) : null,
    raw: res,
  };
}

// EIP-712 typed data for the burn intent, as Circle's signTypedData expects (a JSON string)
export function typedData(burnIntent: BurnIntent): string {
  return json({
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
      ],
      TransferSpec: [
        { name: "version", type: "uint32" },
        { name: "sourceDomain", type: "uint32" },
        { name: "destinationDomain", type: "uint32" },
        { name: "sourceContract", type: "bytes32" },
        { name: "destinationContract", type: "bytes32" },
        { name: "sourceToken", type: "bytes32" },
        { name: "destinationToken", type: "bytes32" },
        { name: "sourceDepositor", type: "bytes32" },
        { name: "destinationRecipient", type: "bytes32" },
        { name: "sourceSigner", type: "bytes32" },
        { name: "destinationCaller", type: "bytes32" },
        { name: "value", type: "uint256" },
        { name: "salt", type: "bytes32" },
        { name: "hookData", type: "bytes" },
      ],
      BurnIntent: [
        { name: "maxBlockHeight", type: "uint256" },
        { name: "maxFee", type: "uint256" },
        { name: "spec", type: "TransferSpec" },
      ],
    },
    domain: { name: "GatewayWallet", version: "1" },
    primaryType: "BurnIntent",
    message: burnIntent,
  });
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------
export async function submitTransfer(burnIntent: BurnIntent, signature: string, forward = true): Promise<string> {
  const res = await call<{ transferId?: string }>("POST", `/v1/transfer?enableForwarder=${forward}`, [
    // contractSigner: Gateway checks the signature with ERC-1271 on the SCA wallet
    { burnIntent, signature, contractSigner: true },
  ]);
  if (!res.transferId) throw new GatewayError(`Gateway accepted the transfer but sent no transferId: ${json(res).slice(0, 300)}`);
  return res.transferId;
}

export type TransferStatus = {
  status: "pending" | "confirmed" | "finalized" | "failed" | "expired" | string;
  transactionHash?: string; // the mint on the destination chain
  forwardingDetails?: { forwardingEnabled: boolean; failureReason?: string };
  fees?: unknown;
};

export async function getTransfer(transferId: string): Promise<TransferStatus> {
  return call<TransferStatus>("GET", `/v1/transfer/${transferId}`);
}
DOC_EOF

cat > "backend/src/bridge/service.ts" <<'DOC_EOF'
// Bridge transfers through Circle Gateway, recorded step by step.
//
// QUOTED -> DEPOSITING -> DEPOSITED -> FINALIZED -> INTENT_SIGNED -> SUBMITTED -> MINTED -> COMPLETE
//                                         ^                                   |
//                                         +----------- EXPIRED <--------------+   (nothing burned: retried)
//
// Safety:
//   - every status change is conditional ("only if it is still X"), so two
//     callers can never do the same step twice
//   - every Circle call uses an idempotency key made from the transfer id and
//     the step, so a retry after a crash never sends twice
//   - the fee Circle may take is capped (BRIDGE_MAX_FEE_USDC) and checked
//     again right before signing
//   - OUT transfers only go to approved destinations
//   - Gateway mints first and burns after; if the mint never happens the
//     attestation expires and nothing is burned
import { and, desc, eq, inArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { approvedDestinations, auditLogs, bridgeEvents, bridgeTransfers } from "../db/schema";
import { env } from "../env";
import { uuidFrom } from "../wallets/service";
import { chainByKey, feeCapMicro, isEvmAddress, type BridgeChain } from "./chains";
import {
  type BurnIntent,
  buildSpec,
  estimate,
  gatewayBalanceMicro,
  getTransfer,
  newSalt,
  submitTransfer,
  typedData,
} from "./gateway";

export class BridgeError extends Error {}

type Transfer = typeof bridgeTransfers.$inferSelect;
type Status = Transfer["status"];

const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

async function event(transferId: string, step: string, fields: { chain?: string; txHash?: string | null; circleTransactionId?: string | null; details?: unknown } = {}) {
  await db.insert(bridgeEvents).values({
    transferId,
    step,
    chain: fields.chain ?? null,
    txHash: fields.txHash ?? null,
    circleTransactionId: fields.circleTransactionId ?? null,
    details: fields.details ?? null,
  });
}

async function move(t: Transfer, from: Status[], to: Status, extra: Partial<typeof bridgeTransfers.$inferInsert> = {}) {
  const [row] = await db
    .update(bridgeTransfers)
    .set({ status: to, ...extra })
    .where(and(eq(bridgeTransfers.id, t.id), inArray(bridgeTransfers.status, from)))
    .returning();
  return row;
}

async function fail(t: Transfer, reason: string) {
  const row = await move(t, ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "EXPIRED"], "FAILED", {
    failureReason: reason.slice(0, 500),
  });
  if (row) {
    await event(t.id, "failed", { details: { reason } });
    await db.insert(auditLogs).values({ actorType: "system", action: "bridge.failed", targetType: "bridge_transfer", targetId: t.id, details: { reason } });
    console.error(`[bridge] ${t.id} FAILED: ${reason}`);
  }
}

// Runs one contract call from a Circle wallet and waits for it to finish onchain.
async function contractCall(p: {
  walletId: string;
  contract: string;
  signature: string;
  params: (string | number)[];
  key: string;
}): Promise<{ id: string; txHash?: string }> {
  const res = await circle.createContractExecutionTransaction({
    walletId: p.walletId,
    contractAddress: p.contract,
    abiFunctionSignature: p.signature,
    abiParameters: p.params,
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(p.key),
  } as unknown as Parameters<typeof circle.createContractExecutionTransaction>[0]);
  const id = res.data?.id;
  if (!id) throw new BridgeError(`Circle did not accept ${p.signature}`);
  for (let i = 0; i < 60; i++) {
    const t = await circle.getTransaction({ id });
    const tx = t.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
    if (tx?.state === "COMPLETE") return { id, txHash: tx.txHash };
    if (tx?.state && FAILED_STATES.includes(tx.state)) {
      throw new BridgeError(`${p.signature} ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
    }
    await new Promise((r) => setTimeout(r, 3_000));
  }
  throw new BridgeError(`${p.signature} did not finish in 3 minutes`);
}

// ---------------------------------------------------------------------------
// Creating a transfer
// ---------------------------------------------------------------------------
export async function isApprovedDestination(chainKey: string, address: string): Promise<boolean> {
  const [row] = await db
    .select({ id: approvedDestinations.id })
    .from(approvedDestinations)
    .where(
      and(
        eq(approvedDestinations.chain, chainKey),
        eq(approvedDestinations.address, address.toLowerCase()),
        eq(approvedDestinations.active, true),
      ),
    )
    .limit(1);
  return Boolean(row);
}

export async function createTransfer(p: {
  direction: "OUT" | "IN";
  userId?: string | null;
  depositorWalletId: string; // Circle wallet id of the SCA that deposits and signs
  depositorAddress: string;
  sourceChain: string;
  destinationChain: string;
  recipientAddress: string;
  amountMicro: number;
}): Promise<Transfer> {
  const source = chainByKey(p.sourceChain);
  const destination = chainByKey(p.destinationChain);
  if (source.key === destination.key) throw new BridgeError("Source and destination must be different chains.");
  if (!isEvmAddress(p.recipientAddress) || !isEvmAddress(p.depositorAddress)) throw new BridgeError("Invalid address.");
  if (!Number.isInteger(p.amountMicro) || p.amountMicro < 10_000) throw new BridgeError("The minimum is 0.01 USDC.");
  if (p.direction === "OUT" && !(await isApprovedDestination(destination.key, p.recipientAddress))) {
    throw new BridgeError("This address is not an approved destination.");
  }

  const salt = newSalt();
  const spec = buildSpec({ source, destination, depositor: p.depositorAddress, recipient: p.recipientAddress, amountMicro: p.amountMicro, salt });
  const est = await estimate(spec, true);
  if (est.maxFeeMicro > feeCapMicro(destination)) {
    throw new BridgeError(`Circle's fee (${(est.maxFeeMicro / 1e6).toFixed(6)} USDC) is above the safety cap of ${(feeCapMicro(destination) / 1e6).toFixed(2)} USDC for ${destination.label}.`);
  }

  const [row] = await db
    .insert(bridgeTransfers)
    .values({
      userId: p.userId ?? null,
      direction: p.direction,
      sourceChain: source.key,
      destinationChain: destination.key,
      sourceDomain: source.domain,
      destinationDomain: destination.domain,
      depositorWalletId: p.depositorWalletId,
      depositorAddress: p.depositorAddress.toLowerCase(),
      recipientAddress: p.recipientAddress.toLowerCase(),
      amountMicro: p.amountMicro,
      maxFeeMicro: est.maxFeeMicro,
      forwardingFeeMicro: est.forwardingFeeMicro,
      salt,
      burnIntent: est.burnIntent,
      status: "QUOTED",
    })
    .returning();
  if (!row) throw new Error("Could not save the bridge transfer");
  await event(row.id, "quoted", { details: { maxFeeMicro: est.maxFeeMicro, forwardingFeeMicro: est.forwardingFeeMicro } });
  return row;
}

// ---------------------------------------------------------------------------
// Moving a transfer forward, one step per call. Safe to call as often as you like.
// ---------------------------------------------------------------------------
export async function advanceTransfer(id: string): Promise<Transfer> {
  const [t] = await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, id)).limit(1);
  if (!t) throw new BridgeError("Bridge transfer not found");
  try {
    switch (t.status) {
      case "QUOTED":
        await stepDeposit(t);
        break;
      case "DEPOSITING":
        await stepDeposit(t);
        break;
      case "DEPOSITED":
        await stepFinality(t);
        break;
      case "FINALIZED":
        await stepSign(t);
        break;
      case "INTENT_SIGNED":
        await stepSubmit(t);
        break;
      case "SUBMITTED":
        await stepTrack(t);
        break;
      case "MINTED":
        await stepComplete(t);
        break;
      case "EXPIRED":
        await stepRetry(t);
        break;
      default:
        break;
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[bridge] ${t.id} ${t.status}: ${message}`);
    await event(t.id, "error", { details: { status: t.status, message } });
  }
  const [now] = await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, id)).limit(1);
  return now ?? t;
}

const needed = (t: Transfer) => t.amountMicro + (t.maxFeeMicro ?? 0);

// Puts amount + fee into the Gateway Wallet on the source chain (if not there already).
// The amount to deposit is decided once and recorded, so a retry sends exactly
// the same calls with the same idempotency keys.
async function stepDeposit(t: Transfer) {
  const source = chainByKey(t.sourceChain);
  if (t.status === "QUOTED") {
    const have = await gatewayBalanceMicro(t.depositorAddress, source.domain);
    if (have >= needed(t)) {
      if (await move(t, ["QUOTED"], "FINALIZED")) {
        await event(t.id, "finalized", { chain: source.key, details: { gatewayBalanceMicro: have, note: "already in Gateway" } });
      }
      return;
    }
    if (!(await move(t, ["QUOTED"], "DEPOSITING"))) return;
    await event(t.id, "deposit_planned", { chain: source.key, details: { value: String(needed(t) - have), gatewayBalanceMicro: have } });
  }

  const [plan] = await db
    .select()
    .from(bridgeEvents)
    .where(and(eq(bridgeEvents.transferId, t.id), eq(bridgeEvents.step, "deposit_planned")))
    .orderBy(desc(bridgeEvents.createdAt))
    .limit(1);
  const value = (plan?.details as { value?: string } | null)?.value;
  if (!value) {
    await fail(t, "deposit plan missing");
    return;
  }
  const round = plan?.id ?? "first"; // a re-quote makes a new plan, so new idempotency keys
  const approve = await contractCall({
    walletId: t.depositorWalletId,
    contract: source.usdc,
    signature: "approve(address,uint256)",
    params: [source.gatewayWallet, value],
    key: `bridge:${t.id}:${round}:approve`,
  });
  await event(t.id, "approve", { chain: source.key, txHash: approve.txHash, circleTransactionId: approve.id, details: { value } });
  const deposit = await contractCall({
    walletId: t.depositorWalletId,
    contract: source.gatewayWallet,
    signature: "deposit(address,uint256)",
    params: [source.usdc, value],
    key: `bridge:${t.id}:${round}:deposit`,
  });
  await event(t.id, "deposit", { chain: source.key, txHash: deposit.txHash, circleTransactionId: deposit.id, details: { value } });
  await move(t, ["DEPOSITING"], "DEPOSITED");
}

// Waits until Gateway counts the deposit (after finality on the source chain).
async function stepFinality(t: Transfer) {
  const source = chainByKey(t.sourceChain);
  const have = await gatewayBalanceMicro(t.depositorAddress, source.domain);
  if (have < needed(t)) return; // not final yet; asked again later
  if (await move(t, ["DEPOSITED"], "FINALIZED")) await event(t.id, "finalized", { chain: source.key, details: { gatewayBalanceMicro: have } });
}

// Fresh fee check, then the depositor wallet signs the burn intent.
async function stepSign(t: Transfer) {
  const source = chainByKey(t.sourceChain);
  const destination = chainByKey(t.destinationChain);
  const spec = buildSpec({
    source, destination, depositor: t.depositorAddress, recipient: t.recipientAddress,
    amountMicro: t.amountMicro, salt: t.salt as `0x${string}`,
  });
  const est = await estimate(spec, true);
  if (est.maxFeeMicro > feeCapMicro(destination)) {
    await fail(t, `fee rose to ${(est.maxFeeMicro / 1e6).toFixed(6)} USDC, above the cap`);
    return;
  }
  const have = await gatewayBalanceMicro(t.depositorAddress, source.domain);
  if (have < t.amountMicro + est.maxFeeMicro) {
    // The fee went up a little: move back so the difference is deposited first
    await move(t, ["FINALIZED"], "QUOTED", { maxFeeMicro: est.maxFeeMicro, burnIntent: est.burnIntent });
    await event(t.id, "requote", { details: { maxFeeMicro: est.maxFeeMicro, gatewayBalanceMicro: have } });
    return;
  }
  const res = await circle.signTypedData({
    walletId: t.depositorWalletId,
    data: typedData(est.burnIntent),
    memo: `dataonchain bridge ${t.id}`,
  } as unknown as Parameters<typeof circle.signTypedData>[0]);
  const signature = res.data?.signature;
  if (!signature) throw new BridgeError("Circle did not return a signature");
  if (await move(t, ["FINALIZED"], "INTENT_SIGNED", {
    burnIntent: est.burnIntent, signature, maxFeeMicro: est.maxFeeMicro, forwardingFeeMicro: est.forwardingFeeMicro,
  })) {
    await event(t.id, "signed", { details: { maxFeeMicro: est.maxFeeMicro } });
  }
}

async function stepSubmit(t: Transfer) {
  if (!t.burnIntent || !t.signature) {
    await fail(t, "signed burn intent missing");
    return;
  }
  let transferId: string;
  try {
    transferId = await submitTransfer(t.burnIntent as BurnIntent, t.signature, true);
  } catch (err) {
    const status = (err as { status?: number }).status;
    // 4xx: Gateway refused it, so nothing was attested or burned
    if (status && status >= 400 && status < 500) {
      await fail(t, err instanceof Error ? err.message : String(err));
      return;
    }
    throw err; // network trouble: try again later
  }
  if (await move(t, ["INTENT_SIGNED"], "SUBMITTED", { gatewayTransferId: transferId })) {
    await event(t.id, "submitted", { details: { gatewayTransferId: transferId } });
  }
}

async function stepTrack(t: Transfer) {
  if (!t.gatewayTransferId) return;
  const s = await getTransfer(t.gatewayTransferId);
  const destination = chainByKey(t.destinationChain);
  if (s.status === "confirmed" || s.status === "finalized") {
    if (await move(t, ["SUBMITTED"], "MINTED", { mintTxHash: s.transactionHash ?? null })) {
      await event(t.id, "minted", { chain: destination.key, txHash: s.transactionHash ?? null, details: { gatewayStatus: s.status, fees: s.fees } });
    }
  } else if (s.status === "failed") {
    await fail(t, `Gateway: ${s.forwardingDetails?.failureReason ?? "transfer failed"}`);
  } else if (s.status === "expired") {
    if (await move(t, ["SUBMITTED"], "EXPIRED")) await event(t.id, "expired", { details: { note: "attestation expired before the mint; nothing burned" } });
  }
}

async function stepComplete(t: Transfer) {
  if (await move(t, ["MINTED"], "COMPLETE")) {
    await event(t.id, "complete", { chain: t.destinationChain, txHash: t.mintTxHash });
    await db.insert(auditLogs).values({
      actorType: "system", action: "bridge.complete", targetType: "bridge_transfer", targetId: t.id,
      details: { amountMicro: t.amountMicro, from: t.sourceChain, to: t.destinationChain, mintTxHash: t.mintTxHash },
    });
  }
}

// An expired attestation burned nothing: sign again with a new salt.
async function stepRetry(t: Transfer) {
  if (await move(t, ["EXPIRED"], "FINALIZED", { salt: newSalt(), signature: null, gatewayTransferId: null })) {
    await event(t.id, "retry", { details: { note: "new salt, signing again" } });
  }
}

export function explorerLink(chain: BridgeChain, txHash: string | null | undefined): string | null {
  return txHash ? `${chain.explorerTx}${txHash}` : null;
}
DOC_EOF

cat > "backend/scripts/gateway-probe.ts" <<'DOC_EOF'
// Live check of the Circle Gateway bridge on testnet (development database):
//   1. fee estimates from Arc to every supported chain
//   2. safety rules: unapproved addresses and same chain transfers are refused
//   3. one real transfer: 0.5 USDC from an Arc Testnet smart wallet, through
//      Gateway with forwarding, to an approved smart wallet on Base Sepolia,
//      recorded step by step from the deposit to the mint
// The two probe wallets are kept (saved in backend/.env) and reused next time,
// so leftover test USDC is not wasted. The treasury tops them up when needed.
// Exit code 3 means the treasury needs more test USDC.
// Run with: npx tsx scripts/gateway-probe.ts
import { appendFileSync } from "node:fs";
import { asc, eq } from "drizzle-orm";
import { bridgeChains, chainByKey, feeCapMicro, homeChain } from "../src/bridge/chains";
import { buildSpec, estimate, gatewayBalanceMicro, newSalt } from "../src/bridge/gateway";
import { BridgeError, advanceTransfer, createTransfer } from "../src/bridge/service";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { approvedDestinations, bridgeEvents } from "../src/db/schema";
import { env } from "../src/env";
import { uuidFrom } from "../src/wallets/service";

const AMOUNT_MICRO = 500_000; // 0.5 USDC
const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
  return { tokenId: b?.token?.id, micro: b ? Math.round(Number(b.amount) * 1_000_000) : 0 };
}

// A probe wallet kept in backend/.env, created once
async function probeWallet(name: string, blockchain: string) {
  const idKey = `GATEWAY_PROBE_${name}_WALLET_ID`;
  const addrKey = `GATEWAY_PROBE_${name}_ADDRESS`;
  if (process.env[idKey] && process.env[addrKey]) return { id: process.env[idKey]!, address: process.env[addrKey]! };
  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [blockchain as "ARC-TESTNET"],
    count: 1,
    accountType: "SCA",
    idempotencyKey: uuidFrom(`gateway-probe:${name}:${blockchain}:${env.CIRCLE_WALLET_SET_ID}`),
  });
  const w = res.data?.wallets?.[0];
  if (!w?.id || !w.address) throw new Error(`Circle did not create the ${name} probe wallet`);
  appendFileSync(".env", `\n# Gateway probe wallet (${name.toLowerCase()}, ${blockchain}): test only\n${idKey}=${w.id}\n${addrKey}=${w.address}\n`);
  process.env[idKey] = w.id;
  process.env[addrKey] = w.address;
  return { id: w.id, address: w.address };
}

async function sendFromTreasury(to: string, micro: number, tokenId: string) {
  const amount = show(micro);
  const res = await circle.createTransaction({
    walletId: env.TREASURY_WALLET_ID,
    tokenId,
    destinationAddress: to,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`gateway-probe:fund:${to}:${Date.now()}`),
  } as unknown as Parameters<typeof circle.createTransaction>[0]);
  const id = res.data?.id;
  if (!id) throw new Error("Circle did not accept the funding transfer");
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const t = await circle.getTransaction({ id });
    const state = (t.data?.transaction as unknown as { state?: string } | undefined)?.state;
    if (state === "COMPLETE") return;
    if (state && ["FAILED", "DENIED", "CANCELLED"].includes(state)) throw new Error(`funding transfer ${state}`);
  }
  throw new Error("funding transfer did not complete");
}

async function main() {
  const arc = homeChain();
  const base = chainByKey("base");

  // 1. Fee estimates to every chain (no money moves)
  console.log(`Gateway API: ${env.GATEWAY_API_URL}`);
  const depositor = await probeWallet("DEPOSITOR", arc.circleBlockchain);
  const recipient = await probeWallet("RECIPIENT", base.circleBlockchain);
  console.log(`Probe depositor (Arc Testnet SCA): ${depositor.address}`);
  console.log(`Probe recipient (Base Sepolia SCA): ${recipient.address}`);
  console.log("\nFees from Arc Testnet for 0.5 USDC, with Circle forwarding:");
  for (const dest of bridgeChains().filter((c) => c.key !== arc.key)) {
    const spec = buildSpec({ source: arc, destination: dest, depositor: depositor.address, recipient: recipient.address, amountMicro: AMOUNT_MICRO, salt: newSalt() });
    const est = await estimate(spec, true);
    const cap = feeCapMicro(dest);
    const note = est.maxFeeMicro > cap ? `  ABOVE the ${show(cap)} cap: transfers there are refused until it drops` : `  (cap ${show(cap)})`;
    console.log(`  to ${dest.label.padEnd(18)} max fee ${show(est.maxFeeMicro)} USDC${est.forwardingFeeMicro !== null ? `, forwarding ${show(est.forwardingFeeMicro)}` : ""}${note}`);
    check(est.maxFeeMicro > 0, `Gateway quotes a fee to ${dest.label}`);
  }

  // 2. Safety rules
  await db
    .insert(approvedDestinations)
    .values({ label: "Gateway probe recipient (testnet)", chain: base.key, address: recipient.address.toLowerCase(), note: "created by scripts/gateway-probe.ts" })
    .onConflictDoNothing();
  try {
    await createTransfer({ direction: "OUT", depositorWalletId: depositor.id, depositorAddress: depositor.address, sourceChain: "arc", destinationChain: "base", recipientAddress: "0x000000000000000000000000000000000000dEaD", amountMicro: AMOUNT_MICRO });
    check(false, "an address that is not approved is refused");
  } catch (err) {
    check(err instanceof BridgeError && /approved/.test(err.message), "an address that is not approved is refused");
  }
  try {
    await createTransfer({ direction: "OUT", depositorWalletId: depositor.id, depositorAddress: depositor.address, sourceChain: "arc", destinationChain: "arc", recipientAddress: recipient.address, amountMicro: AMOUNT_MICRO });
    check(false, "a same chain transfer is refused");
  } catch (err) {
    check(err instanceof BridgeError, "a same chain transfer is refused");
  }

  // 3. Make sure the depositor can cover amount + the largest fee we allow
  const cap = feeCapMicro(base);
  const inGateway = await gatewayBalanceMicro(depositor.address, arc.domain);
  const inWallet = (await usdcOf(depositor.id)).micro;
  const want = AMOUNT_MICRO + cap;
  console.log(`\nProbe depositor: ${show(inWallet)} USDC in wallet, ${show(inGateway)} USDC in Gateway`);
  if (inGateway + inWallet < want) {
    const treasury = await usdcOf(env.TREASURY_WALLET_ID);
    const top = want - inGateway - inWallet + 20_000;
    if (!treasury.tokenId || treasury.micro < top + 50_000) {
      console.log(`NEEDS_FUNDING: treasury has ${show(treasury.micro)} USDC, needs ${show(top + 50_000)}`);
      process.exit(3);
    }
    console.log(`Topping up the probe depositor with ${show(top)} USDC from the treasury...`);
    await sendFromTreasury(depositor.address, top, treasury.tokenId);
  }

  // 4. The real transfer
  const recipientBefore = (await usdcOf(recipient.id)).micro;
  const transfer = await createTransfer({
    direction: "OUT",
    depositorWalletId: depositor.id,
    depositorAddress: depositor.address,
    sourceChain: "arc",
    destinationChain: "base",
    recipientAddress: recipient.address,
    amountMicro: AMOUNT_MICRO,
  });
  console.log(`\nBridge transfer ${transfer.id}: 0.5 USDC Arc Testnet -> Base Sepolia, max fee ${show(transfer.maxFeeMicro ?? 0)} USDC`);
  let t = transfer;
  let last = "";
  const started = Date.now();
  while (!["COMPLETE", "FAILED"].includes(t.status) && Date.now() - started < 15 * 60_000) {
    if (t.status !== last) {
      console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${t.status}`);
      last = t.status;
    }
    t = await advanceTransfer(t.id);
    if (t.status === last) await sleep(4_000);
  }
  console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${t.status}${t.failureReason ? `: ${t.failureReason}` : ""}`);
  check(t.status === "COMPLETE", `transfer complete (${Math.round((Date.now() - started) / 1000)} seconds)`);
  check(Boolean(t.mintTxHash), `mint on Base Sepolia recorded: ${base.explorerTx}${t.mintTxHash}`);

  let recipientAfter = recipientBefore;
  for (let i = 0; i < 30 && recipientAfter < recipientBefore + AMOUNT_MICRO; i++) {
    await sleep(3_000);
    recipientAfter = (await usdcOf(recipient.id)).micro;
  }
  check(recipientAfter - recipientBefore === AMOUNT_MICRO, `the recipient received exactly 0.5 USDC on Base Sepolia (${show(recipientBefore)} -> ${show(recipientAfter)})`);

  const steps = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(asc(bridgeEvents.createdAt));
  console.log("\nRecorded steps:");
  for (const s of steps) {
    console.log(`  ${s.createdAt.toLocaleTimeString("en-GB")}  ${s.step.padEnd(16)} ${s.chain ?? ""} ${s.txHash ?? ""}`);
  }
  const names = steps.map((s) => s.step);
  check(names.includes("finalized") && names.includes("signed") && names.includes("submitted") && names.includes("minted") && names.includes("complete"),
    "every step from Gateway balance to final mint is recorded");
  const leftover = await gatewayBalanceMicro(depositor.address, arc.domain);
  console.log(`\nProbe depositor keeps ${show(leftover)} USDC in Gateway for the next run.`);
}

main()
  .then(() => {
    console.log("All Gateway checks passed.");
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
  "approved_destinations",
  "audit_logs",
  "bridge_events",
  "bridge_transfers",
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

cat > "backend/.env.example" <<'DOC_EOF'
# Copy to backend/.env and fill in real values. Never commit backend/.env.
NODE_ENV=development
PORT=4000
# Comma separated list of websites allowed to call the API
FRONTEND_URL=http://localhost:3000

# Turso
TURSO_DATABASE_URL=libsql://your-database-url.turso.io
TURSO_AUTH_TOKEN=your-turso-token

# Auth (Better Auth). Create a secret with: openssl rand -base64 32
BETTER_AUTH_SECRET=change-me
# The address users open in the browser (the website, not the API)
BETTER_AUTH_URL=http://localhost:3000

# Email (Resend). Without a key, emails are printed in the terminal instead.
RESEND_API_KEY=re_your_key
EMAIL_FROM=dataonchain <no-reply@mail.yourdomain.com>

# Circle developer controlled wallets (run setup/08_wallets.sh to fill these)
CIRCLE_API_KEY=TEST_API_KEY:your-key
CIRCLE_ENTITY_SECRET=64-hex-characters
CIRCLE_WALLET_SET_ID=wallet-set-id
CIRCLE_BLOCKCHAIN=ARC-TESTNET


# VTpass (run setup/09_pricing.sh to fill these)
VTPASS_BASE_URL=https://sandbox.vtpass.com/api
VTPASS_API_KEY=your-api-key
VTPASS_PUBLIC_KEY=your-public-key
VTPASS_SECRET_KEY=your-secret-key

# Pricing. 200 = 2% margin. Set NGN_PER_USDC to use a fixed rate instead of the live one.
PRICING_MARGIN_BPS=200
QUOTE_TTL_MINUTES=10
# NGN_PER_USDC=1500

# Treasury: the platform wallet customer payments go to (setup/10_payments.sh creates it)
TREASURY_WALLET_ID=circle-wallet-id
TREASURY_ADDRESS=0x...
# Extra USDC a wallet must hold on top of the price, to cover the network fee
PAYMENT_FEE_BUFFER_USDC=0.02
EXPLORER_TX_URL=https://explorer.testnet.arc.io/tx/

# Background worker (payments and deliveries). On by default in production.
# WORKER_ENABLED=true


# Bridge (Circle Gateway). Off until the user facing bridge ships.
# BRIDGE_ENABLED=false
# GATEWAY_API_URL=https://gateway-api-testnet.circle.com
# BRIDGE_MAX_FEE_USDC=0.5
DOC_EOF

grep -q 'bridgeTransfers' backend/src/db/schema.ts || fail "Could not write backend/src/db/schema.ts"
green "OK: files written"

# --- 2. Database --------------------------------------------------------------------
step "Database: bridge tables"
if ! grep -rqs 'CREATE TABLE `bridge_transfers`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name bridge_foundation)
fi
grep -rqs 'CREATE TABLE `bridge_transfers`' backend/drizzle/*.sql || fail "The bridge migration was not created"
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Gateway: live test on testnet (0.5 test USDC Arc Testnet -> Base Sepolia)"
echo "This takes 1 to 5 minutes. Each step is printed as it happens."
echo "(If this script stopped here before, it is safe to run again: answer y to the uncommitted changes question.)"
set +e
(cd backend && npx tsx scripts/gateway-probe.ts)
code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury needs more test USDC. Send at least 2 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Gateway test failed (details above). Nothing was committed. Paste the output to Claude."
fi

step "Delivery, refunds, payments, pricing, wallets and auth: make sure they still work"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
set +e
(cd backend && npx tsx scripts/refund-smoke.ts); code=$?
set -e
[[ $code -eq 0 || $code -eq 3 ]] || fail "Refund test failed (details above). Nothing was committed."
ADDR_FILE="$(mktemp)"
set +e
(cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE"); code=$?
set -e
rm -f "$ADDR_FILE"
if [[ $code -eq 3 ]]; then
  yellow "The payment test wallet has less than 0.5 test USDC, so the live payment test was skipped."
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

# --- 4. Production database ---------------------------------------------------------
step "Production database: bridge tables"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the production database. Nothing was committed."
unset PROD_TOKEN
green "OK: production database updated (new empty tables; the live site is unaffected)"

# --- 5. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub (no new Render settings are needed; the bridge stays off)"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Bridge foundation: Circle Gateway client, chain registry, transfer engine, bridge tables"
git push
green "OK: pushed. Render is now deploying."

printf 'Waiting for the API on Render '
for _ in $(seq 1 60); do
  body="$(curl -s --max-time 20 "$PROD_API/api/status" || true)"
  if [[ "$body" == *'"gateway":true'* ]]; then echo; green "OK: the API is live"; break; fi
  printf '.'; sleep 10
done
[[ "$body" == *'"gateway":true'* ]] || yellow "Render has not finished yet. That is fine: nothing user facing changed. Check Events on Render later."

echo
green "Script 15 complete. The bridge engine works on testnet; users do not see it yet."
echo "  Next: script 16 adds bridging out for users (approved VTU provider addresses)."
