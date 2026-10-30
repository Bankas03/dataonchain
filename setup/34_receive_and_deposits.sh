#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 34: add USDC through Base, and see money coming in
#
#   1. Add USDC page: an "Arc" and a "Base" tab. Base shows the user's own Base
#      address and QR code (created the first time), for exchanges that do not
#      support Arc yet; then Move to Arc brings it home
#   2. Deposits: every minute the server checks Circle for USDC, EURC or cirBTC
#      that arrived from outside (one call for all wallets). Each one shows as
#      "Received" in the activity list and the user gets one email. Our own
#      swaps, transfers, refunds and fake look alike tokens never count.
#   3. FAQ: how to add USDC through Base
#   New table: deposits. Tested on testnet first (a real 0.1 USDC between two
#   test wallets is found, once).
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/34_receive_and_deposits.sh
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
[[ -f frontend/src/app/activity/page.tsx ]] || fail "Run this from ~/dataonchain after script 33"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/34_receive_and_deposits.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "backend/scripts" "backend/src" "backend/src/db" "backend/src/deposits" "frontend/src/app" "frontend/src/app/activity" "frontend/src/app/add-usdc" "frontend/src/components"
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
  "deposits",
  "exchange_rates",
  "ledger_entries",
  "orders",
  "payments",
  "refunds",
  "sends",
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
cat > "backend/scripts/deposit-smoke.ts" <<'DOC_EOF'
// Deposits, on testnet and the development database:
//   - USDC from the treasury (our own refunds and test funding) is not a deposit
//   - 0.1 USDC from one test user's wallet to another shows as a deposit once,
//     with the right amount, sender and chain, and a second scan adds nothing
//   - the Base wallet for "Receive on Base" is created once and reused
// Exit code 3 means the treasury needs more test USDC.
// Run with: DEPOSIT_SETTLE_MS=15000 BRIDGE_ENABLED=true npx tsx scripts/deposit-smoke.ts
import { randomUUID } from "node:crypto";
import { inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { deposits, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { listDeposits, scanDeposits } from "../src/deposits/service";
import { ensureChainWallet } from "../src/bridge/wallets";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

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
  return { amount: b ? Number(b.amount) : 0, tokenId: b?.token?.id };
}

async function waitTx(id: string) {
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const tx = await circle.getTransaction({ id });
    const state = (tx.data?.transaction as unknown as { state?: string })?.state;
    if (state === "COMPLETE") return;
    if (state && ["FAILED", "DENIED", "CANCELLED"].includes(state)) throw new Error(`transfer ${state}`);
  }
  throw new Error("transfer did not finish");
}

async function main() {
  const t = await usdcOf(env.TREASURY_WALLET_ID);
  if (!t.tokenId || t.amount < 0.4) {
    console.log(`NEEDS_FUNDING: treasury has ${t.amount} USDC`);
    process.exit(3);
  }
  const a = randomUUID();
  const b = randomUUID();
  const stamp = Date.now();
  await db.insert(users).values([
    { id: a, name: "Deposit Sender", email: `depsmoke-a+${stamp}@example.com`, emailVerified: true, phone: "+2348011111111" },
    { id: b, name: "Deposit Receiver", email: `depsmoke-b+${stamp}@example.com`, emailVerified: true, phone: "+2348011111111" },
  ]);
  try {
    const wa = await ensureUserWallet(a);
    const wb = await ensureUserWallet(b);
    console.log("Funding the sender with 0.3 USDC from the treasury...");
    const fund = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID, tokenId: t.tokenId, destinationAddress: wa.address,
      amount: ["0.3"], amounts: ["0.3"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`dep-smoke:fund:${a}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    await waitTx(fund.data?.id ?? "");
    for (let i = 0; i < 20 && !(await usdcOf(wa.circleWalletId)).tokenId; i++) await sleep(3_000);
    console.log("Sending 0.1 USDC from the sender to the receiver...");
    const send = await circle.createTransaction({
      walletId: wa.circleWalletId, tokenId: (await usdcOf(wa.circleWalletId)).tokenId, destinationAddress: wb.address,
      amount: ["0.1"], amounts: ["0.1"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`dep-smoke:send:${a}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    await waitTx(send.data?.id ?? "");

    console.log("Waiting for Circle to list it, then scanning...");
    let mine: Awaited<ReturnType<typeof listDeposits>> = [];
    for (let i = 0; i < 12 && mine.length === 0; i++) {
      await sleep(10_000);
      await scanDeposits();
      mine = await listDeposits(b);
    }
    check(mine.length === 1 && mine[0]!.token === "USDC" && Number(mine[0]!.amount) === 0.1, "the 0.1 USDC from another wallet shows as a deposit", mine);
    check(mine[0]!.sourceAddress?.toLowerCase() === wa.address.toLowerCase() && mine[0]!.chain === "arc", "with the sender's address, on Arc");
    check((await listDeposits(a)).length === 0, "USDC from the treasury is not shown as a deposit");
    await scanDeposits();
    check((await listDeposits(b)).length === 1, "a second scan adds nothing");

    if (env.BRIDGE_ENABLED) {
      const base1 = await ensureChainWallet(b, "base");
      const base2 = await ensureChainWallet(b, "base");
      check(base1.address === base2.address && /^0x[0-9a-fA-F]{40}$/.test(base1.address), `the Base wallet is created once and reused (${base1.address})`);
    }
  } finally {
    await db.delete(deposits).where(inArray(deposits.userId, [a, b]));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(inArray(wallets.userId, [a, b]))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(inArray(wallets.userId, [a, b]));
    await db.delete(users).where(inArray(users.id, [a, b]));
    console.log("Cleaned up the test users");
  }
}

main()
  .then(() => {
    console.log("All deposit checks passed.");
    process.exit(0);
  })
  .catch((err) => {
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
import { PaymentError, getOrderView, listOrders, orderHistory, orderHistoryCsv, payOrder } from "./payments/service";
import { isNetwork, listDataPlans } from "./catalog/plans";
import { QuoteError, createQuote, getQuote } from "./pricing/quote";
import { getCurrentRate } from "./pricing/rates";
import { listDeposits } from "./deposits/service";
import { isOpenChain } from "./bridge/chains";
import { ensureChainWallet } from "./bridge/wallets";
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, deposits: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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

// USDC that arrived from outside dataonchain, newest first
app.get("/api/deposits", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ deposits: await listDeposits(user.id) });
});

// The user's own wallet on Base, to receive USDC from exchanges that do not
// support Arc yet (then Move to Arc). Created the first time it is asked for.
app.get("/api/wallet/base", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  if (!env.BRIDGE_ENABLED || !isOpenChain("base")) return c.json({ error: "Receiving on Base is not available right now." }, 503);
  const w = await ensureChainWallet(user.id, "base");
  return c.json({ wallet: { address: w.address, network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "Base Sepolia" : "Base" } });
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
// Sends to another wallet on Arc: confirmed with an emailed code first
export const SEND_STATUSES = ["AWAITING_CODE", "SENDING", "SENT", "COMPLETE", "FAILED", "CANCELLED"] as const;
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
export const NETWORK_FEE_STATUSES = ["PENDING", "SENT", "COMPLETE", "FAILED"] as const;

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
    // Our transfer fee, taken from the user's Arc wallet after the transfer
    // completes (never for a failed one) and sent to the treasury
    networkFeeMicro: integer("network_fee_micro").notNull().default(0),
    networkFeeStatus: text("network_fee_status", { enum: NETWORK_FEE_STATUSES }),
    networkFeeTxId: text("network_fee_tx_id"), // Circle transaction id
    networkFeeTxHash: text("network_fee_tx_hash"),
    salt: text("salt").notNull().unique(),
    burnIntent: text("burn_intent", { mode: "json" }),
    signature: text("signature"),
    gatewayTransferId: text("gateway_transfer_id").unique(),
    mintTxHash: text("mint_tx_hash"),
    // Holds the user id while the transfer is open: one open transfer per user
    openKey: text("open_key"),
    status: text("status", { enum: BRIDGE_STATUSES }).notNull().default("QUOTED"),
    failureReason: text("failure_reason"),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [
    index("bridge_transfers_status_idx").on(t.status),
    index("bridge_transfers_user_idx").on(t.userId),
    uniqueIndex("bridge_transfers_open_key_idx").on(t.openKey),
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
// Sends: USDC, EURC or cirBTC from a user's Arc wallet to any Arc address.
// The user confirms with a 6 digit code emailed to them (stored only as a hash).
// open_key holds the user id while a send is open: one at a time per user.
// The Circle transfer's idempotency key comes from the send id, so a retry can
// never send twice.
// ---------------------------------------------------------------------------
export const sends = sqliteTable(
  "sends",
  {
    id: id(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id),
    walletAddress: text("wallet_address").notNull(),
    token: text("token", { enum: SWAP_TOKENS }).notNull(),
    amount: text("amount").notNull(), // decimal string in token units
    toAddress: text("to_address").notNull(),
    status: text("status", { enum: SEND_STATUSES }).notNull().default("AWAITING_CODE"),
    codeHash: text("code_hash"),
    codeExpiresAt: integer("code_expires_at", { mode: "timestamp_ms" }),
    codeAttempts: integer("code_attempts").notNull().default(0),
    circleTransactionId: text("circle_transaction_id").unique(),
    txHash: text("tx_hash"),
    error: text("error"),
    openKey: text("open_key").unique(),
    createdAt: createdAt(),
    updatedAt: updatedAt(),
  },
  (t) => [index("sends_user_idx").on(t.userId), index("sends_status_idx").on(t.status)],
);

// ---------------------------------------------------------------------------
// Deposits: USDC, EURC or cirBTC that arrived in a user's wallet (Arc or Base)
// from outside dataonchain. Found by the worker on Circle; our own swaps,
// transfers between networks and refunds are left out. One row per Circle
// transaction, so a deposit is shown and emailed once.
// ---------------------------------------------------------------------------
export const deposits = sqliteTable(
  "deposits",
  {
    id: id(),
    circleTransactionId: text("circle_transaction_id").notNull().unique(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id),
    walletId: text("wallet_id")
      .notNull()
      .references(() => wallets.id),
    chain: text("chain").notNull(), // registry key: arc, base
    token: text("token").notNull(), // USDC, EURC, cirBTC
    amount: text("amount").notNull(),
    sourceAddress: text("source_address"),
    txHash: text("tx_hash"),
    notifiedAt: integer("notified_at", { mode: "timestamp_ms" }),
    receivedAt: integer("received_at", { mode: "timestamp_ms" }).notNull(),
    createdAt: createdAt(),
  },
  (t) => [index("deposits_user_idx").on(t.userId, t.receivedAt)],
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
cat > "backend/src/deposits/service.ts" <<'DOC_EOF'
// Deposits: USDC, EURC or cirBTC arriving in a user's wallet from outside
// dataonchain (an exchange, another wallet, another dataonchain user).
//
// Every minute the worker asks Circle for inbound transfers of the last 3 hours
// (one call for all wallets, not one per user), keeps the completed ones that
// went to a user's wallet, leaves out our own money movements (swaps, transfers
// between networks, refunds, wallet upgrades), and records each once. The user
// sees "Received" in their activity and gets one email.
//
// Safety: only real USDC, EURC and cirBTC count (checked by contract address on
// mainnet), so a fake token named "USDC" sent to a wallet never shows as money.
import { desc, eq, inArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { bridgeTransfers, deposits, refunds, swaps, users, walletSweeps, wallets } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { bridgeChains, chainByKey, isMainnet, type BridgeChain } from "../bridge/chains";

const LOOKBACK_MS = 3 * 60 * 60_000;
// Our own flows record their transaction a moment after it lands: wait this
// long before deciding a transfer came from outside
const SETTLE_MS = Number(process.env.DEPOSIT_SETTLE_MS ?? 2 * 60_000);
const MAX_PAGES = 10;

// Mainnet token contracts on Arc beside USDC
const ARC_MAINNET_TOKENS: Record<string, "EURC" | "cirBTC"> = {
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1": "EURC",
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0": "cirBTC",
};
// Senders that are our own flows, never a deposit
const INTERNAL_SENDERS = new Set([
  "0x0000000000000000000000000000000000000000",
  "0x7fb8c7260b63934d8da38af902f87ae6e284a845", // App Kit swap contract on Arc
]);

type CircleTx = {
  id: string;
  walletId?: string;
  blockchain: string;
  tokenId?: string;
  amounts?: string[];
  sourceAddress?: string;
  txHash?: string;
  state: string;
  createDate: string;
};
type TokenInfo = { symbol: string; address: string | null; native: boolean };

const tokenCache = new Map<string, TokenInfo | null>();

async function tokenInfo(tokenId: string, circleWalletId: string): Promise<TokenInfo | null> {
  if (tokenCache.has(tokenId)) return tokenCache.get(tokenId) ?? null;
  let info: TokenInfo | null = null;
  try {
    const getToken = (circle as unknown as { getToken?: (i: { id: string }) => Promise<{ data?: { token?: { symbol?: string; tokenAddress?: string; isNative?: boolean } } }> }).getToken;
    if (getToken) {
      const t = (await getToken.call(circle, { id: tokenId })).data?.token;
      if (t?.symbol) info = { symbol: t.symbol, address: t.tokenAddress?.toLowerCase() ?? null, native: Boolean(t.isNative) };
    }
  } catch {
    info = null;
  }
  if (!info) {
    // Fallback: the wallet's own balances list the token while it still holds some
    const res = await circle.getWalletTokenBalance({ id: circleWalletId });
    const b = (res.data?.tokenBalances ?? []).find((x) => x.token?.id === tokenId);
    const t = b?.token as unknown as { symbol?: string; tokenAddress?: string; isNative?: boolean } | undefined;
    if (t?.symbol) info = { symbol: t.symbol, address: t.tokenAddress?.toLowerCase() ?? null, native: Boolean(t.isNative) };
  }
  tokenCache.set(tokenId, info);
  return info;
}

// The token's name in dataonchain, or null when it is not one we show
function knownToken(chain: BridgeChain, info: TokenInfo): "USDC" | "EURC" | "cirBTC" | null {
  const sym = info.symbol.toUpperCase();
  if (info.address && info.address === chain.usdc.toLowerCase()) return "USDC";
  if (chain.key === "arc" && info.native && sym.startsWith("USDC")) return "USDC";
  if (chain.key !== "arc") return null;
  if (isMainnet()) return info.address ? (ARC_MAINNET_TOKENS[info.address] ?? null) : null;
  // Testnet: no real value, so the symbol is enough for EURC and cirBTC
  if (sym.startsWith("EURC")) return "EURC";
  if (sym.startsWith("CIRBTC")) return "cirBTC";
  return null;
}

// Hashes of transactions our own flows made (they also bring money into wallets)
async function ownHashes(hashes: string[]): Promise<Set<string>> {
  const own = new Set<string>();
  if (!hashes.length) return own;
  const lower = hashes.map((h) => h.toLowerCase());
  const all = [...new Set([...hashes, ...lower])];
  const add = (rows: { h: string | null }[]) => rows.forEach((r) => r.h && own.add(r.h.toLowerCase()));
  add(await db.select({ h: swaps.txHash }).from(swaps).where(inArray(swaps.txHash, all)));
  add(await db.select({ h: bridgeTransfers.mintTxHash }).from(bridgeTransfers).where(inArray(bridgeTransfers.mintTxHash, all)));
  add(await db.select({ h: refunds.txHash }).from(refunds).where(inArray(refunds.txHash, all)));
  add(await db.select({ h: walletSweeps.txHash }).from(walletSweeps).where(inArray(walletSweeps.txHash, all)));
  return own;
}

async function notify(d: typeof deposits.$inferSelect, chain: BridgeChain) {
  const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, d.userId)).limit(1);
  if (!user || /@(example\.com|[^@]*\.local)$/i.test(user.email)) return;
  const onArc = chain.key === "arc";
  const message = noticeEmail({
    brand: "dataonchain",
    subject: `You received ${d.amount} ${d.token}`,
    lines: [
      `Hello ${user.name.split(" ")[0]},`,
      `${d.amount} ${d.token} arrived in your dataonchain wallet on ${chain.label}.`,
      ...(d.sourceAddress ? [`From: ${d.sourceAddress}`] : []),
      onArc
        ? "It is in your balance now."
        : `To use it, open your dashboard and tap Move to Arc next to ${chain.label}. It takes about 20 minutes.`,
    ],
    button: { label: "Open your wallet", url: `${env.BETTER_AUTH_URL}/dashboard` },
    footer: "Did not expect this? You do not need to do anything. Never send funds back to someone who asks you to after an unexpected deposit.",
  });
  await sendEmail({ to: user.email, ...message });
}

// One pass for the worker. Safe to run as often as you like.
export async function scanDeposits(): Promise<number> {
  const userWallets = await db
    .select({ id: wallets.id, userId: wallets.userId, circleWalletId: wallets.circleWalletId, blockchain: wallets.blockchain, address: wallets.address })
    .from(wallets)
    .where(eq(wallets.purpose, "user"));
  const byCircleId = new Map(userWallets.filter((w) => w.userId).map((w) => [w.circleWalletId, w]));
  if (!byCircleId.size) return 0;
  const chains = bridgeChains();
  const gatewayMinters = new Set(chains.map((c) => c.gatewayMinter.toLowerCase()));

  const from = new Date(Date.now() - LOOKBACK_MS).toISOString();
  const settled = Date.now() - SETTLE_MS;
  const found: CircleTx[] = [];
  let pageAfter: string | undefined;
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await circle.listTransactions({
      txType: "INBOUND",
      from,
      order: "ASC",
      pageSize: 50,
      includeAll: true,
      ...(pageAfter ? { pageAfter } : {}),
    } as unknown as Parameters<typeof circle.listTransactions>[0]);
    const list = (res.data?.transactions ?? []) as unknown as CircleTx[];
    found.push(...list);
    if (list.length < 50) break;
    pageAfter = list[list.length - 1]!.id;
  }

  const candidates = found.filter(
    (t) => t.state === "COMPLETE" && t.walletId && byCircleId.has(t.walletId) && new Date(t.createDate).getTime() < settled,
  );
  if (!candidates.length) return 0;
  const seen = new Set(
    (await db.select({ id: deposits.circleTransactionId }).from(deposits).where(inArray(deposits.circleTransactionId, candidates.map((t) => t.id)))).map((r) => r.id),
  );
  const fresh = candidates.filter((t) => !seen.has(t.id));
  if (!fresh.length) return 0;
  const own = await ownHashes(fresh.map((t) => t.txHash).filter((h): h is string => Boolean(h)));

  let added = 0;
  for (const t of fresh) {
    const w = byCircleId.get(t.walletId!)!;
    const chain = chains.find((c) => c.circleBlockchain === w.blockchain);
    if (!chain || !t.tokenId || !t.amounts?.[0]) continue;
    const source = t.sourceAddress?.toLowerCase() ?? "";
    if (t.txHash && own.has(t.txHash.toLowerCase())) continue;
    if (INTERNAL_SENDERS.has(source) || gatewayMinters.has(source) || source === env.TREASURY_ADDRESS.toLowerCase()) continue;
    if (userWallets.some((x) => x.userId === w.userId && x.address.toLowerCase() === source)) continue; // their own other wallet
    const info = await tokenInfo(t.tokenId, w.circleWalletId);
    const token = info ? knownToken(chain, info) : null;
    if (!token || Number(t.amounts[0]) <= 0) continue;

    const [row] = await db
      .insert(deposits)
      .values({
        circleTransactionId: t.id,
        userId: w.userId!,
        walletId: w.id,
        chain: chain.key,
        token,
        amount: t.amounts[0],
        sourceAddress: t.sourceAddress ?? null,
        txHash: t.txHash ?? null,
        receivedAt: new Date(t.createDate),
      })
      .onConflictDoNothing()
      .returning();
    if (!row) continue;
    added++;
    try {
      await notify(row, chain);
      await db.update(deposits).set({ notifiedAt: new Date() }).where(eq(deposits.id, row.id));
    } catch (err) {
      console.error(`[deposits] ${row.id} email failed:`, err instanceof Error ? err.message : err);
    }
  }
  if (added) console.log(`[deposits] ${added} new deposit(s)`);
  return added;
}

export async function listDeposits(userId: string) {
  const rows = await db.select().from(deposits).where(eq(deposits.userId, userId)).orderBy(desc(deposits.receivedAt)).limit(20);
  return rows.map((d) => {
    let chain: BridgeChain | null = null;
    try {
      chain = chainByKey(d.chain);
    } catch {
      chain = null;
    }
    return {
      id: d.id,
      chain: d.chain,
      chainLabel: chain?.label ?? d.chain,
      token: d.token,
      amount: d.amount,
      sourceAddress: d.sourceAddress,
      explorerUrl: chain && d.txHash ? `${chain.explorerTx}${d.txHash}` : null,
      receivedAt: d.receivedAt.toISOString(),
    };
  });
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
// and upgrades users to smart contract wallets, moving USDC from old wallets,
// recovers interrupted payments, and keeps bridge transfers moving,
// so nothing stays stuck when a customer closes their browser.
import { and, eq, inArray } from "drizzle-orm";
import { db } from "./db";
import { orders, payments, vtuTransactions } from "./db/schema";
import { fulfilOrder, reconcileOrder } from "./fulfilment/service";
import { recoverInterruptedPayments, refreshPayment } from "./payments/service";
import { advanceRefund, startRefund } from "./refunds/service";
import { runWalletUpgrades } from "./wallets/sweep";
import { bridgeTransfers } from "./db/schema";
import { driveTransfer } from "./bridge/user";
import { advanceOpenNetworkFees } from "./bridge/fees";
import { advanceSends } from "./send/service";
import { scanDeposits } from "./deposits/service";
import { alertStuck, dailyReconcile } from "./bridge/monitor";
import { releaseAbandonedSwaps } from "./swap/service";

const EVERY_MS = 30_000;
// Interrupted payments are looked up on Circle every 5 minutes
const RECOVER_EVERY_MS = 5 * 60_000;
let lastRecovery = 0;
const DEPOSIT_SCAN_MS = 60_000;
let lastDepositScan = 0;

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
  // Payments whose start was interrupted (restart, or Circle's answer was lost)
  if (Date.now() - lastRecovery > RECOVER_EVERY_MS) {
    lastRecovery = Date.now();
    try {
      await recoverInterruptedPayments();
    } catch (err) {
      console.error("[worker] payment recovery failed:", err instanceof Error ? err.message : err);
    }
  }
  // Bridge transfers left behind (for example after a restart)
  try {
    const open = await db
      .select({ id: bridgeTransfers.id })
      .from(bridgeTransfers)
      .where(inArray(bridgeTransfers.status, ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"]))
      .limit(20);
    // Each one moves in the background, so a slow deposit (several minutes on
    // some testnets) never holds up payments, deliveries and refunds here.
    for (const { id } of open) driveTransfer(id);
  } catch (err) {
    console.error("[worker] bridge transfers failed:", err instanceof Error ? err.message : err);
  }
  // Sends to other wallets: expired codes, results from Circle, retries
  try {
    await advanceSends();
  } catch (err) {
    console.error("[worker] sends failed:", err instanceof Error ? err.message : err);
  }
  // Deposits from outside dataonchain (once a minute)
  if (Date.now() - lastDepositScan > DEPOSIT_SCAN_MS) {
    lastDepositScan = Date.now();
    try {
      await scanDeposits();
    } catch (err) {
      console.error("[worker] deposit scan failed:", err instanceof Error ? err.message : err);
    }
  }
  // Our transfer fee on completed transfers
  try {
    await advanceOpenNetworkFees();
  } catch (err) {
    console.error("[worker] transfer fees failed:", err instanceof Error ? err.message : err);
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
cat > "frontend/src/app/activity/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ActivityFeed } from "@/components/ActivityFeed";
import { SupportLink } from "@/components/SupportLink";
import { authClient } from "@/lib/auth-client";

// Onchain history: every send, swap and transfer (and later, purchases), newest first
export default function ActivityPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [flags, setFlags] = useState<{ bridge: boolean; swap: boolean } | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean }) => setFlags({ bridge: Boolean(s.bridge), swap: Boolean(s.swap) }))
      .catch(() => setFlags({ bridge: false, swap: false }));
  }, []);

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-2xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/dashboard" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <Link href="/dashboard" className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink sm:text-4xl dark:text-white">Onchain history</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          What you received, sent, swapped and moved on Arc and Base, newest first. Tap one to see its details and transaction.
        </p>

        <div className="mt-6">
          {session && flags ? <ActivityFeed bridgeOn={flags.bridge} swapOn={flags.swap} full /> : null}
        </div>

        <p className="mt-10 text-center text-sm text-zinc-500">
          Something look wrong? <SupportLink />
        </p>
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/add-usdc/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import QRCode from "qrcode";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Wallet = { address: string; network: string; testnet?: boolean };
type Way = "arc" | "base";

// Add USDC: straight to the Arc wallet, or (for exchanges that do not support
// Arc yet) to the user's own Base wallet, then Move to Arc.
export default function AddUsdcPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [way, setWay] = useState<Way>("arc");
  const [arc, setArc] = useState<Wallet | null>(null);
  const [base, setBase] = useState<Wallet | null>(null);
  const [baseOn, setBaseOn] = useState(false);
  const [qr, setQr] = useState<Record<Way, string | null>>({ arc: null, base: null });
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadingBase, setLoadingBase] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<{ wallet: Wallet }>("/wallet")
      .then(async (r) => {
        setArc(r.wallet);
        const code = await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" });
        setQr((q) => ({ ...q, arc: code }));
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Could not load your wallet."));
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; network?: string }) => setBaseOn(Boolean(s.bridge)))
      .catch(() => setBaseOn(false));
  }, [session]);

  async function choose(next: Way) {
    setWay(next);
    setCopied(false);
    setError(null);
    if (next !== "base" || base) return;
    setLoadingBase(true);
    try {
      const r = await api<{ wallet: Wallet }>("/wallet/base");
      setBase(r.wallet);
      const code = await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" });
      setQr((q) => ({ ...q, base: code }));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your Base wallet.");
    } finally {
      setLoadingBase(false);
    }
  }

  const wallet = way === "arc" ? arc : base;

  async function copy() {
    if (!wallet) return;
    await navigator.clipboard.writeText(wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  const tab = (active: boolean) =>
    `flex-1 rounded-full px-4 py-2 text-sm font-semibold transition-colors ${
      active ? "bg-note text-white dark:bg-mint dark:text-note-deep" : "text-ink hover:bg-white dark:text-zinc-300 dark:hover:bg-white/10"
    }`;

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/dashboard" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <Link href="/dashboard" className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink dark:text-white">Add USDC</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Send USDC from an exchange or another wallet to your address below. Choose the network your exchange supports.
        </p>

        {baseOn ? (
          <div role="tablist" aria-label="Network" className="mt-6 flex gap-1 rounded-full bg-white/70 p-1 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:ring-white/10">
            <button role="tab" aria-selected={way === "arc"} onClick={() => choose("arc")} className={tab(way === "arc")}>
              Arc (fastest)
            </button>
            <button role="tab" aria-selected={way === "base"} onClick={() => choose("base")} className={tab(way === "base")}>
              Base
            </button>
          </div>
        ) : null}

        {error ? <p className="mt-6 rounded-2xl bg-red-50 px-4 py-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
        {(!wallet && !error) || loadingBase ? <p className="mt-6 text-sm text-zinc-500">Loading your wallet...</p> : null}

        {wallet && !loadingBase ? (
          <section className="mt-6 space-y-6 rounded-3xl bg-white p-6 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:ring-white/10">
            <div className="rounded-2xl border-2 border-red-300 bg-red-50 p-4 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <p className="font-semibold">Send only USDC on {wallet.network}.</p>
              <p className="mt-1">
                USDC sent on any other network, or any other token, may be lost for good. When you withdraw from an exchange, choose{" "}
                <strong>{wallet.network}</strong> as the network.
              </p>
            </div>

            <div className="flex flex-col items-center gap-4">
              {qr[way] ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={qr[way]!} alt={`QR code of your ${wallet.network} wallet address`} width={240} height={240} className="rounded-2xl border border-zinc-200 bg-white p-2" />
              ) : (
                <div className="h-[240px] w-[240px] animate-pulse rounded-2xl bg-zinc-100 dark:bg-white/5" />
              )}
              <div className="w-full">
                <p className="text-sm text-zinc-500">Your wallet address on {wallet.network}</p>
                <code className="mt-1 block break-all rounded-xl bg-paper px-3 py-2 font-mono text-sm text-ink dark:bg-white/5 dark:text-zinc-100">
                  {wallet.address}
                </code>
                <button onClick={copy} className="mt-3 w-full rounded-full bg-note px-4 py-3 font-semibold text-white hover:bg-note-deep dark:bg-mint dark:text-note-deep">
                  {copied ? "Copied" : "Copy address"}
                </button>
              </div>
            </div>

            {way === "arc" ? (
              <ul className="list-disc space-y-1 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
                <li>It shows in your balance within a minute, and we email you when it arrives.</li>
                <li>Check the first and last characters of the address after you paste it.</li>
                <li>Send a small amount first if you have not used this address before.</li>
                <li>Your exchange does not list Arc? Choose Base above.</li>
              </ul>
            ) : (
              <ol className="list-decimal space-y-2 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
                <li>
                  Withdraw USDC from your exchange to this address, with <b>{wallet.network}</b> as the network. Send at least 1 USDC.
                </li>
                <li>It arrives in your own {wallet.network} wallet within a few minutes, and we email you.</li>
                <li>
                  On your dashboard, under <b>Your USDC on other networks</b>, tap <b>Move to Arc</b>. It reaches your Arc wallet in about 20
                  minutes. Circle&apos;s fee (about 0.03 USDC) and our 0.10 USDC transfer fee come out of the amount.
                </li>
              </ol>
            )}

            {arc?.testnet && way === "arc" ? (
              <div className="rounded-2xl bg-amber-50 p-4 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <p className="font-semibold">Test network: get free test USDC</p>
                <p className="mt-1">
                  Open{" "}
                  <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                    faucet.circle.com
                  </a>
                  , choose USDC and Arc Testnet, paste your address and send. Test USDC has no real value.
                </p>
              </div>
            ) : null}
          </section>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF
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
    text: "On Arc the network fee is paid in USDC, not in a separate gas token. Our users only ever hold one thing, digital dollars, and costs are predictable in dollars. On top of that, we sponsor the fee, so users never need gas.",
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
  { name: "Circle Gas Station", text: "Pays the network fee for our users' smart wallets. Nobody needs gas to buy airtime or send USDC." },
  { name: "Circle Gateway", text: "One USDC balance that moves between Arc and Base today, with more networks to follow, and no gas needed on either." },
  { name: "App Kit", text: "Powers swaps between USDC, EURC and cirBTC on Arc, with a guaranteed minimum on every swap." },
  { name: "EURC and cirBTC", text: "More than dollars: users can hold and swap into euro stablecoins and Bitcoin on Arc." },
];

const MILESTONES = [
  { title: "Email sign up with an automatic wallet", text: "Confirmed email, then a USDC wallet on Arc created automatically." },
  { title: "Live naira and USDC pricing", text: "A live exchange rate, prices held for 10 minutes, and a clear service fee." },
  { title: "Airtime and data paid with USDC", text: "MTN, Airtel, Glo and 9mobile, paid on Arc and delivered through our VTU partner's test environment." },
  { title: "Instant status and automatic refunds", text: "Orders update in seconds, and failed deliveries are refunded to the wallet without anyone asking." },
  { title: "Smart wallets with no network fees", text: "Every user moved to a smart wallet with sponsored gas; existing balances moved across automatically." },
  { title: "Send USDC to other networks", text: "Crosschain transfers through Circle Gateway, tested on seven networks, with a personal wallet on each and Move to Arc to bring it all home." },
  { title: "Every transfer recorded and checked", text: "Each step from deposit to mint is recorded, stuck transfers raise alerts, and a daily report checks every transfer against Circle." },
  { title: "Swaps on Arc", text: "USDC, EURC and cirBTC, with a fee shown upfront and a minimum you are guaranteed." },
  { title: "Admin dashboard and security review", text: "Full operations dashboard, a code audit, and the fixes that came from it, including password reset." },
  { title: "Public testing on Arc Testnet", text: "Early testers using the platform and shaping it with their feedback." },
  { title: "Live on Arc mainnet", text: "Real USDC wallets on Arc mainnet for every user." },
  { title: "Bridge, swaps and sends live on mainnet", text: "Everyone can now move USDC between Arc and Base, swap USDC, EURC and cirBTC, and send to any Arc wallet with an emailed code." },
];

const ROADMAP = [
  { title: "Company registration", text: "Registering dataonchain with the Corporate Affairs Commission (CAC) in Nigeria.", status: "In progress" },
  { title: "Bridge, swaps and send to another wallet", text: "Live on Arc mainnet for everyone: USDC to Base and back, swaps between USDC, EURC and cirBTC, and sends to any Arc wallet.", status: "Live" },
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
    a: "Yes, on Arc mainnet, with real USDC. You can sign up, get your wallet, add USDC, send it to Base and back, swap between USDC, EURC and cirBTC, and send to any Arc wallet today. Buying airtime and data opens after our company registration and a live provider are in place.",
  },
  {
    q: "How do I add USDC?",
    a: "Open Add USDC from your dashboard and copy your address, or scan the QR code. From an exchange or another wallet, send USDC and choose Arc as the network. If your exchange does not list Arc yet, choose the Base tab, send USDC on Base to the address shown, then tap Move to Arc on your dashboard. Always match the network on both sides: USDC sent on any other network, or any other token, may be lost. We email you when it arrives.",
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
    a: "No. Arc charges its network fee in USDC, and we pay it for you, on Arc and on Base. You pay only the price shown. Sending to another network has Circle's fee plus our small transfer fee (0.10 USDC), both shown before you confirm.",
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
    a: "It moves USDC from your Arc wallet to your own wallet on Base, or to an approved provider, through Circle Gateway. More networks will follow. You pay no gas. You pay Circle's fee and our transfer fee of 0.10 USDC, both shown before you confirm; our fee is taken only when the transfer completes. Sending from Arc usually takes a minute or two, and Move to Arc brings your USDC back from Base in about 20 minutes while Base confirms it.",
  },
  {
    q: "Are there limits on sending?",
    a: "Yes, at launch: 1 to 50 USDC per transfer and 100 USDC per day, one transfer at a time.",
  },
  {
    q: "Can I send USDC to any wallet address?",
    a: "Yes, on Arc. Use Send to a wallet on your dashboard to send USDC, EURC or cirBTC to any wallet address on Arc. You confirm each send with a code we email you, and we pay the gas. At launch you can send up to 50 USDC or EURC per send and 100 per day. Sends cannot be reversed, so check the address, and only send to an exchange or wallet that supports Arc. To reach a wallet on Base, use Send to another network.",
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
          Live on Arc mainnet · send, swap and bridge are open · airtime and data soon
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
            ["2", "blockchains live: Arc and Base"],
            ["0", "gas tokens needed"],
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
                    r.status === "Live"
                      ? "border-emerald-600 bg-emerald-500"
                      : r.status === "In progress"
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
                      r.status === "Live"
                        ? "bg-emerald-600 text-white dark:bg-emerald-500 dark:text-emerald-950"
                        : r.status === "In progress"
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
              Create an account and get your USDC wallet on Arc in a minute. Send, swap and move USDC to Base today;
              buying airtime and data follows.
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
  kind: "order" | "send" | "swap" | "bridge" | "receive";
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
type DepositRow = { id: string; chain: string; chainLabel: string; token: string; amount: string; sourceAddress: string | null; explorerUrl: string | null; receivedAt: string };

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
  receive: <path d="M17 7 7 17M15 17H7V9" />,
};

function toItems(orders: OrderView[], sends: SendRow[], swaps: SwapRow[], bridges: BridgeListItem[], received: DepositRow[], limit: number): Item[] {
  const items: Item[] = [];
  for (const d of received) {
    const arc = d.chain === "arc";
    items.push({
      key: `d-${d.id}`,
      kind: "receive",
      title: arc ? `Received ${d.token}` : `Received ${d.token} on ${d.chainLabel}`,
      detail: arc ? (d.sourceAddress ? `From ${shortAddress(d.sourceAddress)}` : "From another wallet") : "Tap Move to Arc on your dashboard",
      amount: `${num(d.amount, decimals(d.token))} ${d.token}`,
      out: false,
      status: { text: "Received", tone: "good" },
      href: d.explorerUrl ?? "/activity",
      at: new Date(d.receivedAt).getTime(),
    });
  }
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
  return items.sort((a, b) => b.at - a.at).slice(0, limit);
}

// Everything the user did onchain, newest first: sends, swaps, transfers and
// purchases. The dashboard shows the latest 8; the history page shows them all.
export function ActivityFeed({ bridgeOn, swapOn, full = false }: { bridgeOn: boolean; swapOn: boolean; full?: boolean }) {
  const limit = full ? 100 : 8;
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
      const [o, s, w, b, d] = await Promise.all([
        safe(api<{ orders: OrderView[] }>("/orders"), { orders: [] }),
        safe(api<{ sends: SendRow[] }>("/sends"), { sends: [] }),
        swapOn ? safe(api<{ swaps: (SwapRow | null)[] }>("/swaps"), { swaps: [] }) : Promise.resolve({ swaps: [] as (SwapRow | null)[] }),
        bridgeOn ? safe(api<{ transfers: BridgeListItem[] }>("/bridge/transfers"), { transfers: [] }) : Promise.resolve({ transfers: [] as BridgeListItem[] }),
        safe(api<{ deposits: DepositRow[] }>("/deposits"), { deposits: [] }),
      ]);
      if (stop) return;
      setItems(toItems(o.orders, s.sends, w.swaps.filter((x): x is SwapRow => x !== null), b.transfers, d.deposits, limit));
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
  }, [bridgeOn, swapOn, limit]);

  return (
    <section className="rounded-3xl bg-white p-5 ring-1 ring-ink/10 sm:p-6 dark:bg-white/[0.04] dark:ring-white/10">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold text-ink dark:text-white">{full ? "All activity" : "Recent activity"}</h2>
        {full ? null : (
          <Link href="/activity" className="text-sm font-medium text-emerald-700 hover:underline dark:text-mint">
            Onchain history
          </Link>
        )}
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
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">Add USDC to your wallet to get started. What you receive, send, swap and move will show here.</p>
          <Link href="/add-usdc" className="mt-4 inline-block rounded-full bg-note px-5 py-2.5 text-sm font-semibold text-white hover:bg-note-deep">
            Add USDC
          </Link>
        </div>
      ) : null}

      {items && items.length > 0 ? (
        <ul className="mt-2 divide-y divide-ink/5 dark:divide-white/5">
          {items.map((it) => (
            <li key={it.key}>
              <Link
                href={it.href}
                {...(it.href.startsWith("http") ? { target: "_blank", rel: "noreferrer" } : {})}
                className="-mx-2 flex items-center gap-3 rounded-xl px-2 py-3 hover:bg-paper focus-visible:outline-2 focus-visible:outline-emerald-600 dark:hover:bg-white/5"
              >
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
green "OK"

# --- 2. Development database -------------------------------------------------------
step "Database: the deposits table"
if ! grep -rqs 'CREATE TABLE `deposits`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name deposits)
fi
grep -rqs 'CREATE TABLE `deposits`' backend/drizzle/*.sql || fail "The database change was not created. Paste the output to Claude."
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Tests on testnet -------------------------------------------------------------
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

step "Deposits on testnet: 0.1 USDC between two test wallets (takes about 2 minutes)"
set +e
(cd backend && DEPOSIT_SETTLE_MS=15000 BRIDGE_ENABLED=true npx tsx scripts/deposit-smoke.ts); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The testnet treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Deposit test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again. Otherwise paste the output to Claude."
fi
green "OK"

step "Website and admin dashboard: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 4. Live database (before the new code goes live) -----------------------------
step "Live database: the deposits table"
PROD_TOKEN="$(prod_token)"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the live database. Nothing was committed. Run again."
unset PROD_TOKEN
green "OK (the site keeps working: the old code ignores the new columns)"

# --- 5. Commit and push --------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Add USDC through Base, deposits shown as Received with an email"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"deposits":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
[[ "$STATUS" == *'"network":"mainnet"'* ]] || fail "Render is not on mainnet. Tell Claude."
echo "Vercel usually finishes the website a minute or two after the push."

echo
green "Script 34 complete. Add USDC now has a Base tab, and deposits show as Received with an email."
echo
bold "One setting to change in the Circle Console (Gas Station > your Base policy > Manage):"
echo "  Every Move to Arc uses 2 or 3 operations on Base, and your Base policy allows 15 a day,"
echo "  so only about 5 users a day could bring USDC in through Base. Set:"
echo "    Maximum operations per day: 60"
echo "    Maximum spend per transaction: 0.10"
echo "  You still only pay for the gas actually used."
