#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 18: bridge safety (monitoring, daily report, alerts)
#
# What this adds:
#   - stuck transfer alerts: a transfer that sits in one step too long is
#     reported once (Render logs, audit log, and an email to ALERT_EMAIL);
#     the worker keeps retrying it every 30 seconds
#   - daily reconciliation, emailed to ALERT_EMAIL: every transfer completed in
#     the last 24 hours is checked against Circle Gateway's own record (same
#     mint transaction), failures are listed, and the USDC held in Gateway for
#     users (unused fee margins) is totalled
#   - setup/bridge-report.sh: the same report on demand
#   - fixes: slow networks get 10 minutes per step (was 3), and a retried step
#     is recorded once in the transfer history (no more duplicate lines)
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/18_bridge_safety.sh
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
[[ -f backend/src/bridge/wallets.ts ]] || fail "Run this from ~/dataonchain after script 17 (own wallets)"
[[ -n "$(env_get GATEWAY_PROBE_RECIPIENT_ADDRESS)" ]] || fail "GATEWAY_PROBE_RECIPIENT_ADDRESS missing in $ENV_FILE (script 15 creates it)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/18_bridge_safety.sh' || true)" ]]; then
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
import { NETWORK_NAMES, ensureUserWallet, getUsdcBalance, previousWallet } from "./wallets/service";
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
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, bridge: env.BRIDGE_ENABLED }));

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
    bridgeBalance: await bridgeBalance(wallet.address),
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
import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { approvedDestinations, auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries } from "../db/schema";
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
  // A retried step returns the same Circle transaction: record it once
  if (fields.circleTransactionId) {
    const [seen] = await db
      .select({ id: bridgeEvents.id })
      .from(bridgeEvents)
      .where(and(eq(bridgeEvents.transferId, transferId), eq(bridgeEvents.step, step), eq(bridgeEvents.circleTransactionId, fields.circleTransactionId)))
      .limit(1);
    if (seen) return;
  }
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

// Fails the transfer only if it is still in the status this caller acted on,
// so a slower caller can never undo progress made by another one.
async function fail(t: Transfer, reason: string) {
  const row = await move(t, [t.status], "FAILED", {
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
  // Some testnets confirm slowly: wait up to 10 minutes
  for (let i = 0; i < 200; i++) {
    const t = await circle.getTransaction({ id });
    const tx = t.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
    if (tx?.state === "COMPLETE") return { id, txHash: tx.txHash };
    if (tx?.state && FAILED_STATES.includes(tx.state)) {
      throw new BridgeError(`${p.signature} ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
    }
    await new Promise((r) => setTimeout(r, 3_000));
  }
  throw new BridgeError(`${p.signature} did not finish in 10 minutes`);
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
  // The recipient is the user's own Circle wallet (checked by the caller), so it
  // does not need to be on the approved list
  trustedRecipient?: boolean;
}): Promise<Transfer> {
  const source = chainByKey(p.sourceChain);
  const destination = chainByKey(p.destinationChain);
  if (source.key === destination.key) throw new BridgeError("Source and destination must be different chains.");
  if (!isEvmAddress(p.recipientAddress) || !isEvmAddress(p.depositorAddress)) throw new BridgeError("Invalid address.");
  if (!Number.isInteger(p.amountMicro) || p.amountMicro < 10_000) throw new BridgeError("The minimum is 0.01 USDC.");
  if (p.direction === "OUT" && !p.trustedRecipient && !(await isApprovedDestination(destination.key, p.recipientAddress))) {
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
    // 4xx: Gateway refused it, so nothing was attested or burned.
    // If only the fee rose, check the price again and sign again.
    const body = (err as { body?: string }).body ?? "";
    if (status === 400 && /maxFee|forwarding fee/i.test(body)) {
      if (await move(t, ["INTENT_SIGNED"], "FINALIZED", { signature: null })) {
        await event(t.id, "requote", { details: { reason: body.slice(0, 300) } });
      }
      return;
    }
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
    if (t.userId && t.direction === "OUT") {
      const journalId = randomUUID();
      await db.insert(ledgerEntries).values([
        { journalId, account: `customer:${t.userId}`, currency: "USDC", debit: t.amountMicro, memo: `Bridge ${t.id} to ${t.destinationChain}` },
        { journalId, account: `bridge:out:${t.destinationChain}`, currency: "USDC", credit: t.amountMicro, memo: `Bridge ${t.id} mint ${t.mintTxHash ?? ""}` },
      ]);
    }
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

cat > "backend/scripts/bridge-report.ts" <<'DOC_EOF'
// Bridge report on demand (read only): stuck transfers, failures, a check of
// every transfer completed in the last 24 hours against Circle Gateway, and
// the USDC held in Gateway for users.
// Run through: bash setup/bridge-report.sh prod   (or dev)
import { formatReport, reconcile } from "../src/bridge/monitor";

reconcile()
  .then((r) => {
    for (const line of formatReport(r)) console.log(line);
    process.exit(r.issues.length ? 2 : 0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "backend/scripts/monitor-smoke.ts" <<'DOC_EOF'
// Bridge monitoring checks on the development database (no money moves):
//   - a transfer sitting in one step too long is reported as stuck, once
//   - the alert email goes to ALERT_EMAIL
//   - the report flags a "complete" transfer that has no mint transaction
// Run with: ALERT_EMAIL=alerts@example.com EMAIL_OUTBOX_FILE=/tmp/x npx tsx scripts/monitor-smoke.ts
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { eq, inArray } from "drizzle-orm";
import { db } from "../src/db";
import { auditLogs, bridgeTransfers } from "../src/db/schema";
import { alertStuck, findStuck, reconcile } from "../src/bridge/monitor";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox || !process.env.ALERT_EMAIL) throw new Error("Run with ALERT_EMAIL and EMAIL_OUTBOX_FILE set");
  const old = new Date(Date.now() - 3 * 60 * 60_000);
  const base = {
    direction: "OUT" as const,
    sourceChain: "arc",
    destinationChain: "base",
    sourceDomain: 26,
    destinationDomain: 6,
    depositorWalletId: "test-wallet",
    depositorAddress: "0x000000000000000000000000000000000000dead",
    recipientAddress: "0x000000000000000000000000000000000000beef",
    amountMicro: 1_000_000,
  };
  const ids: string[] = [];
  try {
    const [stuck] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "INTENT_SIGNED", createdAt: old, updatedAt: old }).returning();
    const [fresh] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "INTENT_SIGNED" }).returning();
    const [broken] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "COMPLETE" }).returning();
    ids.push(stuck!.id, fresh!.id, broken!.id);

    const found = (await findStuck()).map((t) => t.id);
    check(found.includes(stuck!.id), "a transfer waiting 3 hours after signing is found as stuck");
    check(!found.includes(fresh!.id), "a transfer that just moved is not stuck");

    const first = await alertStuck();
    check(first >= 1, `stuck transfers were reported (${first})`);
    const emails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; subject: string; text: string });
    check(emails.some((e) => e.to === process.env.ALERT_EMAIL && e.text.includes(stuck!.id)), "the alert email went to ALERT_EMAIL and names the transfer");
    await alertStuck();
    const alerts = await db.select().from(auditLogs).where(eq(auditLogs.targetId, stuck!.id));
    check(alerts.filter((a) => a.action === "bridge.stuck").length === 1, "the same stuck transfer is reported only once");

    const report = await reconcile();
    check(report.issues.some((i) => i.includes(broken!.id) && /without a mint/.test(i)), "the report flags a complete transfer without a mint transaction");
    check(report.issues.some((i) => i.includes(stuck!.id)), "the report lists the stuck transfer");
    console.log("Report preview:");
    for (const line of report.lines) console.log(`  ${line}`);
  } finally {
    if (ids.length) {
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ids));
    }
    console.log("Cleaned up the test transfers");
  }
}

main()
  .then(() => {
    console.log("All monitoring checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF

cat > "setup/bridge-report.sh" <<'DOC_EOF'
#!/usr/bin/env bash
# =============================================================================
# dataonchain | Bridge report (read only, changes nothing)
#   bash setup/bridge-report.sh prod     the live site
#   bash setup/bridge-report.sh dev      your development database
# =============================================================================
set -euo pipefail
[[ -f backend/.env ]] || { echo "Run this from ~/dataonchain"; exit 1; }
case "${1:-prod}" in
  dev)
    (cd backend && npx tsx scripts/bridge-report.ts)
    ;;
  prod)
    url="$(turso db show dataonchainprod --url 2>/dev/null | tr -d '[:space:]')"
    [[ "$url" == libsql://* ]] || { echo "Turso is not logged in. Run: turso auth login --headless"; exit 1; }
    token="$(turso db tokens create dataonchainprod --expiration 1d | tr -d '[:space:]')"
    (cd backend && TURSO_DATABASE_URL="$url" TURSO_AUTH_TOKEN="$token" npx tsx scripts/bridge-report.ts)
    ;;
  *)
    echo "Usage: bash setup/bridge-report.sh prod|dev"; exit 1 ;;
esac
DOC_EOF

grep -q 'dailyReconcile' backend/src/worker.ts || fail "Could not write backend/src/worker.ts"
green "OK: files written (no database changes in this script)"

# --- 2. Alert email ---------------------------------------------------------------
step "Where should bridge alerts and the daily report go?"
CURRENT_ALERT="$(env_get ALERT_EMAIL)"
read -r -p "Email address for alerts${CURRENT_ALERT:+ [$CURRENT_ALERT]}: " ALERT
ALERT="${ALERT:-$CURRENT_ALERT}"
[[ "$ALERT" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || fail "That does not look like an email address. Run again."
if grep -q '^ALERT_EMAIL=' "$ENV_FILE"; then
  sed -i "s|^ALERT_EMAIL=.*|ALERT_EMAIL=$ALERT|" "$ENV_FILE"
else
  printf '\n# Bridge alerts and the daily bridge report\nALERT_EMAIL=%s\n' "$ALERT" >> "$ENV_FILE"
fi
green "OK: $ALERT"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Monitoring: checks with test transfers (no money moves)"
OUTBOX="$(mktemp)"
(cd backend && ALERT_EMAIL=alerts@example.com EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/monitor-smoke.ts) \
  || { rm -f "$OUTBOX"; fail "Monitoring test failed (details above). Nothing was committed."; }
rm -f "$OUTBOX"

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

# --- 4. Commit, push ---------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Bridge safety: stuck transfer alerts, daily reconciliation against Circle Gateway, report"
git push
green "OK: pushed."

# --- 5. Render: alert email, then deploy -----------------------------------------
step "Add the alert email on Render"
bold "On Render > your dataonchain service > Environment:"
echo "  1. Add:  ALERT_EMAIL  =  $ALERT"
echo "  2. Click 'Save, rebuild, and deploy'  (NOT 'Save only')"
read -r -p "When you have saved it, press Enter to continue... " _

printf 'Waiting for the new API on Render '
for _ in $(seq 1 60); do
  body="$(curl -s --max-time 20 "$PROD_API/api/status" || true)"
  if [[ "$body" == *'"bridgeMonitor":true'* ]]; then echo; green "OK: live"; break; fi
  printf '.'; sleep 10
done
[[ "$body" == *'"bridgeMonitor":true'* ]] || fail "The API did not come up. Check Events and Logs on Render."

# --- 6. First report from the live site --------------------------------------------
step "Bridge report for the live site (read only)"
set +e
bash setup/bridge-report.sh prod; code=$?
set -e
[[ $code -eq 0 || $code -eq 2 ]] || yellow "Could not produce the report. Try later: bash setup/bridge-report.sh prod"

echo
green "Script 18 complete. The bridge is now watched: stuck transfers are reported, and a report is emailed daily."
echo "  The first daily report is emailed to $ALERT within a few minutes (check spam the first time)."
echo "  Any time: bash setup/bridge-report.sh prod"
