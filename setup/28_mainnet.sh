#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 28: move the live site to Arc MAINNET
#
# What happens, in order (you confirm before anything changes for users):
#   1. Code: the mainnet network list (Arc, Base, Arbitrum, Avalanche, OP,
#      Polygon, Unichain; Ethereum later), mainnet "coming soon" messages,
#      smaller limits, tested on testnet as usual
#   2. Your LIVE Circle key (typed hidden): mainnet wallet set and treasury on
#      Arc, plus read only checks of Gateway and swaps on mainnet (no money moves)
#   3. A full archive copy of the live database (dataonchainprod-testnet-archive)
#   4. Buying, bridge and swaps are paused ("coming soon") on the live site
#   5. You paste the mainnet settings into Render (one paste, from your clipboard)
#   6. Test network activity is removed from the live database (accounts stay;
#      every user gets a fresh mainnet wallet on next login)
#   7. Website wording changes from "public testing" to "live on Arc mainnet"
#
# Your machine (backend/.env) stays on testnet; tests always run there.
# Mainnet settings are kept in backend/.env.mainnet (never committed).
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/28_mainnet.sh
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
  done < <(cat "$ENV_FILE" backend/.env.mainnet 2>/dev/null | grep -E '^[A-Z0-9_]+=')
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

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
command -v turso >/dev/null || fail "Turso CLI not found"
[[ -f frontend/src/app/account/page.tsx ]] || fail "Run this from ~/dataonchain after script 27"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/28_mainnet.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"
grep -qE '^\.env\*' .gitignore || fail ".gitignore does not cover .env files. Tell Claude."
green "OK"

step "Your LIVE (mainnet) Circle API key"
MAINNET_FILE="backend/.env.mainnet"
LIVE_KEY="$(grep -E '^CIRCLE_API_KEY=' "$MAINNET_FILE" 2>/dev/null | cut -d= -f2- || true)"
if [[ -z "$LIVE_KEY" ]]; then
  echo "In the Circle Console (mainnet), copy your API key. It starts with LIVE_API_KEY:"
  echo "Paste it here and press Enter. Nothing is shown while you paste."
  read -r -s LIVE_KEY
  echo
fi
[[ "$LIVE_KEY" == LIVE_API_KEY:* ]] || fail "That is not a live key (it must start with LIVE_API_KEY:). Nothing was changed."
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the mainnet code"
mkdir -p "backend" "backend/scripts" "backend/src" "backend/src/bridge" "backend/src/swap" "frontend/src/app/dashboard" "frontend/src/app/swap"
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

# Largest swap per transaction (USDC or EURC, and cirBTC)
# SWAP_MAX_STABLE=500
# SWAP_MAX_CIRBTC=0.01
# Arc mainnet (setup/28): CIRCLE_BLOCKCHAIN=ARC with a LIVE_API_KEY. The mainnet
# values live in backend/.env.mainnet (never committed) and on Render.
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
import { PaymentError, getOrderView, listOrders, orderHistory, orderHistoryCsv, payOrder } from "./payments/service";
import { isNetwork, listDataPlans } from "./catalog/plans";
import { QuoteError, createQuote, getQuote } from "./pricing/quote";
import { NETWORK_NAMES, ensureUserWallet, previousWallet } from "./wallets/service";
import { SwapError, TOKENS, executeSwap, listSwaps, quoteSwap, tokenBalances } from "./swap/service";
import { getPauses, pauseNotices, pausedMessage } from "./settings";
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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

// Data plans for one network (refreshed from VTpass every hour)
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

// Full order history, 25 per page (?page=2&status=delivered|refunded|failed|open)
app.get("/api/history", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const page = Math.max(1, Math.min(10_000, Number.parseInt(c.req.query("page") ?? "1", 10) || 1));
  return c.json(await orderHistory(user.id, page, c.req.query("status")));
});

// The same history as a CSV file
app.get("/api/history.csv", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const csv = await orderHistoryCsv(user.id);
  const day = new Date().toISOString().slice(0, 10);
  return c.body(csv, 200, {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": `attachment; filename="dataonchain-orders-${day}.csv"`,
    "Cache-Control": "no-store",
  });
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

// Mainnet (checked against Circle's and Arc's contract address pages, October 2026).
// Ethereum is left out at launch: smart wallet set up and gas there cost several
// dollars, paid through Gas Station. Add it back here when that makes sense.
const GATEWAY_WALLET_MAINNET: `0x${string}` = "0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE";
const GATEWAY_MINTER_MAINNET: `0x${string}` = "0x2222222d7164433c4C09B0b0D809a9b52C04C205";

const MAINNET: BridgeChain[] = ([
  { key: "arc", label: "Arc", circleBlockchain: "ARC", domain: 26,
    usdc: "0x3600000000000000000000000000000000000000", explorerTx: "https://explorer.arc.io/tx/" },
  { key: "base", label: "Base", circleBlockchain: "BASE", domain: 6,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", explorerTx: "https://basescan.org/tx/" },
  { key: "arbitrum", label: "Arbitrum", circleBlockchain: "ARB", domain: 3,
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", explorerTx: "https://arbiscan.io/tx/" },
  { key: "avalanche", label: "Avalanche", circleBlockchain: "AVAX", domain: 1,
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", explorerTx: "https://snowtrace.io/tx/" },
  { key: "optimism", label: "OP Mainnet", circleBlockchain: "OP", domain: 2,
    usdc: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", explorerTx: "https://optimistic.etherscan.io/tx/" },
  { key: "polygon", label: "Polygon", circleBlockchain: "MATIC", domain: 7,
    usdc: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", explorerTx: "https://polygonscan.com/tx/" },
  { key: "unichain", label: "Unichain", circleBlockchain: "UNI", domain: 10,
    usdc: "0x078D782b760474a361dDA0AF3839290b0EF57AD6", explorerTx: "https://uniscan.xyz/tx/" },
] as Omit<BridgeChain, "gatewayWallet" | "gatewayMinter">[]).map((c) => ({ ...c, gatewayWallet: GATEWAY_WALLET_MAINNET, gatewayMinter: GATEWAY_MINTER_MAINNET }));

export const isMainnet = () => !env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET");

function registry(): BridgeChain[] {
  if (env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) return TESTNET;
  if (env.CIRCLE_BLOCKCHAIN === "ARC") return MAINNET;
  throw new Error(`No bridge chain list for ${env.CIRCLE_BLOCKCHAIN}.`);
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

// A whole number between min and max (default when not set). A typo stops the
// server at startup with a clear message instead of breaking things later.
function wholeNumber(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be a whole number from ${min} to ${max} (it is "${raw}")`);
  }
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
  SWAP_FEE_BPS: wholeNumber("SWAP_FEE_BPS", 50, 0, 1000), // 0.5%, paid to the treasury
  SWAP_SLIPPAGE_BPS: wholeNumber("SWAP_SLIPPAGE_BPS", 100, 1, 1000), // 1%
  SWAP_DAILY_COUNT: wholeNumber("SWAP_DAILY_COUNT", 20, 1, 1000),
  // Largest swap: USDC or EURC, and cirBTC (start small on mainnet)
  SWAP_MAX_STABLE: optionalNumber("SWAP_MAX_STABLE") ?? 500,
  SWAP_MAX_CIRBTC: optionalNumber("SWAP_MAX_CIRBTC") ?? 0.01,
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
cat > "backend/src/settings.ts" <<'DOC_EOF'
// Switches the admin can flip from the dashboard, without a redeploy.
// Pausing only stops NEW purchases, transfers or swaps. Anything already
// started (payments, deliveries, refunds, bridge transfers) keeps going.
import { db } from "./db";
import { appSettings } from "./db/schema";
import { env } from "./env";

export const PAUSE_KEYS = ["purchasesPaused", "bridgePaused", "swapPaused"] as const;
export type PauseKey = (typeof PAUSE_KEYS)[number];
export type Pauses = Record<PauseKey, boolean>;

const TESTNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data is paused for a short maintenance. Please try again later.",
  bridgePaused: "Sending to other networks is paused for a short maintenance. Please try again later.",
  swapPaused: "Swaps are paused for a short maintenance. Please try again later.",
};
// On mainnet a paused part is one that has not opened yet
const MAINNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data with real USDC is coming soon. Until then you can add USDC to your wallet.",
  bridgePaused: "Sending to other networks opens soon on Arc mainnet.",
  swapPaused: "Swaps open soon on Arc mainnet.",
};
export const PAUSE_MESSAGES: Record<PauseKey, string> = env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? TESTNET_MESSAGES : MAINNET_MESSAGES;

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

// The messages for every paused part, for the dashboard notice
export async function pauseNotices(): Promise<string[]> {
  const p = await getPauses();
  // Bridge and swaps only matter where they are switched on
  const on: Record<PauseKey, boolean> = { purchasesPaused: true, bridgePaused: env.BRIDGE_ENABLED, swapPaused: env.SWAP_ENABLED };
  return PAUSE_KEYS.filter((k) => p[k] && on[k]).map((k) => PAUSE_MESSAGES[k]);
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
cat > "backend/src/swap/service.ts" <<'DOC_EOF'
// Swaps on Arc between USDC, EURC and cirBTC, through Circle App Kit.
//
// Swap: PENDING -> COMPLETE   (or FAILED: nothing swapped, or UNKNOWN: check onchain)
//
// Safety:
//   - one swap at a time per user (unique open_key), so a double click cannot swap twice
//   - the user never gets less than the minimum shown on their quote (the quote
//     minus 1% slippage by default): otherwise the swap reverts and nothing changes
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
  USDC: { decimals: 6, min: 0.5, max: env.SWAP_MAX_STABLE, label: "USDC" },
  EURC: { decimals: 6, min: 0.5, max: env.SWAP_MAX_STABLE, label: "EURC" },
  cirBTC: { decimals: 8, min: 0.000005, max: env.SWAP_MAX_CIRBTC, label: "cirBTC" },
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

type Params = { tokenIn?: unknown; tokenOut?: unknown; amount?: unknown; minOut?: unknown };

function readParams(body: Params) {
  if (!isToken(body.tokenIn) || !isToken(body.tokenOut)) throw new SwapError("Choose two of USDC, EURC and cirBTC.");
  if (body.tokenIn === body.tokenOut) throw new SwapError("Choose two different tokens.");
  return { tokenIn: body.tokenIn, tokenOut: body.tokenOut, amountIn: parseAmount(body.tokenIn, body.amount) };
}

// A decimal amount cut down to the token's decimals (never rounded up). null if not a number.
function trimAmount(token: SwapToken, value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  const m = /^(\d+)(?:\.(\d+))?$/.exec(String(value).trim());
  if (!m) return null;
  const frac = (m[2] ?? "").slice(0, TOKENS[token].decimals).replace(/0+$/, "");
  const text = frac ? `${m[1]}.${frac}` : m[1]!;
  return Number(text) > 0 ? text : null;
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

  // The minimum the user was shown on the quote ("at least Y"). The swap must
  // never give less: it is sent with that minimum as its stop limit, so it
  // reverts (nothing taken) rather than fill below it.
  const shownMin = trimAmount(tokenOut, body.minOut);
  const base = swapParams(wallet.address, tokenIn, tokenOut, amountIn);
  let stopLimit: string | null = shownMin;
  try {
    const estimate = (await appKit().kit.estimateSwap(base as never)) as { estimatedOutput?: unknown; stopLimit?: unknown };
    const freshOut = amountOf(estimate.estimatedOutput);
    const freshMin = trimAmount(tokenOut, amountOf(estimate.stopLimit));
    if (shownMin && freshOut !== null && Number(freshOut) < Number(shownMin)) {
      await db
        .update(swaps)
        .set({ status: "FAILED", estimatedOut: freshOut, minOut: shownMin, error: `price moved: now ${freshOut}, quoted minimum ${shownMin}`, openKey: null })
        .where(eq(swaps.id, row.id));
      throw new SwapError("The price moved since your quote, below the minimum you were shown. Nothing was taken. Please get a new price.", 409);
    }
    // If the price got better, keep the tighter of the two minimums
    if (freshMin && (!stopLimit || Number(freshMin) > Number(stopLimit))) stopLimit = freshMin;
    await db.update(swaps).set({ estimatedOut: freshOut, minOut: stopLimit }).where(eq(swaps.id, row.id));
  } catch (err) {
    if (err instanceof SwapError) throw err;
    const message = errorText(err);
    await db.update(swaps).set({ status: "FAILED", error: message, openKey: null }).where(eq(swaps.id, row.id));
    console.error(`[swap] ${row.id} no quote:`, message);
    throw new SwapError("No price is available for this swap right now. Nothing was taken. Please try again shortly.", 502);
  }
  const params = stopLimit ? { ...base, config: { ...base.config, stopLimit } } : base;

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
cat > "frontend/src/app/dashboard/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ChainWallets } from "@/components/ChainWallets";
import { SupportLink } from "@/components/SupportLink";
import { RecentOrders } from "@/components/RecentOrders";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [bridgeOn, setBridgeOn] = useState(false);
  const [swapOn, setSwapOn] = useState(false);
  const [paused, setPaused] = useState<string[]>([]);
  const [mainnet, setMainnet] = useState(false);
  const [notices, setNotices] = useState<string[]>([]);
  const [buyPaused, setBuyPaused] = useState(false);

  // The "Send to a provider" button appears only when bridging is switched on
  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean; network?: string; notices?: string[]; paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean } }) => {
        setBridgeOn(Boolean(s.bridge));
        setSwapOn(Boolean(s.swap));
        setMainnet(s.network === "mainnet");
        setNotices(s.notices ?? []);
        setBuyPaused(Boolean(s.paused?.purchasesPaused));
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
          <div className="flex items-center gap-2">
          <Link
            href="/account"
            className="rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:text-zinc-300 dark:hover:bg-zinc-900"
          >
            Account
          </Link>
          <button
            onClick={logOut}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Log out
          </button>
          </div>
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
        {mainnet && notices.length > 0 ? (
          <div className="mt-4 rounded-lg bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">
            {notices.map((n) => (
              <p key={n}>{n}</p>
            ))}
          </div>
        ) : null}
        {!mainnet && paused.length > 0 ? (
          <p className="mt-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Short maintenance: {paused.join(", ")} {paused.length > 1 ? "are" : "is"} paused for now. Your balance is safe.
          </p>
        ) : null}

        <div className="mt-4 flex flex-wrap gap-3">
          {mainnet && buyPaused ? (
            <span className="inline-block cursor-not-allowed rounded-lg bg-zinc-200 px-4 py-2.5 font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
              Buy airtime or data · coming soon
            </span>
          ) : (
            <Link
              href="/buy"
              className="inline-block rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
            >
              Buy airtime or data
            </Link>
          )}
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
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium text-zinc-500">Your account</h2>
            <Link href="/account" className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
              Edit
            </Link>
          </div>
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

        <p className="mt-8 text-center text-sm text-zinc-500">
          Need help? <SupportLink />
        </p>
      </div>
    </main>
  );
}
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
      const r = await api<{ swap: SwapView }>("/swap", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount, minOut: quote?.minOut ?? null }) });
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
              <p className="text-xs text-zinc-500">Prices can move quickly. If the swap would give less than the minimum, it is cancelled and nothing is taken.</p>
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
cat > "backend/scripts/mainnet-cutover.ts" <<'DOC_EOF'
// Moving the live database from Arc Testnet to Arc mainnet.
//   pause: closes buying, bridge and swaps (users see "coming soon")
//   clear: removes the test network activity (orders, payments, transfers,
//          swaps, test wallets, test provider addresses). Accounts, logins,
//          data plans, exchange rates and admin settings stay.
// Only runs against the production database (dataonchainprod), and "clear"
// needs --yes-clear-testnet-data. Make the archive copy first (setup/28 does).
// Run with: TURSO_DATABASE_URL=... TURSO_AUTH_TOKEN=... npx tsx scripts/mainnet-cutover.ts pause|clear [--yes-clear-testnet-data]
import { createClient } from "@libsql/client";

const url = process.env.TURSO_DATABASE_URL ?? "";
const mode = process.argv[2];

const TESTNET_CHAINS = ["ARC-TESTNET", "BASE-SEPOLIA", "ARB-SEPOLIA", "ETH-SEPOLIA", "AVAX-FUJI", "OP-SEPOLIA", "MATIC-AMOY", "UNI-SEPOLIA"];

// Children before parents, so links between tables never break
const CLEAR: { table: string; where?: string }[] = [
  { table: "bridge_events" },
  { table: "bridge_transfers" },
  { table: "refunds" },
  { table: "vtu_transactions" },
  { table: "ledger_entries" },
  { table: "payments" },
  { table: "orders" },
  { table: "swaps" },
  { table: "wallet_sweeps" },
  { table: "webhook_events" },
  { table: "treasury_movements" },
  { table: "approved_destinations" },
  { table: "audit_logs", where: "actor_type <> 'admin'" },
  { table: "wallets", where: `blockchain IN (${TESTNET_CHAINS.map((c) => `'${c}'`).join(", ")})` },
];

async function main() {
  if (!/dataonchainprod/.test(url)) throw new Error("This only runs against the production database (dataonchainprod).");
  const db = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
  try {
    if (mode === "pause") {
      for (const key of ["purchasesPaused", "bridgePaused", "swapPaused"]) {
        await db.execute({
          sql: "INSERT INTO app_settings (key, value, updated_at) VALUES (?, 'true', ?) ON CONFLICT(key) DO UPDATE SET value = 'true', updated_at = excluded.updated_at",
          args: [key, Date.now()],
        });
      }
      console.log("Buying, bridge and swaps are paused (users see 'coming soon').");
      return;
    }
    if (mode !== "clear") throw new Error("Choose pause or clear");
    if (!process.argv.includes("--yes-clear-testnet-data")) throw new Error("Add --yes-clear-testnet-data to confirm");

    const before: Record<string, number> = {};
    for (const c of CLEAR) {
      const r = await db.execute(`SELECT count(*) AS n FROM ${c.table}${c.where ? ` WHERE ${c.where}` : ""}`);
      before[c.table] = Number(r.rows[0]?.n ?? 0);
    }
    // One batch: all of it is removed, or nothing is
    await db.batch(
      CLEAR.map((c) => `DELETE FROM ${c.table}${c.where ? ` WHERE ${c.where}` : ""}`),
      "write",
    );
    for (const c of CLEAR) console.log(`  ${c.table}: removed ${before[c.table]}`);
    const users = await db.execute("SELECT count(*) AS n FROM users");
    console.log(`Test network activity removed. ${users.rows[0]?.n} user account(s) kept; each gets a new mainnet wallet on next login.`);
  } finally {
    db.close();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
DOC_EOF
cat > "backend/scripts/mainnet-setup.ts" <<'DOC_EOF'
// Arc mainnet setup with your LIVE Circle API key. Safe to run again.
//   1. Checks the entity secret works with the live key (registers a new one
//      for mainnet only if Circle refuses the current one)
//   2. Creates (or finds) the mainnet wallet set and treasury wallet on Arc
//   3. Read only checks: Circle Gateway mainnet gives a price for Arc -> Base,
//      and App Kit gives a swap price on Arc. No money moves.
// Everything is saved in backend/.env.mainnet (never committed). backend/.env
// stays on testnet for the tests.
// Run with: MAINNET_CIRCLE_API_KEY=LIVE_API_KEY:... npx tsx scripts/mainnet-setup.ts /path/to/recovery/folder
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { config } from "dotenv";
import {
  initiateDeveloperControlledWalletsClient,
  registerEntitySecretCiphertext,
} from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

const FILE = ".env.mainnet";
const apiKey = process.env.MAINNET_CIRCLE_API_KEY ?? "";
const recoveryDir = process.argv[2];

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function readSaved(): Record<string, string> {
  if (!existsSync(FILE)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(FILE, "utf8").split("\n")) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]!] = m[2]!;
  }
  return out;
}

function writeSaved(values: Record<string, string>) {
  const lines = [
    "# Arc MAINNET settings for Render (made by setup/28). Never commit this file.",
    ...Object.entries(values).map(([k, v]) => `${k}=${v}`),
    "",
  ];
  writeFileSync(FILE, lines.join("\n"), { mode: 0o600 });
}

const detail = (err: unknown) => {
  const d = (err as { response?: { data?: unknown } }).response?.data;
  return `${err instanceof Error ? err.message : String(err)}${d ? ` ${JSON.stringify(d)}` : ""}`;
};

async function main() {
  if (!/^LIVE_API_KEY:/.test(apiKey)) throw new Error("MAINNET_CIRCLE_API_KEY must be your LIVE key (it starts with LIVE_API_KEY:)");
  if (!recoveryDir) throw new Error("Give the folder for a recovery file");
  const saved = readSaved();
  let entitySecret = saved.CIRCLE_ENTITY_SECRET || process.env.CIRCLE_ENTITY_SECRET || "";
  if (!entitySecret) throw new Error("No entity secret found in backend/.env");

  // 1 + 2. The wallet set proves the entity secret works with the live key
  const makeSet = async (secret: string) => {
    const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret: secret });
    const res = await client.createWalletSet({ name: "dataonchain users (mainnet)", idempotencyKey: uuidFrom("walletset:mainnet:dataonchain") } as Parameters<typeof client.createWalletSet>[0]);
    return res.data?.walletSet?.id;
  };
  let walletSetId = saved.CIRCLE_WALLET_SET_ID;
  if (!walletSetId) {
    try {
      walletSetId = await makeSet(entitySecret);
      console.log("Your entity secret works with the live key.");
    } catch (err) {
      const why = detail(err);
      if (!/entity ?secret|ciphertext/i.test(why)) throw new Error(`Circle refused the wallet set: ${why}`);
      console.log("Circle needs a separate entity secret for mainnet. Registering a new one...");
      mkdirSync(recoveryDir, { recursive: true, mode: 0o700 });
      entitySecret = randomBytes(32).toString("hex");
      await registerEntitySecretCiphertext({ apiKey, entitySecret, recoveryFileDownloadPath: recoveryDir });
      saved.CIRCLE_ENTITY_SECRET = entitySecret;
      saved.NEW_MAINNET_ENTITY_SECRET = "yes";
      writeSaved(saved);
      console.log(`New mainnet entity secret registered. Recovery file in ${recoveryDir}: ${readdirSync(recoveryDir).join(", ")}`);
      walletSetId = await makeSet(entitySecret);
    }
    if (!walletSetId) throw new Error("Circle did not return a wallet set id");
    saved.CIRCLE_WALLET_SET_ID = walletSetId;
  }
  saved.CIRCLE_ENTITY_SECRET = entitySecret;
  saved.CIRCLE_API_KEY = apiKey;
  saved.CIRCLE_BLOCKCHAIN = "ARC";
  saved.EXPLORER_TX_URL = "https://explorer.arc.io/tx/";
  writeSaved(saved);
  console.log(`Mainnet wallet set: ${walletSetId}`);

  const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });
  if (!saved.TREASURY_WALLET_ID || !saved.TREASURY_ADDRESS) {
    const res = await client.createWallets({
      walletSetId,
      blockchains: ["ARC" as "ARC-TESTNET"],
      count: 1,
      accountType: "EOA",
      idempotencyKey: uuidFrom(`treasury:${walletSetId}:ARC`),
    });
    const w = res.data?.wallets?.[0];
    if (!w?.id || !w.address) throw new Error("Circle did not return the mainnet treasury wallet");
    saved.TREASURY_WALLET_ID = w.id;
    saved.TREASURY_ADDRESS = w.address;
    writeSaved(saved);
  }
  console.log(`Mainnet treasury on Arc: ${saved.TREASURY_ADDRESS}`);

  // 3. Read only checks (no money moves)
  const est = await fetch("https://gateway-api.circle.com/v1/estimate?enableForwarder=true", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify([
      {
        spec: {
          version: 1,
          sourceDomain: 26,
          destinationDomain: 6,
          sourceContract: `0x${"77777777Dcc4d5A8B6E418Fd04D8997ef11000eE".toLowerCase().padStart(64, "0")}`,
          destinationContract: `0x${"2222222d7164433c4C09B0b0D809a9b52C04C205".toLowerCase().padStart(64, "0")}`,
          sourceToken: `0x${"3600000000000000000000000000000000000000".padStart(64, "0")}`,
          destinationToken: `0x${"833589fCD6eDb6E08f4c7C32D4f71b54bdA02913".toLowerCase().padStart(64, "0")}`,
          sourceDepositor: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          destinationRecipient: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          sourceSigner: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          destinationCaller: `0x${"0".repeat(64)}`,
          value: "1000000",
          salt: `0x${randomBytes(32).toString("hex")}`,
          hookData: "0x",
        },
      },
    ]),
    signal: AbortSignal.timeout(30_000),
  });
  const estText = await est.text();
  if (!est.ok) {
    // Not fatal: the bridge stays paused, and this is checked again before it opens
    console.log(`Note: Circle Gateway mainnet gave no price just now (${est.status} ${estText.slice(0, 200)}). The bridge stays paused; checked again before it opens.`);
  } else {
    const fee = Number((JSON.parse(estText) as { body?: { burnIntent?: { maxFee?: string } }[] }).body?.[0]?.burnIntent?.maxFee ?? NaN);
    console.log(`Circle Gateway mainnet works: sending 1 USDC from Arc to Base costs about ${(fee / 1e6).toFixed(4)} USDC.`);
  }

  try {
    const { AppKit } = await import("@circle-fin/app-kit");
    const { createCircleWalletsAdapter } = await import("@circle-fin/adapter-circle-wallets");
    const kit = new AppKit();
    const adapter = createCircleWalletsAdapter({ apiKey, entitySecret });
    const swap = (await kit.estimateSwap({
      from: { adapter, chain: "Arc", address: saved.TREASURY_ADDRESS },
      tokenIn: "USDC",
      tokenOut: "EURC",
      amountIn: "1",
      config: { apiKey, slippageBps: 100 },
    } as never)) as { estimatedOutput?: unknown };
    const out = swap.estimatedOutput as { amount?: string } | string | undefined;
    console.log(`App Kit swaps on Arc mainnet work: 1 USDC is about ${typeof out === "object" ? out?.amount : out} EURC right now.`);
  } catch (err) {
    console.log(`Note: App Kit gave no swap price on Arc mainnet just now (${detail(err).slice(0, 200)}). Swaps stay paused anyway; this is checked again before they open.`);
  }
  console.log("Mainnet setup done. Settings saved in backend/.env.mainnet");
}

main().catch((err) => {
  console.error(detail(err));
  process.exit(1);
});
DOC_EOF
green "OK"

step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build) || fail "Backend check failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Tests on testnet: logins and the admin dashboard"
OUTBOX="$(mktemp)"
(cd backend && ADMIN_EMAIL=admin-smoke@example.com ADMIN_URL=http://localhost:3001 EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 WORKER_ENABLED=false exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
stop_api() { kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"; }
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099) \
  || ! (cd backend && ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/admin-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "A test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again."
fi
stop_api
green "OK"

step "Website: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 2. Mainnet setup with the live key --------------------------------------------
step "Mainnet: wallet set, treasury, and read only checks"
(cd backend && MAINNET_CIRCLE_API_KEY="$LIVE_KEY" npx tsx scripts/mainnet-setup.ts "$HOME/dataonchain-circle-recovery/mainnet") \
  || fail "Mainnet setup failed (details above). Nothing changed for users. Paste the output to Claude."
unset LIVE_KEY
mget() { grep -E "^$1=" "$MAINNET_FILE" | tail -n1 | cut -d= -f2-; }
MAIN_TREASURY="$(mget TREASURY_ADDRESS)"
[[ -n "$MAIN_TREASURY" && -n "$(mget CIRCLE_WALLET_SET_ID)" ]] || fail "Mainnet settings are incomplete in $MAINNET_FILE. Tell Claude."
if [[ "$(mget NEW_MAINNET_ENTITY_SECRET)" == "yes" ]]; then
  yellow "A new entity secret was made for mainnet. Copy the recovery file in ~/dataonchain-circle-recovery/mainnet to your safe place now, like you did for testnet."
  read -r -p "Press Enter when it is backed up... " _
fi
green "OK: mainnet treasury on Arc is $MAIN_TREASURY"

# --- 3. Commit the code ---------------------------------------------------------------
step "Committing the mainnet code"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Mainnet ready: Arc mainnet networks, coming soon messages, swap limits, cutover tools"
git push
green "OK: pushed."
wait_for "the new code on Render (still on testnet)" "$PROD_API/api/status" '"mainnetReady":true' || fail "The API did not come up. Check Events and Logs on Render."

# --- 4. The switch ----------------------------------------------------------------------
echo
bold "Ready to move the live site to Arc mainnet."
echo "  From here, the live site changes for users. Buying, bridge and swaps will show 'coming soon',"
echo "  and test network orders, transfers and wallets are removed from the live database"
echo "  (after a full archive copy is made)."
read -r -p "Type SWITCH to continue (anything else stops here, safely): " ans
[[ "$ans" == "SWITCH" ]] || fail "Stopped before the switch. Nothing changed for users. Run again when ready."

step "Archive copy of the live database"
ARCHIVE="dataonchainprod-testnet-archive"
if turso db list 2>/dev/null | grep -q "^$ARCHIVE "; then
  green "OK: archive already exists ($ARCHIVE)"
else
  turso db create "$ARCHIVE" --from-db "$PROD_DB" --wait || fail "Could not make the archive copy. Nothing changed for users."
  green "OK: archive saved as $ARCHIVE"
fi

step "Pausing buying, bridge and swaps on the live site"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx tsx scripts/mainnet-cutover.ts pause) \
  || fail "Could not pause. Nothing else changed. Run again."
green "OK"

step "Render: switch to mainnet"
RENDER_BLOCK="$(cat <<RB
CIRCLE_API_KEY=$(mget CIRCLE_API_KEY)
CIRCLE_ENTITY_SECRET=$(mget CIRCLE_ENTITY_SECRET)
CIRCLE_WALLET_SET_ID=$(mget CIRCLE_WALLET_SET_ID)
CIRCLE_BLOCKCHAIN=ARC
TREASURY_WALLET_ID=$(mget TREASURY_WALLET_ID)
TREASURY_ADDRESS=$MAIN_TREASURY
EXPLORER_TX_URL=https://explorer.arc.io/tx/
GATEWAY_API_URL=https://gateway-api.circle.com
BRIDGE_MAX_USDC=50
BRIDGE_DAILY_USDC=100
SWAP_MAX_STABLE=100
SWAP_MAX_CIRBTC=0.001
RB
)"
bold "On Render > your dataonchain service > Environment:"
echo "  1. Click 'Add from .env' (or 'Add Environment Variable' > 'Add from .env')"
if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$RENDER_BLOCK" | clip.exe
  echo "  2. Paste with Ctrl+V: 12 lines are already on your clipboard (they include your live key)"
else
  yellow "  2. Paste these 12 lines (keep them private and clear the screen afterwards):"
  printf '%s\n' "$RENDER_BLOCK"
fi
echo "     Existing names (like CIRCLE_API_KEY) are replaced with the new values."
echo "  3. Check that CIRCLE_BLOCKCHAIN now shows ARC"
echo "  4. Click 'Save, rebuild, and deploy'  (NOT 'Save only')"
unset RENDER_BLOCK
read -r -p "When it is saved and deploying, press Enter... " _
command -v clip.exe >/dev/null 2>&1 && printf ' ' | clip.exe
wait_for "the API on Arc mainnet" "$PROD_API/api/status" '"network":"mainnet"' || fail "Render is not on mainnet yet. Check the variables (CIRCLE_BLOCKCHAIN=ARC) and that a new deploy started, then run this script again: it carries on from here."

step "Removing test network activity from the live database"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx tsx scripts/mainnet-cutover.ts clear --yes-clear-testnet-data) \
  || fail "Could not clear the test data (details above). The site is on mainnet with everything paused; run this script again."
unset PROD_TOKEN
green "OK"

# --- 5. Website wording -------------------------------------------------------------
step "Website: from 'public testing' to 'live on Arc mainnet'"
cat > "frontend/src/app/page.tsx" <<'DOC_EOF'
import Link from "next/link";
import { SupportLink } from "@/components/SupportLink";
import { SUPPORT_WHATSAPP_DISPLAY } from "@/lib/support";

// The public home page: what dataonchain is, why it is built on Arc, the Arc
// and Circle tools behind it, what is done, and what comes next.

const NAV = [
  { href: "#about", label: "About" },
  { href: "#why-arc", label: "Why Arc" },
  { href: "#tools", label: "Built with" },
  { href: "#milestones", label: "Milestones" },
  { href: "#roadmap", label: "Roadmap" },
  { href: "#faq", label: "FAQ" },
];

const HOW = [
  { title: "Sign up with your email", text: "No seed phrase, no browser extension. A USDC wallet on Arc is created for you the moment you confirm your email." },
  { title: "Get a price in USDC", text: "Pick MTN, Airtel, Glo or 9mobile, airtime or a data plan. We show the naira value and the exact USDC price, held for 10 minutes." },
  { title: "Pay and it is delivered", text: "Pay from your wallet with one tap. The payment settles on Arc and the airtime or data goes straight to the phone." },
  { title: "Refunded if it fails", text: "If a network cannot deliver, your USDC goes back to your wallet automatically. Every step is shown on the order page." },
];

const WHY_ARC = [
  {
    title: "Fees are paid in USDC",
    text: "On Arc the network fee is paid in USDC, not in a separate gas token. Our users only ever hold one thing, digital dollars, and costs are predictable in dollars. On top of that, we sponsor the fee, so users pay nothing extra.",
  },
  {
    title: "Final in under a second",
    text: "Arc settles a payment in under a second, and once settled it cannot be reversed. That is what lets us start delivering airtime the moment you pay, and why a refund, once sent, is final.",
  },
  {
    title: "Built by the issuer of USDC",
    text: "Arc comes from Circle, the company behind USDC and EURC. Wallets, gas sponsorship, crosschain transfers and swaps all come from the same family of tools, so a small team can build what used to need a large one.",
  },
  {
    title: "Made for stablecoin payments",
    text: "Arc is designed for everyday payments and currency exchange between stablecoins. Buying airtime and data is the most everyday payment there is in Nigeria, which makes it a natural fit.",
  },
];

const TOOLS = [
  { name: "Arc network", text: "Where every payment, refund and swap settles. Each one links to the Arc explorer so anyone can verify it." },
  { name: "USDC", text: "The digital dollar users pay with, and the currency Arc uses for its own network fees." },
  { name: "Circle Wallets", text: "A smart contract wallet created for every user at sign up, so people who have never used crypto can start in a minute." },
  { name: "Circle Gas Station", text: "Pays the network fee for our users' smart wallets. Nobody needs gas to buy airtime." },
  { name: "Circle Gateway", text: "One USDC balance that moves to six other networks: Base, Arbitrum, Avalanche, OP, Polygon and Unichain, with no gas needed on any of them." },
  { name: "App Kit", text: "Powers swaps between USDC, EURC and cirBTC on Arc, with a guaranteed minimum on every swap." },
  { name: "EURC and cirBTC", text: "More than dollars: users can hold and swap into euro stablecoins and Bitcoin on Arc." },
];

const MILESTONES = [
  { title: "Email sign up with an automatic wallet", text: "Confirmed email, then a USDC wallet on Arc created automatically." },
  { title: "Live naira and USDC pricing", text: "A live exchange rate, prices held for 10 minutes, and a clear service fee." },
  { title: "Airtime and data paid with USDC", text: "MTN, Airtel, Glo and 9mobile, paid on Arc and delivered through our VTU partner's test environment." },
  { title: "Instant status and automatic refunds", text: "Orders update in seconds, and failed deliveries are refunded to the wallet without anyone asking." },
  { title: "Smart wallets with no network fees", text: "Every user moved to a smart wallet with sponsored gas; existing balances moved across automatically." },
  { title: "Send USDC to seven networks", text: "Crosschain transfers through Circle Gateway, a personal wallet on each network, and Move to Arc to bring it all home." },
  { title: "Every transfer recorded and checked", text: "Each step from deposit to mint is recorded, stuck transfers raise alerts, and a daily report checks every transfer against Circle." },
  { title: "Swaps on Arc", text: "USDC, EURC and cirBTC, with a fee shown upfront and a minimum you are guaranteed." },
  { title: "Admin dashboard and security review", text: "Full operations dashboard, a code audit, and the fixes that came from it, including password reset." },
  { title: "Public testing on Arc Testnet", text: "Early testers using the platform and shaping it with their feedback." },
  { title: "Live on Arc mainnet", text: "Real USDC wallets on Arc mainnet for every user, with sending to other networks and swaps ready to open." },
];

const ROADMAP = [
  { title: "Company registration", text: "Registering dataonchain with the Corporate Affairs Commission (CAC) in Nigeria.", status: "In progress" },
  { title: "Bridge and swaps on Arc mainnet", text: "Deployed on Arc mainnet and opening to everyone soon.", status: "In progress" },
  { title: "Live airtime and data delivery", text: "Connecting a live VTU provider once registration is complete.", status: "Planned" },
  { title: "Full launch on Arc mainnet", text: "Real USDC payments for airtime and data, for everyone in Nigeria.", status: "Planned" },
  { title: "Easier ways to add and cash out USDC", text: "Simple on and off ramps between naira and USDC.", status: "Planned" },
  { title: "Paying providers directly on Arc", text: "Settling with VTU providers in USDC on Arc as they start to accept it.", status: "Planned" },
];

const FAQ: { q: string; a: string }[] = [
  {
    q: "What is dataonchain?",
    a: "A website where you buy airtime and mobile data for any Nigerian line and pay with USDC, a digital dollar, on the Arc blockchain. You can also send USDC to other blockchains and swap between USDC, EURC and cirBTC.",
  },
  {
    q: "Is dataonchain live?",
    a: "Yes, on Arc mainnet, with real USDC. You can sign up, get your wallet and add USDC today. Buying airtime and data opens after our company registration and a live provider are in place, and sending to other networks and swaps open soon.",
  },
  {
    q: "How do I add USDC?",
    a: "Open Add USDC from your dashboard and copy your address, or scan the QR code. From an exchange or another wallet, send USDC and choose Arc as the network. USDC sent on any other network, or any other token, may be lost.",
  },
  {
    q: "Do I need a crypto wallet, a seed phrase or any crypto knowledge?",
    a: "No. When you confirm your email, a smart wallet on Arc is created for you through Circle's wallet service. There is no seed phrase to write down and nothing to install. You log in with your email and password like any other website.",
  },
  {
    q: "Which networks and amounts can I buy?",
    a: "MTN, Airtel, Glo and 9mobile. Airtime from ₦50 to ₦50,000 per purchase, and the data plans each network offers, shown with their naira price. You can top up your own number or anyone else's.",
  },
  {
    q: "How is the USDC price worked out?",
    a: "We convert the naira price with a live exchange rate and add a small service fee. You see the exact USDC amount, the rate and the fee before you pay, and that price is held for 10 minutes.",
  },
  {
    q: "Do I pay a network (gas) fee?",
    a: "No. Arc charges its network fee in USDC, and we pay it for you. You pay only the price shown.",
  },
  {
    q: "How fast is delivery?",
    a: "Usually a few seconds. Your payment settles on Arc in under a second and the order goes to the network straight away. The order page updates live as each step completes.",
  },
  {
    q: "What happens if my airtime or data does not arrive?",
    a: "If the network cannot deliver, your USDC is refunded to your wallet automatically, usually within a minute, and the order page shows the refund transaction. If a network takes long to answer, the order shows Checking while we confirm with them; it then ends either delivered or refunded.",
  },
  {
    q: "I typed the wrong number. Can I get my money back?",
    a: "If the number is valid, the airtime or data is delivered to it and cannot be reversed, so please check the number and the network before you pay. A number that is not valid simply fails, and you are refunded automatically.",
  },
  {
    q: "What is Send to another network?",
    a: "It moves USDC from your Arc wallet to your own wallet on Base, Arbitrum, Avalanche, OP, Polygon or Unichain, or to an approved provider, through Circle Gateway. You pay no gas on any network, only Circle's fee, which is shown before you confirm. A transfer can take up to about 20 minutes while the networks confirm it, and Move to Arc brings your USDC back.",
  },
  {
    q: "Are there limits on sending?",
    a: "Yes, at launch: 1 to 50 USDC per transfer and 100 USDC per day, one transfer at a time.",
  },
  {
    q: "Can I send USDC to any wallet address?",
    a: "Not yet. For safety, USDC can only go to your own wallets on the supported networks or to approved providers. Sending to any address you choose may come later.",
  },
  {
    q: "How do swaps work?",
    a: "On the Swap page, pick two of USDC, EURC and cirBTC and enter an amount. You see what you get, the fee (0.5%) and the minimum you are guaranteed. If the price moves below that minimum, the swap is cancelled and nothing is taken. Some pairs may have no price at times.",
  },
  {
    q: "Is my money safe?",
    a: "Every payment, refund and swap is a real transaction on Arc that you can open in the Arc explorer from your order page. Payments that fail are refunded automatically, and every crosschain transfer is recorded step by step and checked against Circle every day.",
  },
  {
    q: "I forgot my password. What do I do?",
    a: "Click Forgot password? on the login page and enter your email. We send a link to choose a new password; it works once and expires after an hour. Your wallet and balance stay exactly as they were.",
  },
  {
    q: "Why Arc?",
    a: "Fees are paid in USDC, payments are final in under a second, and Arc comes from Circle, the issuer of USDC, with wallets, gas sponsorship, crosschain transfers and swaps built in. See the Why Arc section above for more.",
  },
  {
    q: "How do I contact you?",
    a: `Chat with us on WhatsApp at ${SUPPORT_WHATSAPP_DISPLAY}. If it is about an order, use the Report a problem button on the order page: it sends us the order reference so we can help faster.`,
  },
  {
    q: "Is dataonchain a registered company?",
    a: "Our registration with the Corporate Affairs Commission (CAC) in Nigeria is in progress. Buying airtime and data opens after it is complete.",
  },
];

function SectionTitle({ id, kicker, title, text }: { id: string; kicker: string; title: string; text?: string }) {
  return (
    <div id={id} className="scroll-mt-24">
      <p className="text-sm font-semibold uppercase tracking-wider text-emerald-700 dark:text-emerald-400">{kicker}</p>
      <h2 className="mt-2 text-3xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h2>
      {text ? <p className="mt-3 max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-400">{text}</p> : null}
    </div>
  );
}

export default function Home() {
  return (
    <main className="min-h-screen bg-zinc-50 dark:bg-zinc-950">
      <header className="sticky top-0 z-20 border-b border-zinc-200/70 bg-zinc-50/90 backdrop-blur dark:border-zinc-800 dark:bg-zinc-950/90">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3">
          <Link href="/" className="font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <nav className="hidden gap-5 text-sm text-zinc-600 md:flex dark:text-zinc-400">
            {NAV.map((n) => (
              <a key={n.href} href={n.href} className="hover:text-zinc-900 dark:hover:text-zinc-100">
                {n.label}
              </a>
            ))}
          </nav>
          <div className="flex gap-2">
            <Link href="/login" className="rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:text-zinc-300 dark:hover:bg-zinc-900">
              Log in
            </Link>
            <Link href="/signup" className="rounded-lg bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-800">
              Sign up
            </Link>
          </div>
        </div>
      </header>

      {/* Hero */}
      <section className="mx-auto max-w-5xl px-4 pb-16 pt-16 sm:pt-24">
        <p className="inline-flex items-center gap-2 rounded-full border border-amber-300 bg-amber-50 px-3 py-1 text-xs font-medium text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">
          <span className="h-1.5 w-1.5 rounded-full bg-amber-500" />
          Live on Arc mainnet · buying airtime and data opens soon
        </p>
        <h1 className="mt-6 max-w-3xl text-4xl font-semibold tracking-tight text-zinc-900 sm:text-6xl dark:text-zinc-50">
          Buy airtime and data with USDC.
        </h1>
        <p className="mt-5 max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-400">
          Top up any MTN, Airtel, Glo or 9mobile line in seconds. Paid in USDC on Arc, delivered to the phone, refunded
          automatically if anything goes wrong.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Link href="/signup" className="rounded-lg bg-emerald-700 px-5 py-3 font-medium text-white hover:bg-emerald-800">
            Create an account
          </Link>
          <a
            href="#about"
            className="rounded-lg border border-zinc-300 px-5 py-3 font-medium text-zinc-900 hover:bg-white dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-900"
          >
            Learn about the project
          </a>
        </div>
        <dl className="mt-14 grid grid-cols-2 gap-6 border-t border-zinc-200 pt-8 sm:grid-cols-4 dark:border-zinc-800">
          {[
            ["4", "Nigerian networks"],
            ["7", "blockchains connected"],
            ["0", "network fees for users"],
            ["< 1 s", "settlement on Arc"],
          ].map(([value, text]) => (
            <div key={text}>
              <dt className="text-3xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-50">{value}</dt>
              <dd className="mt-1 text-sm text-zinc-500">{text}</dd>
            </div>
          ))}
        </dl>
      </section>

      {/* About */}
      <section className="border-t border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="about"
            kicker="About"
            title="Digital dollars for everyday spending"
            text="Many Nigerians already hold dollar stablecoins, but spending them on daily needs still means selling to someone, waiting, and paying fees along the way. dataonchain lets you spend USDC directly on the thing you buy most often: airtime and mobile data. You sign up with an email, we handle the blockchain, and the top up lands on the phone."
          />
          <ol className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
            {HOW.map((h, i) => (
              <li key={h.title} className="rounded-xl border border-zinc-200 p-5 dark:border-zinc-800">
                <span className="flex h-8 w-8 items-center justify-center rounded-full bg-emerald-700 text-sm font-semibold text-white">{i + 1}</span>
                <h3 className="mt-4 font-semibold text-zinc-900 dark:text-zinc-50">{h.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{h.text}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* Why Arc */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="why-arc"
            kicker="Why Arc"
            title="Why we are building on Arc"
            text="A payment for airtime has to be cheap, instant and simple, or nobody will use it. Arc, the blockchain built by Circle for stablecoin payments, gives us all three."
          />
          <div className="mt-12 grid gap-5 sm:grid-cols-2">
            {WHY_ARC.map((w) => (
              <div key={w.title} className="rounded-xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
                <h3 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{w.title}</h3>
                <p className="mt-2 leading-relaxed text-zinc-600 dark:text-zinc-400">{w.text}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Tools */}
      <section className="border-y border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle
            id="tools"
            kicker="Built with"
            title="The Arc and Circle tools behind dataonchain"
            text="Everything a user touches runs on these building blocks. They are why a small team could get from an idea to a working product with wallets, crosschain transfers and swaps."
          />
          <div className="mt-12 grid gap-px overflow-hidden rounded-xl border border-zinc-200 bg-zinc-200 sm:grid-cols-2 lg:grid-cols-3 dark:border-zinc-800 dark:bg-zinc-800">
            {TOOLS.map((t) => (
              <div key={t.name} className="bg-white p-6 dark:bg-zinc-900">
                <h3 className="font-semibold text-emerald-800 dark:text-emerald-300">{t.name}</h3>
                <p className="mt-2 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{t.text}</p>
              </div>
            ))}
            <div className="hidden bg-white p-6 sm:block dark:bg-zinc-900" />
            <div className="hidden bg-white p-6 lg:block dark:bg-zinc-900" />
          </div>
        </div>
      </section>

      {/* Milestones */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle id="milestones" kicker="Milestones" title="What we have built so far" text="Built and tested in public on Arc Testnet, and now live on Arc mainnet." />
          <ol className="mt-12 grid gap-x-10 sm:grid-cols-2">
            {MILESTONES.map((m) => (
              <li key={m.title} className="flex gap-4 border-b border-zinc-200 py-5 dark:border-zinc-800">
                <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-emerald-700 text-xs font-bold text-white">✓</span>
                <div>
                  <h3 className="font-semibold text-zinc-900 dark:text-zinc-50">{m.title}</h3>
                  <p className="mt-1 text-sm leading-relaxed text-zinc-600 dark:text-zinc-400">{m.text}</p>
                </div>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* Roadmap */}
      <section className="border-t border-zinc-200 bg-white py-20 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="mx-auto max-w-5xl px-4">
          <SectionTitle id="roadmap" kicker="Roadmap" title="What comes next" text="The road from public testing to a live product for everyone in Nigeria." />
          <ol className="relative mt-12 space-y-8 border-l-2 border-zinc-200 pl-8 dark:border-zinc-800">
            {ROADMAP.map((r) => (
              <li key={r.title} className="relative">
                <span
                  className={`absolute -left-[41px] top-1 h-4 w-4 rounded-full border-2 ${
                    r.status === "In progress"
                      ? "border-amber-500 bg-amber-400"
                      : r.status === "Next"
                        ? "border-emerald-600 bg-white dark:bg-zinc-900"
                        : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900"
                  }`}
                />
                <div className="flex flex-wrap items-center gap-3">
                  <h3 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{r.title}</h3>
                  <span
                    className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${
                      r.status === "In progress"
                        ? "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
                        : r.status === "Next"
                          ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                          : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                    }`}
                  >
                    {r.status}
                  </span>
                </div>
                <p className="mt-1 text-zinc-600 dark:text-zinc-400">{r.text}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* FAQ */}
      <section className="py-20">
        <div className="mx-auto max-w-3xl px-4">
          <SectionTitle id="faq" kicker="FAQ" title="Questions people ask" />
          <div className="mt-10 divide-y divide-zinc-200 rounded-xl border border-zinc-200 bg-white dark:divide-zinc-800 dark:border-zinc-800 dark:bg-zinc-900">
            {FAQ.map((f) => (
              <details key={f.q} className="group px-5">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 py-4 font-medium text-zinc-900 dark:text-zinc-50 [&::-webkit-details-marker]:hidden">
                  {f.q}
                  <span className="shrink-0 text-xl leading-none text-emerald-700 transition group-open:rotate-45 dark:text-emerald-400">+</span>
                </summary>
                <p className="pb-5 leading-relaxed text-zinc-600 dark:text-zinc-400">{f.a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* Call to action */}
      <section className="py-20">
        <div className="mx-auto max-w-5xl px-4">
          <div className="rounded-2xl bg-emerald-800 px-6 py-12 text-center sm:px-12">
            <h2 className="text-3xl font-semibold tracking-tight text-white">Get started</h2>
            <p className="mx-auto mt-3 max-w-xl text-emerald-100">
              Create an account and get your USDC wallet on Arc in a minute. Buying airtime and data, sending to other
              networks and swaps open soon.
            </p>
            <div className="mt-8 flex flex-wrap justify-center gap-3">
              <Link href="/signup" className="rounded-lg bg-white px-5 py-3 font-medium text-emerald-900 hover:bg-emerald-50">
                Create an account
              </Link>
              <Link href="/login" className="rounded-lg border border-emerald-500 px-5 py-3 font-medium text-white hover:bg-emerald-700">
                Log in
              </Link>
            </div>
          </div>
        </div>
      </section>

      <footer className="border-t border-zinc-200 py-8 dark:border-zinc-800">
        <div className="mx-auto flex max-w-5xl flex-col gap-4 px-4 text-sm text-zinc-500 sm:flex-row sm:items-center sm:justify-between">
          <div className="space-y-1">
            <p>© {new Date().getFullYear()} dataonchain · Built on Arc</p>
            <p>Live on Arc mainnet.</p>
          </div>
          <nav className="flex flex-wrap items-center gap-x-5 gap-y-2">
            <Link href="/terms" className="hover:text-zinc-900 dark:hover:text-zinc-100">Terms</Link>
            <Link href="/privacy" className="hover:text-zinc-900 dark:hover:text-zinc-100">Privacy</Link>
            <Link href="/refund-policy" className="hover:text-zinc-900 dark:hover:text-zinc-100">Refunds</Link>
            <SupportLink>WhatsApp {SUPPORT_WHATSAPP_DISPLAY}</SupportLink>
          </nav>
        </div>
      </footer>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/terms/page.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import Link from "next/link";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Terms of Service · dataonchain" };

export default function TermsPage() {
  return (
    <LegalPage
      title="Terms of Service"
      updated="28 October 2026"
      intro={
        <p>
          These terms are the agreement between you and dataonchain when you use our website and services. By creating an
          account or using the service, you agree to them. Please read them together with our{" "}
          <Link href="/privacy" className="text-emerald-700 underline dark:text-emerald-400">Privacy Policy</Link> and{" "}
          <Link href="/refund-policy" className="text-emerald-700 underline dark:text-emerald-400">Refund Policy</Link>.
        </p>
      }
    >
      <h2>1. Who we are</h2>
      <p>
        dataonchain is a service, based in Nigeria, that lets you buy airtime and mobile data for Nigerian phone lines and
        pay with USDC on the Arc blockchain. Our registration with the Corporate Affairs Commission (CAC) is in progress.
        When it is complete, this page will show our registered name and address.
      </p>

      <h2>2. Launch on Arc mainnet</h2>
      <p>dataonchain runs on Arc mainnet with real USDC. Features open step by step:</p>
      <ul>
        <li>Buying airtime and data opens after our company registration and a live provider are in place.</li>
        <li>Sending to other networks and swaps open when we announce them on the website.</li>
        <li>Limits apply while we launch, and features, limits and fees may change. We may pause a feature for maintenance or safety.</li>
      </ul>

      <h2>3. Who can use dataonchain</h2>
      <ul>
        <li>You must be at least 18 years old and able to enter into a binding agreement.</li>
        <li>You must give true details (name, email and Nigerian phone number) and keep them up to date.</li>
        <li>You must not use dataonchain where the law does not allow it, or on behalf of someone who is not allowed to use it.</li>
      </ul>

      <h2>4. Your account</h2>
      <ul>
        <li>You need a confirmed email address to buy, send or swap.</li>
        <li>Keep your password secret. You are responsible for what happens in your account unless it was caused by our failure.</li>
        <li>Tell us straight away on WhatsApp if you think someone else has used your account, and reset your password.</li>
      </ul>

      <h2>5. Your wallet</h2>
      <p>
        When you confirm your email, we create a smart wallet for you on Arc using Circle&apos;s wallet service. You do not
        get a seed phrase: dataonchain operates the wallet through Circle on your behalf. This means:
      </p>
      <ul>
        <li>We only move funds from your wallet when you ask (a purchase, a transfer or a swap), to return funds to you (a refund or moving to your new wallet), or when the law requires it.</li>
        <li>We also create wallets for you on the other supported networks when you first send to them. They work the same way.</li>
        <li>Only send USDC, EURC or cirBTC on Arc to your Arc wallet address. Tokens sent on another network, or other tokens, may be lost and we may not be able to recover them.</li>
        <li>Blockchain transactions are final. Once a payment or transfer is confirmed on the network, it cannot be reversed.</li>
      </ul>

      <h2>6. Buying airtime and data</h2>
      <ul>
        <li>Before you pay, we show the naira value, the exact USDC price, the exchange rate and our service fee. That price is held for 10 minutes.</li>
        <li>Check the phone number and the network before you pay. Airtime or data delivered to a valid number cannot be reversed.</li>
        <li>Delivery is done by our airtime and data provider and the mobile network. It usually takes seconds but can take longer when a network is slow.</li>
        <li>If delivery fails, you are refunded as set out in our Refund Policy.</li>
      </ul>

      <h2>7. Sending to other networks</h2>
      <ul>
        <li>You can send USDC from Arc to your own wallets on the supported networks, or to approved providers, through Circle Gateway. You can also bring it back to Arc.</li>
        <li>Circle charges a fee for each transfer, shown before you confirm. We do not add our own fee to transfers.</li>
        <li>Transfers can take up to about 20 minutes. Limits apply per transfer and per day, and you can have one transfer in progress at a time.</li>
        <li>We may refuse or pause transfers, for example when Circle&apos;s fee is unusually high or for security reasons.</li>
      </ul>

      <h2>8. Swaps</h2>
      <ul>
        <li>Swaps between USDC, EURC and cirBTC on Arc use third party liquidity. Prices are set by the market, not by us, and some pairs may have no price at times.</li>
        <li>Our swap fee (currently 0.5%) is included in the amount shown. Before you confirm, we show the minimum you will receive. If the price moves below it, the swap is cancelled and nothing is taken.</li>
      </ul>

      <h2>9. Fees</h2>
      <p>
        Every fee is shown before you confirm: the service fee in each airtime or data price, Circle&apos;s fee for transfers,
        and the swap fee. You do not pay network (gas) fees for your Arc wallet; we cover them. We may change our fees, and
        any change applies only to purchases made after it.
      </p>

      <h2>10. Things you must not do</h2>
      <ul>
        <li>Use dataonchain for fraud, money laundering, terrorist financing, sanctions evasion or any other unlawful purpose.</li>
        <li>Use stolen funds, or someone else&apos;s account or details without permission.</li>
        <li>Try to break, overload, copy or get around the security of the service.</li>
        <li>Abuse refunds, limits or promotions.</li>
      </ul>
      <p>We may ask you to verify your identity, and we may report suspicious activity to the authorities where the law requires it.</p>

      <h2>11. Suspension and closing accounts</h2>
      <p>
        We may suspend or close an account that breaks these terms, puts other users or the service at risk, or where the
        law requires it. A suspended account cannot start new purchases, transfers or swaps, but orders already in progress
        are completed and refunds are still sent. You can ask us to close your account at any time on WhatsApp. Any balance
        in your wallets must be moved out first.
      </p>

      <h2>12. Availability and changes</h2>
      <p>
        We work to keep dataonchain available, but we do not promise it will always be. We may pause parts of the service
        for maintenance or safety, and we may add, change or remove features. If we make a change that affects you
        significantly, we will tell you on the website.
      </p>

      <h2>13. Services we rely on</h2>
      <p>
        dataonchain depends on services we do not control, including the Arc blockchain, Circle (wallets, transfers and
        swaps), our airtime and data provider, the mobile networks, and our hosting and email providers. We are not
        responsible for their failures, but when one of them affects your order we will do what we reasonably can to help,
        including refunds where our Refund Policy applies.
      </p>

      <h2>14. Risks you should know</h2>
      <ul>
        <li>Stablecoins aim to keep a steady value but are not guaranteed. cirBTC and other tokens can change in value quickly.</li>
        <li>Blockchains and smart contracts can have faults, delays or outages.</li>
        <li>Laws about digital assets can change and may affect what we can offer.</li>
      </ul>

      <h2>15. Our responsibility to you</h2>
      <p>
        Nothing in these terms limits rights you have under Nigerian consumer protection law that cannot be limited. Apart
        from that, and as far as the law allows, we are not responsible for indirect or unforeseeable losses, and our total
        responsibility for any one claim is limited to the amount of the transaction it relates to.
      </p>

      <h2>16. Changes to these terms</h2>
      <p>
        We may update these terms. The date at the top shows the latest version. If a change is significant, we will tell
        you on the website before it applies. Continuing to use dataonchain after that means you accept the new terms.
      </p>

      <h2>17. Law and disputes</h2>
      <p>
        These terms are governed by the laws of the Federal Republic of Nigeria. If something goes wrong, please contact us
        first on WhatsApp so we can try to fix it. If we cannot agree, the dispute will be settled by the courts of Nigeria.
      </p>
    </LegalPage>
  );
}
DOC_EOF
(cd frontend && npm run build) || fail "Website build failed (details above). The site is already on mainnet; paste the output to Claude."
git add -A frontend
git diff --cached --quiet || git commit -q -m "Website: live on Arc mainnet"
git push
wait_for "the website wording" "$PROD_FRONTEND/" 'Live on Arc mainnet' 30 || yellow "Vercel has not published it yet. Check vercel.com in a few minutes."

echo
green "Script 28 complete. dataonchain is live on Arc mainnet."
echo "  Status: $PROD_API/api/status   (network: mainnet)"
echo "  Users can sign up, get their mainnet wallet and add USDC."
echo "  Buying, bridge and swaps show 'coming soon' (admin dashboard > Settings to open them later)."
echo "  Mainnet treasury on Arc: $MAIN_TREASURY"
echo
bold "Before you open the bridge or swaps:"
echo "  1. Your lawyer's answer on SEC registration"
echo "  2. Circle Gas Station on mainnet (Arc and the 6 networks), with spend limits and billing"
echo "  3. An always on server (Render paid plan, or a free uptime ping) so transfers never stall"
echo "  4. Ask Claude for the live check script (about 1 real USDC to Base and back, and a small swap)"
