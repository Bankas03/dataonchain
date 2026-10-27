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

// ---------------------------------------------------------------------------
// Admin dashboard. There is one admin: the email in ADMIN_EMAIL (set on
// Render). Passwords are stored only as scrypt hashes; session tokens, login
// codes and reset tokens only as hashes, so a database copy cannot log in.
// ---------------------------------------------------------------------------
export const ADMIN_SESSION_STAGES = ["code", "active"] as const;

export const adminAccounts = sqliteTable("admin_accounts", {
  id: id(),
  email: text("email").notNull().unique(), // lowercase
  passwordHash: text("password_hash"),     // empty until set with "Forgot password"
  failedAttempts: integer("failed_attempts").notNull().default(0),
  lockedUntil: integer("locked_until", { mode: "timestamp_ms" }),
  passwordChangedAt: integer("password_changed_at", { mode: "timestamp_ms" }),
  lastLoginAt: integer("last_login_at", { mode: "timestamp_ms" }),
  createdAt: createdAt(),
  updatedAt: updatedAt(),
});

// A login waits in stage "code" until the emailed code is entered.
export const adminSessions = sqliteTable(
  "admin_sessions",
  {
    id: id(),
    accountId: text("account_id")
      .notNull()
      .references(() => adminAccounts.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull().unique(),
    stage: text("stage", { enum: ADMIN_SESSION_STAGES }).notNull().default("code"),
    codeHash: text("code_hash"),
    codeAttempts: integer("code_attempts").notNull().default(0),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    lastSeenAt: integer("last_seen_at", { mode: "timestamp_ms" }).notNull(),
    createdAt: createdAt(),
  },
  (t) => [index("admin_sessions_account_idx").on(t.accountId)],
);

export const adminResetTokens = sqliteTable(
  "admin_reset_tokens",
  {
    id: id(),
    accountId: text("account_id")
      .notNull()
      .references(() => adminAccounts.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull().unique(),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    usedAt: integer("used_at", { mode: "timestamp_ms" }),
    ipAddress: text("ip_address"),
    createdAt: createdAt(),
  },
  (t) => [index("admin_reset_tokens_account_idx").on(t.accountId)],
);

// Switches the admin can flip without a redeploy (for example pausing swaps).
export const appSettings = sqliteTable("app_settings", {
  key: text("key").primaryKey(),
  value: text("value").notNull(),
  updatedAt: updatedAt(),
});
