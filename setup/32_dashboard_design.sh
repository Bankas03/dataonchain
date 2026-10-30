#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 32: a new look for the dashboard
#
#   - A balance card styled like a dollar note: your USDC balance in large
#     type, about how much it is in naira, EURC and cirBTC, and your address
#   - Big buttons for Add USDC, Send, Swap, To Base, and Airtime and data
#     (marked Soon while buying is paused)
#   - One "Recent activity" list with your sends, swaps, transfers and orders
#   - New fonts across the website (Figtree, with Bricolage Grotesque for
#     balances and headings), and matching light and dark colours
#   No database change. The API also returns the naira rate with the wallet.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/32_dashboard_design.sh
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
  done < <(cat "$ENV_FILE" backend/.env.mainnet 2>/dev/null | grep -E '^[A-Z0-9_]+=')
  if [[ -n "$found" ]]; then
    git diff --cached --name-only
    git reset -q
    fail "The value of$found is inside one of the files above. Nothing was committed. Delete that file or remove the secret, then run again."
  fi
}

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

prod_token() {
  local t
  t="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
  [[ "$t" == eyJ* ]] || fail "Could not create a production database token"
  printf '%s' "$t"
}

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v turso >/dev/null || fail "Turso CLI not found"
[[ -f backend/src/send/service.ts ]] || fail "Run this from ~/dataonchain after script 31"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/32_dashboard_design.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "backend/src" "frontend/src/app" "frontend/src/app/dashboard" "frontend/src/components"
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
import { getCurrentRate } from "./pricing/rates";
import { NETWORK_NAMES, ensureUserWallet, previousWallet } from "./wallets/service";
import { SwapError, TOKENS, executeSwap, listSwaps, quoteSwap, tokenBalances } from "./swap/service";
import { SendError, confirmSend, getSendView, listSends, sendInfo, startSend } from "./send/service";
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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
  // For the "about ₦…" line under the balance (the live market rate, before our fee)
  let ngnPerUsdc: number | null = null;
  try {
    ngnPerUsdc = (await getCurrentRate()).koboPerUsdc / 100;
  } catch {
    ngnPerUsdc = null;
  }
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
    ngnPerUsdc,
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
    return c.json({ destinations: await listDestinations(), limits: { min: env.BRIDGE_MIN_USDC, max: env.BRIDGE_MAX_USDC, daily: env.BRIDGE_DAILY_USDC }, networkFee: env.BRIDGE_NETWORK_FEE_USDC });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

app.post("/api/bridge/quote", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const paused = await pausedMessage("bridgePaused", user.email);
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
  const paused = await pausedMessage("bridgePaused", user.email);
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
    return c.json({ wallets: await chainBalances(user.id), networkFee: env.BRIDGE_NETWORK_FEE_USDC });
  } catch (err) {
    return bridgeErrors(err, c);
  }
});

// "Move to Arc": everything in the user's wallet on that network comes home
app.post("/api/bridge/return", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const paused = await pausedMessage("bridgePaused", user.email);
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
  const paused = await pausedMessage("swapPaused", user.email);
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
  const paused = await pausedMessage("swapPaused", user.email);
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

// ---------------------------------------------------------------------------
// Send USDC, EURC or cirBTC to another wallet on Arc, confirmed with an emailed code
// ---------------------------------------------------------------------------
function sendErrors(err: unknown, c: Context) {
  if (err instanceof SendError) return c.json({ error: err.message }, err.status);
  throw err;
}

app.get("/api/send/info", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  return c.json({ ...(await sendInfo(user.id)), paused: await pausedMessage("sendPaused", user.email) });
});

app.post("/api/send", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const paused = await pausedMessage("sendPaused", user.email);
  if (paused) return c.json({ error: paused }, 503);
  const body = (await c.req.json().catch(() => ({}))) as { token?: unknown; amount?: unknown; toAddress?: unknown; confirmNetwork?: unknown };
  try {
    return c.json({ send: await startSend({ id: user.id, email: user.email, name: user.name }, body) });
  } catch (err) {
    return sendErrors(err, c);
  }
});

app.post("/api/send/:id/confirm", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const paused = await pausedMessage("sendPaused", user.email);
  if (paused) return c.json({ error: paused }, 503);
  const body = (await c.req.json().catch(() => ({}))) as { code?: unknown };
  try {
    return c.json({ send: await confirmSend(user.id, c.req.param("id"), body.code) });
  } catch (err) {
    return sendErrors(err, c);
  }
});

app.get("/api/sends", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ sends: await listSends(user.id) });
});

app.get("/api/sends/:id", requireAuth, async (c) => {
  const { user } = c.get("auth");
  const send = await getSendView(user.id, c.req.param("id"));
  if (!send) return c.json({ error: "Send not found" }, 404);
  return c.json({ send });
});

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
DOC_EOF
cat > "frontend/src/app/dashboard/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { ActivityFeed } from "@/components/ActivityFeed";
import { ChainWallets } from "@/components/ChainWallets";
import { SupportLink } from "@/components/SupportLink";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

type Status = {
  bridge?: boolean;
  swap?: boolean;
  network?: string;
  notices?: string[];
  paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean; sendPaused?: boolean };
};

function greeting() {
  const h = Number(new Date().toLocaleString("en-GB", { hour: "numeric", hour12: false, timeZone: "Africa/Lagos" }));
  return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening";
}

const icon = (path: ReactNode) => (
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {path}
  </svg>
);

const ICONS = {
  add: icon(<path d="M12 5v14M5 12h14" />),
  send: icon(<path d="M7 17 17 7M9 7h8v8" />),
  swap: icon(<path d="M7 4 3 8l4 4M3 8h14M17 20l4-4-4-4M21 16H7" />),
  bridge: icon(<path d="M4 12a8 8 0 0 1 16 0M12 4v16M4 12h16" />),
  airtime: icon(<path d="M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2" />),
};

type Action = { href: string; label: string; icon: ReactNode; soon?: boolean; primary?: boolean };

function ActionTile({ a }: { a: Action }) {
  const circle = a.primary
    ? "bg-note text-white group-hover:bg-note-deep dark:bg-mint dark:text-note-deep dark:group-hover:bg-mint/90"
    : "bg-white text-ink ring-1 ring-ink/10 group-hover:bg-paper dark:bg-white/[0.06] dark:text-white dark:ring-white/10 dark:group-hover:bg-white/10";
  const inner = (
    <>
      <span className={`relative flex h-14 w-14 items-center justify-center rounded-2xl transition-colors ${circle} ${a.soon ? "opacity-50" : ""}`}>
        {a.icon}
        {a.soon ? (
          <span className="absolute -right-2 -top-2 rounded-full bg-gold px-1.5 py-0.5 text-[10px] font-bold text-note-deep">Soon</span>
        ) : null}
      </span>
      <span className={`text-center text-xs font-semibold leading-tight sm:text-sm ${a.soon ? "text-zinc-500" : "text-ink dark:text-white"}`}>{a.label}</span>
    </>
  );
  if (a.soon) {
    return (
      <span className="flex flex-col items-center gap-2" aria-disabled="true" title="Coming soon">
        {inner}
      </span>
    );
  }
  return (
    <Link href={a.href} className="group flex flex-col items-center gap-2 rounded-2xl focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-emerald-600">
      {inner}
    </Link>
  );
}

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [status, setStatus] = useState<Status | null>(null);

  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: Status) => setStatus(s))
      .catch(() => setStatus({}));
  }, []);

  useEffect(() => {
    if (isPending || data) return;
    // A failed confirmation link lands here with ?error=...
    const failedLink = new URLSearchParams(window.location.search).has("error");
    router.replace(failedLink ? "/login?error=link" : "/login");
  }, [isPending, data, router]);

  if (isPending || !data) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-paper text-zinc-500 dark:bg-[#07120e]">
        <span className="h-8 w-8 animate-spin rounded-full border-2 border-note/20 border-t-note dark:border-white/10 dark:border-t-mint" aria-label="Loading" />
      </main>
    );
  }

  const { user } = data;
  const mainnet = status?.network === "mainnet";
  const bridgeOn = Boolean(status?.bridge);
  const swapOn = Boolean(status?.swap);
  const buyPaused = Boolean(status?.paused?.purchasesPaused);
  const first = user.name.split(" ")[0];

  // Testnet maintenance notice (on mainnet the notices say what opens soon)
  const paused: string[] = [];
  if (status?.paused?.purchasesPaused) paused.push("buying airtime and data");
  if (status?.paused?.bridgePaused && bridgeOn) paused.push("sending to other networks");
  if (status?.paused?.swapPaused && swapOn) paused.push("swaps");
  if (status?.paused?.sendPaused) paused.push("sending to other wallets");
  // On mainnet, buying airtime and data shows as "Soon" on its button instead
  const notices = (status?.notices ?? []).filter((n) => !(mainnet && /airtime and data/i.test(n)));

  const actions: Action[] = [
    { href: "/add-usdc", label: "Add USDC", icon: ICONS.add, primary: true },
    { href: "/send", label: "Send", icon: ICONS.send },
    ...(swapOn ? [{ href: "/swap", label: "Swap", icon: ICONS.swap }] : []),
    ...(bridgeOn ? [{ href: "/bridge", label: "To Base", icon: ICONS.bridge }] : []),
    { href: "/buy", label: "Airtime and data", icon: ICONS.airtime, soon: mainnet && buyPaused },
  ];

  async function logOut() {
    await authClient.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-2xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <nav className="flex items-center gap-1">
            <Link
              href="/account"
              className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10"
            >
              Account
            </Link>
            <button
              onClick={logOut}
              className="rounded-full px-3 py-2 text-sm font-semibold text-zinc-600 hover:bg-white dark:text-zinc-400 dark:hover:bg-white/10"
            >
              Log out
            </button>
          </nav>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink sm:text-4xl dark:text-white">
          {greeting()}, {first}
        </h1>

        {user.status === "suspended" ? (
          <p className="mt-4 rounded-2xl bg-red-50 px-4 py-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
            Your account is suspended. Please contact support. Orders already in progress still complete, and refunds still go out.
          </p>
        ) : null}
        {!user.emailVerified ? (
          <p className="mt-4 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Confirm your email to use your wallet: open the link we sent to {user.email}.
          </p>
        ) : null}

        <div className="mt-6">
          <WalletCard />
        </div>

        <nav aria-label="Actions" className={`mt-6 grid gap-2 ${actions.length >= 5 ? "grid-cols-5" : "grid-cols-4"}`}>
          {actions.map((a) => (
            <ActionTile key={a.label} a={a} />
          ))}
        </nav>

        {mainnet && notices.length > 0 ? (
          <div className="mt-6 space-y-1 rounded-2xl bg-sky-50 px-4 py-3 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">
            {notices.map((n) => (
              <p key={n}>{n}</p>
            ))}
          </div>
        ) : null}
        {mainnet && buyPaused ? (
          <p className="mt-6 rounded-2xl bg-white px-4 py-3 text-sm text-zinc-600 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:text-zinc-300 dark:ring-white/10">
            Buying airtime and data with USDC is coming soon. Until then you can add, send, swap and move your USDC.
          </p>
        ) : null}
        {!mainnet && status && paused.length > 0 ? (
          <p className="mt-6 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Short maintenance: {paused.join(", ")} {paused.length > 1 ? "are" : "is"} paused for now. Your balance is safe.
          </p>
        ) : null}

        <div className="mt-6">
          <ActivityFeed bridgeOn={bridgeOn} swapOn={swapOn} />
        </div>

        {bridgeOn ? <ChainWallets /> : null}

        <p className="mt-10 text-center text-sm text-zinc-500">
          Need help? <SupportLink />
        </p>
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/globals.css" <<'DOC_EOF'
@import "tailwindcss";

/* Dark mode follows the "dark" class on <html> (set by the theme switch, or
   from the phone or computer setting until the user picks one). */
@custom-variant dark (&:where(.dark, .dark *));

:root {
  --background: #ffffff;
  --foreground: #171717;
  color-scheme: light;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-body), Arial, Helvetica, sans-serif;
  --font-display: var(--font-display-face), var(--font-body), Arial, sans-serif;
  --font-mono: var(--font-geist-mono);
}

/* dataonchain colours: a dollar note green, a fresh mint for money moving in,
   a warm gold for naira, on a cool paper white */
@theme {
  --color-note: #0b3b2e;
  --color-note-deep: #062a20;
  --color-mint: #3ddc97;
  --color-gold: #f0c35a;
  --color-paper: #eef3f0;
  --color-ink: #10241d;
}

:root.dark {
  --background: #0a0a0a;
  --foreground: #ededed;
  color-scheme: dark;
}

body {
  background: var(--background);
  color: var(--foreground);
  font-family: var(--font-body), Arial, Helvetica, sans-serif;
}

@media (prefers-reduced-motion: no-preference) {
  .balance-in {
    animation: balance-in 600ms cubic-bezier(0.2, 0.7, 0.2, 1) both;
  }
}
@keyframes balance-in {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
DOC_EOF
cat > "frontend/src/app/layout.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import { Bricolage_Grotesque, Figtree, Geist_Mono } from "next/font/google";
import { ThemeToggle } from "@/components/ThemeToggle";
import "./globals.css";

// Figtree for reading, Bricolage Grotesque for balances and headings
const body = Figtree({
  variable: "--font-body",
  subsets: ["latin"],
});

const display = Bricolage_Grotesque({
  variable: "--font-display-face",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "dataonchain",
  description: "Your USDC wallet on Arc: send, swap and spend digital dollars in Nigeria",
};

// Runs before the page is drawn, so there is no flash of the wrong colours:
// the saved choice, or else the phone or computer setting.
const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem("theme");var d=t==="dark"||(t!=="light"&&window.matchMedia("(prefers-color-scheme: dark)").matches);var r=document.documentElement;if(d){r.classList.add("dark")}else{r.classList.remove("dark")}r.style.colorScheme=d?"dark":"light"}catch(e){}})();`;

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${body.variable} ${display.variable} ${geistMono.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body className="min-h-full flex flex-col">
        {children}
        <ThemeToggle />
      </body>
    </html>
  );
}
DOC_EOF
cat > "frontend/src/components/ActivityFeed.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useEffect, useState, type ReactNode } from "react";
import { api } from "@/lib/api";
import { BRIDGE_DONE, BRIDGE_LABELS, shortAddress, type BridgeListItem } from "@/lib/bridge";
import { STATUS_LABELS, describe, usdc, type OrderView } from "@/lib/orders";

type Tone = "wait" | "good" | "bad";
type Item = {
  key: string;
  kind: "order" | "send" | "swap" | "bridge";
  title: string;
  detail: string;
  amount: string;
  out: boolean; // money leaving the wallet
  status: { text: string; tone: Tone };
  href: string;
  at: number;
};

type SwapRow = { id: string; status: string; tokenIn: string; tokenOut: string; amountIn: string; amountOut: string | null; createdAt: string };
type SendRow = { id: string; status: string; token: string; amount: string; toShort: string; createdAt: string };

const num = (v: string, max = 6) => Number(v).toLocaleString("en-US", { maximumFractionDigits: max });
const decimals = (token: string) => (token === "cirBTC" ? 8 : 6);

function when(ms: number) {
  const d = new Date(ms);
  const today = new Date();
  const time = d.toLocaleTimeString("en-NG", { hour: "numeric", minute: "2-digit" });
  if (d.toDateString() === today.toDateString()) return `Today, ${time}`;
  const y = new Date(today);
  y.setDate(today.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return `Yesterday, ${time}`;
  return d.toLocaleDateString("en-NG", { day: "numeric", month: "short" });
}

const SWAP_STATUS: Record<string, { text: string; tone: Tone }> = {
  COMPLETE: { text: "Done", tone: "good" },
  FAILED: { text: "Cancelled", tone: "bad" },
  UNKNOWN: { text: "Checking", tone: "wait" },
  PENDING: { text: "In progress", tone: "wait" },
};
const SEND_STATUS: Record<string, { text: string; tone: Tone }> = {
  COMPLETE: { text: "Sent", tone: "good" },
  FAILED: { text: "Not sent", tone: "bad" },
  SENDING: { text: "Sending", tone: "wait" },
  SENT: { text: "Sending", tone: "wait" },
};

const TONE_TEXT: Record<Tone, string> = {
  good: "text-emerald-700 dark:text-mint",
  bad: "text-red-700 dark:text-red-400",
  wait: "text-amber-700 dark:text-gold",
};

const ICONS: Record<Item["kind"], ReactNode> = {
  order: <path d="M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2" />,
  send: <path d="M7 17 17 7M9 7h8v8" />,
  swap: <path d="M7 4 3 8l4 4M3 8h14M17 20l4-4-4-4M21 16H7" />,
  bridge: <path d="M4 12a8 8 0 0 1 16 0M12 4v16M4 12h16" />,
};

function toItems(orders: OrderView[], sends: SendRow[], swaps: SwapRow[], bridges: BridgeListItem[]): Item[] {
  const items: Item[] = [];
  for (const o of orders) {
    items.push({
      key: `o-${o.reference}`,
      kind: "order",
      title: describe(o),
      detail: o.phone,
      amount: `${usdc(o.usdcAmount)} USDC`,
      out: true,
      status: STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" },
      href: `/orders/${o.reference}`,
      at: new Date(o.createdAt).getTime(),
    });
  }
  for (const s of sends) {
    items.push({
      key: `s-${s.id}`,
      kind: "send",
      title: `Sent ${s.token}`,
      detail: `To ${s.toShort}`,
      amount: `${num(s.amount, decimals(s.token))} ${s.token}`,
      out: true,
      status: SEND_STATUS[s.status] ?? { text: s.status, tone: "wait" },
      href: "/send",
      at: new Date(s.createdAt).getTime(),
    });
  }
  for (const s of swaps) {
    items.push({
      key: `w-${s.id}`,
      kind: "swap",
      title: `Swapped ${s.tokenIn} to ${s.tokenOut}`,
      detail: s.amountOut ? `Got ${num(s.amountOut, decimals(s.tokenOut))} ${s.tokenOut}` : s.tokenOut,
      amount: `${num(s.amountIn, decimals(s.tokenIn))} ${s.tokenIn}`,
      out: true,
      status: SWAP_STATUS[s.status] ?? { text: s.status, tone: "wait" },
      href: "/swap",
      at: new Date(s.createdAt).getTime(),
    });
  }
  for (const b of bridges) {
    const home = b.direction === "IN";
    items.push({
      key: `b-${b.id}`,
      kind: "bridge",
      title: home ? `Moved to Arc from ${b.sourceChainLabel}` : `Sent to ${b.destinationChainLabel}`,
      detail: home ? "Your Arc wallet" : `To ${shortAddress(b.recipientAddress)}`,
      amount: `${num(b.amount)} USDC`,
      out: !home,
      status: BRIDGE_LABELS[b.status] ?? { text: b.status, tone: "wait" },
      href: `/bridge/${b.id}`,
      at: new Date(b.createdAt).getTime(),
    });
  }
  return items.sort((a, b) => b.at - a.at).slice(0, 8);
}

// Everything the user did, newest first: purchases, sends, swaps and transfers
export function ActivityFeed({ bridgeOn, swapOn }: { bridgeOn: boolean; swapOn: boolean }) {
  const [items, setItems] = useState<Item[] | null>(null);

  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const safe = async <T,>(p: Promise<T>, fallback: T) => {
      try {
        return await p;
      } catch {
        return fallback;
      }
    };
    const load = async () => {
      const [o, s, w, b] = await Promise.all([
        safe(api<{ orders: OrderView[] }>("/orders"), { orders: [] }),
        safe(api<{ sends: SendRow[] }>("/sends"), { sends: [] }),
        swapOn ? safe(api<{ swaps: (SwapRow | null)[] }>("/swaps"), { swaps: [] }) : Promise.resolve({ swaps: [] as (SwapRow | null)[] }),
        bridgeOn ? safe(api<{ transfers: BridgeListItem[] }>("/bridge/transfers"), { transfers: [] }) : Promise.resolve({ transfers: [] as BridgeListItem[] }),
      ]);
      if (stop) return;
      setItems(toItems(o.orders, s.sends, w.swaps.filter((x): x is SwapRow => x !== null), b.transfers));
      // Keep it live while anything is still moving
      const moving =
        o.orders.some((x) => ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"].includes(x.status)) ||
        s.sends.some((x) => ["SENDING", "SENT"].includes(x.status)) ||
        b.transfers.some((x) => !BRIDGE_DONE.includes(x.status));
      if (moving) timer = setTimeout(load, 8000);
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [bridgeOn, swapOn]);

  return (
    <section className="rounded-3xl bg-white p-5 ring-1 ring-ink/10 sm:p-6 dark:bg-white/[0.04] dark:ring-white/10">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold text-ink dark:text-white">Recent activity</h2>
        <Link href="/history" className="text-sm font-medium text-emerald-700 hover:underline dark:text-mint">
          Airtime and data history
        </Link>
      </div>

      {items === null ? (
        <ul className="mt-4 space-y-3" aria-label="Loading">
          {[0, 1, 2].map((i) => (
            <li key={i} className="h-12 animate-pulse rounded-xl bg-zinc-100 dark:bg-white/5" />
          ))}
        </ul>
      ) : null}

      {items && items.length === 0 ? (
        <div className="mt-4 rounded-2xl bg-paper px-4 py-6 text-center dark:bg-white/5">
          <p className="font-medium text-ink dark:text-white">Nothing here yet</p>
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">Add USDC to your wallet to get started. Your sends, swaps and transfers will show here.</p>
          <Link href="/add-usdc" className="mt-4 inline-block rounded-full bg-note px-5 py-2.5 text-sm font-semibold text-white hover:bg-note-deep">
            Add USDC
          </Link>
        </div>
      ) : null}

      {items && items.length > 0 ? (
        <ul className="mt-2 divide-y divide-ink/5 dark:divide-white/5">
          {items.map((it) => (
            <li key={it.key}>
              <Link href={it.href} className="-mx-2 flex items-center gap-3 rounded-xl px-2 py-3 hover:bg-paper focus-visible:outline-2 focus-visible:outline-emerald-600 dark:hover:bg-white/5">
                <span
                  className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full ${
                    it.out ? "bg-paper text-ink dark:bg-white/10 dark:text-white" : "bg-mint/20 text-emerald-800 dark:text-mint"
                  }`}
                  aria-hidden="true"
                >
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    {ICONS[it.kind]}
                  </svg>
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold text-ink dark:text-white">{it.title}</span>
                  <span className="block truncate text-xs text-zinc-500 dark:text-zinc-400">
                    {it.detail}, {when(it.at)}
                  </span>
                </span>
                <span className="shrink-0 text-right">
                  <span className="block text-sm font-semibold tabular-nums text-ink dark:text-white">
                    {it.out ? "" : "+"}
                    {it.amount}
                  </span>
                  <span className={`block text-xs font-medium ${TONE_TEXT[it.status.tone]}`}>{it.status.text}</span>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}
DOC_EOF
cat > "frontend/src/components/ChainWallets.tsx" <<'DOC_EOF'
"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { shortAddress, type BridgeView, type ChainWallet } from "@/lib/bridge";

const usdc = (s: string) => Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

// The user's own wallets on other networks (created the first time they send there)
export function ChainWallets() {
  const router = useRouter();
  const [rows, setRows] = useState<ChainWallet[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fee, setFee] = useState(0);

  useEffect(() => {
    api<{ wallets: ChainWallet[]; networkFee?: number }>("/bridge/wallets")
      .then((r) => {
        setRows(r.wallets);
        setFee(r.networkFee ?? 0);
      })
      .catch(() => setRows([]));
  }, []);

  async function moveToArc(chain: string) {
    setBusy(chain);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/return", { method: "POST", body: JSON.stringify({ chain }) });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not start the transfer.");
      setBusy(null);
    }
  }

  if (!rows || rows.length === 0) return null;

  return (
    <section className="mt-4 rounded-3xl bg-white p-5 ring-1 ring-ink/10 sm:p-6 dark:bg-white/[0.04] dark:ring-white/10">
      <h2 className="font-display text-lg font-semibold text-ink dark:text-white">Your USDC on other networks</h2>
      <ul className="mt-2 divide-y divide-ink/5 dark:divide-white/5">
        {rows.map((w) => (
          <li key={w.chain} className="flex flex-wrap items-center justify-between gap-3 py-3">
            <div className="min-w-0">
              <p className="text-sm font-semibold text-ink dark:text-white">{w.chainLabel}</p>
              <a href={w.explorerUrl} target="_blank" rel="noreferrer" className="font-mono text-xs text-emerald-700 hover:underline dark:text-emerald-400">
                {shortAddress(w.address)}
              </a>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-sm font-semibold tabular-nums text-ink dark:text-white">
                {w.balance === null ? "unavailable" : `${usdc(w.balance)} USDC`}
              </span>
              {w.balance !== null && Number(w.balance) >= 0.1 + fee ? (
                <button
                  onClick={() => moveToArc(w.chain)}
                  disabled={busy !== null}
                  className="rounded-full bg-note px-3.5 py-1.5 text-xs font-semibold text-white hover:bg-note-deep disabled:opacity-60 dark:bg-mint dark:text-note-deep dark:hover:bg-mint/90"
                >
                  {busy === w.chain ? "Starting..." : "Move to Arc"}
                </button>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
      <p className="mt-2 text-xs text-zinc-500">
        Move to Arc sends everything on that network back to your Arc wallet, minus Circle&apos;s fee
        {fee > 0 ? ` and our ${fee.toFixed(2)} USDC transfer fee (taken on Arc when it arrives)` : ""}. No gas needed.
      </p>
      {error ? (
        <p className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
      ) : null}
    </section>
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
  ngnPerUsdc?: number | null;
};

// The fine wavy lines printed on banknotes, drawn once as a background
const WAVES = (() => {
  const lines: string[] = [];
  for (let i = 0; i < 16; i++) {
    const y0 = 40 + i * 16;
    const amp = 18 + (i % 4) * 6;
    const phase = i * 0.55;
    let d = "";
    for (let x = 0; x <= 640; x += 8) {
      const y = y0 + Math.sin(x / 46 + phase) * amp * Math.sin(x / 210 + i * 0.3);
      d += `${x === 0 ? "M" : "L"}${x} ${y.toFixed(1)} `;
    }
    lines.push(d.trim());
  }
  return lines;
})();

function split(amount: string | null): { whole: string; cents: string } | null {
  if (amount === null) return null;
  const n = Number(amount);
  if (Number.isNaN(n)) return null;
  const text = n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
  const [whole, cents = "00"] = text.split(".");
  return { whole: whole ?? "0", cents };
}

const tokenText = (v: string, max: number) => Number(v).toLocaleString("en-US", { maximumFractionDigits: max });

// The balance card at the top of the dashboard: USDC balance, its naira value,
// other tokens, and the wallet address to copy.
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
    } catch (e) {
      setError(e instanceof Error ? e.message : "We could not load your wallet. Please try again.");
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

  const amount = split(data?.balance.usdc ?? null);
  const naira =
    data?.ngnPerUsdc && data.balance.usdc !== null
      ? Math.floor(Number(data.balance.usdc) * data.ngnPerUsdc).toLocaleString("en-NG")
      : null;
  const extras = data?.tokens
    ? [
        Number(data.tokens.EURC) > 0 ? { label: "EURC", value: tokenText(data.tokens.EURC, 6) } : null,
        Number(data.tokens.cirBTC) > 0 ? { label: "cirBTC", value: tokenText(data.tokens.cirBTC, 8) } : null,
      ].filter((t): t is { label: string; value: string } => t !== null)
    : [];

  return (
    <>
      <section className="relative overflow-hidden rounded-[28px] bg-note text-white shadow-[0_28px_60px_-32px_rgba(6,42,32,0.85)] dark:bg-note-deep dark:ring-1 dark:ring-white/10">
        <svg
          aria-hidden="true"
          viewBox="0 0 640 320"
          preserveAspectRatio="none"
          className="pointer-events-none absolute inset-0 h-full w-full text-mint opacity-[0.13]"
        >
          {WAVES.map((d, i) => (
            <path key={i} d={d} fill="none" stroke="currentColor" strokeWidth="1" />
          ))}
        </svg>
        <div className="pointer-events-none absolute -right-16 -top-20 h-64 w-64 rounded-full border-[28px] border-white/[0.04]" aria-hidden="true" />

        <div className="relative p-6 sm:p-8">
          <div className="flex items-center justify-between gap-3">
            <p className="text-sm font-medium text-white/70">USDC balance</p>
            {data ? (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1 text-xs font-semibold text-white/90">
                <span className="h-1.5 w-1.5 rounded-full bg-mint" aria-hidden="true" />
                {data.wallet.network}
              </span>
            ) : null}
          </div>

          {loading && !data ? (
            <div className="mt-4 space-y-3" aria-live="polite">
              <div className="h-14 w-48 animate-pulse rounded-xl bg-white/10" />
              <p className="text-sm text-white/60">Setting up your wallet...</p>
            </div>
          ) : null}

          {error && !data ? (
            <div className="mt-4 space-y-3">
              <p className="text-sm text-white/80">{error}</p>
              <button onClick={load} className="rounded-full bg-white px-4 py-2 text-sm font-semibold text-note hover:bg-white/90">
                Try again
              </button>
            </div>
          ) : null}

          {data ? (
            <>
              <p className="balance-in mt-3 font-display text-[3.25rem] font-semibold leading-none tracking-tight tabular-nums sm:text-7xl">
                {amount ? (
                  <>
                    <span className="mr-1 align-top text-2xl font-medium text-white/55 sm:text-3xl">$</span>
                    {amount.whole}
                    <span className="text-white/45">.{amount.cents}</span>
                  </>
                ) : (
                  <span className="text-3xl text-white/70">Balance unavailable</span>
                )}
              </p>

              <div className="mt-4 flex flex-wrap items-center gap-2">
                {naira ? (
                  <span className="rounded-full bg-gold/15 px-3 py-1 text-sm font-semibold text-gold">about ₦{naira}</span>
                ) : null}
                {extras.map((t) => (
                  <span key={t.label} className="rounded-full bg-white/10 px-3 py-1 text-sm font-medium text-white/90">
                    {t.value} {t.label}
                  </span>
                ))}
              </div>
              {data.bridgeBalance && Number(data.bridgeBalance) > 0 ? (
                <p className="mt-3 text-sm text-white/65">
                  Plus {tokenText(data.bridgeBalance, 6)} USDC in your bridge balance, used first for your next transfer.
                </p>
              ) : null}

              <div className="mt-6 flex items-center gap-2 border-t border-white/10 pt-4">
                <code className="min-w-0 flex-1 truncate font-mono text-sm text-white/75" title={data.wallet.address}>
                  {data.wallet.address}
                </code>
                <button
                  onClick={copy}
                  className="shrink-0 rounded-full bg-white/10 px-3.5 py-1.5 text-sm font-semibold text-white hover:bg-white/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  {copied ? "Copied" : "Copy address"}
                </button>
                <button
                  onClick={load}
                  disabled={loading}
                  aria-label="Refresh balance"
                  title="Refresh balance"
                  className="shrink-0 rounded-full bg-white/10 p-2 text-white hover:bg-white/20 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={loading ? "animate-spin" : ""}>
                    <path d="M21 12a9 9 0 1 1-2.64-6.36" />
                    <path d="M21 3v6h-6" />
                  </svg>
                </button>
              </div>
            </>
          ) : null}
        </div>
      </section>

      {data?.wallet.previousAddress ? (
        <p className="mt-3 rounded-2xl bg-white px-4 py-3 text-sm text-zinc-600 ring-1 ring-ink/10 dark:bg-white/5 dark:text-zinc-300 dark:ring-white/10">
          Your wallet was upgraded. Use the address above from now on. Any USDC in or sent to your old address (
          <span className="font-mono">{data.wallet.previousAddress.slice(0, 6)}...{data.wallet.previousAddress.slice(-4)}</span>) moves here
          automatically within a few minutes, minus a tiny network fee.
        </p>
      ) : null}

      {data?.wallet.testnet ? (
        <p className="mt-3 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
          Test network: this USDC has no real value. Get free test USDC at{" "}
          <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
            faucet.circle.com
          </a>{" "}
          (choose Arc Testnet and paste your address).
        </p>
      ) : null}
    </>
  );
}
DOC_EOF
green "OK"

step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build) || fail "Backend check failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Website: build (includes its type check)"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Dashboard redesign: balance card with naira value, action buttons, one activity list, new fonts"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"dashboardV2":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
curl -s --max-time 30 "$PROD_FRONTEND/" >/dev/null || true
echo "Vercel usually finishes the website a minute or two after the push."

echo
green "Script 32 complete. Log in at $PROD_FRONTEND to see the new dashboard (try dark mode too)."
