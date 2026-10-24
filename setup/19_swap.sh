#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 19: swaps on Arc (USDC, EURC, cirBTC)
#
# What this adds:
#   - "Swap" page: pick two of USDC, EURC and cirBTC, see the expected amount,
#     the guaranteed minimum (1% slippage) and the fees, then confirm
#   - built on Circle App Kit (Swap) with the Circle Wallets adapter; gas is
#     paid by Gas Station, like everything else
#   - fee: 0.5% to the dataonchain treasury (Arc keeps 10% of it), plus 0.02%
#     to the swap provider
#   - safety: one swap at a time per user, limits per swap, 20 swaps per day,
#     cancelled instead of filled at a worse price, SWAP_ENABLED switch
#   - every swap recorded (swaps table); interrupted ones are flagged in the
#     daily report; the wallet card shows EURC and cirBTC balances
#   - last step: you switch it on with SWAP_ENABLED=true on Render
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/19_swap.sh
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
[[ -f backend/src/bridge/monitor.ts ]] || fail "Run this from ~/dataonchain after script 18 (bridge safety)"
[[ -n "$(env_get GATEWAY_PROBE_RECIPIENT_ADDRESS)" ]] || fail "GATEWAY_PROBE_RECIPIENT_ADDRESS missing in $ENV_FILE (script 15 creates it)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/19_swap.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Installing Circle App Kit (swap) in the backend"
(cd backend && npm install @circle-fin/app-kit @circle-fin/adapter-circle-wallets) || fail "Could not install App Kit. Check your internet connection and run again."
green "OK"

step "Writing backend and frontend files"
mkdir -p backend/src/swap frontend/src/app/swap
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
// Token swaps on Arc (Circle App Kit): USDC, EURC, cirBTC
export const SWAP_TOKENS = ["USDC", "EURC", "cirBTC"] as const;
export const SWAP_STATUSES = ["PENDING", "COMPLETE", "FAILED", "UNKNOWN"] as const;
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
// Swaps on Arc. open_key holds the user id while a swap is running, so a user
// can only have one swap in progress at a time (double clicks cannot swap twice).
// Amounts are decimal strings in token units (cirBTC has 8 decimals).
// ---------------------------------------------------------------------------
export const swaps = sqliteTable(
  "swaps",
  {
    id: id(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id),
    walletAddress: text("wallet_address").notNull(),
    tokenIn: text("token_in", { enum: SWAP_TOKENS }).notNull(),
    tokenOut: text("token_out", { enum: SWAP_TOKENS }).notNull(),
    amountIn: text("amount_in").notNull(),
    estimatedOut: text("estimated_out"),
    minOut: text("min_out"),
    amountOut: text("amount_out"),
    feeBps: integer("fee_bps").notNull(),
    slippageBps: integer("slippage_bps").notNull(),
    txHash: text("tx_hash"),
    status: text("status", { enum: SWAP_STATUSES }).notNull().default("PENDING"),
    error: text("error"),
    details: text("details", { mode: "json" }),
    openKey: text("open_key").unique(),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("swaps_user_idx").on(t.userId), index("swaps_status_idx").on(t.status)],
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
  // Swaps on Arc (Circle App Kit). Off until switched on.
  SWAP_ENABLED: (process.env.SWAP_ENABLED ?? "false") === "true",
  SWAP_FEE_BPS: Number(process.env.SWAP_FEE_BPS ?? 50), // 0.5%, paid to the treasury
  SWAP_SLIPPAGE_BPS: Number(process.env.SWAP_SLIPPAGE_BPS ?? 100), // 1%
  SWAP_DAILY_COUNT: Number(process.env.SWAP_DAILY_COUNT ?? 20),
  // Where bridge alerts and the daily bridge report are emailed (optional)
  ALERT_EMAIL: process.env.ALERT_EMAIL?.trim() || undefined,
  // Limits for users bridging out (USDC)
  BRIDGE_MIN_USDC: optionalNumber("BRIDGE_MIN_USDC") ?? 1,
  BRIDGE_MAX_USDC: optionalNumber("BRIDGE_MAX_USDC") ?? 100,
  BRIDGE_DAILY_USDC: optionalNumber("BRIDGE_DAILY_USDC") ?? 200,
  // The most Circle may take in fees for one bridge transfer (safety cap)
  BRIDGE_MAX_FEE_USDC: optionalNumber("BRIDGE_MAX_FEE_USDC") ?? 0.5,
  // Background worker: on in production unless WORKER_ENABLED=false
  WORKER_ENABLED: (process.env.WORKER_ENABLED ?? (NODE_ENV === "production" ? "true" : "false")) === "true",
};
DOC_EOF

cat > "backend/src/app.ts" <<'DOC_EOF'
// The API: routes, CORS and error handling.
import { Hono, type Context } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { auth } from "./auth";
import { requireAuth } from "./auth/middleware";
import { client } from "./db";
import { env } from "./env";
import { PaymentError, getOrderView, listOrders, payOrder } from "./payments/service";
import { isNetwork, listDataPlans } from "./catalog/plans";
import { QuoteError, createQuote, getQuote } from "./pricing/quote";
import { NETWORK_NAMES, ensureUserWallet, previousWallet } from "./wallets/service";
import { SwapError, TOKENS, executeSwap, listSwaps, quoteSwap, tokenBalances } from "./swap/service";
import { BridgeUserError, bridgeBalance, chainBalances, getBridgeView, listBridges, listDestinations, quoteBridge, returnToArc, startBridge } from "./bridge/user";

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
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED }));

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
  let tokens: { EURC: string; cirBTC: string } | null = null;
  try {
    const all = await tokenBalances(wallet.circleWalletId);
    usdc = all.USDC;
    tokens = { EURC: all.EURC, cirBTC: all.cirBTC };
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
    bridgeBalance: await bridgeBalance(wallet.address),
    balance: { usdc },
    tokens,
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

// ---------------------------------------------------------------------------
// Bridge OUT: send USDC from the user's Arc wallet to an approved address on
// another chain (Circle Gateway). Off unless BRIDGE_ENABLED=true.
// ---------------------------------------------------------------------------
function bridgeErrors(err: unknown, c: Context) {
  if (err instanceof BridgeUserError) return c.json({ error: err.message }, err.status);
  throw err;
}

app.get("/api/bridge/destinations", requireAuth, async (c) => {
  try {
    return c.json({ destinations: await listDestinations(), limits: { min: env.BRIDGE_MIN_USDC, max: env.BRIDGE_MAX_USDC, daily: env.BRIDGE_DAILY_USDC } });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

app.post("/api/bridge/quote", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const body = (await c.req.json().catch(() => ({}))) as { destinationId?: unknown; amount?: unknown };
  try {
    return c.json({ quote: await quoteBridge(user.id, body) });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

app.post("/api/bridge/transfers", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const body = (await c.req.json().catch(() => ({}))) as { destinationId?: unknown; amount?: unknown };
  try {
    return c.json({ transfer: await startBridge(user.id, body) });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

// The user's own wallets on other networks, with balances
app.get("/api/bridge/wallets", requireAuth, async (c) => {
  const { user } = c.get("auth");
  try {
    return c.json({ wallets: await chainBalances(user.id) });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

// "Move to Arc": everything in the user's wallet on that network comes home
app.post("/api/bridge/return", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const body = (await c.req.json().catch(() => ({}))) as { chain?: unknown };
  try {
    return c.json({ transfer: await returnToArc(user.id, body) });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

app.get("/api/bridge/transfers", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ transfers: await listBridges(user.id) });
});

app.get("/api/bridge/transfers/:id", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const transfer = await getBridgeView(user.id, c.req.param("id"));
  if (!transfer) return c.json({ error: "Transfer not found" }, 404);
  return c.json({ transfer });
});

// ---------------------------------------------------------------------------
// Swaps on Arc: USDC, EURC, cirBTC (Circle App Kit). Off unless SWAP_ENABLED=true.
// ---------------------------------------------------------------------------
function swapErrors(err: unknown, c: Context) {
  if (err instanceof SwapError) return c.json({ error: err.message }, err.status);
  throw err;
}

app.get("/api/swap/tokens", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!env.SWAP_ENABLED) return c.json({ error: "Swaps are not available yet." }, 503);
  const wallet = await ensureUserWallet(user.id);
  return c.json({
    balances: await tokenBalances(wallet.circleWalletId),
    limits: TOKENS,
    feePercent: env.SWAP_FEE_BPS / 100,
    slippagePercent: env.SWAP_SLIPPAGE_BPS / 100,
  });
});

app.post("/api/swap/quote", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const body = (await c.req.json().catch(() => ({}))) as { tokenIn?: unknown; tokenOut?: unknown; amount?: unknown };
  try {
    return c.json({ quote: await quoteSwap(user.id, body) });
  } catch (err) {
    return swapErrors(err, c);
  }
});

app.post("/api/swap", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const body = (await c.req.json().catch(() => ({}))) as { tokenIn?: unknown; tokenOut?: unknown; amount?: unknown };
  try {
    return c.json({ swap: await executeSwap(user.id, body) });
  } catch (err) {
    return swapErrors(err, c);
  }
});

app.get("/api/swaps", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ swaps: await listSwaps(user.id) });
});

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
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
import { bridgeTransfers } from "./db/schema";
import { advanceTransfer } from "./bridge/service";
import { driving } from "./bridge/user";
import { alertStuck, dailyReconcile } from "./bridge/monitor";
import { releaseAbandonedSwaps } from "./swap/service";

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
  // Bridge transfers left behind (for example after a restart)
  try {
    const open = await db
      .select({ id: bridgeTransfers.id })
      .from(bridgeTransfers)
      .where(inArray(bridgeTransfers.status, ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"]))
      .limit(20);
    for (const { id } of open) {
      if (driving.has(id)) continue;
      driving.add(id);
      try {
        await advanceTransfer(id);
      } finally {
        driving.delete(id);
      }
    }
  } catch (err) {
    console.error("[worker] bridge transfers failed:", err instanceof Error ? err.message : err);
  }
  // Report stuck bridge transfers (once each) and run the daily reconciliation
  try {
    await alertStuck();
    await dailyReconcile();
  } catch (err) {
    console.error("[worker] bridge monitoring failed:", err instanceof Error ? err.message : err);
  }
  try {
    await releaseAbandonedSwaps();
  } catch (err) {
    console.error("[worker] swaps check failed:", err instanceof Error ? err.message : err);
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

cat > "backend/src/bridge/monitor.ts" <<'DOC_EOF'
// Watching the bridge:
//   - stuck transfers: anything sitting in one step for too long is reported
//     once (audit log, Render logs, and email to ALERT_EMAIL). The worker keeps
//     retrying them every 30 seconds in the meantime.
//   - daily reconciliation: every completed transfer is checked against Circle
//     Gateway's own record (same mint transaction), and leftover Gateway
//     balances are totalled. The report is emailed to ALERT_EMAIL once a day.
import { and, desc, eq, gte, inArray, lt, notInArray } from "drizzle-orm";
import { db } from "../db";
import { auditLogs, bridgeTransfers } from "../db/schema";
import { sendEmail } from "../email";
import { env } from "../env";
import { bridgeChains, chainByKey } from "./chains";
import { gatewayBalanceMicro, getTransfer } from "./gateway";
import { swapSummary } from "../swap/service";

type Transfer = typeof bridgeTransfers.$inferSelect;

// How long a transfer may stay in one step before it counts as stuck (minutes).
// DEPOSITED waits for source chain finality: about 20 minutes on Ethereum based networks.
export const STUCK_AFTER_MINUTES: Partial<Record<Transfer["status"], number>> = {
  QUOTED: 30,
  DEPOSITING: 30,
  DEPOSITED: 60,
  FINALIZED: 30,
  INTENT_SIGNED: 15,
  SUBMITTED: 20,
  MINTED: 10,
  EXPIRED: 30,
};

const usdc = (micro: number) => (micro / 1_000_000).toFixed(6);
const minutesAgo = (d: Date) => Math.round((Date.now() - d.getTime()) / 60_000);

export async function findStuck(): Promise<Transfer[]> {
  const out: Transfer[] = [];
  for (const [status, minutes] of Object.entries(STUCK_AFTER_MINUTES)) {
    const rows = await db
      .select()
      .from(bridgeTransfers)
      .where(and(eq(bridgeTransfers.status, status as Transfer["status"]), lt(bridgeTransfers.updatedAt, new Date(Date.now() - minutes * 60_000))))
      .limit(50);
    out.push(...rows);
  }
  return out;
}

function describe(t: Transfer): string {
  return `${t.id}  ${usdc(t.amountMicro)} USDC ${chainByKey(t.sourceChain).label} -> ${chainByKey(t.destinationChain).label}, ${t.status} for ${minutesAgo(t.updatedAt)} min`;
}

async function notify(subject: string, lines: string[]) {
  if (!env.ALERT_EMAIL) return;
  const text = lines.join("\n");
  const html = `<pre style="font-family:monospace;font-size:13px">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</pre>`;
  try {
    await sendEmail({ to: env.ALERT_EMAIL, subject, text, html });
  } catch (err) {
    console.error("[bridge] could not email the alert:", err instanceof Error ? err.message : err);
  }
}

// Reports each stuck transfer once per step. Returns how many new alerts were raised.
export async function alertStuck(): Promise<number> {
  const stuck = await findStuck();
  const fresh: Transfer[] = [];
  for (const t of stuck) {
    const previous = await db
      .select({ details: auditLogs.details })
      .from(auditLogs)
      .where(and(eq(auditLogs.action, "bridge.stuck"), eq(auditLogs.targetId, t.id)));
    if (previous.some((p) => (p.details as { status?: string } | null)?.status === t.status)) continue;
    await db.insert(auditLogs).values({
      actorType: "system",
      action: "bridge.stuck",
      targetType: "bridge_transfer",
      targetId: t.id,
      details: { status: t.status, minutes: minutesAgo(t.updatedAt) },
    });
    console.error(`[bridge] STUCK ${describe(t)}`);
    fresh.push(t);
  }
  if (fresh.length) {
    await notify(`dataonchain: ${fresh.length} bridge transfer${fresh.length > 1 ? "s" : ""} stuck`, [
      "These bridge transfers have not moved for a while. The worker keeps retrying them.",
      "Funds are safe: Gateway only burns after the mint, and deposits stay in the user's Gateway balance.",
      "",
      ...fresh.map(describe),
      "",
      "Details: bash setup/bridge-report.sh prod",
    ]);
  }
  return fresh.length;
}

export type Report = { generatedAt: string; issues: string[]; lines: string[] };

export async function reconcile(): Promise<Report> {
  const issues: string[] = [];
  const lines: string[] = [];
  const since = new Date(Date.now() - 24 * 60 * 60_000);

  const open = await db
    .select()
    .from(bridgeTransfers)
    .where(notInArray(bridgeTransfers.status, ["COMPLETE", "FAILED"]));
  const failed = await db
    .select()
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "FAILED"), gte(bridgeTransfers.updatedAt, since)));
  const done = await db
    .select()
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "COMPLETE"), gte(bridgeTransfers.updatedAt, since)))
    .orderBy(desc(bridgeTransfers.updatedAt));

  lines.push(`Last 24 hours: ${done.length} complete (${usdc(done.reduce((s, t) => s + t.amountMicro, 0))} USDC), ${failed.length} failed. Open now: ${open.length}.`);

  // Every completed transfer must match Circle Gateway's own record
  let checked = 0;
  for (const t of done) {
    if (!t.mintTxHash) {
      issues.push(`COMPLETE without a mint transaction: ${t.id}`);
      continue;
    }
    if (!t.gatewayTransferId) {
      issues.push(`COMPLETE without a Gateway transfer id: ${t.id}`);
      continue;
    }
    try {
      const g = await getTransfer(t.gatewayTransferId);
      if (!["confirmed", "finalized"].includes(g.status)) issues.push(`Gateway says ${g.status} for completed transfer ${t.id}`);
      else if ((g.transactionHash ?? "").toLowerCase() !== t.mintTxHash.toLowerCase()) issues.push(`Mint transaction differs from Gateway's for ${t.id}`);
      else checked++;
    } catch (err) {
      issues.push(`Could not check ${t.id} with Gateway: ${err instanceof Error ? err.message : err}`);
    }
  }
  lines.push(`Checked against Circle Gateway: ${checked} of ${done.length} completed transfers match.`);

  for (const t of await findStuck()) issues.push(`Stuck: ${describe(t)}`);
  for (const t of failed) lines.push(`Failed: ${t.id}  ${usdc(t.amountMicro)} USDC to ${chainByKey(t.destinationChain).label}: ${t.failureReason ?? "unknown"}`);

  // Leftovers held in Gateway for users (unused fee margins, unfinished transfers)
  const pairs = await db
    .selectDistinct({ depositor: bridgeTransfers.depositorAddress, chain: bridgeTransfers.sourceChain })
    .from(bridgeTransfers);
  let held = 0;
  const perChain: Record<string, number> = {};
  for (const p of pairs) {
    try {
      const b = await gatewayBalanceMicro(p.depositor, chainByKey(p.chain).domain);
      held += b;
      perChain[p.chain] = (perChain[p.chain] ?? 0) + b;
    } catch {
      issues.push(`Could not read the Gateway balance of ${p.depositor} on ${p.chain}`);
    }
  }
  lines.push(`Held in Circle Gateway for users: ${usdc(held)} USDC across ${pairs.length} wallet(s)` +
    (Object.keys(perChain).length ? ` (${bridgeChains().filter((c) => perChain[c.key]).map((c) => `${c.label} ${usdc(perChain[c.key]!)}`).join(", ")})` : ""));

  // Swaps on Arc
  const s = await swapSummary(since);
  lines.push(`Swaps, last 24 hours: ${s.complete} complete, ${s.failed} failed (nothing taken).`);
  for (const u of s.unknown) issues.push(`Swap needs a check (interrupted or unclear): ${u}`);

  return { generatedAt: new Date().toISOString(), issues, lines };
}

export function formatReport(r: Report): string[] {
  return [
    `dataonchain bridge report, ${new Date(r.generatedAt).toLocaleString("en-GB", { timeZone: "Africa/Lagos" })} (Lagos)`,
    "",
    ...r.lines,
    "",
    r.issues.length ? `${r.issues.length} issue(s):` : "No issues found.",
    ...r.issues.map((i) => `  - ${i}`),
  ];
}

// Once a day (checked every worker tick): run the reconciliation and email it.
export async function dailyReconcile(): Promise<boolean> {
  const [last] = await db
    .select({ createdAt: auditLogs.createdAt })
    .from(auditLogs)
    .where(inArray(auditLogs.action, ["bridge.reconcile"]))
    .orderBy(desc(auditLogs.createdAt))
    .limit(1);
  if (last && Date.now() - last.createdAt.getTime() < 24 * 60 * 60_000) return false;
  const r = await reconcile();
  await db.insert(auditLogs).values({ actorType: "system", action: "bridge.reconcile", targetType: "bridge", targetId: null, details: { issues: r.issues, lines: r.lines } });
  for (const line of formatReport(r)) console.log(`[bridge report] ${line}`);
  await notify(r.issues.length ? `dataonchain bridge report: ${r.issues.length} issue(s)` : "dataonchain bridge report: all good", formatReport(r));
  return true;
}
DOC_EOF

cat > "backend/src/swap/service.ts" <<'DOC_EOF'
// Swaps on Arc between USDC, EURC and cirBTC, through Circle App Kit.
//
// Swap: PENDING -> COMPLETE   (or FAILED: nothing swapped, or UNKNOWN: check onchain)
//
// Safety:
//   - one swap at a time per user (unique open_key), so a double click cannot swap twice
//   - the user never gets less than the quote minus the slippage (1% by default):
//     otherwise the swap reverts and nothing changes
//   - limits per swap and swaps per day; SWAP_ENABLED switches it all off
//   - the dataonchain fee (0.5%) is taken by App Kit and sent to the treasury
//     (Arc keeps 10% of that fee); the swap provider charges 0.02%
import { AppKit } from "@circle-fin/app-kit";
import { createCircleWalletsAdapter } from "@circle-fin/adapter-circle-wallets";
import { and, desc, eq, gte, inArray, isNull, lt } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, swaps } from "../db/schema";
import { env } from "../env";
import { ensureUserWallet } from "../wallets/service";

export type SwapToken = (typeof SWAP_TOKENS)[number];

export class SwapError extends Error {
  constructor(message: string, public status: 400 | 402 | 404 | 409 | 502 | 503 = 400) {
    super(message);
  }
}

// Decimals and per swap limits, in token units
export const TOKENS: Record<SwapToken, { decimals: number; min: number; max: number; label: string }> = {
  USDC: { decimals: 6, min: 0.5, max: 500, label: "USDC" },
  EURC: { decimals: 6, min: 0.5, max: 500, label: "EURC" },
  cirBTC: { decimals: 8, min: 0.000005, max: 0.01, label: "cirBTC" },
};

const CHAIN = env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "Arc_Testnet" : "Arc";
const EXPLORER_TX = env.EXPLORER_TX_URL;

let kit: AppKit | null = null;
let adapter: ReturnType<typeof createCircleWalletsAdapter> | null = null;
function appKit() {
  if (!kit) kit = new AppKit();
  if (!adapter) adapter = createCircleWalletsAdapter({ apiKey: env.CIRCLE_API_KEY, entitySecret: env.CIRCLE_ENTITY_SECRET });
  return { kit, adapter };
}

function isToken(value: unknown): value is SwapToken {
  return typeof value === "string" && (SWAP_TOKENS as readonly string[]).includes(value);
}

function parseAmount(token: SwapToken, amount: unknown): string {
  const text = String(amount ?? "").trim();
  const decimals = TOKENS[token].decimals;
  if (!new RegExp(`^\\d+(\\.\\d{1,${decimals}})?$`).test(text)) throw new SwapError(`Enter an amount of ${token}, with at most ${decimals} decimals.`);
  const n = Number(text);
  if (n < TOKENS[token].min) throw new SwapError(`The minimum is ${TOKENS[token].min} ${token}.`);
  if (n > TOKENS[token].max) throw new SwapError(`The maximum per swap is ${TOKENS[token].max} ${token}.`);
  return text;
}

function requireEnabled() {
  if (!env.SWAP_ENABLED) throw new SwapError("Swaps are not available yet.", 503);
}

// The user's Arc balances of all three tokens, as decimal strings
export async function tokenBalances(circleWalletId: string): Promise<Record<SwapToken, string>> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const list = res.data?.tokenBalances ?? [];
  const find = (sym: string) => list.find((b) => (b.token?.symbol ?? "").toUpperCase().startsWith(sym.toUpperCase()))?.amount ?? "0";
  return { USDC: find("USDC"), EURC: find("EURC"), cirBTC: find("CIRBTC") };
}

type Params = { tokenIn?: unknown; tokenOut?: unknown; amount?: unknown };

function readParams(body: Params) {
  if (!isToken(body.tokenIn) || !isToken(body.tokenOut)) throw new SwapError("Choose two of USDC, EURC and cirBTC.");
  if (body.tokenIn === body.tokenOut) throw new SwapError("Choose two different tokens.");
  return { tokenIn: body.tokenIn, tokenOut: body.tokenOut, amountIn: parseAmount(body.tokenIn, body.amount) };
}

function swapParams(address: string, tokenIn: SwapToken, tokenOut: SwapToken, amountIn: string) {
  const { adapter } = appKit();
  return {
    from: { adapter, chain: CHAIN, address },
    tokenIn,
    tokenOut,
    amountIn,
    config: {
      apiKey: env.CIRCLE_API_KEY,
      slippageBps: env.SWAP_SLIPPAGE_BPS,
      // Smart contract wallets approve instead of signing a permit
      allowanceStrategy: "approve",
      ...(env.SWAP_FEE_BPS > 0 ? { customFee: { percentageBps: env.SWAP_FEE_BPS, recipientAddress: env.TREASURY_ADDRESS } } : {}),
    },
  };
}

// Reads an amount from App Kit's answer, which may be a string or { amount, token }
function amountOf(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number") return String(value);
  const v = value as { amount?: unknown };
  return v.amount !== undefined ? String(v.amount) : null;
}

function errorText(err: unknown): string {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  const base = err instanceof Error ? err.message : String(err);
  return (detail ? `${base} ${JSON.stringify(detail)}` : base).slice(0, 500);
}

function friendly(message: string): string {
  if (/liquidity|route|revert|INSUFFICIENT_OUTPUT|slippage|stop ?limit/i.test(message)) {
    return "The price moved or there was not enough liquidity, so the swap was cancelled. Nothing was taken. Please try again, or try a smaller amount.";
  }
  return "The swap could not be completed. Nothing was taken. Please try again in a moment.";
}

export async function quoteSwap(userId: string, body: Params) {
  requireEnabled();
  const { tokenIn, tokenOut, amountIn } = readParams(body);
  const wallet = await ensureUserWallet(userId);
  const balances = await tokenBalances(wallet.circleWalletId);
  let estimate: unknown;
  try {
    estimate = await appKit().kit.estimateSwap(swapParams(wallet.address, tokenIn, tokenOut, amountIn) as never);
  } catch (err) {
    console.error("[swap] estimate failed:", errorText(err));
    throw new SwapError("No price is available for this swap right now. Please try again shortly, or try a smaller amount.", 502);
  }
  const e = estimate as { estimatedOutput?: unknown; stopLimit?: unknown; fees?: unknown };
  return {
    tokenIn,
    tokenOut,
    amountIn,
    estimatedOut: amountOf(e.estimatedOutput),
    minOut: amountOf(e.stopLimit),
    feePercent: env.SWAP_FEE_BPS / 100,
    slippagePercent: env.SWAP_SLIPPAGE_BPS / 100,
    fees: e.fees ?? null,
    balance: balances[tokenIn],
    enough: Number(balances[tokenIn]) >= Number(amountIn),
  };
}

export async function executeSwap(userId: string, body: Params) {
  requireEnabled();
  const { tokenIn, tokenOut, amountIn } = readParams(body);
  const wallet = await ensureUserWallet(userId);

  const today = await db
    .select({ id: swaps.id })
    .from(swaps)
    .where(and(eq(swaps.userId, userId), gte(swaps.createdAt, new Date(Date.now() - 24 * 60 * 60_000)), inArray(swaps.status, ["COMPLETE", "PENDING", "UNKNOWN"])));
  if (today.length >= env.SWAP_DAILY_COUNT) throw new SwapError(`The limit is ${env.SWAP_DAILY_COUNT} swaps per day.`, 409);

  const balances = await tokenBalances(wallet.circleWalletId);
  if (Number(balances[tokenIn]) < Number(amountIn)) {
    throw new SwapError(`Not enough ${tokenIn}. You have ${balances[tokenIn]} ${tokenIn}.`, 402);
  }

  // Claim: only one swap at a time per user
  const [row] = await db
    .insert(swaps)
    .values({
      userId,
      walletAddress: wallet.address,
      tokenIn,
      tokenOut,
      amountIn,
      feeBps: env.SWAP_FEE_BPS,
      slippageBps: env.SWAP_SLIPPAGE_BPS,
      status: "PENDING",
      openKey: userId,
    })
    .onConflictDoNothing()
    .returning();
  if (!row) throw new SwapError("You already have a swap in progress. Please wait for it to finish.", 409);

  const params = swapParams(wallet.address, tokenIn, tokenOut, amountIn);
  try {
    const estimate = (await appKit().kit.estimateSwap(params as never)) as { estimatedOutput?: unknown; stopLimit?: unknown };
    await db.update(swaps).set({ estimatedOut: amountOf(estimate.estimatedOutput), minOut: amountOf(estimate.stopLimit) }).where(eq(swaps.id, row.id));
  } catch (err) {
    const message = errorText(err);
    await db.update(swaps).set({ status: "FAILED", error: message, openKey: null }).where(eq(swaps.id, row.id));
    console.error(`[swap] ${row.id} no quote:`, message);
    throw new SwapError("No price is available for this swap right now. Nothing was taken. Please try again shortly.", 502);
  }

  try {
    const result = (await appKit().kit.swap(params as never)) as {
      txHash?: string;
      amountOut?: unknown;
      fees?: unknown;
      progress?: { status?: string; substatus?: string; substatusMessage?: string };
    };
    const ok = Boolean(result.txHash) && (!result.progress?.status || /DONE|COMPLETE|SUCCESS/i.test(result.progress.status));
    await db
      .update(swaps)
      .set({
        status: ok ? "COMPLETE" : "UNKNOWN",
        txHash: result.txHash ?? null,
        amountOut: amountOf(result.amountOut),
        details: { fees: result.fees ?? null, progress: result.progress ?? null },
        openKey: null,
      })
      .where(eq(swaps.id, row.id));
    await db.insert(auditLogs).values({
      actorType: "user", actorId: userId, action: ok ? "swap.complete" : "swap.unknown", targetType: "swap", targetId: row.id,
      details: { tokenIn, tokenOut, amountIn, amountOut: amountOf(result.amountOut), txHash: result.txHash ?? null },
    });
    console.log(`[swap] ${row.id} ${amountIn} ${tokenIn} -> ${amountOf(result.amountOut) ?? "?"} ${tokenOut} ${ok ? "COMPLETE" : "UNKNOWN"} ${result.txHash ?? ""}`);
  } catch (err) {
    const message = errorText(err);
    // App Kit reports failures before or during the transaction. A transaction
    // hash in the error means something was sent: mark UNKNOWN to be checked.
    const sent = /0x[0-9a-fA-F]{64}/.exec(message)?.[0] ?? null;
    await db
      .update(swaps)
      .set({ status: sent ? "UNKNOWN" : "FAILED", error: message, txHash: sent, openKey: null })
      .where(eq(swaps.id, row.id));
    console.error(`[swap] ${row.id} ${sent ? "UNKNOWN" : "FAILED"}:`, message);
    if (!sent) throw new SwapError(friendly(message), 502);
  }
  return getSwapView(userId, row.id);
}

export async function getSwapView(userId: string, id: string) {
  const [s] = await db.select().from(swaps).where(and(eq(swaps.id, id), eq(swaps.userId, userId))).limit(1);
  if (!s) return null;
  return {
    id: s.id,
    status: s.status,
    tokenIn: s.tokenIn,
    tokenOut: s.tokenOut,
    amountIn: s.amountIn,
    estimatedOut: s.estimatedOut,
    minOut: s.minOut,
    amountOut: s.amountOut,
    feePercent: s.feeBps / 100,
    txHash: s.txHash,
    explorerUrl: s.txHash ? `${EXPLORER_TX}${s.txHash}` : null,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSwaps(userId: string) {
  const rows = await db.select().from(swaps).where(eq(swaps.userId, userId)).orderBy(desc(swaps.createdAt)).limit(20);
  return Promise.all(rows.map((s) => getSwapView(userId, s.id)));
}

// A swap left PENDING (for example the server restarted mid swap) is marked
// UNKNOWN after 10 minutes so it shows up in the daily report for a check.
export async function releaseAbandonedSwaps(): Promise<number> {
  const rows = await db
    .update(swaps)
    .set({ status: "UNKNOWN", openKey: null, error: "Interrupted: check the wallet onchain" })
    .where(and(eq(swaps.status, "PENDING"), lt(swaps.updatedAt, new Date(Date.now() - 10 * 60_000))))
    .returning({ id: swaps.id });
  return rows.length;
}

export async function swapSummary(since: Date) {
  const rows = await db.select().from(swaps).where(gte(swaps.createdAt, since));
  const unknown = await db.select().from(swaps).where(and(eq(swaps.status, "UNKNOWN"), isNull(swaps.openKey)));
  return {
    complete: rows.filter((r) => r.status === "COMPLETE").length,
    failed: rows.filter((r) => r.status === "FAILED").length,
    unknown: unknown.map((u) => `${u.id} ${u.amountIn} ${u.tokenIn} -> ${u.tokenOut} ${u.txHash ?? "(no tx)"}`),
  };
}
DOC_EOF

cat > "backend/scripts/swap-smoke.ts" <<'DOC_EOF'
// Swaps on Arc Testnet with the development database:
//   a test user swaps 0.5 USDC to EURC, then the EURC back to USDC.
// Exit code 3: the treasury needs more test USDC.
// Exit code 4: Arc Testnet had no liquidity or price for the swap (Circle's side).
// Run with: SWAP_ENABLED=true npx tsx scripts/swap-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, swaps, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { SwapError, executeSwap, quoteSwap, tokenBalances } from "../src/swap/service";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function refused(label: string, fn: () => Promise<unknown>, pattern: RegExp) {
  try {
    await fn();
    check(false, label);
  } catch (err) {
    check(err instanceof SwapError && pattern.test(err.message), label, err instanceof Error ? err.message : err);
  }
}

class NoLiquidity extends Error {}

async function main() {
  if (!env.SWAP_ENABLED) throw new Error("Run with SWAP_ENABLED=true");
  const tRes = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (tRes.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!t?.token?.id || Number(t.amount) < 1.2) {
    console.log(`NEEDS_FUNDING: treasury has ${t?.amount ?? 0} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Swap Smoke Test", email: `swapsmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  try {
    const wallet = await ensureUserWallet(userId);
    await refused("swapping a token for itself is refused", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "USDC", amount: "1" }), /different/);
    await refused("an amount below the minimum is refused", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.1" }), /minimum/);
    await refused("an unknown token is refused", () => executeSwap(userId, { tokenIn: "USDT", tokenOut: "EURC", amount: "1" }), /Choose/);
    await refused("an empty wallet cannot swap", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" }), /Not enough/);

    console.log("Funding the test user's Arc wallet with 1 USDC from the treasury...");
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID, tokenId: t.token.id, destinationAddress: wallet.address,
      amount: ["1.000000"], amounts: ["1.000000"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`swap-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check(Number((await tokenBalances(wallet.circleWalletId)).USDC) >= 1, "test wallet funded");

    // One swap at a time
    await db.insert(swaps).values({ userId, walletAddress: wallet.address, tokenIn: "USDC", tokenOut: "EURC", amountIn: "0.5", feeBps: 50, slippageBps: 100, openKey: userId });
    await refused("a second swap waits for the first", () => executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" }), /in progress/);
    await db.delete(swaps).where(eq(swaps.userId, userId));

    // USDC -> EURC
    let quote;
    try {
      quote = await quoteSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" });
    } catch (err) {
      throw new NoLiquidity(err instanceof Error ? err.message : String(err));
    }
    console.log(`Quote: 0.5 USDC -> about ${quote.estimatedOut} EURC, at least ${quote.minOut}`);
    check(Number(quote.estimatedOut) > 0, "a price is available for USDC -> EURC");

    let swap;
    try {
      swap = await executeSwap(userId, { tokenIn: "USDC", tokenOut: "EURC", amount: "0.5" });
    } catch (err) {
      if (err instanceof SwapError && err.status === 502) throw new NoLiquidity(err.message);
      throw err;
    }
    check(swap?.status === "COMPLETE" && Boolean(swap.txHash), `swap complete: ${swap?.explorerUrl}`, swap);
    let eurc = "0";
    for (let i = 0; i < 20 && Number(eurc) === 0; i++) {
      await sleep(3_000);
      eurc = (await tokenBalances(wallet.circleWalletId)).EURC;
    }
    check(Number(eurc) > 0 && (!swap?.minOut || Number(eurc) >= Number(swap.minOut)), `received ${eurc} EURC (at least ${swap?.minOut ?? "?"} promised)`);

    // EURC -> USDC (everything back)
    const back = eurc.includes(".") ? eurc.slice(0, eurc.indexOf(".") + 7) : eurc;
    if (Number(back) >= 0.5) {
      const usdcBefore = Number((await tokenBalances(wallet.circleWalletId)).USDC);
      let swapBack;
      try {
        swapBack = await executeSwap(userId, { tokenIn: "EURC", tokenOut: "USDC", amount: back });
      } catch (err) {
        if (err instanceof SwapError && err.status === 502) throw new NoLiquidity(err.message);
        throw err;
      }
      check(swapBack?.status === "COMPLETE", `swapped ${back} EURC back to USDC: ${swapBack?.explorerUrl}`);
      let usdcAfter = usdcBefore;
      for (let i = 0; i < 20 && usdcAfter <= usdcBefore; i++) {
        await sleep(3_000);
        usdcAfter = Number((await tokenBalances(wallet.circleWalletId)).USDC);
      }
      check(usdcAfter > usdcBefore, `USDC balance went up (${usdcBefore} -> ${usdcAfter})`);
    } else {
      console.log(`Skipped swapping back: ${eurc} EURC is below the 0.5 minimum.`);
    }
    const rows = await db.select().from(swaps).where(eq(swaps.userId, userId));
    check(rows.every((r) => r.openKey === null && ["COMPLETE"].includes(r.status)), "every swap is recorded as complete and released");
  } finally {
    const ids = (await db.select({ id: swaps.id }).from(swaps).where(eq(swaps.userId, userId))).map((r) => r.id);
    if (ids.length) await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
    await db.delete(swaps).where(eq(swaps.userId, userId));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All swap checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    if (err instanceof NoLiquidity) {
      console.error(`NO_LIQUIDITY: ${err.message}`);
      process.exit(4);
    }
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
  "swaps",
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

# Swaps on Arc (Circle App Kit). Off until switched on.
# SWAP_ENABLED=false
# SWAP_FEE_BPS=50
# SWAP_SLIPPAGE_BPS=100
# SWAP_DAILY_COUNT=20
DOC_EOF

cat > "frontend/src/app/swap/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Limits = Record<Token, { decimals: number; min: number; max: number }>;
type TokensResponse = { balances: Record<Token, string>; limits: Limits; feePercent: number; slippagePercent: number };
type Quote = {
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  feePercent: number;
  slippagePercent: number;
  balance: string;
  enough: boolean;
};
type SwapView = {
  id: string;
  status: string;
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  amountOut: string | null;
  explorerUrl: string | null;
  createdAt: string;
};

const fmt = (v: string | null | undefined, token: Token) =>
  v === null || v === undefined ? "?" : Number(v).toLocaleString("en-US", { maximumFractionDigits: token === "cirBTC" ? 8 : 6 });

function choiceClass(active: boolean) {
  return `rounded-lg border px-3 py-2 text-sm font-medium transition ${
    active
      ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
  }`;
}

export default function SwapPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [info, setInfo] = useState<TokensResponse | null>(null);
  const [tokenIn, setTokenIn] = useState<Token>("USDC");
  const [tokenOut, setTokenOut] = useState<Token>("EURC");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [done, setDone] = useState<SwapView | null>(null);
  const [recent, setRecent] = useState<SwapView[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      setInfo(await api<TokensResponse>("/swap/tokens"));
      const r = await api<{ swaps: SwapView[] }>("/swaps");
      setRecent(r.swaps.filter(Boolean));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, []);

  useEffect(() => {
    if (session) void load();
  }, [session, load]);

  function pick(side: "in" | "out", t: Token) {
    setQuote(null);
    setDone(null);
    if (side === "in") {
      if (t === tokenOut) setTokenOut(tokenIn);
      setTokenIn(t);
    } else {
      if (t === tokenIn) setTokenIn(tokenOut);
      setTokenOut(t);
    }
  }

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    setDone(null);
    try {
      const r = await api<{ quote: Quote }>("/swap/quote", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount }) });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ swap: SwapView }>("/swap", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount }) });
      setDone(r.swap);
      setQuote(null);
      setAmount("");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "The swap could not be completed.");
    } finally {
      setBusy(false);
    }
  }

  const limit = info?.limits[tokenIn];

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Swap</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Swap between USDC, EURC and cirBTC in your Arc wallet. No gas to pay.
          {info ? ` Fee ${info.feePercent}%; if the price moves more than ${info.slippagePercent}% against you, the swap is cancelled.` : ""}
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have: {TOKEN_LIST.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(" · ")}
          </p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <form onSubmit={getQuote} className="space-y-5">
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">From</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("in", t)} className={choiceClass(tokenIn === t)}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">To</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("out", t)} disabled={t === tokenIn} className={`${choiceClass(tokenOut === t)} disabled:opacity-40`}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="flex items-center justify-between">
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount of {tokenIn}
                </label>
                {info ? (
                  <button
                    type="button"
                    onClick={() => {
                      setAmount(info.balances[tokenIn]);
                      setQuote(null);
                    }}
                    className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                  >
                    Use all ({fmt(info.balances[tokenIn], tokenIn)})
                  </button>
                ) : null}
              </div>
              <input
                id="amount"
                inputMode="decimal"
                value={amount}
                onChange={(e) => {
                  setAmount(e.target.value);
                  setQuote(null);
                  setDone(null);
                }}
                placeholder={limit ? `${limit.min} to ${limit.max}` : ""}
                className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
              />
            </div>
            {!quote ? (
              <button
                type="submit"
                disabled={busy || !amount}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a price..." : "Get a price"}
              </button>
            ) : null}
          </form>

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[10rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">You swap</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.amountIn, quote.tokenIn)} {quote.tokenIn}</dd>
                <dt className="text-zinc-500">You get about</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.estimatedOut, quote.tokenOut)} {quote.tokenOut}</dd>
                <dt className="text-zinc-500">At least</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {fmt(quote.minOut, quote.tokenOut)} {quote.tokenOut} <span className="text-xs text-zinc-500">(or it is cancelled)</span>
                </dd>
                <dt className="text-zinc-500">Fees</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.feePercent}% dataonchain + 0.02% swap provider, included above</dd>
              </dl>
              {!quote.enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough {quote.tokenIn}. You have {fmt(quote.balance, quote.tokenIn)}.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={confirm}
                  disabled={busy || !quote.enough}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Swapping..." : "Confirm swap"}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
              <p className="text-xs text-zinc-500">Prices on the test network can move a lot. If the swap is cancelled, nothing is taken.</p>
            </div>
          ) : null}

          {done ? (
            <div
              className={`rounded-lg px-3 py-2 text-sm ${
                done.status === "COMPLETE"
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
              }`}
            >
              {done.status === "COMPLETE"
                ? `Done. ${fmt(done.amountIn, done.tokenIn)} ${done.tokenIn} swapped for ${fmt(done.amountOut ?? done.estimatedOut, done.tokenOut)} ${done.tokenOut}.`
                : "The swap was sent but its result is not clear yet. Check your balance in a minute; our team is notified."}
              {done.explorerUrl ? (
                <a href={done.explorerUrl} target="_blank" rel="noreferrer" className="ml-1 font-medium underline">
                  View transaction
                </a>
              ) : null}
            </div>
          ) : null}

          {error ? (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          ) : null}
        </section>

        {recent.length > 0 ? (
          <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <h2 className="text-sm font-medium text-zinc-500">Recent swaps</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {recent.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <span className="text-zinc-900 dark:text-zinc-100">
                    {fmt(s.amountIn, s.tokenIn)} {s.tokenIn} → {s.amountOut ? `${fmt(s.amountOut, s.tokenOut)} ` : ""}
                    {s.tokenOut}
                  </span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    {s.status === "COMPLETE" ? "Done" : s.status === "FAILED" ? "Cancelled" : s.status === "UNKNOWN" ? "Checking" : "In progress"}
                    {s.explorerUrl ? (
                      <a href={s.explorerUrl} target="_blank" rel="noreferrer" className="text-emerald-700 hover:underline dark:text-emerald-400">
                        tx
                      </a>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF

cat > "frontend/src/app/dashboard/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ChainWallets } from "@/components/ChainWallets";
import { RecentOrders } from "@/components/RecentOrders";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [bridgeOn, setBridgeOn] = useState(false);
  const [swapOn, setSwapOn] = useState(false);

  // The "Send to a provider" button appears only when bridging is switched on
  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean }) => {
        setBridgeOn(Boolean(s.bridge));
        setSwapOn(Boolean(s.swap));
      })
      .catch(() => setBridgeOn(false));
  }, []);

  useEffect(() => {
    if (isPending || data) return;
    // A failed confirmation link lands here with ?error=...
    const failedLink = new URLSearchParams(window.location.search).has("error");
    router.replace(failedLink ? "/login?error=link" : "/login");
  }, [isPending, data, router]);

  if (isPending || !data) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const { user } = data;

  async function logOut() {
    await authClient.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-2xl">
        <header className="flex items-center justify-between">
          <span className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">dataonchain</span>
          <button
            onClick={logOut}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Log out
          </button>
        </header>

        <h1 className="mt-10 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          Hello, {user.name.split(" ")[0]}
        </h1>

        <div className="mt-4 flex flex-wrap gap-3">
          <Link
            href="/buy"
            className="inline-block rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
          >
            Buy airtime or data
          </Link>
          {swapOn ? (
            <Link
              href="/swap"
              className="inline-block rounded-lg border border-emerald-700 px-4 py-2.5 font-medium text-emerald-800 hover:bg-emerald-50 dark:border-emerald-500 dark:text-emerald-300 dark:hover:bg-emerald-950"
            >
              Swap
            </Link>
          ) : null}
          {bridgeOn ? (
            <Link
              href="/bridge"
              className="inline-block rounded-lg border border-emerald-700 px-4 py-2.5 font-medium text-emerald-800 hover:bg-emerald-50 dark:border-emerald-500 dark:text-emerald-300 dark:hover:bg-emerald-950"
            >
              Send to another network
            </Link>
          ) : null}
        </div>

        <section className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="text-sm font-medium text-zinc-500">Your account</h2>
          <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-[8rem_1fr]">
            <dt className="text-zinc-500">Name</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.name}</dd>
            <dt className="text-zinc-500">Email</dt>
            <dd className="flex items-center gap-2 text-zinc-900 dark:text-zinc-100">
              {user.email}
              {user.emailVerified ? (
                <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                  Confirmed
                </span>
              ) : null}
            </dd>
            <dt className="text-zinc-500">Phone</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.phone}</dd>
          </dl>
        </section>

        <WalletCard />
        {bridgeOn ? <ChainWallets /> : null}
        <RecentOrders />
      </div>
    </main>
  );
}
DOC_EOF

cat > "frontend/src/components/WalletCard.tsx" <<'DOC_EOF'
"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean; gasFree?: boolean; previousAddress?: string | null };
  balance: { usdc: string | null };
  bridgeBalance?: string | null;
  tokens?: { EURC: string; cirBTC: string } | null;
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
            {data.tokens && (Number(data.tokens.EURC) > 0 || Number(data.tokens.cirBTC) > 0) ? (
              <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                Also:{" "}
                {[
                  Number(data.tokens.EURC) > 0 ? `${Number(data.tokens.EURC).toLocaleString("en-US", { maximumFractionDigits: 6 })} EURC` : null,
                  Number(data.tokens.cirBTC) > 0 ? `${Number(data.tokens.cirBTC).toLocaleString("en-US", { maximumFractionDigits: 8 })} cirBTC` : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            ) : null}
            {data.bridgeBalance && Number(data.bridgeBalance) > 0 ? (
              <p className="mt-1 text-sm text-zinc-500">
                Plus {formatUsdc(data.bridgeBalance)} USDC in your bridge balance (used first for your next transfer)
              </p>
            ) : null}
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

grep -q 'executeSwap' backend/src/swap/service.ts || fail "Could not write backend/src/swap/service.ts"
green "OK: files written"

# --- 2. Database --------------------------------------------------------------------
step "Database: swaps table"
if ! grep -rqs 'CREATE TABLE `swaps`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name swaps)
fi
grep -rqs 'CREATE TABLE `swaps`' backend/drizzle/*.sql || fail "The swaps migration was not created"
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Swaps: real test on Arc Testnet (0.5 USDC -> EURC -> back to USDC)"
echo "Uses 1 test USDC from the treasury. Takes about a minute."
set +e
(cd backend && SWAP_ENABLED=true npx tsx scripts/swap-smoke.ts); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury needs more test USDC. Send at least 2 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -eq 4 ]]; then
  yellow "Arc Testnet had no liquidity or price for the swap just now (Circle's side, a known testnet issue)."
  yellow "The code and safety checks before that point passed. You can try again later, or continue."
  read -r -p "Continue without a completed test swap? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Nothing was committed. Run again later."
elif [[ $code -ne 0 ]]; then
  fail "Swap test failed (details above). Nothing was committed. Paste the output to Claude."
fi

step "Delivery, pricing, wallets and auth: make sure they still work"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
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
step "Production database: swaps table"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the production database. Nothing was committed."
unset PROD_TOKEN
green "OK"

# --- 5. Commit, push ---------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Swaps on Arc: USDC, EURC, cirBTC via Circle App Kit, 0.5% fee, 1% slippage"
git push
green "OK: pushed."

wait_for() { # label url text
  local label="$1" url="$2" want="$3" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *"$want"* ]]; then echo; green "OK: $label"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}
wait_for "the new API on Render" "$PROD_API/api/status" '"swapCode":true' || fail "The API did not come up. Check Events and Logs on Render."

# --- 6. Switch it on -----------------------------------------------------------------
step "Switch swaps on"
bold "On Render > your dataonchain service > Environment:"
echo "  1. Add:  SWAP_ENABLED  =  true"
echo "  2. Click 'Save, rebuild, and deploy'  (NOT 'Save only')"
echo "  Optional (defaults shown): SWAP_FEE_BPS=50 (0.5%)  SWAP_SLIPPAGE_BPS=100 (1%)  SWAP_DAILY_COUNT=20"
read -r -p "When you have saved it, press Enter to continue... " _
wait_for "swaps on the API" "$PROD_API/api/status" '"swap":true' || fail "Render does not show SWAP_ENABLED=true yet. Check the variable and that a new deploy started."
wait_for "swaps on the website" "$PROD_FRONTEND/api/status" '"swap":true' || fail "The website cannot see it yet. Check vercel.com."

echo
green "Script 19 complete. Users can swap USDC, EURC and cirBTC on Arc."
echo "  Try it: $PROD_FRONTEND/dashboard > 'Swap'"
