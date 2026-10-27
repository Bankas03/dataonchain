#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 21: admin dashboard (dashboard.dataonchain.online)
#
# What this adds:
#   - a separate admin website (folder admin/, its own Vercel project) at
#     https://dashboard.dataonchain.online
#   - one admin only: the email you choose, set on Render as ADMIN_EMAIL (not
#     in the code). Login = password + a 6 digit code emailed to that address.
#     Forgot password, change password, sessions list, sign out everywhere.
#   - lockout after 5 wrong passwords (you get an email), 60 minute idle logout,
#     an email on every login and password change
#   - pages: overview (users, volume, margin, balances, issues), users, orders,
#     refunds, bridge transfers, swaps, providers, activity log, settings
#   - safe controls, all logged: check an order with VTpass now, retry a
#     refund, suspend or restore a user, pause purchases / bridge / swaps,
#     turn a provider on or off
#   - users see a short maintenance message when something is paused, and a
#     notice if their account is suspended
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/21_admin_dashboard.sh
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
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s#^$1=.*#$1=$2#" "$ENV_FILE"
  else
    grep -q "^# Admin dashboard (setup/21_admin_dashboard.sh)" "$ENV_FILE" \
      || printf '\n# Admin dashboard (setup/21_admin_dashboard.sh)\n' >> "$ENV_FILE"
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

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

wait_for() { # label url text [tries]
  local label="$1" url="$2" want="$3" tries="${4:-60}" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 "$tries"); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *"$want"* ]]; then echo; green "OK: $label"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
command -v turso >/dev/null || fail "Turso CLI not found (it was installed in script 01)"
command -v curl >/dev/null || fail "curl not found. Run: sudo apt install -y curl"
[[ -f backend/src/swap/service.ts ]] || fail "Run this from ~/dataonchain after script 19 (swaps)"
grep -q "Recent transfers" frontend/src/app/bridge/page.tsx || fail "Run script 20 (bridge history) first"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/21_admin_dashboard.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

step "The admin email and the dashboard address"
ADMIN_EMAIL_VALUE="$(env_get ADMIN_EMAIL)"
if [[ -z "$ADMIN_EMAIL_VALUE" ]]; then
  echo "Only this one email will be able to log in to the admin dashboard."
  echo "Login codes and password reset links go to it, so use a mailbox only you can open."
  read -r -p "Admin email: " ADMIN_EMAIL_VALUE
fi
ADMIN_EMAIL_VALUE="$(printf '%s' "$ADMIN_EMAIL_VALUE" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$ADMIN_EMAIL_VALUE" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || fail "That does not look like an email address: $ADMIN_EMAIL_VALUE"
ADMIN_SITE="$(env_get PRODUCTION_ADMIN_URL)"
if [[ -z "$ADMIN_SITE" ]]; then
  read -r -p "Dashboard address [https://dashboard.dataonchain.online]: " ADMIN_SITE
  ADMIN_SITE="${ADMIN_SITE:-https://dashboard.dataonchain.online}"
fi
ADMIN_SITE="${ADMIN_SITE%/}"
[[ "$ADMIN_SITE" == https://* ]] || fail "The dashboard address must start with https://"
ADMIN_HOST="${ADMIN_SITE#https://}"
env_set ADMIN_EMAIL "$ADMIN_EMAIL_VALUE"
env_set PRODUCTION_ADMIN_URL "$ADMIN_SITE"
grep -qE "^ADMIN_URL=" "$ENV_FILE" || env_set ADMIN_URL "http://localhost:3001"
green "OK: admin $ADMIN_EMAIL_VALUE, dashboard $ADMIN_SITE"

# --- 1. Code ---------------------------------------------------------------------
step "Writing backend, website and admin dashboard files"
mkdir -p "admin" "admin/src/app" "admin/src/app/(auth)/forgot" "admin/src/app/(auth)/login" "admin/src/app/(auth)/reset" "admin/src/app/(dash)" "admin/src/app/(dash)/activity" "admin/src/app/(dash)/bridge" "admin/src/app/(dash)/bridge/[id]" "admin/src/app/(dash)/orders" "admin/src/app/(dash)/orders/[key]" "admin/src/app/(dash)/providers" "admin/src/app/(dash)/refunds" "admin/src/app/(dash)/settings" "admin/src/app/(dash)/swaps" "admin/src/app/(dash)/users" "admin/src/app/(dash)/users/[id]" "admin/src/components" "admin/src/lib" "backend" "backend/scripts" "backend/src" "backend/src/admin" "backend/src/auth" "backend/src/db" "backend/src/email" "backend/src/fulfilment" "backend/src/vtpass" "frontend/src/app/dashboard"
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

# Admin dashboard (setup/21_admin_dashboard.sh). The only email that can log in,
# and the dashboard's address, used in password reset links.
# ADMIN_EMAIL=you@example.com
# ADMIN_URL=http://localhost:3001
DOC_EOF
cat > "backend/scripts/db-check.ts" <<'DOC_EOF'
// Checks the database is reachable and every expected table exists.
// Run with: npm run db:check
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const EXPECTED_TABLES = [
  "accounts",
  "admin_accounts",
  "admin_reset_tokens",
  "admin_sessions",
  "app_settings",
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
import { getPauses, pausedMessage } from "./settings";
import { adminApp } from "./admin/routes";
import { BridgeUserError, bridgeBalance, chainBalances, getBridgeView, listBridges, listDestinations, quoteBridge, returnToArc, startBridge } from "./bridge/user";

export const app = new Hono();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: env.FRONTEND_URLS,
    credentials: true,
    allowHeaders: ["Content-Type", "Authorization", "X-Admin-Request"],
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses() }));

// Admin dashboard API (its own login; see src/admin)
app.route("/api/admin", adminApp);

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
  const paused = await pausedMessage("purchasesPaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("purchasesPaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("bridgePaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("bridgePaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("bridgePaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("swapPaused");
  if (paused) return c.json({ error: paused }, 503);
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
  const paused = await pausedMessage("swapPaused");
  if (paused) return c.json({ error: paused }, 503);
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
cat > "backend/src/auth/middleware.ts" <<'DOC_EOF'
// Protects a route: only signed in users get through (and not suspended ones).
// Usage: app.get("/api/something", requireAuth, (c) => { const { user } = c.get("auth"); ... })
import { createMiddleware } from "hono/factory";
import { auth, type AuthSession } from "./index";

export const requireAuth = createMiddleware<{ Variables: { auth: AuthSession } }>(
  async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers });
    if (!session) {
      return c.json({ error: "Please log in" }, 401);
    }
    // Suspended by the admin: nothing new until restored
    if ((session.user as { status?: string }).status === "suspended") {
      return c.json({ error: "Your account is suspended. Please contact support." }, 403);
    }
    c.set("auth", session);
    await next();
  },
);
DOC_EOF
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
DOC_EOF
cat > "backend/src/email/templates.ts" <<'DOC_EOF'
// Email wording. Plain text and HTML versions of every email.
function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === '"' ? "&quot;" : "&#39;",
  );
}

export function verificationEmail(name: string, url: string) {
  const first = name.trim().split(/\s+/)[0] || "there";
  const subject = "Confirm your email for dataonchain";

  const text = [
    `Hi ${first},`,
    "",
    "Confirm your email to finish setting up your dataonchain account:",
    url,
    "",
    "This link expires after one hour. If you did not create an account, you can ignore this email.",
    "",
    "dataonchain",
  ].join("\n");

  const safeUrl = escapeHtml(url);
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain</td></tr>
          <tr><td style="padding-top:24px;font-size:16px;">Hi ${escapeHtml(first)},</td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">Confirm your email to finish setting up your account.</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${safeUrl}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">Confirm my email</a>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">
            This link expires after one hour. If the button does not work, copy this address into your browser:<br>
            <span style="word-break:break-all;">${safeUrl}</span>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;color:#71717a;">If you did not create an account, you can ignore this email.</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  return { subject, text, html };
}

// A short email with optional big code or button. Used by the admin dashboard.
export function noticeEmail(p: { subject: string; lines: string[]; code?: string; button?: { label: string; url: string }; footer?: string }) {
  const text = [
    ...p.lines,
    ...(p.code ? ["", p.code] : []),
    ...(p.button ? ["", `${p.button.label}: ${p.button.url}`] : []),
    ...(p.footer ? ["", p.footer] : []),
    "",
    "dataonchain",
  ].join("\n");
  const paragraphs = p.lines
    .map((l) => `<tr><td style="padding-top:12px;font-size:15px;line-height:1.5;">${escapeHtml(l)}</td></tr>`)
    .join("");
  const code = p.code
    ? `<tr><td style="padding-top:20px;font-size:32px;font-weight:bold;letter-spacing:8px;font-family:monospace;">${escapeHtml(p.code)}</td></tr>`
    : "";
  const button = p.button
    ? `<tr><td style="padding-top:24px;"><a href="${escapeHtml(p.button.url)}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">${escapeHtml(p.button.label)}</a></td></tr>
<tr><td style="padding-top:16px;font-size:13px;line-height:1.5;color:#71717a;">If the button does not work, copy this address into your browser:<br><span style="word-break:break-all;">${escapeHtml(p.button.url)}</span></td></tr>`
    : "";
  const footer = p.footer ? `<tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">${escapeHtml(p.footer)}</td></tr>` : "";
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain admin</td></tr>
          ${paragraphs}${code}${button}${footer}
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
  return { subject: p.subject, text, html };
}
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
  // Admin dashboard: the only email that can log in, and the dashboard's address
  // (used in password reset links). Both set on Render.
  ADMIN_EMAIL: process.env.ADMIN_EMAIL?.trim().toLowerCase() || undefined,
  ADMIN_URL: (process.env.ADMIN_URL ?? "http://localhost:3001").trim().replace(/\/$/, ""),
  // Background worker: on in production unless WORKER_ENABLED=false
  WORKER_ENABLED: (process.env.WORKER_ENABLED ?? (NODE_ENV === "production" ? "true" : "false")) === "true",
};
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
// force: an admin asked to check now, so the waiting times are skipped.
export async function reconcileOrder(orderId: string, force = false): Promise<void> {
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
  if (force) {
    // checked right away
  } else if (order.status === "FLAGGED") {
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

// The VTpass wallet balance in naira (what is left to buy airtime and data with).
export async function getVtpassBalance(): Promise<number> {
  const body = await vtGet<{ contents?: { balance?: unknown }; content?: { balance?: unknown } }>("/balance");
  const value = Number(body.contents?.balance ?? body.content?.balance);
  if (!Number.isFinite(value)) throw new Error(`VTpass balance not understood: ${JSON.stringify(body).slice(0, 120)}`);
  return value;
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
  const [paused, setPaused] = useState<string[]>([]);

  // The "Send to a provider" button appears only when bridging is switched on
  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean; paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean } }) => {
        setBridgeOn(Boolean(s.bridge));
        setSwapOn(Boolean(s.swap));
        const parts: string[] = [];
        if (s.paused?.purchasesPaused) parts.push("buying airtime and data");
        if (s.paused?.bridgePaused && s.bridge) parts.push("sending to other networks");
        if (s.paused?.swapPaused && s.swap) parts.push("swaps");
        setPaused(parts);
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

        {user.status === "suspended" ? (
          <p className="mt-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
            Your account is suspended. Please contact support. Orders already in progress still complete, and refunds
            still go out.
          </p>
        ) : null}
        {paused.length > 0 ? (
          <p className="mt-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Short maintenance: {paused.join(", ")} {paused.length > 1 ? "are" : "is"} paused for now. Your balance is safe.
          </p>
        ) : null}

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
cat > "admin/.env.example" <<'DOC_EOF'
# Copy to admin/.env.local. No secrets here.
# Where the admin dashboard forwards /api requests (read on the server, not in the browser)
API_URL=http://localhost:4000
DOC_EOF
cat > "admin/README.md" <<'DOC_EOF'
# dataonchain admin dashboard

A separate Next.js website for the admin, at `https://dashboard.dataonchain.online`
(Vercel project `dataonchain-admin`, Root Directory `admin`).

- Every `/api/*` request is passed through to the backend (`API_URL`), so the
  admin login cookie belongs to this website only.
- Only the email in `ADMIN_EMAIL` (set on Render) can log in: password, then a
  6 digit code emailed to that address. First time: use "Forgot password" to set
  the password.
- The admin API lives in `backend/src/admin`.

Local:

```bash
cp .env.example .env.local   # API_URL=http://localhost:4000
npm install
npm run dev                  # http://localhost:3001
```
DOC_EOF
cat > "admin/eslint.config.mjs" <<'DOC_EOF'
import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
  ]),
]);

export default eslintConfig;
DOC_EOF
cat > "admin/next.config.ts" <<'DOC_EOF'
import type { NextConfig } from "next";

// The admin dashboard. Every /api/... request is passed through to the backend,
// so the admin login cookie belongs to this website only.
const API_URL = (process.env.API_URL ?? "http://localhost:4000").replace(/\/$/, "");

const nextConfig: NextConfig = {
  poweredByHeader: false,
  async rewrites() {
    return [{ source: "/api/:path*", destination: `${API_URL}/api/:path*` }];
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          // Never shown inside another website, never indexed, no address leaks
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
          { key: "X-Robots-Tag", value: "noindex, nofollow" },
          { key: "Referrer-Policy", value: "no-referrer" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
          { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
        ],
      },
    ];
  },
};

export default nextConfig;
DOC_EOF
cat > "admin/package.json" <<'DOC_EOF'
{
  "name": "dataonchain-admin",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3001",
    "build": "next build",
    "start": "next start -p 3001",
    "lint": "eslint"
  },
  "dependencies": {
    "next": "16.3.8",
    "react": "19.2.8",
    "react-dom": "19.2.8"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4",
    "@types/node": "^20",
    "@types/react": "^19",
    "@types/react-dom": "^19",
    "eslint": "^9",
    "eslint-config-next": "16.3.8",
    "tailwindcss": "^4",
    "typescript": "^5"
  }
}
DOC_EOF
cat > "admin/postcss.config.mjs" <<'DOC_EOF'
const config = {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};

export default config;
DOC_EOF
cat > "admin/src/app/(auth)/forgot/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function ForgotPage() {
  const [sent, setSent] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    try {
      const r = await post<{ message: string }>("/forgot", { email: String(form.get("email")).trim() });
      setSent(r.message);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send the link.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <AuthCard
      title="Reset your password"
      subtitle="Enter the admin email. We will email a link to choose a new password. This also unlocks a locked login."
      footer={
        <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Back to login
        </Link>
      }
    >
      {sent ? (
        <Notice tone="good">{sent}</Notice>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <Input label="Email" name="email" type="email" autoComplete="username" required autoFocus />
          {error ? <Notice>{error}</Notice> : null}
          <Submit busy={busy}>Email me a link</Submit>
        </form>
      )}
    </AuthCard>
  );
}
DOC_EOF
cat > "admin/src/app/(auth)/login/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [step, setStep] = useState<"password" | "code">("password");
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function sendPassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    const typed = String(form.get("email")).trim();
    try {
      await post("/login", { email: typed, password: String(form.get("password")) });
      setEmail(typed);
      setStep("code");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not log you in.");
    } finally {
      setBusy(false);
    }
  }

  async function sendCode(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    try {
      await post("/login/code", { code: String(form.get("code")).trim() });
      router.replace("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "That code did not work.");
      if (err instanceof Error && /log in again|expired/i.test(err.message)) setStep("password");
      setBusy(false);
    }
  }

  if (step === "code") {
    return (
      <AuthCard title="Check your email" subtitle={`We sent a 6 digit code to ${email}. It expires in 10 minutes.`}>
        <form onSubmit={sendCode} className="space-y-4">
          <Input label="Code" name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9 ]{6,7}" maxLength={7} required autoFocus />
          {error ? <Notice>{error}</Notice> : null}
          <Submit busy={busy}>Log in</Submit>
          <button type="button" onClick={() => setStep("password")} className="w-full text-sm text-zinc-500 hover:underline">
            Start again
          </button>
        </form>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      title="Admin login"
      subtitle="Only the dataonchain admin can log in here."
      footer={
        <Link href="/forgot" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Forgot password? (or set it for the first time)
        </Link>
      }
    >
      <form onSubmit={sendPassword} className="space-y-4">
        <Input label="Email" name="email" type="email" autoComplete="username" required autoFocus />
        <Input label="Password" name="password" type="password" autoComplete="current-password" required />
        {error ? <Notice>{error}</Notice> : null}
        <Submit busy={busy}>Continue</Submit>
      </form>
    </AuthCard>
  );
}
DOC_EOF
cat > "admin/src/app/(auth)/reset/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useEffect, useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function ResetPage() {
  const [token, setToken] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // The token is after "#" in the link, so it never reaches a server log.
  // Take it, then remove it from the address bar.
  useEffect(() => {
    const t = new URLSearchParams(window.location.hash.slice(1)).get("token");
    setToken(t);
    setReady(true);
    if (t) window.history.replaceState(null, "", "/reset");
  }, []);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const form = new FormData(e.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("again"))) {
      setError("The two passwords are not the same.");
      return;
    }
    setBusy(true);
    try {
      await post("/reset", { token, password });
      setDone(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not set the password.");
    } finally {
      setBusy(false);
    }
  }

  const back = (
    <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      Go to login
    </Link>
  );

  if (!ready) return <AuthCard title="Choose a new password">Loading...</AuthCard>;
  if (done) {
    return (
      <AuthCard title="Password saved" footer={back}>
        <Notice tone="good">Your new password is set and every old session was signed out. You can log in now.</Notice>
      </AuthCard>
    );
  }
  if (!token) {
    return (
      <AuthCard title="Link not complete" footer={back}>
        <Notice>
          This page needs the link from the email. Open the email again, or ask for a{" "}
          <Link href="/forgot" className="underline">
            new link
          </Link>
          .
        </Notice>
      </AuthCard>
    );
  }
  return (
    <AuthCard title="Choose a new password" subtitle="At least 12 characters. A short sentence is easy to remember and hard to guess." footer={back}>
      <form onSubmit={onSubmit} className="space-y-4">
        <Input label="New password" name="password" type="password" autoComplete="new-password" minLength={12} required autoFocus />
        <Input label="New password again" name="again" type="password" autoComplete="new-password" minLength={12} required />
        {error ? <Notice>{error}</Notice> : null}
        <Submit busy={busy}>Save password</Submit>
      </form>
    </AuthCard>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/activity/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, Json, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = { id: string; actorType: string; action: string; targetType: string | null; targetId: string | null; details: unknown; at: string };
type List = { total: number; page: number; pageSize: number; activity: Row[] };

function target(r: Row) {
  if (!r.targetId) return <span className="text-zinc-400">—</span>;
  if (r.targetType === "order") return <RowLink href={`/orders/${r.targetId}`}>order</RowLink>;
  if (r.targetType === "user") return <RowLink href={`/users/${r.targetId}`}>user</RowLink>;
  if (r.targetType === "bridge_transfer") return <RowLink href={`/bridge/${r.targetId}`}>transfer</RowLink>;
  return <span className="text-zinc-500">{r.targetType}</span>;
}

export default function ActivityPage() {
  const [actor, setActor, ready] = useQueryParam("actor");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/activity?actor=${actor}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Activity" subtitle="Everything the admin and the system did: logins, refunds, alerts, switches, suspensions." />
      <Card
        title={data ? `${count(data.total)} event(s)` : "Activity"}
        right={
          <Select
            value={actor}
            onChange={(v) => {
              setActor(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "Everything" },
              { value: "admin", label: "Admin only" },
              { value: "system", label: "System only" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["When", "Who", "What", "On", "Details"]} empty={data.activity.length === 0}>
              {data.activity.map((a) => (
                <tr key={a.id}>
                  <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
                  <Td>
                    <Badge tone={a.actorType === "admin" ? "wait" : "plain"}>{a.actorType}</Badge>
                  </Td>
                  <Td className="font-mono text-xs">{a.action}</Td>
                  <Td>{target(a)}</Td>
                  <Td>
                    <Json value={a.details} />
                  </Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/bridge/[id]/page.tsx" <<'DOC_EOF'
"use client";

import { useParams } from "next/navigation";
import { Badge, Card, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  transfer: {
    id: string;
    direction: string;
    status: string;
    from: string;
    to: string;
    recipientAddress: string;
    depositorAddress: string;
    amount: string;
    maxFee: string | null;
    forwardingFee: string | null;
    failureReason: string | null;
    gatewayTransferId: string | null;
    mintTxHash: string | null;
    mintUrl: string | null;
    userId: string | null;
    email: string | null;
    createdAt: string;
    updatedAt: string;
  };
  events: { step: string; chain: string | null; txHash: string | null; txUrl: string | null; details: unknown; at: string }[];
};

export default function BridgeTransferPage() {
  const { id } = useParams<{ id: string }>();
  const { data, error } = useLoad<Detail>(id ? `/bridge/${id}` : null);
  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const t = data.transfer;

  return (
    <>
      <PageTitle title={`${usdc(t.amount)} USDC, ${t.from} → ${t.to}`} subtitle={t.direction === "IN" ? "Move to Arc" : "Send out"} right={<Badge status={t.status} />} />
      <Card title="Transfer">
        <DefList
          items={[
            ["Customer", t.userId ? <RowLink key="u" href={`/users/${t.userId}`}>{t.email ?? t.userId}</RowLink> : "System test"],
            ["From wallet", <span key="f" className="font-mono text-xs">{t.depositorAddress}</span>],
            ["To address", <span key="t" className="font-mono text-xs">{t.recipientAddress}</span>],
            ["Amount received", `${usdc(t.amount)} USDC`],
            ["Circle fee (max)", t.maxFee ? `${usdc(t.maxFee)} USDC` : "—"],
            ["Forwarding fee", t.forwardingFee ? `${usdc(t.forwardingFee)} USDC` : "—"],
            ["Gateway transfer", <span key="g" className="font-mono text-xs">{t.gatewayTransferId ?? "—"}</span>],
            ["Mint", <ExtLink key="m" href={t.mintUrl}>{t.mintTxHash ?? "Not yet"}</ExtLink>],
            ["Problem", t.failureReason ?? "—"],
            ["Started", when(t.createdAt)],
            ["Last step", when(t.updatedAt)],
            ["Transfer id", <span key="i" className="font-mono text-xs">{t.id}</span>],
          ]}
        />
      </Card>
      <Card title="Every step" className="mt-6">
        <Table head={["When", "Step", "Network", "Transaction", "Details"]} empty={data.events.length === 0}>
          {data.events.map((e, i) => (
            <tr key={i}>
              <Td className="whitespace-nowrap text-zinc-500">{when(e.at)}</Td>
              <Td>{e.step}</Td>
              <Td>{e.chain ?? "—"}</Td>
              <Td>
                <ExtLink href={e.txUrl}>{e.txHash ? `${e.txHash.slice(0, 12)}...` : "—"}</ExtLink>
              </Td>
              <Td>
                <Json value={e.details} />
              </Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/bridge/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { count, label, short, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  direction: string;
  status: string;
  from: string;
  to: string;
  recipientAddress: string;
  amount: string;
  maxFee: string | null;
  failureReason: string | null;
  userId: string | null;
  email: string | null;
  createdAt: string;
  updatedAt: string;
};
type List = { total: number; page: number; pageSize: number; transfers: Row[] };

const STATUSES = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED", "FAILED"];

export default function BridgePage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(readyQ && readyS ? `/bridge?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Bridge transfers" subtitle="USDC moved between Arc and other networks through Circle Gateway, every step recorded from deposit to mint." />
      <Card
        title={data ? `${count(data.total)} transfer(s)` : "Transfers"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[{ value: "", label: "All" }, { value: "open", label: "Still moving" }, ...STATUSES.map((s) => ({ value: s, label: label(s) }))]}
            />
            <SearchBox
              initial={q}
              placeholder="Email, address or id"
              onSearch={(v) => {
                setQ(v);
                setPage(1);
              }}
            />
          </div>
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Route", "Customer", "Amount", "To address", "Status", "Started", "Last step"]} empty={data.transfers.length === 0}>
              {data.transfers.map((t) => (
                <tr key={t.id}>
                  <Td>
                    <RowLink href={`/bridge/${t.id}`}>
                      {t.from} → {t.to}
                    </RowLink>
                    <span className="block text-xs text-zinc-500">{t.direction === "IN" ? "Move to Arc" : "Send out"}</span>
                  </Td>
                  <Td>{t.userId ? <RowLink href={`/users/${t.userId}`}>{t.email ?? t.userId}</RowLink> : <span className="text-zinc-500">System test</span>}</Td>
                  <Td className="tabular-nums">{usdc(t.amount)}</Td>
                  <Td className="font-mono text-xs">{short(t.recipientAddress)}</Td>
                  <Td>
                    <Badge status={t.status} />
                    {t.failureReason ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{t.failureReason}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(t.createdAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(t.updatedAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/layout.tsx" <<'DOC_EOF'
import type { ReactNode } from "react";
import { Shell } from "@/components/Shell";

export default function DashLayout({ children }: { children: ReactNode }) {
  return <Shell>{children}</Shell>;
}
DOC_EOF
cat > "admin/src/app/(dash)/orders/[key]/page.tsx" <<'DOC_EOF'
"use client";

import { useParams } from "next/navigation";
import { useState } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { label, naira, short, usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  order: {
    id: string;
    reference: string;
    status: string;
    serviceType: string;
    network: string;
    planName: string | null;
    phone: string;
    ngnAmount: number;
    marginNgn: number;
    usdcAmount: string;
    rateNgnPerUsdc: number | null;
    rateSource: string | null;
    failureReason: string | null;
    createdAt: string;
    updatedAt: string;
  };
  user: { id: string; name: string; email: string; status: string };
  payments: { id: string; status: string; amount: string; fromAddress: string | null; toAddress: string; txUrl: string | null; txHash: string | null; confirmedAt: string | null; createdAt: string }[];
  deliveries: { id: string; provider: string; requestId: string; providerReference: string | null; status: string; request: unknown; response: unknown; createdAt: string; updatedAt: string }[];
  refund: { status: string; amount: string; toAddress: string; attempt: number; txUrl: string | null; lastError: string | null; confirmedAt: string | null; createdAt: string } | null;
  ledger: { account: string; currency: string; debit: string; credit: string; memo: string | null; createdAt: string }[];
  activity: { id: string; actorType: string; action: string; details: unknown; at: string }[];
  actions: { requery: boolean; retryRefund: boolean };
};

export default function OrderPage() {
  const { key } = useParams<{ key: string }>();
  const { data, error, reload } = useLoad<Detail>(key ? `/orders/${key}` : null);
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const { order } = data;

  async function act(path: string, what: string) {
    setMessage(null);
    try {
      const r = await post<{ before: string; after: string }>(path);
      setMessage({ tone: "good", text: `${what}: ${label(r.before)} → ${label(r.after)}` });
      reload();
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "That did not work." });
    }
  }

  return (
    <>
      <PageTitle
        title={`Order ${order.reference}`}
        subtitle={`${order.network.toUpperCase()} ${order.serviceType}${order.planName ? `, ${order.planName}` : ""} to ${order.phone}`}
        right={<Badge status={order.status} />}
      />

      {data.actions.requery || data.actions.retryRefund || message ? (
        <Card title="Actions" className="mb-6">
          <div className="flex flex-wrap items-center gap-3">
            {data.actions.requery ? (
              <ConfirmButton confirmText="Ask VTpass now" onConfirm={() => act(`/orders/${order.reference}/recheck`, "Checked with VTpass")}>
                Check with VTpass now
              </ConfirmButton>
            ) : null}
            {data.actions.retryRefund ? (
              <ConfirmButton confirmText="Yes, refund" onConfirm={() => act(`/orders/${order.reference}/refund`, "Refund")}>
                {order.status === "FLAGGED" ? "Retry the failed refund" : "Push the refund now"}
              </ConfirmButton>
            ) : null}
          </div>
          <p className="mt-3 text-xs text-zinc-500">
            The background worker does these automatically; use them to check now. A delivery is never sent twice, and a refund can never be paid twice.
          </p>
          {message ? <div className="mt-3"><Notice tone={message.tone}>{message.text}</Notice></div> : null}
        </Card>
      ) : null}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Order">
          <DefList
            items={[
              ["Customer", <RowLink key="u" href={`/users/${data.user.id}`}>{data.user.name} ({data.user.email})</RowLink>],
              ["Price", `${naira(order.ngnAmount)} = ${usdc(order.usdcAmount)} USDC`],
              ["Our margin", naira(order.marginNgn)],
              ["Rate", order.rateNgnPerUsdc ? `${naira(order.rateNgnPerUsdc)} per USDC (${order.rateSource ?? "?"})` : "—"],
              ["Created", when(order.createdAt)],
              ["Last change", when(order.updatedAt)],
              ["Note to customer", order.failureReason ?? "—"],
              ["Order id", <span key="i" className="font-mono text-xs">{order.id}</span>],
            ]}
          />
        </Card>
        <Card title="Refund">
          {data.refund ? (
            <DefList
              items={[
                ["Status", <Badge key="s" status={data.refund.status} />],
                ["Amount", `${usdc(data.refund.amount)} USDC`],
                ["To", <span key="t" className="font-mono text-xs">{data.refund.toAddress}</span>],
                ["Attempt", String(data.refund.attempt)],
                ["Transaction", <ExtLink key="x" href={data.refund.txUrl}>{data.refund.txUrl ? "View on explorer" : "Not sent yet"}</ExtLink>],
                ["Last error", data.refund.lastError ?? "—"],
                ["Started", when(data.refund.createdAt)],
                ["Confirmed", when(data.refund.confirmedAt)],
              ]}
            />
          ) : (
            <p className="text-sm text-zinc-500">No refund for this order.</p>
          )}
        </Card>
      </div>

      <Card title="Payment on Arc" className="mt-6">
        <Table head={["Status", "Amount", "From", "Transaction", "Confirmed"]} empty={data.payments.length === 0}>
          {data.payments.map((p) => (
            <tr key={p.id}>
              <Td><Badge status={p.status} /></Td>
              <Td className="tabular-nums">{usdc(p.amount)} USDC</Td>
              <Td className="font-mono text-xs">{short(p.fromAddress)}</Td>
              <Td><ExtLink href={p.txUrl}>{short(p.txHash, 10)}</ExtLink></Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(p.confirmedAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>

      <Card title="Delivery (VTpass)" className="mt-6">
        <Table head={["Status", "Request id", "VTpass ref", "Sent", "Last update", "Request", "Answer"]} empty={data.deliveries.length === 0}>
          {data.deliveries.map((d) => (
            <tr key={d.id}>
              <Td><Badge status={d.status} /></Td>
              <Td className="font-mono text-xs">{d.requestId}</Td>
              <Td className="font-mono text-xs">{d.providerReference ?? "—"}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.createdAt)}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.updatedAt)}</Td>
              <Td><Json value={d.request} /></Td>
              <Td><Json value={d.response} /></Td>
            </tr>
          ))}
        </Table>
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card title="Ledger">
          <Table head={["Account", "Debit", "Credit", "Memo"]} empty={data.ledger.length === 0}>
            {data.ledger.map((l, i) => (
              <tr key={i}>
                <Td className="font-mono text-xs">{l.account}</Td>
                <Td className="tabular-nums">{l.debit !== "0.000000" && l.debit !== "0" ? `${l.debit} ${l.currency}` : ""}</Td>
                <Td className="tabular-nums">{l.credit !== "0.000000" && l.credit !== "0" ? `${l.credit} ${l.currency}` : ""}</Td>
                <Td className="text-zinc-500">{l.memo ?? ""}</Td>
              </tr>
            ))}
          </Table>
        </Card>
        <Card title="History">
          <Table head={["When", "Who", "What", "Details"]} empty={data.activity.length === 0}>
            {data.activity.map((a) => (
              <tr key={a.id}>
                <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
                <Td>{a.actorType}</Td>
                <Td>{a.action}</Td>
                <Td><Json value={a.details} /></Td>
              </tr>
            ))}
          </Table>
        </Card>
      </div>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/orders/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { count, label, naira, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  reference: string;
  status: string;
  userId: string;
  email: string;
  serviceType: string;
  network: string;
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  failureReason: string | null;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; orders: Row[] };

const STATUSES = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED", "FLAGGED", "FAILED", "REFUND_PENDING", "REFUNDED", "QUOTED", "EXPIRED"];

export default function OrdersPage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const path = readyQ && readyS ? `/orders?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null;
  const { data, error } = useLoad<List>(path);

  return (
    <>
      <PageTitle title="Orders" subtitle="Airtime and data purchases. Unpaid prices are hidden unless you pick All." />
      <Card
        title={data ? `${count(data.total)} order(s)` : "Orders"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[
                { value: "", label: "All paid orders" },
                { value: "open", label: "Still in progress" },
                { value: "all", label: "All (including unpaid)" },
                ...STATUSES.map((s) => ({ value: s, label: label(s) })),
              ]}
            />
            <SearchBox
              initial={q}
              placeholder="Reference, phone or email"
              onSearch={(v) => {
                setQ(v);
                setPage(1);
              }}
            />
          </div>
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Reference", "Customer", "What", "Phone", "Price", "Status", "Date"]} empty={data.orders.length === 0}>
              {data.orders.map((o) => (
                <tr key={o.id}>
                  <Td>
                    <RowLink href={`/orders/${o.reference}`}>{o.reference}</RowLink>
                  </Td>
                  <Td>
                    <RowLink href={`/users/${o.userId}`}>{o.email}</RowLink>
                  </Td>
                  <Td>
                    {o.network.toUpperCase()} {o.serviceType}
                    {o.planName ? <span className="block text-xs text-zinc-500">{o.planName}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap">{o.phone}</Td>
                  <Td className="whitespace-nowrap tabular-nums">
                    {naira(o.ngnAmount)}
                    <span className="block text-xs text-zinc-500">{usdc(o.usdcAmount)} USDC</span>
                  </Td>
                  <Td>
                    <Badge status={o.status} />
                    {o.failureReason ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{o.failureReason}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(o.createdAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { Badge, Card, Loading, Notice, PageTitle, Stat } from "@/components/ui";
import { ago, count, label, naira, token, usdc } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Window = { all: number; d1: number; d7: number; d30: number };
type Overview = {
  generatedAt: string;
  testnet: boolean;
  vtpassSandbox: boolean;
  pauses: { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean };
  users: { total: number; verified: number; suspended: number; new1: number; new7: number; new30: number };
  volume: {
    orders: Window;
    usdc: { all: string; d1: string; d7: string; d30: string };
    ngn: Window;
    marginNgn: { all: number; d30: number };
  };
  ordersByStatus: Record<string, number>;
  refunds: Record<string, { count: number; usdc: string }>;
  bridge: { enabled: boolean; complete: number; usdc: string; complete30: number; usdc30: string; open: number; stuck: number };
  swaps: { enabled: boolean; complete: number; complete30: number; volume30: Record<string, number>; fees30: Record<string, number>; unknown: number };
  balances: { treasuryAddress: string; treasuryUrl: string; treasury: Record<string, string> | null; vtpassNgn: number | null };
  days: { day: string; orders: number; usdc: string; ngn: number; newUsers: number }[];
  issues: { text: string; href: string }[];
};

const STATUS_ORDER = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED", "FLAGGED", "FAILED", "REFUND_PENDING", "REFUNDED", "QUOTED", "EXPIRED"];

export default function OverviewPage() {
  const { data, error, loading, reload } = useLoad<Overview>("/overview");

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;

  const paused = [
    data.pauses.purchasesPaused ? "Purchases" : null,
    data.pauses.bridgePaused ? "Bridge" : null,
    data.pauses.swapPaused ? "Swaps" : null,
  ].filter(Boolean);
  const maxUsdc = Math.max(1, ...data.days.map((d) => Number(d.usdc)));
  const refundsDone = data.refunds.CONFIRMED;

  return (
    <>
      <PageTitle
        title="Overview"
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            {data.testnet ? <Badge tone="warn">Arc Testnet</Badge> : <Badge tone="good">Mainnet</Badge>}
            {data.vtpassSandbox ? <Badge tone="warn">VTpass sandbox</Badge> : <Badge tone="good">VTpass live</Badge>}
            {paused.length ? <Badge tone="bad">Paused: {paused.join(", ")}</Badge> : null}
            <span>Updated {ago(data.generatedAt)}</span>
          </span>
        }
        right={
          <button
            onClick={reload}
            disabled={loading}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
          >
            {loading ? "Refreshing..." : "Refresh"}
          </button>
        }
      />

      {data.issues.length ? (
        <Card title="Needs attention" className="mb-6 border-amber-300 dark:border-amber-800">
          <ul className="space-y-2 text-sm">
            {data.issues.map((i) => (
              <li key={i.text} className="flex items-start gap-2">
                <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-amber-500" />
                <Link href={i.href} className="text-zinc-800 hover:underline dark:text-zinc-200">
                  {i.text}
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      ) : (
        <div className="mb-6">
          <Notice tone="good">All clear: no flagged orders, failed refunds, stuck transfers or low balances.</Notice>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Users" value={count(data.users.total)} hint={`${count(data.users.new7)} new this week · ${count(data.users.verified)} confirmed`} href="/users" />
        <Stat
          label="Orders delivered"
          value={count(data.volume.orders.d30)}
          hint={`Last 30 days · today ${count(data.volume.orders.d1)} · all time ${count(data.volume.orders.all)}`}
          href="/orders?status=FULFILLED"
        />
        <Stat label="Volume (USDC)" value={usdc(data.volume.usdc.d30)} hint={`Last 30 days · 7 days ${usdc(data.volume.usdc.d7)} · all ${usdc(data.volume.usdc.all)}`} />
        <Stat label="Volume (naira)" value={naira(data.volume.ngn.d30)} hint={`Last 30 days · all ${naira(data.volume.ngn.all)}`} />
        <Stat label="Margin earned" value={naira(data.volume.marginNgn.d30)} hint={`Last 30 days · all ${naira(data.volume.marginNgn.all)}`} />
        <Stat
          label="Refunds"
          value={count(refundsDone?.count ?? 0)}
          hint={`${usdc(refundsDone?.usdc ?? 0)} USDC returned · ${count(data.ordersByStatus.REFUND_PENDING ?? 0)} in progress`}
          href="/refunds"
        />
        <Stat
          label="Bridge transfers"
          value={data.bridge.enabled ? count(data.bridge.complete30) : "Off"}
          hint={data.bridge.enabled ? `${usdc(data.bridge.usdc30)} USDC in 30 days · ${data.bridge.open} open · ${data.bridge.stuck} stuck` : "BRIDGE_ENABLED is off"}
          href="/bridge"
        />
        <Stat
          label="Swaps"
          value={data.swaps.enabled ? count(data.swaps.complete30) : "Off"}
          hint={
            data.swaps.enabled
              ? `Last 30 days · fees ${Object.entries(data.swaps.fees30).map(([t, v]) => `${token(v)} ${t}`).join(", ") || "none yet"}`
              : "SWAP_ENABLED is off"
          }
          href="/swaps"
        />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card title="Volume, last 14 days (USDC, delivered orders)" className="lg:col-span-2">
          <div className="flex h-44 items-end gap-1.5">
            {data.days.map((d) => (
              <div key={d.day} className="group relative flex h-full flex-1 flex-col justify-end">
                <div
                  className="rounded-t bg-emerald-600/80 group-hover:bg-emerald-700 dark:bg-emerald-500/70"
                  style={{ height: `${Math.max(Number(d.usdc) > 0 ? 3 : 0, (Number(d.usdc) / maxUsdc) * 100)}%` }}
                />
                <div className="pointer-events-none absolute bottom-full left-1/2 z-10 mb-1 hidden -translate-x-1/2 whitespace-nowrap rounded bg-zinc-900 px-2 py-1 text-xs text-white group-hover:block">
                  {d.day}: {d.orders} orders · {usdc(d.usdc)} USDC · {naira(d.ngn)} · {d.newUsers} new users
                </div>
              </div>
            ))}
          </div>
          <div className="mt-2 flex justify-between text-xs text-zinc-500">
            <span>{data.days[0]?.day}</span>
            <span>today</span>
          </div>
        </Card>

        <Card title="Balances">
          <dl className="space-y-3 text-sm">
            <div>
              <dt className="text-zinc-500">
                Treasury on Arc{" "}
                <a href={data.balances.treasuryUrl} target="_blank" rel="noreferrer noopener" className="text-emerald-700 hover:underline dark:text-emerald-400">
                  (view)
                </a>
              </dt>
              <dd className="mt-1 font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
                {data.balances.treasury
                  ? Object.entries(data.balances.treasury)
                      .map(([t, v]) => `${t === "USDC" || t === "EURC" ? usdc(v) : token(v)} ${t}`)
                      .join(" · ")
                  : "Could not read"}
              </dd>
            </div>
            <div>
              <dt className="text-zinc-500">VTpass wallet</dt>
              <dd className="mt-1 font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
                {data.balances.vtpassNgn === null ? "Could not read" : naira(data.balances.vtpassNgn)}
              </dd>
            </div>
          </dl>
        </Card>
      </div>

      <Card title="Orders by status" className="mt-6">
        <div className="flex flex-wrap gap-2">
          {STATUS_ORDER.filter((s) => data.ordersByStatus[s]).map((s) => (
            <Link
              key={s}
              href={`/orders?status=${s}`}
              className="flex items-center gap-2 rounded-lg border border-zinc-200 px-3 py-2 text-sm hover:border-zinc-300 dark:border-zinc-800 dark:hover:border-zinc-700"
            >
              <Badge status={s} />
              <span className="font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">{count(data.ordersByStatus[s])}</span>
            </Link>
          ))}
          {Object.keys(data.ordersByStatus).length === 0 ? <p className="text-sm text-zinc-500">No orders yet.</p> : null}
        </div>
        <p className="mt-3 text-xs text-zinc-500">{label("QUOTED")} and expired orders are prices that were never paid.</p>
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/providers/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, ConfirmButton, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Provider = { id: string; label: string; chain: string; address: string; explorerUrl: string | null; active: boolean; note: string | null; createdAt: string };

export default function ProvidersPage() {
  const { data, error, reload } = useLoad<{ providers: Provider[] }>("/providers");
  const [message, setMessage] = useState<string | null>(null);

  async function toggle(p: Provider) {
    setMessage(null);
    try {
      await post(`/providers/${p.id}`, { active: !p.active });
      reload();
    } catch (err) {
      setMessage(err instanceof Error ? err.message : "Could not change it.");
    }
  }

  return (
    <>
      <PageTitle
        title="Providers"
        subtitle="Approved addresses users can send USDC to on other networks. Nothing else can receive bridged USDC."
      />
      <Card title="Approved addresses">
        {error ? <Notice>{error}</Notice> : null}
        {message ? <Notice>{message}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <Table head={["Name", "Network", "Address", "Status", "Added", ""]} empty={data.providers.length === 0}>
            {data.providers.map((p) => (
              <tr key={p.id}>
                <Td>
                  {p.label}
                  {p.note ? <span className="block text-xs text-zinc-500">{p.note}</span> : null}
                </Td>
                <Td>{p.chain}</Td>
                <Td>
                  <ExtLink href={p.explorerUrl}>
                    <span className="font-mono text-xs">{p.address}</span>
                  </ExtLink>
                </Td>
                <Td>{p.active ? <Badge tone="good">On</Badge> : <Badge tone="plain">Off</Badge>}</Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(p.createdAt)}</Td>
                <Td>
                  <ConfirmButton danger={p.active} confirmText={p.active ? "Yes, turn off" : "Yes, turn on"} onConfirm={() => toggle(p)}>
                    {p.active ? "Turn off" : "Turn on"}
                  </ConfirmButton>
                </Td>
              </tr>
            ))}
          </Table>
        ) : null}
        <p className="mt-4 text-xs text-zinc-500">
          To add a new provider address, run <span className="font-mono">bash setup/destinations.sh prod add</span> on your computer. Adding
          addresses stays outside the dashboard on purpose, so a stolen admin login cannot send USDC to a new address.
        </p>
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/refunds/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  amount: string;
  attempt: number;
  lastError: string | null;
  txUrl: string | null;
  reference: string;
  orderStatus: string;
  email: string;
  userId: string;
  createdAt: string;
  confirmedAt: string | null;
};
type List = { total: number; page: number; pageSize: number; refunds: Row[] };

export default function RefundsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/refunds?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle
        title="Refunds"
        subtitle="USDC sent back from the treasury when a paid order could not be delivered. Failed refunds can be retried from the order page."
      />
      <Card
        title={data ? `${count(data.total)} refund(s)` : "Refunds"}
        right={
          <Select
            value={status}
            onChange={(v) => {
              setStatus(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "All" },
              { value: "PENDING", label: "Waiting to send" },
              { value: "SENT", label: "Sent, confirming" },
              { value: "CONFIRMED", label: "Confirmed" },
              { value: "FAILED", label: "Failed (needs retry)" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Order", "Customer", "Amount", "Status", "Attempt", "Note", "Started", "Confirmed"]} empty={data.refunds.length === 0}>
              {data.refunds.map((r) => (
                <tr key={r.id}>
                  <Td>
                    <RowLink href={`/orders/${r.reference}`}>{r.reference}</RowLink>
                  </Td>
                  <Td>
                    <RowLink href={`/users/${r.userId}`}>{r.email}</RowLink>
                  </Td>
                  <Td className="tabular-nums">
                    <ExtLink href={r.txUrl}>{usdc(r.amount)} USDC</ExtLink>
                  </Td>
                  <Td>
                    <Badge status={r.status} />
                  </Td>
                  <Td className="tabular-nums">{r.attempt}</Td>
                  <Td className="max-w-xs text-xs text-zinc-500">{r.lastError ?? ""}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(r.createdAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(r.confirmedAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/settings/page.tsx" <<'DOC_EOF'
"use client";

import { useState, type FormEvent } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { ago, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Pauses = { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean };
type Settings = {
  pauses: Pauses;
  setup: {
    network: string;
    testnet: boolean;
    vtpass: string;
    pricingMarginPercent: number;
    quoteMinutes: number;
    fixedRate: number | null;
    treasuryAddress: string;
    treasuryUrl: string;
    bridgeEnabled: boolean;
    bridgeLimits: { min: number; max: number; daily: number; maxFee: number };
    bridgeChains: string[];
    swapEnabled: boolean;
    swapFeePercent: number;
    swapSlippagePercent: number;
    swapDailyCount: number;
    alertEmail: boolean;
    worker: boolean;
  };
};
type Session = { id: string; current: boolean; ip: string | null; userAgent: string | null; createdAt: string; lastSeenAt: string };
type Me = { email: string; lastLoginAt: string | null; passwordChangedAt: string | null; sessionExpiresAt: string; idleMinutes: number };

const SWITCHES: { key: keyof Pauses; title: string; text: string }[] = [
  { key: "purchasesPaused", title: "Buying airtime and data", text: "New orders and payments. Orders already paid still deliver or refund." },
  { key: "bridgePaused", title: "Sending to other networks", text: "New bridge transfers and Move to Arc. Transfers already started keep going." },
  { key: "swapPaused", title: "Swaps", text: "New swaps on Arc." },
];

export default function SettingsPage() {
  const settings = useLoad<Settings>("/settings");
  const sessions = useLoad<{ sessions: Session[] }>("/sessions");
  const me = useLoad<Me>("/me");
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [pwMessage, setPwMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  async function flip(key: keyof Pauses, paused: boolean) {
    setMessage(null);
    try {
      await post("/settings/pause", { key, paused });
      setMessage({ tone: "good", text: paused ? "Paused. Users see a short maintenance message." : "Open again." });
      settings.reload();
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not change it." });
    }
  }

  async function changePassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setPwMessage(null);
    const formEl = e.currentTarget;
    const form = new FormData(formEl);
    const next = String(form.get("next"));
    if (next !== String(form.get("again"))) {
      setPwMessage({ tone: "bad", text: "The two new passwords are not the same." });
      return;
    }
    setBusy(true);
    try {
      await post("/password", { current: String(form.get("current")), next });
      formEl.reset();
      setPwMessage({ tone: "good", text: "Password changed. Every other session was signed out." });
      sessions.reload();
      me.reload();
    } catch (err) {
      setPwMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not change the password." });
    } finally {
      setBusy(false);
    }
  }

  async function endOthers() {
    await post("/sessions/end-others");
    sessions.reload();
  }

  const s = settings.data;
  const input = "mt-1.5 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950";

  return (
    <>
      <PageTitle title="Settings" subtitle="Switches, your password and sessions, and how the server is set up." />
      {settings.error ? <Notice>{settings.error}</Notice> : null}

      <Card title="Pause switches" className="mb-6">
        {!s ? (
          <Loading />
        ) : (
          <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {SWITCHES.map((sw) => {
              const paused = s.pauses[sw.key];
              return (
                <li key={sw.key} className="flex flex-wrap items-center justify-between gap-3 py-3">
                  <div>
                    <p className="flex items-center gap-2 text-sm font-medium text-zinc-900 dark:text-zinc-100">
                      {sw.title} {paused ? <Badge tone="bad">Paused</Badge> : <Badge tone="good">Open</Badge>}
                    </p>
                    <p className="text-xs text-zinc-500">{sw.text}</p>
                  </div>
                  <ConfirmButton danger={!paused} confirmText={paused ? "Yes, open" : "Yes, pause"} onConfirm={() => flip(sw.key, !paused)}>
                    {paused ? "Open again" : "Pause"}
                  </ConfirmButton>
                </li>
              );
            })}
          </ul>
        )}
        {message ? <div className="mt-3"><Notice tone={message.tone}>{message.text}</Notice></div> : null}
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Your password">
          {me.data ? (
            <p className="mb-4 text-sm text-zinc-500">
              Logged in as {me.data.email}. Password last changed {me.data.passwordChangedAt ? when(me.data.passwordChangedAt) : "never"}. You are logged out after{" "}
              {me.data.idleMinutes} minutes without activity.
            </p>
          ) : null}
          <form onSubmit={changePassword} className="space-y-3">
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">Current password</span>
              <input name="current" type="password" autoComplete="current-password" required className={input} />
            </label>
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">New password (12 characters or more)</span>
              <input name="next" type="password" autoComplete="new-password" minLength={12} required className={input} />
            </label>
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">New password again</span>
              <input name="again" type="password" autoComplete="new-password" minLength={12} required className={input} />
            </label>
            {pwMessage ? <Notice tone={pwMessage.tone}>{pwMessage.text}</Notice> : null}
            <button disabled={busy} className="rounded-lg bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-800 disabled:opacity-60">
              {busy ? "Saving..." : "Change password"}
            </button>
          </form>
        </Card>

        <Card
          title="Signed in sessions"
          right={
            sessions.data && sessions.data.sessions.length > 1 ? (
              <ConfirmButton danger confirmText="Yes, sign them out" onConfirm={endOthers}>
                Sign out the others
              </ConfirmButton>
            ) : null
          }
        >
          {sessions.data ? (
            <Table head={["Browser", "IP", "Last seen"]}>
              {sessions.data.sessions.map((x) => (
                <tr key={x.id}>
                  <Td className="max-w-xs text-xs">
                    {x.current ? <Badge tone="good">This one</Badge> : null} <span className="text-zinc-500">{x.userAgent ?? "unknown"}</span>
                  </Td>
                  <Td className="font-mono text-xs">{x.ip ?? "?"}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{ago(x.lastSeenAt)}</Td>
                </tr>
              ))}
            </Table>
          ) : (
            <Loading />
          )}
        </Card>
      </div>

      {s ? (
        <Card title="Server setup (read only)" className="mt-6">
          <DefList
            items={[
              ["Network", `${s.setup.network}${s.setup.testnet ? " (test network)" : ""}`],
              ["VTpass", s.setup.vtpass],
              ["Price margin", `${s.setup.pricingMarginPercent}% · prices held ${s.setup.quoteMinutes} min${s.setup.fixedRate ? ` · fixed rate ₦${s.setup.fixedRate}` : " · live rate"}`],
              ["Treasury", <ExtLink key="t" href={s.setup.treasuryUrl}><span className="font-mono text-xs">{s.setup.treasuryAddress}</span></ExtLink>],
              [
                "Bridge",
                s.setup.bridgeEnabled
                  ? `On · ${s.setup.bridgeLimits.min} to ${s.setup.bridgeLimits.max} USDC per transfer, ${s.setup.bridgeLimits.daily} per day · fee cap ${s.setup.bridgeLimits.maxFee} · ${s.setup.bridgeChains.join(", ")}`
                  : "Off",
              ],
              ["Swaps", s.setup.swapEnabled ? `On · fee ${s.setup.swapFeePercent}% · slippage ${s.setup.swapSlippagePercent}% · ${s.setup.swapDailyCount} per user per day` : "Off"],
              ["Alert emails", s.setup.alertEmail ? "On (ALERT_EMAIL)" : "Off: set ALERT_EMAIL on Render"],
              ["Background worker", s.setup.worker ? "Running" : "Off"],
            ]}
          />
          <p className="mt-4 text-xs text-zinc-500">These come from Render settings. Change them on Render and choose Save, rebuild, and deploy.</p>
        </Card>
      ) : null}
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/swaps/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, token, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  amountOut: string | null;
  feePercent: number;
  txUrl: string | null;
  error: string | null;
  userId: string;
  email: string;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; swaps: Row[] };

export default function SwapsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/swaps?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Swaps" subtitle="USDC, EURC and cirBTC swaps on Arc. Interrupted swaps (Checking) need a look onchain." />
      <Card
        title={data ? `${count(data.total)} swap(s)` : "Swaps"}
        right={
          <Select
            value={status}
            onChange={(v) => {
              setStatus(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "All" },
              { value: "COMPLETE", label: "Complete" },
              { value: "FAILED", label: "Cancelled" },
              { value: "UNKNOWN", label: "Interrupted" },
              { value: "PENDING", label: "Running" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Customer", "Swap", "Expected", "Minimum", "Fee", "Status", "Date"]} empty={data.swaps.length === 0}>
              {data.swaps.map((s) => (
                <tr key={s.id}>
                  <Td>
                    <RowLink href={`/users/${s.userId}`}>{s.email}</RowLink>
                  </Td>
                  <Td>
                    <ExtLink href={s.txUrl}>
                      {token(s.amountIn)} {s.tokenIn} → {s.amountOut ? token(s.amountOut) : "?"} {s.tokenOut}
                    </ExtLink>
                  </Td>
                  <Td className="tabular-nums">{token(s.estimatedOut)}</Td>
                  <Td className="tabular-nums">{token(s.minOut)}</Td>
                  <Td>{s.feePercent}%</Td>
                  <Td>
                    <Badge status={s.status} />
                    {s.error ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{s.error}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/users/[id]/page.tsx" <<'DOC_EOF'
"use client";

import { useParams } from "next/navigation";
import { useState, type ReactNode } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { label, naira, short, token, usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  user: { id: string; name: string; email: string; phone: string | null; emailVerified: boolean; status: string; createdAt: string };
  totals: { orders: number; spentUsdc: string; spentNgn: number };
  arcWallet: { address: string; explorerUrl: string; balances: Record<string, string> | null } | null;
  wallets: { address: string; blockchain: string; accountType: string; retiredAt: string | null; createdAt: string }[];
  otherChains: { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null }[];
  orders: { id: string; reference: string; status: string; serviceType: string; network: string; planName: string | null; phone: string; ngnAmount: number; usdcAmount: string; createdAt: string }[];
  bridges: { id: string; status: string; from: string; to: string; amount: string; recipientAddress: string; createdAt: string }[];
  swaps: { id: string; status: string; tokenIn: string; tokenOut: string; amountIn: string; amountOut: string | null; txUrl: string | null; createdAt: string }[];
  sweeps: { id: string; status: string; amount: string; toAddress: string; txUrl: string | null; createdAt: string }[];
  activity: { id: string; actorType: string; action: string; details: unknown; at: string }[];
};

export default function UserPage() {
  const { id } = useParams<{ id: string }>();
  const { data, error, reload } = useLoad<Detail>(id ? `/users/${id}` : null);
  const [reason, setReason] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const { user } = data;

  async function setStatus(status: "active" | "suspended") {
    setActionError(null);
    try {
      await post(`/users/${user.id}/status`, { status, reason });
      setReason("");
      reload();
    } catch (err) {
      setActionError(err instanceof Error ? err.message : "Could not change the status.");
    }
  }

  return (
    <>
      <PageTitle title={user.name} subtitle={user.email} right={<Badge status={user.status} />} />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Account">
          <DefList
            items={[
              ["Email", <span key="e">{user.email} {user.emailVerified ? <Badge tone="good">Confirmed</Badge> : <Badge tone="warn">Not confirmed</Badge>}</span>],
              ["Phone", user.phone ?? "—"],
              ["Joined", when(user.createdAt)],
              ["Orders", `${data.totals.orders} (delivered: ${usdc(data.totals.spentUsdc)} USDC, ${naira(data.totals.spentNgn)})`],
              ["User id", <span key="i" className="font-mono text-xs">{user.id}</span>],
            ]}
          />
          <div className="mt-5 border-t border-zinc-100 pt-4 dark:border-zinc-800">
            {user.status === "suspended" ? (
              <div className="flex flex-wrap items-center gap-3">
                <p className="text-sm text-zinc-600 dark:text-zinc-400">This user cannot buy, send or swap.</p>
                <ConfirmButton confirmText="Yes, restore" onConfirm={() => setStatus("active")}>
                  Restore user
                </ConfirmButton>
              </div>
            ) : (
              <div className="space-y-2">
                <input
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Reason for suspending (kept in the activity log)"
                  className="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950"
                />
                <ConfirmButton danger confirmText="Yes, suspend" disabled={!reason.trim()} onConfirm={() => setStatus("suspended")}>
                  Suspend user
                </ConfirmButton>
                <p className="text-xs text-zinc-500">Suspending signs the user out. Orders in progress still finish and refunds still go out.</p>
              </div>
            )}
            {actionError ? <div className="mt-3"><Notice>{actionError}</Notice></div> : null}
          </div>
        </Card>

        <Card title="Wallets">
          {data.arcWallet ? (
            <DefList
              items={[
                ["Arc wallet", <ExtLink key="a" href={data.arcWallet.explorerUrl}><span className="font-mono text-xs">{data.arcWallet.address}</span></ExtLink>],
                [
                  "Balances",
                  data.arcWallet.balances
                    ? Object.entries(data.arcWallet.balances).map(([t, v]) => `${t === "cirBTC" ? token(v) : usdc(v)} ${t}`).join(" · ")
                    : "Could not read",
                ],
                ...data.otherChains.map(
                  (c) =>
                    [c.chainLabel, <span key={c.chain}><ExtLink href={c.explorerUrl}>{short(c.address)}</ExtLink> · {c.balance === null ? "?" : `${usdc(c.balance)} USDC`}</span>] as [string, ReactNode],
                ),
              ]}
            />
          ) : (
            <p className="text-sm text-zinc-500">No wallet yet (created on the first dashboard visit after confirming the email).</p>
          )}
          {data.wallets.some((w) => w.retiredAt) ? (
            <p className="mt-4 text-xs text-zinc-500">
              Old wallets: {data.wallets.filter((w) => w.retiredAt).map((w) => `${short(w.address)} (${w.accountType}, retired ${when(w.retiredAt)})`).join(", ")}
            </p>
          ) : null}
        </Card>
      </div>

      <Card title="Orders" className="mt-6">
        <Table head={["Reference", "What", "Phone", "Price", "Status", "Date"]} empty={data.orders.length === 0}>
          {data.orders.map((o) => (
            <tr key={o.id}>
              <Td><RowLink href={`/orders/${o.reference}`}>{o.reference}</RowLink></Td>
              <Td>{o.network.toUpperCase()} {o.serviceType}{o.planName ? <span className="block text-xs text-zinc-500">{o.planName}</span> : null}</Td>
              <Td>{o.phone}</Td>
              <Td className="whitespace-nowrap tabular-nums">{naira(o.ngnAmount)}<span className="block text-xs text-zinc-500">{usdc(o.usdcAmount)} USDC</span></Td>
              <Td><Badge status={o.status} /></Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(o.createdAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card title="Bridge transfers">
          <Table head={["Route", "Amount", "Status", "Date"]} empty={data.bridges.length === 0}>
            {data.bridges.map((b) => (
              <tr key={b.id}>
                <Td><RowLink href={`/bridge/${b.id}`}>{b.from} → {b.to}</RowLink></Td>
                <Td className="tabular-nums">{usdc(b.amount)}</Td>
                <Td><Badge status={b.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(b.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
        <Card title="Swaps">
          <Table head={["Swap", "Status", "Date"]} empty={data.swaps.length === 0}>
            {data.swaps.map((s) => (
              <tr key={s.id}>
                <Td>
                  <ExtLink href={s.txUrl}>{token(s.amountIn)} {s.tokenIn} → {s.amountOut ? token(s.amountOut) : "?"} {s.tokenOut}</ExtLink>
                </Td>
                <Td><Badge status={s.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
      </div>

      {data.sweeps.length ? (
        <Card title="Wallet upgrade sweeps" className="mt-6">
          <Table head={["Amount", "To", "Status", "Date"]}>
            {data.sweeps.map((s) => (
              <tr key={s.id}>
                <Td><ExtLink href={s.txUrl}>{usdc(s.amount)} USDC</ExtLink></Td>
                <Td className="font-mono text-xs">{short(s.toAddress)}</Td>
                <Td><Badge status={s.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
      ) : null}

      <Card title="Admin actions on this user" className="mt-6">
        <Table head={["When", "Action", "Details"]} empty={data.activity.length === 0}>
          {data.activity.map((a) => (
            <tr key={a.id}>
              <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
              <Td>{label(a.action.replace(/^admin\./, ""))}</Td>
              <Td><Json value={a.details} /></Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/(dash)/users/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { ago, count, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  name: string;
  email: string;
  phone: string | null;
  emailVerified: boolean;
  status: string;
  createdAt: string;
  orders: number;
  spentUsdc: string;
  lastOrderAt: string | null;
};
type List = { total: number; page: number; pageSize: number; users: Row[] };

export default function UsersPage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const path = readyQ && readyS ? `/users?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null;
  const { data, error } = useLoad<List>(path);

  return (
    <>
      <PageTitle title="Users" subtitle="Everyone who signed up. Click a name for wallets, balances and history." />
      <Card
        title={data ? `${count(data.total)} user(s)` : "Users"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[
                { value: "", label: "Everyone" },
                { value: "active", label: "Active" },
                { value: "suspended", label: "Suspended" },
                { value: "unverified", label: "Email not confirmed" },
              ]}
            />
            <SearchBox
              initial={q}
              placeholder="Name, email or phone"
              onSearch={(v) => {
                setQ(v);
                setPage(1);
              }}
            />
          </div>
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["User", "Phone", "Status", "Orders", "Spent (USDC)", "Last order", "Joined"]} empty={data.users.length === 0}>
              {data.users.map((u) => (
                <tr key={u.id}>
                  <Td>
                    <RowLink href={`/users/${u.id}`}>{u.name}</RowLink>
                    <span className="block text-xs text-zinc-500">{u.email}</span>
                  </Td>
                  <Td className="whitespace-nowrap">{u.phone ?? "—"}</Td>
                  <Td>
                    <span className="flex flex-wrap gap-1">
                      <Badge status={u.status} />
                      {u.emailVerified ? null : <Badge tone="warn">Unconfirmed</Badge>}
                    </span>
                  </Td>
                  <Td className="tabular-nums">{u.orders}</Td>
                  <Td className="tabular-nums">{usdc(u.spentUsdc)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{ago(u.lastOrderAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(u.createdAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
DOC_EOF
cat > "admin/src/app/globals.css" <<'DOC_EOF'
@import "tailwindcss";

:root {
  --background: #ffffff;
  --foreground: #171717;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-geist-sans);
  --font-mono: var(--font-geist-mono);
}

@media (prefers-color-scheme: dark) {
  :root {
    --background: #0a0a0a;
    --foreground: #ededed;
  }
}

body {
  background: var(--background);
  color: var(--foreground);
  font-family: var(--font-geist-sans), Arial, Helvetica, sans-serif;
}
DOC_EOF
cat > "admin/src/app/layout.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "dataonchain admin",
  description: "Private admin dashboard",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
      <body className="min-h-full">{children}</body>
    </html>
  );
}
DOC_EOF
cat > "admin/src/app/robots.ts" <<'DOC_EOF'
import type { MetadataRoute } from "next";

// Search engines: stay out
export default function robots(): MetadataRoute.Robots {
  return { rules: { userAgent: "*", disallow: "/" } };
}
DOC_EOF
cat > "admin/src/components/AuthCard.tsx" <<'DOC_EOF'
import type { InputHTMLAttributes, ReactNode } from "react";

export function AuthCard({ title, subtitle, children, footer }: { title: string; subtitle?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="w-full max-w-sm">
        <p className="mb-6 text-center text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
          dataonchain <span className="font-normal text-zinc-500">admin</span>
        </p>
        <div className="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{title}</h1>
          {subtitle ? <p className="mt-1 text-sm text-zinc-500">{subtitle}</p> : null}
          <div className="mt-5">{children}</div>
        </div>
        {footer ? <div className="mt-4 text-center text-sm text-zinc-500">{footer}</div> : null}
      </div>
    </main>
  );
}

export function Input(props: InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  const { label, ...rest } = props;
  return (
    <label className="block">
      <span className="text-sm font-medium text-zinc-700 dark:text-zinc-300">{label}</span>
      <input
        {...rest}
        className="mt-1.5 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
      />
    </label>
  );
}

export function Submit({ busy, children }: { busy: boolean; children: ReactNode }) {
  return (
    <button
      type="submit"
      disabled={busy}
      className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
    >
      {busy ? "Please wait..." : children}
    </button>
  );
}
DOC_EOF
cat > "admin/src/components/Shell.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { api, post } from "@/lib/api";

type Me = { email: string; sessionExpiresAt: string; idleMinutes: number };

const NAV = [
  { href: "/", label: "Overview" },
  { href: "/users", label: "Users" },
  { href: "/orders", label: "Orders" },
  { href: "/refunds", label: "Refunds" },
  { href: "/bridge", label: "Bridge" },
  { href: "/swaps", label: "Swaps" },
  { href: "/providers", label: "Providers" },
  { href: "/activity", label: "Activity" },
  { href: "/settings", label: "Settings" },
];

// Every dashboard page sits inside this: it checks the login and shows the menu.
export function Shell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const [me, setMe] = useState<Me | null>(null);

  useEffect(() => {
    api<Me>("/me")
      .then(setMe)
      .catch(() => router.replace("/login"));
  }, [router]);

  async function logOut() {
    await post("/logout").catch(() => null);
    router.replace("/login");
  }

  if (!me) {
    return <main className="flex min-h-screen items-center justify-center text-sm text-zinc-500">Checking your login...</main>;
  }

  const active = (href: string) => (href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`));

  return (
    <div className="min-h-screen bg-zinc-50 dark:bg-zinc-950 lg:flex">
      <aside className="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 lg:sticky lg:top-0 lg:h-screen lg:w-56 lg:shrink-0 lg:border-b-0 lg:border-r">
        <div className="flex items-center justify-between px-4 py-4 lg:block">
          <Link href="/" className="block text-base font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain <span className="font-normal text-zinc-500">admin</span>
          </Link>
          <button onClick={logOut} className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400 lg:hidden">
            Log out
          </button>
        </div>
        <nav className="flex gap-1 overflow-x-auto px-2 pb-3 lg:flex-col lg:overflow-visible lg:pb-0">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={`whitespace-nowrap rounded-lg px-3 py-2 text-sm font-medium ${
                active(n.href)
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800"
              }`}
            >
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="hidden px-4 py-6 text-xs text-zinc-500 lg:absolute lg:bottom-0 lg:block lg:w-56">
          <p className="truncate" title={me.email}>
            {me.email}
          </p>
          <button onClick={logOut} className="mt-2 font-medium text-zinc-700 hover:underline dark:text-zinc-300">
            Log out
          </button>
        </div>
      </aside>
      <main className="min-w-0 flex-1 px-4 py-6 sm:px-8 sm:py-8">
        <div className="mx-auto max-w-6xl">{children}</div>
      </main>
    </div>
  );
}
DOC_EOF
cat > "admin/src/components/ui.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useState, type FormEvent, type ReactNode } from "react";
import { TONE_CLASS, label, toneOf, type Tone } from "@/lib/format";

export function PageTitle({ title, subtitle, right }: { title: string; subtitle?: ReactNode; right?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h1>
        {subtitle ? <p className="mt-1 text-sm text-zinc-500">{subtitle}</p> : null}
      </div>
      {right}
    </div>
  );
}

export function Card({ title, right, children, className = "" }: { title?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`rounded-xl border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900 ${className}`}>
      {title || right ? (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title ? <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">{title}</h2> : <span />}
          {right}
        </div>
      ) : null}
      {children}
    </section>
  );
}

export function Stat({ label: name, value, hint, href }: { label: string; value: ReactNode; hint?: ReactNode; href?: string }) {
  const body = (
    <div className="h-full rounded-xl border border-zinc-200 bg-white p-4 transition hover:border-zinc-300 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-700">
      <p className="text-xs font-medium uppercase tracking-wide text-zinc-500">{name}</p>
      <p className="mt-2 text-2xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-50">{value}</p>
      {hint ? <p className="mt-1 text-xs text-zinc-500">{hint}</p> : null}
    </div>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

export function Badge({ status, tone, children }: { status?: string; tone?: Tone; children?: ReactNode }) {
  const t = tone ?? (status ? toneOf(status) : "plain");
  return (
    <span className={`inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset ${TONE_CLASS[t]}`}>
      {children ?? (status ? label(status) : "")}
    </span>
  );
}

export function Table({ head, children, empty }: { head: ReactNode[]; children: ReactNode; empty?: boolean }) {
  return (
    <div className="-mx-5 overflow-x-auto">
      <table className="w-full min-w-[640px] text-left text-sm">
        <thead>
          <tr className="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800">
            {head.map((h, i) => (
              <th key={i} className="whitespace-nowrap px-5 py-2 font-medium">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">{children}</tbody>
      </table>
      {empty ? <p className="px-5 py-8 text-center text-sm text-zinc-500">Nothing here yet.</p> : null}
    </div>
  );
}

export function Td({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <td className={`px-5 py-2.5 align-top text-zinc-800 dark:text-zinc-200 ${className}`}>{children}</td>;
}

export function RowLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <Link href={href} className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      {children}
    </Link>
  );
}

export function ExtLink({ href, children }: { href: string | null | undefined; children: ReactNode }) {
  if (!href) return <span className="text-zinc-400">{children}</span>;
  return (
    <a href={href} target="_blank" rel="noreferrer noopener" className="text-emerald-700 hover:underline dark:text-emerald-400">
      {children}
    </a>
  );
}

export function Pager({ page, pageSize, total, onPage }: { page: number; pageSize: number; total: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  return (
    <div className="mt-4 flex items-center justify-between text-sm text-zinc-500">
      <span>
        {total.toLocaleString("en-US")} in total · page {page} of {pages}
      </span>
      <div className="flex gap-2">
        <button
          disabled={page <= 1}
          onClick={() => onPage(page - 1)}
          className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          Previous
        </button>
        <button
          disabled={page >= pages}
          onClick={() => onPage(page + 1)}
          className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          Next
        </button>
      </div>
    </div>
  );
}

export function Notice({ tone = "bad", children }: { tone?: Tone; children: ReactNode }) {
  return <p className={`rounded-lg px-3 py-2 text-sm ring-1 ring-inset ${TONE_CLASS[tone]}`}>{children}</p>;
}

export function Loading() {
  return <p className="py-10 text-center text-sm text-zinc-500">Loading...</p>;
}

export function Json({ value }: { value: unknown }) {
  if (value === null || value === undefined) return <span className="text-zinc-400">—</span>;
  return (
    <details className="text-xs">
      <summary className="cursor-pointer text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">Show</summary>
      <pre className="mt-2 max-h-80 max-w-xl overflow-auto rounded-lg bg-zinc-50 p-3 text-zinc-700 dark:bg-zinc-950 dark:text-zinc-300">
        {JSON.stringify(value, null, 2)}
      </pre>
    </details>
  );
}

export function Select({ value, onChange, options }: { value: string; onChange: (v: string) => void; options: { value: string; label: string }[] }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-800 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-200"
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

export function SearchBox({ initial, placeholder, onSearch }: { initial: string; placeholder: string; onSearch: (q: string) => void }) {
  const [text, setText] = useState(initial);
  const [seen, setSeen] = useState(initial);
  // Follow the initial value once it is read from the address bar
  if (initial !== seen) {
    setSeen(initial);
    setText(initial);
  }
  function submit(e: FormEvent) {
    e.preventDefault();
    onSearch(text.trim());
  }
  return (
    <form onSubmit={submit} className="flex gap-2">
      <input
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={placeholder}
        className="w-64 max-w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
      />
      <button className="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300">
        Search
      </button>
    </form>
  );
}

// A button that asks "Are you sure?" inline before doing anything.
export function ConfirmButton({
  children,
  confirmText = "Yes, do it",
  onConfirm,
  danger = false,
  disabled = false,
}: {
  children: ReactNode;
  confirmText?: string;
  onConfirm: () => Promise<void>;
  danger?: boolean;
  disabled?: boolean;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const base = "rounded-lg px-3 py-1.5 text-sm font-medium disabled:opacity-50";
  const main = danger
    ? "border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
    : "border border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800";
  if (!asking) {
    return (
      <button disabled={disabled} onClick={() => setAsking(true)} className={`${base} ${main}`}>
        {children}
      </button>
    );
  }
  return (
    <span className="inline-flex gap-2">
      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true);
          try {
            await onConfirm();
          } finally {
            setBusy(false);
            setAsking(false);
          }
        }}
        className={`${base} ${danger ? "bg-red-600 text-white hover:bg-red-700" : "bg-emerald-700 text-white hover:bg-emerald-800"}`}
      >
        {busy ? "Working..." : confirmText}
      </button>
      <button disabled={busy} onClick={() => setAsking(false)} className={`${base} ${main}`}>
        Cancel
      </button>
    </span>
  );
}

export function DefList({ items }: { items: [string, ReactNode][] }) {
  return (
    <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-[11rem_1fr]">
      {items.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-zinc-500">{k}</dt>
          <dd className="min-w-0 break-words text-zinc-900 dark:text-zinc-100">{v}</dd>
        </div>
      ))}
    </dl>
  );
}
DOC_EOF
cat > "admin/src/lib/api.ts" <<'DOC_EOF'
// Calls the admin API through this website's /api pass through.
// Changes (POST) carry X-Admin-Request: 1, which the server requires.
// A 401 on any page except the login pages sends the admin to /login.
export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

const PUBLIC_PAGES = ["/login", "/forgot", "/reset"];

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase();
  const res = await fetch(`/api/admin${path}`, {
    ...init,
    method,
    credentials: "same-origin",
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      ...(method !== "GET" ? { "X-Admin-Request": "1" } : {}),
      ...init.headers,
    },
  });
  const body: unknown = await res.json().catch(() => null);
  if (res.status === 401 && typeof window !== "undefined" && !PUBLIC_PAGES.includes(window.location.pathname)) {
    window.location.href = "/login";
  }
  if (!res.ok) {
    const message =
      body && typeof body === "object" && "error" in body
        ? String((body as { error: unknown }).error)
        : `Something went wrong (${res.status}). Please try again.`;
    throw new ApiError(message, res.status);
  }
  return body as T;
}

export function post<T>(path: string, data: unknown = {}): Promise<T> {
  return api<T>(path, { method: "POST", body: JSON.stringify(data) });
}
DOC_EOF
cat > "admin/src/lib/format.ts" <<'DOC_EOF'
// Display helpers. Times are shown in Lagos time.
export const naira = (n: number | null | undefined) =>
  n === null || n === undefined ? "—" : `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;

export const usdc = (s: string | number | null | undefined, digits = 2) =>
  s === null || s === undefined
    ? "—"
    : Number(s).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: 6 });

export const token = (s: string | number | null | undefined) =>
  s === null || s === undefined ? "—" : Number(s).toLocaleString("en-US", { maximumFractionDigits: 8 });

export const count = (n: number | null | undefined) => (n ?? 0).toLocaleString("en-US");

export function when(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });
}

export function ago(iso: string | null | undefined): string {
  if (!iso) return "—";
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

export const short = (a: string | null | undefined, n = 6) => (a ? (a.length > n * 2 + 3 ? `${a.slice(0, n)}...${a.slice(-4)}` : a) : "—");

export type Tone = "good" | "bad" | "warn" | "wait" | "plain";

const GOOD = ["FULFILLED", "REFUNDED", "COMPLETE", "CONFIRMED", "DELIVERED", "active", "MINTED"];
const BAD = ["FAILED", "MISMATCH", "suspended", "DENIED"];
const WARN = ["FLAGGED", "REFUND_PENDING", "UNKNOWN"];
const PLAIN = ["QUOTED", "EXPIRED"];

export function toneOf(status: string): Tone {
  if (GOOD.includes(status)) return "good";
  if (BAD.includes(status)) return "bad";
  if (WARN.includes(status)) return "warn";
  if (PLAIN.includes(status)) return "plain";
  return "wait";
}

export const TONE_CLASS: Record<Tone, string> = {
  good: "bg-emerald-50 text-emerald-800 ring-emerald-600/20 dark:bg-emerald-950 dark:text-emerald-300",
  bad: "bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-950 dark:text-red-300",
  warn: "bg-amber-50 text-amber-900 ring-amber-600/20 dark:bg-amber-950 dark:text-amber-200",
  wait: "bg-sky-50 text-sky-800 ring-sky-600/20 dark:bg-sky-950 dark:text-sky-300",
  plain: "bg-zinc-100 text-zinc-700 ring-zinc-500/20 dark:bg-zinc-800 dark:text-zinc-300",
};

export const label = (s: string) => s.replace(/_/g, " ").toLowerCase().replace(/^\w/, (c) => c.toUpperCase());
DOC_EOF
cat > "admin/src/lib/use-load.ts" <<'DOC_EOF'
"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "./api";

// Loads one admin API path. Pass null to wait. reload() fetches it again.
export function useLoad<T>(path: string | null) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (!path) return;
    let stop = false;
    setLoading(true);
    api<T>(path)
      .then((d) => {
        if (stop) return;
        setData(d);
        setError(null);
      })
      .catch((e: unknown) => {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this page.");
      })
      .finally(() => {
        if (!stop) setLoading(false);
      });
    return () => {
      stop = true;
    };
  }, [path, tick]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { data, error, loading, reload };
}

// Reads ?name=value from the address bar once, after the page loads.
export function useQueryParam(name: string, fallback = ""): [string, (v: string) => void, boolean] {
  const [value, setValue] = useState(fallback);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const v = new URLSearchParams(window.location.search).get(name);
    if (v !== null) setValue(v);
    setReady(true);
  }, [name]);
  const update = useCallback(
    (v: string) => {
      setValue(v);
      const params = new URLSearchParams(window.location.search);
      if (v) params.set(name, v);
      else params.delete(name);
      const qs = params.toString();
      window.history.replaceState(null, "", `${window.location.pathname}${qs ? `?${qs}` : ""}`);
    },
    [name],
  );
  return [value, update, ready];
}
DOC_EOF
cat > "admin/tsconfig.json" <<'DOC_EOF'
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "incremental": true,
    "plugins": [
      {
        "name": "next"
      }
    ],
    "paths": {
      "@/*": ["./src/*"]
    }
  },
  "include": [
    "next-env.d.ts",
    "**/*.ts",
    "**/*.tsx",
    ".next/types/**/*.ts",
    ".next/dev/types/**/*.ts",
    "**/*.mts"
  ],
  "exclude": ["node_modules"]
}
DOC_EOF
cat > "backend/scripts/admin-smoke.ts" <<'DOC_EOF'
// End to end test of the admin login and API against a running backend,
// on the development database. Cleans up after itself.
// The backend must run with the same ADMIN_EMAIL and with EMAIL_OUTBOX_FILE set.
// Run with:
//   ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE=/tmp/x npx tsx scripts/admin-smoke.ts http://localhost:4099
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { eq, inArray, or } from "drizzle-orm";
import { db } from "../src/db";
import { adminAccounts, adminResetTokens, adminSessions, auditLogs, users } from "../src/db/schema";
import { setPause } from "../src/settings";

const base = `${(process.argv[2] ?? "http://localhost:4099").replace(/\/$/, "")}/api/admin`;
const statusUrl = `${(process.argv[2] ?? "http://localhost:4099").replace(/\/$/, "")}/api/status`;
const outbox = process.env.EMAIL_OUTBOX_FILE;
const adminEmail = (process.env.ADMIN_EMAIL ?? "").toLowerCase();
const PASSWORD = "Admin smoke 2024 password!";
const PASSWORD2 = "Another admin smoke pass 77";

type Result = { status: number; body: Record<string, unknown>; cookies: string[] };
const jar = new Map<string, string>();

async function call(path: string, method = "GET", body?: unknown, opts: { header?: boolean } = {}): Promise<Result> {
  const cookie = [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  const res = await fetch(base + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(method !== "GET" && opts.header !== false ? { "X-Admin-Request": "1" } : {}),
      ...(cookie ? { Cookie: cookie } : {}),
      "User-Agent": "admin-smoke",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const cookies = res.headers.getSetCookie();
  for (const c of cookies) {
    const [pair] = c.split(";");
    const [name, ...rest] = pair!.split("=");
    const value = rest.join("=");
    if (!value || /max-age=0/i.test(c)) jar.delete(name!.trim());
    else jar.set(name!.trim(), value);
  }
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    parsed = { raw: text };
  }
  return { status: res.status, body: parsed, cookies };
}

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

type Mail = { to: string; subject: string; text: string };
async function mails(): Promise<Mail[]> {
  const lines = (await readFile(outbox!, "utf8").catch(() => "")).trim().split("\n").filter(Boolean);
  return lines.map((l) => JSON.parse(l) as Mail);
}
async function waitForMail(subjectPart: string, after: number): Promise<Mail> {
  for (let i = 0; i < 40; i++) {
    const found = (await mails()).slice(after).filter((m) => m.to === adminEmail && m.subject.includes(subjectPart));
    if (found.length) return found[found.length - 1]!;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`No email with "${subjectPart}" arrived`);
}

async function resetFlow(password: string): Promise<void> {
  const before = (await mails()).length;
  const r = await call("/forgot", "POST", { email: adminEmail.toUpperCase() });
  check(r.status === 200, "forgot password answers");
  const mail = await waitForMail("admin password", before);
  const token = /#token=([A-Za-z0-9_-]+)/.exec(mail.text)?.[1];
  check(Boolean(token), "the reset email has a link with the token after #");
  const done = await call("/reset", "POST", { token, password });
  check(done.status === 200, "a new password can be set with the link", done.body);
  const again = await call("/reset", "POST", { token, password });
  check(again.status === 400, "the same link cannot be used twice");
}

async function login(password: string): Promise<void> {
  const before = (await mails()).length;
  const r = await call("/login", "POST", { email: adminEmail, password });
  check(r.status === 200 && r.body.step === "code", "email and password accepted, code requested", r.body);
  const mail = await waitForMail("login code", before);
  const code = /\b(\d{6})\b/.exec(mail.text)?.[1];
  check(Boolean(code), "the code arrives by email");
  const wrong = await call("/login/code", "POST", { code: code === "000000" ? "111111" : "000000" });
  check(wrong.status === 401, "a wrong code is refused");
  const ok = await call("/login/code", "POST", { code });
  check(ok.status === 200, "the right code logs in", ok.body);
  const cookie = ok.cookies.find((c) => c.startsWith("doc_admin="));
  check(Boolean(cookie && /HttpOnly/i.test(cookie) && /SameSite=Strict/i.test(cookie)), "the session cookie is HttpOnly and SameSite=Strict", cookie);
}

async function main() {
  if (!outbox || !adminEmail) throw new Error("Run with ADMIN_EMAIL and EMAIL_OUTBOX_FILE set");
  const testUserId = randomUUID();
  try {
    // A clean start for the test admin
    const [old] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, adminEmail));
    if (old) {
      await db.delete(adminSessions).where(eq(adminSessions.accountId, old.id));
      await db.delete(adminResetTokens).where(eq(adminResetTokens.accountId, old.id));
      await db.delete(adminAccounts).where(eq(adminAccounts.id, old.id));
    }

    check((await call("/me")).status === 401, "nothing is visible without logging in");
    check((await call("/overview")).status === 401, "the overview needs a login");
    check((await call("/login", "POST", { email: adminEmail, password: "x" }, { header: false })).status === 400, "changes without the dashboard header are refused");

    const before = (await mails()).length;
    await call("/forgot", "POST", { email: "someone-else@example.com" });
    await new Promise((r) => setTimeout(r, 500));
    check((await mails()).slice(before).length === 0, "forgot password for another email sends nothing");

    const noPassword = await call("/login", "POST", { email: adminEmail, password: PASSWORD });
    check(noPassword.status === 401, "no login before a password is set");

    const weakBefore = (await mails()).length;
    await call("/forgot", "POST", { email: adminEmail });
    const weakMail = await waitForMail("admin password", weakBefore);
    const weakToken = /#token=([A-Za-z0-9_-]+)/.exec(weakMail.text)?.[1];
    check((await call("/reset", "POST", { token: weakToken, password: "short" })).status === 400, "a short password is refused");

    await resetFlow(PASSWORD);
    check((await call("/login", "POST", { email: adminEmail, password: "wrong password here" })).status === 401, "a wrong password is refused");
    await login(PASSWORD);

    const me = await call("/me");
    check(me.status === 200 && me.body.email === adminEmail, "logged in as the admin email", me.body);

    // Every page of the dashboard answers
    const overview = await call("/overview");
    check(overview.status === 200 && typeof (overview.body.users as { total?: unknown })?.total === "number", "overview loads", overview.body);
    check(Array.isArray(overview.body.days) && (overview.body.days as unknown[]).length === 14, "overview has 14 days of volume");
    for (const path of ["/users", "/orders", "/orders?status=open", "/refunds", "/bridge", "/swaps", "/providers", "/activity", "/settings", "/sessions"]) {
      const r = await call(path);
      check(r.status === 200, `${path} loads`, r.body);
    }
    check((await call("/orders/NOPE")).status === 404, "an unknown order is a 404");

    // Pausing swaps shows on the public status, then reopens
    const pause = await call("/settings/pause", "POST", { key: "swapPaused", paused: true });
    check(pause.status === 200, "swaps can be paused", pause.body);
    const status = (await (await fetch(statusUrl)).json()) as { paused?: { swapPaused?: boolean } };
    check(status.paused?.swapPaused === true, "the public status shows swaps paused");
    check((await call("/settings/pause", "POST", { key: "swapPaused", paused: false })).status === 200, "swaps can be reopened");
    check((await call("/settings/pause", "POST", { key: "nonsense", paused: true })).status === 400, "unknown switches are refused");

    // Suspending a user
    await db.insert(users).values({ id: testUserId, name: "Admin Smoke User", email: `admin-smoke-user+${Date.now()}@example.com`, emailVerified: true, phone: "+2348000000000" });
    check((await call(`/users/${testUserId}/status`, "POST", { status: "suspended" })).status === 400, "a suspension needs a reason");
    check((await call(`/users/${testUserId}/status`, "POST", { status: "suspended", reason: "smoke test" })).status === 200, "a user can be suspended");
    const u = await call(`/users/${testUserId}`);
    check((u.body.user as { status?: string })?.status === "suspended", "the user shows as suspended");
    check((await call(`/users/${testUserId}/status`, "POST", { status: "active" })).status === 200, "a user can be restored");
    const found = await call(`/users?q=${encodeURIComponent("Admin Smoke User")}`);
    check((found.body.users as unknown[]).length >= 1, "user search finds the user by name");

    // Changing the password signs out other sessions
    check((await call("/password", "POST", { current: "not it at all", next: PASSWORD2 })).status === 401, "changing the password needs the current one");
    check((await call("/password", "POST", { current: PASSWORD, next: PASSWORD2 })).status === 200, "the password can be changed");

    check((await call("/logout", "POST")).status === 200, "log out");
    check((await call("/me")).status === 401, "logged out for real");

    // Five wrong passwords lock the login, even for the right password
    for (let i = 0; i < 5; i++) await call("/login", "POST", { email: adminEmail, password: `wrong ${i} password` });
    const locked = await call("/login", "POST", { email: adminEmail, password: PASSWORD2 });
    check(locked.status === 423, "five wrong passwords lock the login", locked.body);
    await waitForMail("locked", 0);
    check(true, "the admin is emailed about the lock");
    await resetFlow(PASSWORD);
    await login(PASSWORD);
    check((await call("/me")).status === 200, "forgot password unlocks the login");
    await call("/logout", "POST");
  } finally {
    const [acc] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, adminEmail));
    await setPause("swapPaused", false);
    await db.delete(auditLogs).where(or(eq(auditLogs.targetId, testUserId), inArray(auditLogs.actorId, acc ? [acc.id] : ["none"])));
    await db.delete(users).where(eq(users.id, testUserId));
    if (acc) {
      await db.delete(adminSessions).where(eq(adminSessions.accountId, acc.id));
      await db.delete(adminResetTokens).where(eq(adminResetTokens.accountId, acc.id));
      await db.delete(adminAccounts).where(eq(adminAccounts.id, acc.id));
    }
    console.log("Cleaned up the test admin and test user");
  }
}

main()
  .then(() => {
    console.log("All admin checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF
cat > "backend/src/admin/actions.ts" <<'DOC_EOF'
// Things the admin can do from the dashboard. Each one is small, safe to
// repeat, and written to the audit log with the admin as the actor.
import { and, eq } from "drizzle-orm";
import { db } from "../db";
import { approvedDestinations, orders, payments, refunds, sessions, users } from "../db/schema";
import { reconcileOrder } from "../fulfilment/service";
import { advanceRefund, startRefund } from "../refunds/service";
import { setPause, type PauseKey } from "../settings";
import { adminAudit } from "./auth";

export class AdminActionError extends Error {
  constructor(message: string, public status: 400 | 404 | 409 = 400) {
    super(message);
  }
}

async function findOrder(key: string) {
  const [order] = await db.select().from(orders).where(eq(orders.id, key)).limit(1);
  if (order) return order;
  const [byRef] = await db.select().from(orders).where(eq(orders.reference, key.toUpperCase())).limit(1);
  if (!byRef) throw new AdminActionError("Order not found.", 404);
  return byRef;
}

async function statusOf(orderId: string): Promise<string> {
  const [o] = await db.select({ status: orders.status }).from(orders).where(eq(orders.id, orderId)).limit(1);
  return o?.status ?? "UNKNOWN";
}

// Ask VTpass about the order right now (normally the worker waits between checks).
export async function recheckOrder(adminId: string, key: string) {
  const order = await findOrder(key);
  if (order.status !== "FULFILMENT_PENDING" && order.status !== "FLAGGED") {
    throw new AdminActionError("This order is not waiting for VTpass.", 409);
  }
  await reconcileOrder(order.id, true);
  const after = await statusOf(order.id);
  await adminAudit("admin.order_recheck", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// Start or push a refund. A refund that failed 3 times gets a new attempt:
// Circle never sent it (each attempt has its own idempotency key), so this
// cannot pay twice.
export async function retryRefund(adminId: string, key: string) {
  const order = await findOrder(key);
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);

  if (order.status === "FAILED") {
    const [paid] = await db
      .select({ id: payments.id })
      .from(payments)
      .where(and(eq(payments.orderId, order.id), eq(payments.status, "CONFIRMED")))
      .limit(1);
    if (!paid) throw new AdminActionError("This order was never paid, so there is nothing to refund.", 409);
    await startRefund(order.id);
  } else if (order.status === "REFUND_PENDING") {
    await advanceRefund(order.id);
  } else if (order.status === "FLAGGED" && refund?.status === "FAILED") {
    const [reopened] = await db
      .update(refunds)
      .set({ status: "PENDING", attempt: refund.attempt + 1, circleTransactionId: null, lastError: "Retried by the admin" })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "FAILED")))
      .returning();
    if (!reopened) throw new AdminActionError("The refund changed in the meantime. Reload and try again.", 409);
    await db
      .update(orders)
      .set({ status: "REFUND_PENDING" })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FLAGGED")));
    await advanceRefund(order.id);
  } else {
    throw new AdminActionError("There is no refund to retry for this order.", 409);
  }
  const after = await statusOf(order.id);
  await adminAudit("admin.refund_retry", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// Suspended users cannot log in to anything new (orders, bridge, swaps).
// Their orders already in progress still finish, and refunds still go out.
export async function setUserStatus(adminId: string, userId: string, status: unknown, reason: unknown) {
  if (status !== "active" && status !== "suspended") throw new AdminActionError("Choose active or suspended.");
  const note = typeof reason === "string" ? reason.trim().slice(0, 300) : "";
  if (status === "suspended" && !note) throw new AdminActionError("Write a short reason for the suspension.");
  const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
  if (!user) throw new AdminActionError("User not found.", 404);
  if (user.status === status) return { status };
  await db.update(users).set({ status }).where(eq(users.id, userId));
  if (status === "suspended") await db.delete(sessions).where(eq(sessions.userId, userId));
  await adminAudit(
    status === "suspended" ? "admin.user_suspended" : "admin.user_restored",
    { email: user.email, reason: note || null },
    adminId,
    { type: "user", id: userId },
  );
  return { status };
}

export async function setProviderActive(adminId: string, id: string, active: unknown) {
  if (typeof active !== "boolean") throw new AdminActionError("Choose on or off.");
  const [row] = await db.update(approvedDestinations).set({ active }).where(eq(approvedDestinations.id, id)).returning();
  if (!row) throw new AdminActionError("Provider not found.", 404);
  await adminAudit(active ? "admin.provider_enabled" : "admin.provider_disabled", { label: row.label, chain: row.chain, address: row.address }, adminId, {
    type: "destination",
    id,
  });
  return { active };
}

export async function setPauseSwitch(adminId: string, key: PauseKey, paused: unknown) {
  if (typeof paused !== "boolean") throw new AdminActionError("Choose paused or open.");
  await setPause(key, paused);
  await adminAudit(paused ? "admin.paused" : "admin.resumed", { what: key }, adminId, { type: "setting", id: key });
  return { [key]: paused };
}
DOC_EOF
cat > "backend/src/admin/auth.ts" <<'DOC_EOF'
// Admin login for the dashboard.
//
// One admin only: the email in ADMIN_EMAIL. Logging in takes two steps:
//   1. email + password  -> a 6 digit code is emailed to ADMIN_EMAIL
//   2. the code          -> an admin session (8 hours, ends after 60 minutes idle)
//
// Safety:
//   - passwords are stored as scrypt hashes; session tokens, codes and reset
//     tokens only as hashes, so a copy of the database cannot be used to log in
//   - 5 wrong passwords lock the login for 15 minutes (and email the admin);
//     "Forgot password" unlocks it
//   - 5 wrong codes end that login attempt
//   - changing ADMIN_EMAIL on Render ends every session at once; the new
//     address sets its own password with "Forgot password"
//   - every login, lock and password change is emailed and written to the audit log
import { createHash, createHmac, randomBytes, randomInt, scrypt, timingSafeEqual } from "node:crypto";
import { and, eq, gte, isNull, lt, ne, or } from "drizzle-orm";
import { db } from "../db";
import { adminAccounts, adminResetTokens, adminSessions, auditLogs } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";

export type AdminAccount = typeof adminAccounts.$inferSelect;
export type AdminSession = typeof adminSessions.$inferSelect;
export type Meta = { ip: string; userAgent: string };

export const CODE_MINUTES = 10;
export const SESSION_HOURS = 8;
export const IDLE_MINUTES = 60;
const MAX_CODE_ATTEMPTS = 5;
const MAX_FAILED_PASSWORDS = 5;
const LOCK_MINUTES = 15;
const RESET_MINUTES = 30;
const RESETS_PER_HOUR = 3;
export const MIN_PASSWORD = 12;
const MAX_PASSWORD = 128;

export class AdminAuthError extends Error {
  constructor(message: string, public status: 400 | 401 | 423 | 429 | 502 | 503 = 400) {
    super(message);
  }
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------
const SCRYPT_N = 32768;

function scryptKey(password: string, salt: Buffer, n: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, 64, { N: n, r: 8, p: 1, maxmem: 128 * 1024 * 1024 }, (err, key) => (err ? reject(err) : resolve(key)));
  });
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scryptKey(password, salt, SCRYPT_N);
  return `scrypt$${SCRYPT_N}$${salt.toString("base64")}$${key.toString("base64")}`;
}

let dummyHash: string | null = null;

// Always does the same amount of work, so the answer time reveals nothing.
export async function verifyPassword(password: string, stored: string | null): Promise<boolean> {
  if (!stored) {
    dummyHash ??= await hashPassword("not-a-real-password-just-for-timing");
    await verifyPassword(password, dummyHash);
    return false;
  }
  const [kind, n, salt, key] = stored.split("$");
  if (kind !== "scrypt" || !n || !salt || !key) return false;
  const expected = Buffer.from(key, "base64");
  const actual = await scryptKey(password, Buffer.from(salt, "base64"), Number(n));
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");
const newToken = () => randomBytes(32).toString("base64url");
const codeHash = (sessionId: string, code: string) =>
  createHmac("sha256", env.BETTER_AUTH_SECRET).update(`admin-code:${sessionId}:${code}`).digest("hex");

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

export function checkNewPassword(password: unknown, email: string): string {
  if (typeof password !== "string" || password.length < MIN_PASSWORD) {
    throw new AdminAuthError(`Use at least ${MIN_PASSWORD} characters for the password.`);
  }
  if (password.length > MAX_PASSWORD) throw new AdminAuthError(`Use at most ${MAX_PASSWORD} characters.`);
  if (password.toLowerCase().includes(email.split("@")[0]!.toLowerCase())) {
    throw new AdminAuthError("The password must not contain your email name.");
  }
  if (new Set(password).size < 5) throw new AdminAuthError("That password is too simple. Mix more different characters.");
  return password;
}

// ---------------------------------------------------------------------------
// The account
// ---------------------------------------------------------------------------
const lagosTime = (d: Date) =>
  d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

function requireConfigured(): string {
  if (!env.ADMIN_EMAIL) throw new AdminAuthError("The admin login is not set up yet (ADMIN_EMAIL is missing on the server).", 503);
  return env.ADMIN_EMAIL;
}

async function currentAccount(): Promise<AdminAccount> {
  const email = requireConfigured();
  await db.insert(adminAccounts).values({ email }).onConflictDoNothing();
  const [account] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, email)).limit(1);
  if (!account) throw new AdminAuthError("Could not load the admin account.", 503);
  return account;
}

export async function adminAudit(action: string, details: Record<string, unknown>, accountId: string | null, target?: { type: string; id: string | null }) {
  await db.insert(auditLogs).values({
    actorType: "admin",
    actorId: accountId,
    action,
    targetType: target?.type ?? "admin",
    targetId: target?.id ?? null,
    details,
  });
}

type NoticeExtra = Omit<Parameters<typeof noticeEmail>[0], "subject" | "lines">;

async function notify(subject: string, lines: string[], extra: NoticeExtra = {}): Promise<void> {
  if (!env.ADMIN_EMAIL) return;
  await sendEmail({ to: env.ADMIN_EMAIL, ...noticeEmail({ subject, lines, ...extra }) });
}

function notifyQuietly(subject: string, lines: string[]) {
  void notify(subject, lines).catch((err) => console.error("[admin] notice email failed:", err instanceof Error ? err.message : err));
}

// ---------------------------------------------------------------------------
// Step 1: email and password
// ---------------------------------------------------------------------------
export async function startLogin(emailInput: unknown, passwordInput: unknown, meta: Meta): Promise<string> {
  const account = await currentAccount();
  const email = typeof emailInput === "string" ? emailInput.trim().toLowerCase() : "";
  const password = typeof passwordInput === "string" ? passwordInput.slice(0, MAX_PASSWORD) : "";
  const emailOk = email === account.email;

  if (account.lockedUntil && account.lockedUntil.getTime() > Date.now()) {
    await verifyPassword(password, null);
    throw new AdminAuthError(
      `Too many wrong passwords. The admin login is locked until ${lagosTime(account.lockedUntil)} (Lagos time). Use "Forgot password" to unlock it now.`,
      423,
    );
  }

  const passwordOk = await verifyPassword(password, emailOk ? account.passwordHash : null);
  if (!emailOk || !passwordOk) {
    if (emailOk) {
      const failed = account.failedAttempts + 1;
      if (failed >= MAX_FAILED_PASSWORDS) {
        const until = new Date(Date.now() + LOCK_MINUTES * 60_000);
        await db.update(adminAccounts).set({ failedAttempts: 0, lockedUntil: until }).where(eq(adminAccounts.id, account.id));
        await adminAudit("admin.locked", { ip: meta.ip, until: until.toISOString() }, account.id);
        notifyQuietly("dataonchain admin login locked", [
          `Someone entered the wrong admin password ${MAX_FAILED_PASSWORDS} times. The login is locked until ${lagosTime(until)} (Lagos time).`,
          `Last attempt from IP ${meta.ip}.`,
          'If this was not you, use "Forgot password" to set a new password. That also unlocks the login.',
        ]);
      } else {
        await db.update(adminAccounts).set({ failedAttempts: failed }).where(eq(adminAccounts.id, account.id));
      }
    }
    throw new AdminAuthError(
      account.passwordHash || !emailOk ? "Wrong email or password." : 'No password is set yet. Use "Forgot password" to set one.',
      401,
    );
  }

  await db.update(adminAccounts).set({ failedAttempts: 0 }).where(eq(adminAccounts.id, account.id));
  // Housekeeping: finished and unfinished logins that expired
  await db.delete(adminSessions).where(or(lt(adminSessions.expiresAt, new Date()), and(eq(adminSessions.accountId, account.id), eq(adminSessions.stage, "code"))));

  const token = newToken();
  const now = new Date();
  const [session] = await db
    .insert(adminSessions)
    .values({
      accountId: account.id,
      tokenHash: sha256(token),
      stage: "code",
      ipAddress: meta.ip,
      userAgent: meta.userAgent.slice(0, 300),
      expiresAt: new Date(now.getTime() + CODE_MINUTES * 60_000),
      lastSeenAt: now,
    })
    .returning();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  await db.update(adminSessions).set({ codeHash: codeHash(session!.id, code) }).where(eq(adminSessions.id, session!.id));
  try {
    await notify(
      "Your dataonchain admin login code",
      ["Enter this code on the admin dashboard to finish logging in:"],
      { code, footer: `The code expires in ${CODE_MINUTES} minutes. Login attempt from IP ${meta.ip}. If this was not you, change your password now.` },
    );
  } catch (err) {
    console.error("[admin] could not email the login code:", err instanceof Error ? err.message : err);
    await db.delete(adminSessions).where(eq(adminSessions.id, session!.id));
    throw new AdminAuthError("Could not send the login code email. Please try again.", 502);
  }
  return token;
}

// ---------------------------------------------------------------------------
// Step 2: the emailed code. Returns a fresh token for the real session.
// ---------------------------------------------------------------------------
export async function finishLogin(pendingToken: string | undefined, codeInput: unknown, meta: Meta): Promise<string> {
  const account = await currentAccount();
  const expired = new AdminAuthError("This login has expired. Please log in again.", 401);
  if (!pendingToken) throw expired;
  const [pending] = await db
    .select()
    .from(adminSessions)
    .where(and(eq(adminSessions.tokenHash, sha256(pendingToken)), eq(adminSessions.stage, "code")))
    .limit(1);
  if (!pending || pending.accountId !== account.id || pending.expiresAt.getTime() < Date.now() || !pending.codeHash) throw expired;

  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(pending.id, code), pending.codeHash)) {
    const attempts = pending.codeAttempts + 1;
    if (attempts >= MAX_CODE_ATTEMPTS) {
      await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
      await adminAudit("admin.code_failed", { ip: meta.ip }, account.id);
      throw new AdminAuthError("Too many wrong codes. Please log in again.", 401);
    }
    await db.update(adminSessions).set({ codeAttempts: attempts }).where(eq(adminSessions.id, pending.id));
    throw new AdminAuthError(`Wrong code. ${MAX_CODE_ATTEMPTS - attempts} tries left.`, 401);
  }

  // The pending login is used up; the real session gets a brand new token
  await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
  const token = newToken();
  const now = new Date();
  await db.insert(adminSessions).values({
    accountId: account.id,
    tokenHash: sha256(token),
    stage: "active",
    ipAddress: meta.ip,
    userAgent: meta.userAgent.slice(0, 300),
    expiresAt: new Date(now.getTime() + SESSION_HOURS * 60 * 60_000),
    lastSeenAt: now,
  });
  await db.update(adminAccounts).set({ lastLoginAt: now }).where(eq(adminAccounts.id, account.id));
  await adminAudit("admin.login", { ip: meta.ip, userAgent: meta.userAgent.slice(0, 200) }, account.id);
  notifyQuietly("New login to the dataonchain admin dashboard", [
    `You logged in to the admin dashboard on ${lagosTime(now)} (Lagos time).`,
    `IP: ${meta.ip}`,
    `Browser: ${meta.userAgent.slice(0, 160) || "unknown"}`,
    'If this was not you, change your password now. Changing it signs out every session.',
  ]);
  return token;
}

// ---------------------------------------------------------------------------
// Checking a session on every admin request
// ---------------------------------------------------------------------------
export async function readSession(token: string | undefined): Promise<{ account: AdminAccount; session: AdminSession } | null> {
  if (!token || !env.ADMIN_EMAIL) return null;
  const [row] = await db
    .select({ session: adminSessions, account: adminAccounts })
    .from(adminSessions)
    .innerJoin(adminAccounts, eq(adminSessions.accountId, adminAccounts.id))
    .where(and(eq(adminSessions.tokenHash, sha256(token)), eq(adminSessions.stage, "active")))
    .limit(1);
  if (!row) return null;
  const now = Date.now();
  const idle = now - row.session.lastSeenAt.getTime() > IDLE_MINUTES * 60_000;
  // A different ADMIN_EMAIL on the server ends old sessions
  if (row.account.email !== env.ADMIN_EMAIL || row.session.expiresAt.getTime() < now || idle) {
    await db.delete(adminSessions).where(eq(adminSessions.id, row.session.id));
    return null;
  }
  if (now - row.session.lastSeenAt.getTime() > 60_000) {
    await db.update(adminSessions).set({ lastSeenAt: new Date(now) }).where(eq(adminSessions.id, row.session.id));
  }
  return row;
}

export async function endSession(token: string | undefined): Promise<void> {
  if (!token) return;
  await db.delete(adminSessions).where(eq(adminSessions.tokenHash, sha256(token)));
}

export async function listSessions(accountId: string, currentId: string) {
  const rows = await db
    .select()
    .from(adminSessions)
    .where(and(eq(adminSessions.accountId, accountId), eq(adminSessions.stage, "active"), gte(adminSessions.expiresAt, new Date())));
  return rows.map((s) => ({
    id: s.id,
    current: s.id === currentId,
    ip: s.ipAddress,
    userAgent: s.userAgent,
    createdAt: s.createdAt.toISOString(),
    lastSeenAt: s.lastSeenAt.toISOString(),
  }));
}

export async function endOtherSessions(accountId: string, currentId: string): Promise<number> {
  const rows = await db
    .delete(adminSessions)
    .where(and(eq(adminSessions.accountId, accountId), ne(adminSessions.id, currentId)))
    .returning({ id: adminSessions.id });
  await adminAudit("admin.sessions_ended", { count: rows.length }, accountId);
  return rows.length;
}

// ---------------------------------------------------------------------------
// Forgot password: a link to ADMIN_EMAIL, valid 30 minutes, used once.
// Always answers the same way, whatever email was typed.
// ---------------------------------------------------------------------------
export async function requestReset(emailInput: unknown, meta: Meta): Promise<void> {
  const account = await currentAccount();
  const email = typeof emailInput === "string" ? emailInput.trim().toLowerCase() : "";
  if (email !== account.email) return;
  const recent = await db
    .select({ id: adminResetTokens.id })
    .from(adminResetTokens)
    .where(and(eq(adminResetTokens.accountId, account.id), gte(adminResetTokens.createdAt, new Date(Date.now() - 60 * 60_000))));
  if (recent.length >= RESETS_PER_HOUR) return;

  const token = newToken();
  await db.insert(adminResetTokens).values({
    accountId: account.id,
    tokenHash: sha256(token),
    expiresAt: new Date(Date.now() + RESET_MINUTES * 60_000),
    ipAddress: meta.ip,
  });
  await adminAudit("admin.reset_requested", { ip: meta.ip }, account.id);
  // The token is after "#", so it never reaches any server log
  const url = `${env.ADMIN_URL}/reset#token=${token}`;
  try {
    await notify(
      account.passwordHash ? "Reset your dataonchain admin password" : "Set your dataonchain admin password",
      [account.passwordHash ? "Someone asked to reset the admin dashboard password." : "Set the password for the admin dashboard."],
      {
        button: { label: account.passwordHash ? "Choose a new password" : "Set my password", url },
        footer: `The link works once and expires in ${RESET_MINUTES} minutes. Requested from IP ${meta.ip}. If this was not you, ignore this email: your password stays the same.`,
      },
    );
  } catch (err) {
    console.error("[admin] could not email the reset link:", err instanceof Error ? err.message : err);
  }
}

export async function resetPassword(tokenInput: unknown, passwordInput: unknown, meta: Meta): Promise<void> {
  const account = await currentAccount();
  const invalid = new AdminAuthError('This link is not valid any more. Use "Forgot password" to get a new one.', 400);
  if (typeof tokenInput !== "string" || tokenInput.length < 20) throw invalid;
  const password = checkNewPassword(passwordInput, account.email);
  const [row] = await db
    .select()
    .from(adminResetTokens)
    .where(and(eq(adminResetTokens.tokenHash, sha256(tokenInput)), isNull(adminResetTokens.usedAt)))
    .limit(1);
  if (!row || row.accountId !== account.id || row.expiresAt.getTime() < Date.now()) throw invalid;
  // Use the link up first, so it can never be used twice
  const [claimed] = await db
    .update(adminResetTokens)
    .set({ usedAt: new Date() })
    .where(and(eq(adminResetTokens.id, row.id), isNull(adminResetTokens.usedAt)))
    .returning();
  if (!claimed) throw invalid;

  await db
    .update(adminAccounts)
    .set({ passwordHash: await hashPassword(password), failedAttempts: 0, lockedUntil: null, passwordChangedAt: new Date() })
    .where(eq(adminAccounts.id, account.id));
  // Every other link and every session ends
  await db.update(adminResetTokens).set({ usedAt: new Date() }).where(and(eq(adminResetTokens.accountId, account.id), isNull(adminResetTokens.usedAt)));
  await db.delete(adminSessions).where(eq(adminSessions.accountId, account.id));
  await adminAudit("admin.password_reset", { ip: meta.ip }, account.id);
  notifyQuietly("Your dataonchain admin password was changed", [
    `The admin dashboard password was set on ${lagosTime(new Date())} (Lagos time), from IP ${meta.ip}.`,
    "Every admin session was signed out.",
    'If this was not you, use "Forgot password" right away and check who can read this mailbox.',
  ]);
}

export async function changePassword(account: AdminAccount, sessionId: string, currentInput: unknown, nextInput: unknown, meta: Meta): Promise<void> {
  const current = typeof currentInput === "string" ? currentInput.slice(0, MAX_PASSWORD) : "";
  if (!(await verifyPassword(current, account.passwordHash))) throw new AdminAuthError("Your current password is not right.", 401);
  const next = checkNewPassword(nextInput, account.email);
  if (next === current) throw new AdminAuthError("Choose a password different from the current one.");
  await db
    .update(adminAccounts)
    .set({ passwordHash: await hashPassword(next), passwordChangedAt: new Date() })
    .where(eq(adminAccounts.id, account.id));
  await db.delete(adminSessions).where(and(eq(adminSessions.accountId, account.id), ne(adminSessions.id, sessionId)));
  await adminAudit("admin.password_changed", { ip: meta.ip }, account.id);
  notifyQuietly("Your dataonchain admin password was changed", [
    `The admin dashboard password was changed on ${lagosTime(new Date())} (Lagos time), from IP ${meta.ip}.`,
    "Every other admin session was signed out.",
    'If this was not you, use "Forgot password" right away.',
  ]);
}
DOC_EOF
cat > "backend/src/admin/data.ts" <<'DOC_EOF'
// Read only views for the admin dashboard. Nothing here changes data.
import { and, count, desc, eq, gte, inArray, isNull, like, notInArray, or, sql, type SQL, type SQLWrapper } from "drizzle-orm";
import { db } from "../db";
import {
  ORDER_STATUSES,
  approvedDestinations,
  auditLogs,
  bridgeEvents,
  bridgeTransfers,
  dataPlans,
  exchangeRates,
  ledgerEntries,
  orders,
  payments,
  refunds,
  swaps,
  users,
  vtuTransactions,
  walletSweeps,
  wallets,
  BRIDGE_STATUSES,
  REFUND_STATUSES,
  SWAP_STATUSES,
} from "../db/schema";
import { env } from "../env";
import { bridgeChains, chainByKey, type BridgeChain } from "../bridge/chains";
import { findStuck } from "../bridge/monitor";
import { listChainWallets } from "../bridge/wallets";
import { tokenBalances } from "../swap/service";
import { getVtpassBalance } from "../vtpass/client";
import { getPauses } from "../settings";

export const PAGE_SIZE = 50;
const HOUR = 60 * 60_000;
const DAY = 24 * HOUR;

// Alerts on the overview when balances run low
const LOW_TREASURY_USDC = 5;
const LOW_VTPASS_NGN = 5_000;

export const OPEN_ORDER_STATUSES = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"] as const;
const OPEN_BRIDGE_STATUSES = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"] as const;

export function pageOf(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 && n < 100_000 ? n : 1;
}

export const usdcText = (micro: number) =>
  `${micro < 0 ? "-" : ""}${Math.floor(Math.abs(micro) / 1_000_000)}.${String(Math.abs(micro) % 1_000_000).padStart(6, "0")}`;
const iso = (d: Date | null | undefined) => (d ? d.toISOString() : null);
const arcTx = (hash: string | null | undefined) => (hash ? `${env.EXPLORER_TX_URL}${hash}` : null);
const arcAddress = (address: string) => `${env.EXPLORER_TX_URL.replace(/\/tx\/?$/, "/address/")}${address}`;
const localPhone = (phone: string) => (phone.startsWith("+234") ? `0${phone.slice(4)}` : phone);

function safeChain(key: string | null | undefined): BridgeChain | null {
  if (!key) return null;
  try {
    return chainByKey(key);
  } catch {
    return null;
  }
}

function withTimeout<T>(p: Promise<T>, ms = 8_000): Promise<T> {
  return Promise.race([p, new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), ms))]);
}

// Turns what the admin typed into a LIKE pattern. "08031234567" also finds "+2348031234567".
function searchTerms(q: string): string[] {
  const t = q.trim().slice(0, 100);
  const out = [`%${t}%`];
  if (/^0\d{6,}$/.test(t)) out.push(`%+234${t.slice(1)}%`);
  return out;
}

function sumSince(column: SQLWrapper, createdAt: SQLWrapper, since: number) {
  return sql<number>`coalesce(sum(case when ${createdAt} >= ${since} then ${column} else 0 end), 0)`.mapWith(Number);
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------
export async function overview() {
  const now = Date.now();
  const d1 = now - DAY;
  const d7 = now - 7 * DAY;
  const d30 = now - 30 * DAY;
  const one = sql`1`;

  const [u] = await db
    .select({
      total: count(),
      verified: sql<number>`coalesce(sum(case when ${users.emailVerified} = 1 then 1 else 0 end), 0)`.mapWith(Number),
      suspended: sql<number>`coalesce(sum(case when ${users.status} = 'suspended' then 1 else 0 end), 0)`.mapWith(Number),
      new1: sumSince(one, users.createdAt, d1),
      new7: sumSince(one, users.createdAt, d7),
      new30: sumSince(one, users.createdAt, d30),
    })
    .from(users);

  const [v] = await db
    .select({
      count: count(),
      usdc: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(${orders.ngnAmountKobo}), 0)`.mapWith(Number),
      margin: sql<number>`coalesce(sum(${orders.marginKobo}), 0)`.mapWith(Number),
      count1: sumSince(one, orders.createdAt, d1),
      count7: sumSince(one, orders.createdAt, d7),
      count30: sumSince(one, orders.createdAt, d30),
      usdc1: sumSince(orders.usdcAmountMicro, orders.createdAt, d1),
      usdc7: sumSince(orders.usdcAmountMicro, orders.createdAt, d7),
      usdc30: sumSince(orders.usdcAmountMicro, orders.createdAt, d30),
      ngn1: sumSince(orders.ngnAmountKobo, orders.createdAt, d1),
      ngn7: sumSince(orders.ngnAmountKobo, orders.createdAt, d7),
      ngn30: sumSince(orders.ngnAmountKobo, orders.createdAt, d30),
      margin30: sumSince(orders.marginKobo, orders.createdAt, d30),
    })
    .from(orders)
    .where(eq(orders.status, "FULFILLED"));

  const byStatus = await db
    .select({ status: orders.status, n: count() })
    .from(orders)
    .groupBy(orders.status);

  const refundRows = await db
    .select({ status: refunds.status, n: count(), micro: sql<number>`coalesce(sum(${refunds.amountMicro}), 0)`.mapWith(Number) })
    .from(refunds)
    .groupBy(refunds.status);

  const [b] = await db
    .select({
      complete: count(),
      micro: sql<number>`coalesce(sum(${bridgeTransfers.amountMicro}), 0)`.mapWith(Number),
      complete30: sumSince(one, bridgeTransfers.createdAt, d30),
      micro30: sumSince(bridgeTransfers.amountMicro, bridgeTransfers.createdAt, d30),
    })
    .from(bridgeTransfers)
    .where(eq(bridgeTransfers.status, "COMPLETE"));
  const [bOpen] = await db.select({ n: count() }).from(bridgeTransfers).where(inArray(bridgeTransfers.status, [...OPEN_BRIDGE_STATUSES]));
  let stuck = 0;
  try {
    stuck = (await findStuck()).length;
  } catch {
    stuck = 0;
  }

  const swapRows = await db.select().from(swaps).where(and(eq(swaps.status, "COMPLETE"), gte(swaps.createdAt, new Date(d30))));
  const swapFees: Record<string, number> = {};
  const swapVolume: Record<string, number> = {};
  for (const s of swapRows) {
    const amount = Number(s.amountIn);
    if (!Number.isFinite(amount)) continue;
    swapVolume[s.tokenIn] = (swapVolume[s.tokenIn] ?? 0) + amount;
    swapFees[s.tokenIn] = (swapFees[s.tokenIn] ?? 0) + (amount * s.feeBps) / 10_000;
  }
  const [sAll] = await db.select({ n: count() }).from(swaps).where(eq(swaps.status, "COMPLETE"));
  const [sUnknown] = await db.select({ n: count() }).from(swaps).where(eq(swaps.status, "UNKNOWN"));

  // Last 14 days, by Lagos date
  const since14 = now - 14 * DAY;
  const lagosDay = (col: SQLWrapper) => sql<string>`date(${col} / 1000 + 3600, 'unixepoch')`;
  const orderDays = await db
    .select({
      day: lagosDay(orders.createdAt),
      n: count(),
      usdc: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(${orders.ngnAmountKobo}), 0)`.mapWith(Number),
    })
    .from(orders)
    .where(and(eq(orders.status, "FULFILLED"), gte(orders.createdAt, new Date(since14))))
    .groupBy(lagosDay(orders.createdAt));
  const userDays = await db
    .select({ day: lagosDay(users.createdAt), n: count() })
    .from(users)
    .where(gte(users.createdAt, new Date(since14)))
    .groupBy(lagosDay(users.createdAt));
  const days = [];
  for (let i = 13; i >= 0; i--) {
    const day = new Date(now - i * DAY + HOUR).toISOString().slice(0, 10);
    const o = orderDays.find((r) => r.day === day);
    const n = userDays.find((r) => r.day === day);
    days.push({ day, orders: o?.n ?? 0, usdc: usdcText(o?.usdc ?? 0), ngn: (o?.ngn ?? 0) / 100, newUsers: n?.n ?? 0 });
  }

  // Live balances (slow services must not hold the page)
  const [treasury, vtpass] = await Promise.allSettled([
    withTimeout(tokenBalances(env.TREASURY_WALLET_ID)),
    withTimeout(getVtpassBalance()),
  ]);
  const treasuryBalances = treasury.status === "fulfilled" ? treasury.value : null;
  const vtpassBalance = vtpass.status === "fulfilled" ? vtpass.value : null;

  const statusCount = (s: string) => byStatus.find((r) => r.status === s)?.n ?? 0;
  const refundCount = (s: string) => refundRows.find((r) => r.status === s)?.n ?? 0;

  const issues: { text: string; href: string }[] = [];
  if (statusCount("FLAGGED")) issues.push({ text: `${statusCount("FLAGGED")} order(s) need review (flagged)`, href: "/orders?status=FLAGGED" });
  if (refundCount("FAILED")) issues.push({ text: `${refundCount("FAILED")} refund(s) failed and need a retry`, href: "/refunds?status=FAILED" });
  if (statusCount("REFUND_PENDING")) issues.push({ text: `${statusCount("REFUND_PENDING")} refund(s) in progress`, href: "/orders?status=REFUND_PENDING" });
  if (stuck) issues.push({ text: `${stuck} bridge transfer(s) stuck`, href: "/bridge?status=open" });
  if (sUnknown?.n) issues.push({ text: `${sUnknown.n} swap(s) interrupted, check onchain`, href: "/swaps?status=UNKNOWN" });
  if (treasuryBalances && Number(treasuryBalances.USDC) < LOW_TREASURY_USDC) {
    issues.push({ text: `Treasury is low: ${treasuryBalances.USDC} USDC (refunds need USDC)`, href: "/settings" });
  }
  if (treasury.status === "rejected") issues.push({ text: "Could not read the treasury balance from Circle", href: "/settings" });
  if (vtpassBalance !== null && vtpassBalance < LOW_VTPASS_NGN) {
    issues.push({ text: `VTpass wallet is low: ₦${vtpassBalance.toLocaleString("en-NG")}`, href: "/settings" });
  }
  if (vtpass.status === "rejected") issues.push({ text: "Could not read the VTpass balance", href: "/settings" });

  return {
    generatedAt: new Date().toISOString(),
    testnet: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET"),
    vtpassSandbox: env.VTPASS_BASE_URL.includes("sandbox"),
    pauses: await getPauses(),
    users: { total: u?.total ?? 0, verified: u?.verified ?? 0, suspended: u?.suspended ?? 0, new1: u?.new1 ?? 0, new7: u?.new7 ?? 0, new30: u?.new30 ?? 0 },
    volume: {
      orders: { all: v?.count ?? 0, d1: v?.count1 ?? 0, d7: v?.count7 ?? 0, d30: v?.count30 ?? 0 },
      usdc: { all: usdcText(v?.usdc ?? 0), d1: usdcText(v?.usdc1 ?? 0), d7: usdcText(v?.usdc7 ?? 0), d30: usdcText(v?.usdc30 ?? 0) },
      ngn: { all: (v?.ngn ?? 0) / 100, d1: (v?.ngn1 ?? 0) / 100, d7: (v?.ngn7 ?? 0) / 100, d30: (v?.ngn30 ?? 0) / 100 },
      marginNgn: { all: (v?.margin ?? 0) / 100, d30: (v?.margin30 ?? 0) / 100 },
    },
    ordersByStatus: Object.fromEntries(byStatus.map((r) => [r.status, r.n])),
    refunds: Object.fromEntries(refundRows.map((r) => [r.status, { count: r.n, usdc: usdcText(r.micro) }])),
    bridge: {
      enabled: env.BRIDGE_ENABLED,
      complete: b?.complete ?? 0,
      usdc: usdcText(b?.micro ?? 0),
      complete30: b?.complete30 ?? 0,
      usdc30: usdcText(b?.micro30 ?? 0),
      open: bOpen?.n ?? 0,
      stuck,
    },
    swaps: { enabled: env.SWAP_ENABLED, complete: sAll?.n ?? 0, complete30: swapRows.length, volume30: swapVolume, fees30: swapFees, unknown: sUnknown?.n ?? 0 },
    balances: {
      treasuryAddress: env.TREASURY_ADDRESS,
      treasuryUrl: arcAddress(env.TREASURY_ADDRESS),
      treasury: treasuryBalances,
      vtpassNgn: vtpassBalance,
    },
    days,
    issues,
  };
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------
export async function listUsers(q: string | undefined, status: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (q?.trim()) {
    const terms = searchTerms(q);
    conds.push(or(eq(users.id, q.trim()), ...terms.flatMap((t) => [like(users.email, t), like(users.name, t), like(users.phone, t)])));
  }
  if (status === "active" || status === "suspended") conds.push(eq(users.status, status));
  if (status === "unverified") conds.push(eq(users.emailVerified, false));
  const where = conds.length ? and(...conds) : undefined;

  const [total] = await db.select({ n: count() }).from(users).where(where);
  const rows = await db
    .select()
    .from(users)
    .where(where)
    .orderBy(desc(users.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  const ids = rows.map((r) => r.id);
  const stats = ids.length
    ? await db
        .select({
          userId: orders.userId,
          n: count(),
          micro: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.usdcAmountMicro} else 0 end), 0)`.mapWith(Number),
          last: sql<number>`max(${orders.createdAt})`.mapWith(Number),
        })
        .from(orders)
        .where(and(inArray(orders.userId, ids), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
        .groupBy(orders.userId)
    : [];
  const arc = ids.length
    ? await db
        .select({ userId: wallets.userId, address: wallets.address })
        .from(wallets)
        .where(and(inArray(wallets.userId, ids), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN), eq(wallets.accountType, "SCA"), isNull(wallets.retiredAt)))
    : [];

  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    users: rows.map((r) => {
      const s = stats.find((x) => x.userId === r.id);
      return {
        id: r.id,
        name: r.name,
        email: r.email,
        phone: r.phone ? localPhone(r.phone) : null,
        emailVerified: r.emailVerified,
        status: r.status,
        createdAt: r.createdAt.toISOString(),
        orders: s?.n ?? 0,
        spentUsdc: usdcText(s?.micro ?? 0),
        lastOrderAt: s?.last ? new Date(s.last).toISOString() : null,
        walletAddress: arc.find((w) => w.userId === r.id)?.address ?? null,
      };
    }),
  };
}

export async function getUser(id: string) {
  const [user] = await db.select().from(users).where(eq(users.id, id)).limit(1);
  if (!user) return null;

  const walletRows = await db.select().from(wallets).where(eq(wallets.userId, id)).orderBy(desc(wallets.createdAt));
  const arc = walletRows.find((w) => w.blockchain === env.CIRCLE_BLOCKCHAIN && w.accountType === "SCA" && !w.retiredAt);
  let balances: Record<string, string> | null = null;
  if (arc) {
    try {
      balances = await withTimeout(tokenBalances(arc.circleWalletId));
    } catch {
      balances = null;
    }
  }
  let otherChains: { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null }[] = [];
  if (env.BRIDGE_ENABLED) {
    try {
      otherChains = (await withTimeout(listChainWallets(id), 15_000)).map((w) => ({
        chain: w.chain,
        chainLabel: w.chainLabel,
        address: w.address,
        explorerUrl: w.explorerUrl,
        balance: w.balanceMicro === null ? null : usdcText(w.balanceMicro),
      }));
    } catch {
      otherChains = [];
    }
  }

  const orderRows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.userId, id), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(50);
  const [totals] = await db
    .select({
      n: count(),
      micro: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.usdcAmountMicro} else 0 end), 0)`.mapWith(Number),
      ngn: sql<number>`coalesce(sum(case when ${orders.status} = 'FULFILLED' then ${orders.ngnAmountKobo} else 0 end), 0)`.mapWith(Number),
    })
    .from(orders)
    .where(and(eq(orders.userId, id), notInArray(orders.status, ["QUOTED", "EXPIRED"])));
  const bridgeRows = await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.userId, id)).orderBy(desc(bridgeTransfers.createdAt)).limit(20);
  const swapRows = await db.select().from(swaps).where(eq(swaps.userId, id)).orderBy(desc(swaps.createdAt)).limit(20);
  const sweepRows = await db.select().from(walletSweeps).where(eq(walletSweeps.userId, id)).orderBy(desc(walletSweeps.createdAt)).limit(10);
  const activity = await db
    .select()
    .from(auditLogs)
    .where(and(eq(auditLogs.targetType, "user"), eq(auditLogs.targetId, id)))
    .orderBy(desc(auditLogs.createdAt))
    .limit(30);

  return {
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      phone: user.phone ? localPhone(user.phone) : null,
      emailVerified: user.emailVerified,
      status: user.status,
      createdAt: user.createdAt.toISOString(),
    },
    totals: { orders: totals?.n ?? 0, spentUsdc: usdcText(totals?.micro ?? 0), spentNgn: (totals?.ngn ?? 0) / 100 },
    arcWallet: arc ? { address: arc.address, explorerUrl: arcAddress(arc.address), balances } : null,
    wallets: walletRows.map((w) => ({
      address: w.address,
      blockchain: w.blockchain,
      accountType: w.accountType,
      retiredAt: iso(w.retiredAt),
      createdAt: w.createdAt.toISOString(),
    })),
    otherChains,
    orders: orderRows.map(({ order, planName }) => ({
      id: order.id,
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      createdAt: order.createdAt.toISOString(),
    })),
    bridges: bridgeRows.map(bridgeRow),
    swaps: swapRows.map(swapRow),
    sweeps: sweepRows.map((s) => ({
      id: s.id,
      status: s.status,
      amount: usdcText(s.amountMicro),
      toAddress: s.toAddress,
      txUrl: arcTx(s.txHash),
      createdAt: s.createdAt.toISOString(),
    })),
    activity: activity.map(activityRow),
  };
}

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------
export async function listOrders(status: string | undefined, q: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (status === "open") conds.push(inArray(orders.status, [...OPEN_ORDER_STATUSES]));
  else if (status && (ORDER_STATUSES as readonly string[]).includes(status)) conds.push(eq(orders.status, status as (typeof ORDER_STATUSES)[number]));
  else if (status !== "all") conds.push(notInArray(orders.status, ["QUOTED", "EXPIRED"]));
  if (q?.trim()) {
    const terms = searchTerms(q);
    conds.push(or(eq(orders.reference, q.trim().toUpperCase()), ...terms.flatMap((t) => [like(orders.reference, t), like(orders.phone, t), like(users.email, t)])));
  }
  const where = conds.length ? and(...conds) : undefined;
  const [total] = await db.select({ n: count() }).from(orders).innerJoin(users, eq(orders.userId, users.id)).where(where);
  const rows = await db
    .select({ order: orders, email: users.email, planName: dataPlans.name })
    .from(orders)
    .innerJoin(users, eq(orders.userId, users.id))
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(where)
    .orderBy(desc(orders.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    orders: rows.map(({ order, email, planName }) => ({
      id: order.id,
      reference: order.reference,
      status: order.status,
      userId: order.userId,
      email,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      failureReason: order.failureReason,
      createdAt: order.createdAt.toISOString(),
    })),
  };
}

export async function getOrder(key: string) {
  const [row] = await db
    .select({ order: orders, user: users, planName: dataPlans.name, rate: exchangeRates.koboPerUsdc, rateSource: exchangeRates.source })
    .from(orders)
    .innerJoin(users, eq(orders.userId, users.id))
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .leftJoin(exchangeRates, eq(orders.exchangeRateId, exchangeRates.id))
    .where(or(eq(orders.id, key), eq(orders.reference, key.toUpperCase())))
    .limit(1);
  if (!row) return null;
  const { order, user } = row;
  const paymentRows = await db.select().from(payments).where(eq(payments.orderId, order.id)).orderBy(desc(payments.createdAt));
  const vtuRows = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, order.id)).orderBy(desc(vtuTransactions.createdAt));
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  const ledger = await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, order.id)).orderBy(ledgerEntries.createdAt);
  const activity = await db
    .select()
    .from(auditLogs)
    .where(and(eq(auditLogs.targetType, "order"), eq(auditLogs.targetId, order.id)))
    .orderBy(desc(auditLogs.createdAt))
    .limit(50);

  const confirmedPayment = paymentRows.some((p) => p.status === "CONFIRMED");
  const openVtu = vtuRows.some((t) => ["SENT", "PENDING", "UNKNOWN"].includes(t.status));
  return {
    order: {
      id: order.id,
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: row.planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      marginNgn: order.marginKobo / 100,
      usdcAmount: usdcText(order.usdcAmountMicro),
      rateNgnPerUsdc: row.rate ? row.rate / 100 : null,
      rateSource: row.rateSource ?? null,
      failureReason: order.failureReason,
      quoteExpiresAt: order.quoteExpiresAt.toISOString(),
      createdAt: order.createdAt.toISOString(),
      updatedAt: order.updatedAt.toISOString(),
    },
    user: { id: user.id, name: user.name, email: user.email, status: user.status },
    payments: paymentRows.map((p) => ({
      id: p.id,
      status: p.status,
      amount: usdcText(p.amountMicro),
      fromAddress: p.fromAddress,
      toAddress: p.toAddress,
      txHash: p.txHash,
      txUrl: arcTx(p.txHash),
      circleTransactionId: p.circleTransactionId,
      confirmedAt: iso(p.confirmedAt),
      createdAt: p.createdAt.toISOString(),
    })),
    deliveries: vtuRows.map((t) => ({
      id: t.id,
      provider: t.provider,
      requestId: t.requestId,
      providerReference: t.providerReference,
      attempt: t.attempt,
      status: t.status,
      request: t.requestPayload,
      response: t.responsePayload,
      createdAt: t.createdAt.toISOString(),
      updatedAt: t.updatedAt.toISOString(),
    })),
    refund: refund
      ? {
          status: refund.status,
          amount: usdcText(refund.amountMicro),
          toAddress: refund.toAddress,
          attempt: refund.attempt,
          txHash: refund.txHash,
          txUrl: arcTx(refund.txHash),
          lastError: refund.lastError,
          confirmedAt: iso(refund.confirmedAt),
          createdAt: refund.createdAt.toISOString(),
        }
      : null,
    ledger: ledger.map((l) => ({
      account: l.account,
      currency: l.currency,
      debit: l.currency === "USDC" ? usdcText(l.debit) : String(l.debit / 100),
      credit: l.currency === "USDC" ? usdcText(l.credit) : String(l.credit / 100),
      memo: l.memo,
      createdAt: l.createdAt.toISOString(),
    })),
    activity: activity.map(activityRow),
    actions: {
      requery: ["FULFILMENT_PENDING", "FLAGGED"].includes(order.status) && openVtu,
      retryRefund:
        (order.status === "FAILED" && confirmedPayment) ||
        order.status === "REFUND_PENDING" ||
        (order.status === "FLAGGED" && refund?.status === "FAILED"),
    },
  };
}

// ---------------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------------
export async function listRefunds(status: string | undefined, page: number) {
  const where = status && (REFUND_STATUSES as readonly string[]).includes(status) ? eq(refunds.status, status as (typeof REFUND_STATUSES)[number]) : undefined;
  const [total] = await db.select({ n: count() }).from(refunds).where(where);
  const rows = await db
    .select({ refund: refunds, reference: orders.reference, orderId: orders.id, orderStatus: orders.status, email: users.email, userId: users.id })
    .from(refunds)
    .innerJoin(orders, eq(refunds.orderId, orders.id))
    .innerJoin(users, eq(orders.userId, users.id))
    .where(where)
    .orderBy(desc(refunds.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    refunds: rows.map(({ refund, reference, orderId, orderStatus, email, userId }) => ({
      id: refund.id,
      status: refund.status,
      amount: usdcText(refund.amountMicro),
      attempt: refund.attempt,
      lastError: refund.lastError,
      txUrl: arcTx(refund.txHash),
      reference,
      orderId,
      orderStatus,
      email,
      userId,
      createdAt: refund.createdAt.toISOString(),
      confirmedAt: iso(refund.confirmedAt),
    })),
  };
}

// ---------------------------------------------------------------------------
// Bridge transfers
// ---------------------------------------------------------------------------
function bridgeRow(t: typeof bridgeTransfers.$inferSelect) {
  return {
    id: t.id,
    direction: t.direction,
    status: t.status,
    from: safeChain(t.sourceChain)?.label ?? t.sourceChain,
    to: safeChain(t.destinationChain)?.label ?? t.destinationChain,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    maxFee: t.maxFeeMicro === null ? null : usdcText(t.maxFeeMicro),
    failureReason: t.failureReason,
    createdAt: t.createdAt.toISOString(),
    updatedAt: t.updatedAt.toISOString(),
  };
}

export async function listBridge(status: string | undefined, q: string | undefined, page: number) {
  const conds: (SQL | undefined)[] = [];
  if (status === "open") conds.push(inArray(bridgeTransfers.status, [...OPEN_BRIDGE_STATUSES]));
  else if (status && (BRIDGE_STATUSES as readonly string[]).includes(status)) conds.push(eq(bridgeTransfers.status, status as (typeof BRIDGE_STATUSES)[number]));
  if (q?.trim()) {
    const t = `%${q.trim().slice(0, 100)}%`;
    conds.push(or(eq(bridgeTransfers.id, q.trim()), like(users.email, t), like(bridgeTransfers.recipientAddress, t)));
  }
  const where = conds.length ? and(...conds) : undefined;
  const [total] = await db.select({ n: count() }).from(bridgeTransfers).leftJoin(users, eq(bridgeTransfers.userId, users.id)).where(where);
  const rows = await db
    .select({ t: bridgeTransfers, email: users.email })
    .from(bridgeTransfers)
    .leftJoin(users, eq(bridgeTransfers.userId, users.id))
    .where(where)
    .orderBy(desc(bridgeTransfers.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    transfers: rows.map(({ t, email }) => ({ ...bridgeRow(t), userId: t.userId, email: email ?? null })),
  };
}

export async function getBridge(id: string) {
  const [row] = await db
    .select({ t: bridgeTransfers, email: users.email })
    .from(bridgeTransfers)
    .leftJoin(users, eq(bridgeTransfers.userId, users.id))
    .where(eq(bridgeTransfers.id, id))
    .limit(1);
  if (!row) return null;
  const { t } = row;
  const events = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(bridgeEvents.createdAt);
  const destination = safeChain(t.destinationChain);
  return {
    transfer: {
      ...bridgeRow(t),
      userId: t.userId,
      email: row.email ?? null,
      depositorAddress: t.depositorAddress,
      forwardingFee: t.forwardingFeeMicro === null ? null : usdcText(t.forwardingFeeMicro),
      gatewayTransferId: t.gatewayTransferId,
      mintTxHash: t.mintTxHash,
      mintUrl: destination && t.mintTxHash ? `${destination.explorerTx}${t.mintTxHash}` : null,
    },
    events: events.map((e) => {
      const chain = safeChain(e.chain);
      return {
        step: e.step,
        chain: chain?.label ?? e.chain,
        txHash: e.txHash,
        txUrl: chain && e.txHash ? `${chain.explorerTx}${e.txHash}` : null,
        details: e.details,
        at: e.createdAt.toISOString(),
      };
    }),
  };
}

// ---------------------------------------------------------------------------
// Swaps
// ---------------------------------------------------------------------------
function swapRow(s: typeof swaps.$inferSelect) {
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
    txUrl: arcTx(s.txHash),
    error: s.error,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSwapsAdmin(status: string | undefined, page: number) {
  const where = status && (SWAP_STATUSES as readonly string[]).includes(status) ? eq(swaps.status, status as (typeof SWAP_STATUSES)[number]) : undefined;
  const [total] = await db.select({ n: count() }).from(swaps).where(where);
  const rows = await db
    .select({ s: swaps, email: users.email })
    .from(swaps)
    .innerJoin(users, eq(swaps.userId, users.id))
    .where(where)
    .orderBy(desc(swaps.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    swaps: rows.map(({ s, email }) => ({ ...swapRow(s), userId: s.userId, email })),
  };
}

// ---------------------------------------------------------------------------
// Providers (approved bridge destinations)
// ---------------------------------------------------------------------------
export async function listProviders() {
  const rows = await db.select().from(approvedDestinations).orderBy(desc(approvedDestinations.createdAt));
  return rows.map((d) => {
    const chain = safeChain(d.chain);
    return {
      id: d.id,
      label: d.label,
      chain: chain?.label ?? d.chain,
      address: d.address,
      explorerUrl: chain ? `${chain.explorerTx.replace(/\/tx\/?$/, "/address/")}${d.address}` : null,
      active: d.active,
      note: d.note,
      createdAt: d.createdAt.toISOString(),
    };
  });
}

// ---------------------------------------------------------------------------
// Activity (audit log)
// ---------------------------------------------------------------------------
function activityRow(a: typeof auditLogs.$inferSelect) {
  return {
    id: a.id,
    actorType: a.actorType,
    action: a.action,
    targetType: a.targetType,
    targetId: a.targetId,
    details: a.details,
    at: a.createdAt.toISOString(),
  };
}

export async function listActivity(actor: string | undefined, page: number) {
  const where = actor === "admin" || actor === "system" || actor === "user" ? eq(auditLogs.actorType, actor) : undefined;
  const [total] = await db.select({ n: count() }).from(auditLogs).where(where);
  const rows = await db
    .select()
    .from(auditLogs)
    .where(where)
    .orderBy(desc(auditLogs.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return { total: total?.n ?? 0, page, pageSize: PAGE_SIZE, activity: rows.map(activityRow) };
}

// ---------------------------------------------------------------------------
// Settings page: switches and the server's current (non secret) setup
// ---------------------------------------------------------------------------
export async function settingsView() {
  return {
    pauses: await getPauses(),
    setup: {
      network: env.CIRCLE_BLOCKCHAIN,
      testnet: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET"),
      vtpass: env.VTPASS_BASE_URL.includes("sandbox") ? "sandbox" : "live",
      pricingMarginPercent: env.PRICING_MARGIN_BPS / 100,
      quoteMinutes: env.QUOTE_TTL_MINUTES,
      fixedRate: env.NGN_PER_USDC ?? null,
      treasuryAddress: env.TREASURY_ADDRESS,
      treasuryUrl: arcAddress(env.TREASURY_ADDRESS),
      bridgeEnabled: env.BRIDGE_ENABLED,
      bridgeLimits: { min: env.BRIDGE_MIN_USDC, max: env.BRIDGE_MAX_USDC, daily: env.BRIDGE_DAILY_USDC, maxFee: env.BRIDGE_MAX_FEE_USDC },
      bridgeChains: env.BRIDGE_ENABLED ? bridgeChains().map((c) => c.label) : [],
      swapEnabled: env.SWAP_ENABLED,
      swapFeePercent: env.SWAP_FEE_BPS / 100,
      swapSlippagePercent: env.SWAP_SLIPPAGE_BPS / 100,
      swapDailyCount: env.SWAP_DAILY_COUNT,
      alertEmail: Boolean(env.ALERT_EMAIL),
      worker: env.WORKER_ENABLED,
    },
  };
}
DOC_EOF
cat > "backend/src/admin/routes.ts" <<'DOC_EOF'
// Admin API, mounted at /api/admin. Used only by the admin dashboard website,
// which passes /api/* through to this server, so the cookies belong to the
// dashboard's own address.
//
//   - session cookie: HttpOnly, Secure (in production), SameSite=Strict
//   - every change (POST) must carry the header X-Admin-Request: 1, which a
//     form on another website cannot send
//   - answers are never cached
//   - too many login, code or reset requests from one IP are refused for a while
import { Hono, type Context } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { createMiddleware } from "hono/factory";
import { env } from "../env";
import { isPauseKey } from "../settings";
import { AdminActionError, recheckOrder, retryRefund, setPauseSwitch, setProviderActive, setUserStatus } from "./actions";
import {
  AdminAuthError,
  CODE_MINUTES,
  IDLE_MINUTES,
  MIN_PASSWORD,
  SESSION_HOURS,
  changePassword,
  endOtherSessions,
  endSession,
  finishLogin,
  listSessions,
  readSession,
  requestReset,
  resetPassword,
  startLogin,
  type AdminAccount,
  type AdminSession,
  type Meta,
} from "./auth";
import {
  getBridge,
  getOrder,
  getUser,
  listActivity,
  listBridge,
  listOrders,
  listProviders,
  listRefunds,
  listSwapsAdmin,
  listUsers,
  overview,
  pageOf,
  settingsView,
} from "./data";

type Vars = { Variables: { admin: { account: AdminAccount; session: AdminSession } } };

const SESSION_COOKIE = "doc_admin";
const PENDING_COOKIE = "doc_admin_pending";
const secure = env.NODE_ENV === "production";

export const adminApp = new Hono<Vars>();

function meta(c: Context): Meta {
  const forwarded = c.req.header("x-forwarded-for")?.split(",")[0]?.trim();
  return { ip: forwarded || c.req.header("x-real-ip") || "unknown", userAgent: c.req.header("user-agent") ?? "" };
}

function setSessionCookie(c: Context, name: string, value: string, maxAgeSeconds: number) {
  setCookie(c, name, value, { path: "/", httpOnly: true, secure, sameSite: "Strict", maxAge: maxAgeSeconds });
}

function clearCookies(c: Context) {
  deleteCookie(c, SESSION_COOKIE, { path: "/", secure });
  deleteCookie(c, PENDING_COOKIE, { path: "/", secure });
}

// Simple per IP limit for the login, code and reset routes (kept in memory)
const hits = new Map<string, { count: number; resetAt: number }>();
function tooMany(c: Context, bucket: string, limit: number, windowMinutes: number): boolean {
  const key = `${bucket}:${meta(c).ip}`;
  const now = Date.now();
  const entry = hits.get(key);
  if (!entry || entry.resetAt < now) {
    hits.set(key, { count: 1, resetAt: now + windowMinutes * 60_000 });
    if (hits.size > 5_000) for (const [k, v] of hits) if (v.resetAt < now) hits.delete(k);
    return false;
  }
  entry.count += 1;
  return entry.count > limit;
}

function fail(c: Context, err: unknown) {
  if (err instanceof AdminAuthError || err instanceof AdminActionError) return c.json({ error: err.message }, err.status);
  throw err;
}

async function body(c: Context): Promise<Record<string, unknown>> {
  const b = await c.req.json().catch(() => null);
  return b && typeof b === "object" ? (b as Record<string, unknown>) : {};
}

adminApp.use("*", async (c, next) => {
  if (c.req.method !== "GET" && c.req.header("x-admin-request") !== "1") {
    return c.json({ error: "Bad request" }, 400);
  }
  await next();
  c.header("Cache-Control", "no-store");
  c.header("X-Robots-Tag", "noindex, nofollow");
});

const requireAdmin = createMiddleware<Vars>(async (c, next) => {
  const found = await readSession(getCookie(c, SESSION_COOKIE));
  if (!found) {
    deleteCookie(c, SESSION_COOKIE, { path: "/", secure });
    return c.json({ error: "Please log in" }, 401);
  }
  c.set("admin", found);
  await next();
});

// ---------------------------------------------------------------------------
// Logging in and out, passwords
// ---------------------------------------------------------------------------
adminApp.get("/config", (c) =>
  c.json({ configured: Boolean(env.ADMIN_EMAIL), minPassword: MIN_PASSWORD, codeMinutes: CODE_MINUTES, idleMinutes: IDLE_MINUTES, sessionHours: SESSION_HOURS }),
);

adminApp.post("/login", async (c) => {
  if (tooMany(c, "login", 20, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    const token = await startLogin(b.email, b.password, meta(c));
    setSessionCookie(c, PENDING_COOKIE, token, CODE_MINUTES * 60);
    return c.json({ step: "code" });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/login/code", async (c) => {
  if (tooMany(c, "code", 30, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    const token = await finishLogin(getCookie(c, PENDING_COOKIE), b.code, meta(c));
    deleteCookie(c, PENDING_COOKIE, { path: "/", secure });
    setSessionCookie(c, SESSION_COOKIE, token, SESSION_HOURS * 60 * 60);
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/logout", async (c) => {
  await endSession(getCookie(c, SESSION_COOKIE));
  clearCookies(c);
  return c.json({ ok: true });
});

adminApp.post("/forgot", async (c) => {
  if (tooMany(c, "forgot", 5, 60)) return c.json({ error: "Too many requests. Please wait an hour." }, 429);
  const b = await body(c);
  try {
    await requestReset(b.email, meta(c));
  } catch (err) {
    return fail(c, err);
  }
  return c.json({ ok: true, message: "If that is the admin email, a link is on its way. It expires in 30 minutes." });
});

adminApp.post("/reset", async (c) => {
  if (tooMany(c, "reset", 10, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    await resetPassword(b.token, b.password, meta(c));
    clearCookies(c);
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.get("/me", requireAdmin, (c) => {
  const { account, session } = c.get("admin");
  return c.json({
    email: account.email,
    lastLoginAt: account.lastLoginAt?.toISOString() ?? null,
    passwordChangedAt: account.passwordChangedAt?.toISOString() ?? null,
    sessionExpiresAt: session.expiresAt.toISOString(),
    idleMinutes: IDLE_MINUTES,
  });
});

adminApp.post("/password", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  const b = await body(c);
  try {
    await changePassword(account, session.id, b.current, b.next, meta(c));
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.get("/sessions", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  return c.json({ sessions: await listSessions(account.id, session.id) });
});

adminApp.post("/sessions/end-others", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  return c.json({ ended: await endOtherSessions(account.id, session.id) });
});

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------
adminApp.get("/overview", requireAdmin, async (c) => c.json(await overview()));

adminApp.get("/users", requireAdmin, async (c) =>
  c.json(await listUsers(c.req.query("q"), c.req.query("status"), pageOf(c.req.query("page")))),
);

adminApp.get("/users/:id", requireAdmin, async (c) => {
  const user = await getUser(c.req.param("id"));
  if (!user) return c.json({ error: "User not found" }, 404);
  return c.json(user);
});

adminApp.get("/orders", requireAdmin, async (c) =>
  c.json(await listOrders(c.req.query("status"), c.req.query("q"), pageOf(c.req.query("page")))),
);

adminApp.get("/orders/:key", requireAdmin, async (c) => {
  const order = await getOrder(c.req.param("key"));
  if (!order) return c.json({ error: "Order not found" }, 404);
  return c.json(order);
});

adminApp.get("/refunds", requireAdmin, async (c) => c.json(await listRefunds(c.req.query("status"), pageOf(c.req.query("page")))));

adminApp.get("/bridge", requireAdmin, async (c) =>
  c.json(await listBridge(c.req.query("status"), c.req.query("q"), pageOf(c.req.query("page")))),
);

adminApp.get("/bridge/:id", requireAdmin, async (c) => {
  const transfer = await getBridge(c.req.param("id"));
  if (!transfer) return c.json({ error: "Transfer not found" }, 404);
  return c.json(transfer);
});

adminApp.get("/swaps", requireAdmin, async (c) => c.json(await listSwapsAdmin(c.req.query("status"), pageOf(c.req.query("page")))));

adminApp.get("/providers", requireAdmin, async (c) => c.json({ providers: await listProviders() }));

adminApp.get("/activity", requireAdmin, async (c) => c.json(await listActivity(c.req.query("actor"), pageOf(c.req.query("page")))));

adminApp.get("/settings", requireAdmin, async (c) => c.json(await settingsView()));

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
adminApp.post("/orders/:key/recheck", requireAdmin, async (c) => {
  try {
    return c.json(await recheckOrder(c.get("admin").account.id, c.req.param("key")));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/orders/:key/refund", requireAdmin, async (c) => {
  try {
    return c.json(await retryRefund(c.get("admin").account.id, c.req.param("key")));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/users/:id/status", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await setUserStatus(c.get("admin").account.id, c.req.param("id"), b.status, b.reason));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/providers/:id", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await setProviderActive(c.get("admin").account.id, c.req.param("id"), b.active));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/settings/pause", requireAdmin, async (c) => {
  const b = await body(c);
  if (!isPauseKey(b.key)) return c.json({ error: "Unknown switch" }, 400);
  try {
    return c.json(await setPauseSwitch(c.get("admin").account.id, b.key, b.paused));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.notFound((c) => c.json({ error: "Not found" }, 404));
DOC_EOF
cat > "backend/src/settings.ts" <<'DOC_EOF'
// Switches the admin can flip from the dashboard, without a redeploy.
// Pausing only stops NEW purchases, transfers or swaps. Anything already
// started (payments, deliveries, refunds, bridge transfers) keeps going.
import { db } from "./db";
import { appSettings } from "./db/schema";

export const PAUSE_KEYS = ["purchasesPaused", "bridgePaused", "swapPaused"] as const;
export type PauseKey = (typeof PAUSE_KEYS)[number];
export type Pauses = Record<PauseKey, boolean>;

export const PAUSE_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data is paused for a short maintenance. Please try again later.",
  bridgePaused: "Sending to other networks is paused for a short maintenance. Please try again later.",
  swapPaused: "Swaps are paused for a short maintenance. Please try again later.",
};

const CACHE_MS = 10_000;
let cache: { at: number; value: Pauses } | null = null;

export function isPauseKey(value: unknown): value is PauseKey {
  return typeof value === "string" && (PAUSE_KEYS as readonly string[]).includes(value);
}

export async function getPauses(): Promise<Pauses> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.value;
  const value: Pauses = { purchasesPaused: false, bridgePaused: false, swapPaused: false };
  try {
    const rows = await db.select().from(appSettings);
    for (const key of PAUSE_KEYS) value[key] = rows.find((r) => r.key === key)?.value === "true";
  } catch (err) {
    // Never block users because the settings could not be read
    console.error("[settings] could not read switches:", err instanceof Error ? err.message : err);
    return value;
  }
  cache = { at: Date.now(), value };
  return value;
}

// The message to show users when this part is paused, or null when it is open.
export async function pausedMessage(key: PauseKey): Promise<string | null> {
  return (await getPauses())[key] ? PAUSE_MESSAGES[key] : null;
}

export async function setPause(key: PauseKey, paused: boolean): Promise<void> {
  const value = paused ? "true" : "false";
  await db
    .insert(appSettings)
    .values({ key, value })
    .onConflictDoUpdate({ target: appSettings.key, set: { value, updatedAt: new Date() } });
  cache = null;
}
DOC_EOF
green "OK"

step "Admin dashboard: installing packages (same versions as the website)"
if [[ ! -f admin/package-lock.json ]]; then
  cp frontend/package-lock.json admin/package-lock.json
  python3 - <<'PY'
import json
p = "admin/package-lock.json"
d = json.load(open(p))
d["name"] = "dataonchain-admin"
root = d.get("packages", {}).get("", {})
root["name"] = "dataonchain-admin"
root.get("dependencies", {}).pop("better-auth", None)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
fi
(cd admin && npm install --no-audit --no-fund) || fail "Could not install the admin dashboard packages. Check your internet connection and run again."
green "OK"

# --- 2. Database --------------------------------------------------------------------
step "Database: admin tables"
if ! grep -rqs 'CREATE TABLE `admin_accounts`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name admin_dashboard)
fi
grep -rqs 'CREATE TABLE `admin_accounts`' backend/drizzle/*.sql || fail "The admin migration was not created"
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build) || fail "Backend check failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Admin login and pages: full test on the development database"
echo "Uses a test admin (admin-smoke@example.com) and removes it afterwards."
OUTBOX="$(mktemp)"
(cd backend && ADMIN_EMAIL=admin-smoke@example.com ADMIN_URL=http://localhost:3001 EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 WORKER_ENABLED=false exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
stop_api() { kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"; }
if ! (cd backend && ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/admin-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "Admin test failed (details above). Nothing was committed. Paste the output to Claude."
fi
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "User login test failed (details above). Nothing was committed."
fi
stop_api
green "OK"

step "Delivery: make sure it still works"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
green "OK"

step "Website and admin dashboard: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed."
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 4. Production database ---------------------------------------------------------
step "Production database: admin tables"
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
git commit -q -m "Admin dashboard: separate site, one admin with password and emailed code, users, volume, orders, refunds, bridge, swaps, safe controls"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"admin":true' || fail "The API did not come up. Check Events and Logs on Render."

# --- 6. Render: the admin email ------------------------------------------------------
step "Render: tell the API who the admin is"
bold "On Render > your dataonchain service > Environment, add these two:"
echo "  ADMIN_EMAIL  =  $ADMIN_EMAIL_VALUE"
echo "  ADMIN_URL    =  $ADMIN_SITE"
echo "Then click 'Save, rebuild, and deploy'  (NOT 'Save only')."
read -r -p "When you have saved it, press Enter to continue... " _
wait_for "the admin login on the API" "$PROD_API/api/status" '"adminConfigured":true' || fail "Render does not show ADMIN_EMAIL yet. Check the variable and that a new deploy started."

# --- 7. Vercel: the admin website -----------------------------------------------------
step "Vercel: create the admin website (one time)"
bold "On vercel.com:"
echo "  1. Add New > Project > Import your dataonchain repository again"
echo "  2. Project Name: dataonchain-admin"
echo "  3. Root Directory: click Edit and choose  admin"
echo "  4. Environment Variables: add"
echo "       API_URL  =  $PROD_API"
echo "  5. Click Deploy and wait until it says Congratulations"
echo "  6. Open the new project > Settings > Domains > Add:  $ADMIN_HOST"
echo "     (your domain is already on Vercel, so it connects by itself)"
read -r -p "When the domain shows Valid Configuration, press Enter to continue... " _
wait_for "the dashboard at $ADMIN_SITE" "$ADMIN_SITE/api/status" '"adminConfigured":true' 30 \
  || fail "$ADMIN_SITE does not reach the API yet. Check the Root Directory (admin), API_URL, and the domain on Vercel, then run this script again (it skips what is done)."
curl -s --max-time 20 "$ADMIN_SITE/login" | grep -q "dataonchain admin" || yellow "The login page did not answer as expected. Open $ADMIN_SITE/login in your browser to check."

echo
green "Script 21 complete. The admin dashboard is live at $ADMIN_SITE"
echo
bold "First login (one time):"
echo "  1. Open $ADMIN_SITE/forgot"
echo "  2. Enter $ADMIN_EMAIL_VALUE and click 'Email me a link'"
echo "  3. Open the email, click 'Set my password', choose a password (12+ characters)"
echo "  4. Log in at $ADMIN_SITE/login, then enter the 6 digit code from your email"
