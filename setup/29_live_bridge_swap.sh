#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 29: bridge and swaps on Arc mainnet, ready to open
#
#   1. Sending to other networks: only Arc and Base on mainnet (the networks
#      with a Gas Station policy)
#   2. Our transfer fee: 0.10 USDC per completed transfer, shown before the
#      user confirms, taken from their Arc wallet only when the transfer
#      completes, and paid to the treasury (it covers the gas we sponsor)
#   3. Live checks before opening: your admin email can use the bridge and
#      swaps while they are still paused for everyone else
#   4. Website wording: Arc and Base, the transfer fee (FAQ and terms)
#   Tested on testnet first (a real 0.2 USDC transfer to Base Sepolia, with the
#   fee), then the live database gets the new fee columns, then it is pushed.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/29_live_bridge_swap.sh
#
# After your live tests, see what happened on mainnet (read only):
#   bash setup/29_live_bridge_swap.sh report
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
[[ -f backend/scripts/mainnet-cutover.ts ]] || fail "Run this from ~/dataonchain after script 28"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

# --- Report mode: read only, then stop -------------------------------------------
if [[ "${1:-}" == "report" ]]; then
  step "Mainnet: latest transfers and swaps (read only)"
  PROD_TOKEN="$(prod_token)"
  (cd backend && CIRCLE_BLOCKCHAIN=ARC EXPLORER_TX_URL=https://explorer.arc.io/tx/ \
    TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx tsx scripts/live-report.ts) \
    || fail "Could not read the live database (details above)."
  unset PROD_TOKEN
  echo
  echo "Paste this to Claude if anything looks wrong."
  exit 0
fi

if [[ -n "$(git status --porcelain | grep -v 'setup/29_live_bridge_swap.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "backend" "backend/scripts" "backend/src" "backend/src/bridge" "backend/src/db" "frontend/src/app" "frontend/src/app/bridge" "frontend/src/app/bridge/[id]" "frontend/src/app/terms" "frontend/src/components" "frontend/src/lib"
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
# Our transfer fee on each completed transfer, paid to the treasury (0 = off)
# BRIDGE_NETWORK_FEE_USDC=0.1
# Networks users can send to. Default: all on testnet, arc,base on mainnet
# BRIDGE_CHAINS=arc,base
# Accounts that can still use a paused bridge or swaps (live checks). Default: ADMIN_EMAIL
# PAUSE_BYPASS_EMAILS=

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
cat > "backend/scripts/bridge-own-smoke.ts" <<'DOC_EOF'
// Own wallets on other networks, on testnet and the development database:
//   1. a test user sends 0.2 USDC from Arc to their OWN new wallet on Base Sepolia
//   2. the dashboard balance for Base Sepolia shows it, and our transfer fee
//      (BRIDGE_NETWORK_FEE_USDC) went from their Arc wallet to the treasury
//   also: only the networks in BRIDGE_CHAINS are offered, and the admin can
//   still use the bridge while it is paused (nobody else can)
//   3. (optional, about 20 minutes) "Move to Arc" brings it back to their Arc wallet
// Exit code 3 means the treasury needs more test USDC.
// Run with: BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 BRIDGE_CHAINS=arc,base PAUSE_BYPASS_EMAILS=tester@example.com \
//   npx tsx scripts/bridge-own-smoke.ts [--with-return]
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { appSettings, auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { BridgeUserError, chainBalances, driving, getBridgeView, listDestinations, returnToArc, startBridge } from "../src/bridge/user";
import { usdcMicroOf } from "../src/bridge/wallets";
import { advanceNetworkFee, networkFeeMicro } from "../src/bridge/fees";
import { getPauses, pausedMessage, setPause } from "../src/settings";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND_MICRO = 400_000;
const withReturn = process.argv.includes("--with-return");

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function waitDone(userId: string, id: string, minutes: number) {
  let view = await getBridgeView(userId, id);
  let last = "";
  const t0 = Date.now();
  while (view && !["COMPLETE", "FAILED"].includes(view.status) && Date.now() - t0 < minutes * 60_000) {
    if (view.status !== last) {
      console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view.status}`);
      last = view.status;
    }
    await sleep(5_000);
    view = await getBridgeView(userId, id);
  }
  console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""}`);
  return { view, seconds: Math.round((Date.now() - t0) / 1000) };
}

async function main() {
  if (!env.BRIDGE_ENABLED) throw new Error("Run with BRIDGE_ENABLED=true");
  const treasuryRes = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (treasuryRes.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const treasuryMicro = t ? Math.round(Number(t.amount) * 1e6) : 0;
  if (!t?.token?.id || treasuryMicro < FUND_MICRO + 100_000) {
    console.log(`NEEDS_FUNDING: treasury has ${show(treasuryMicro)} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Own Wallet Smoke Test", email: `ownsmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  const ids: string[] = [];
  try {
    const dests = await listDestinations();
    check(dests.some((d) => d.id === "own:base" && d.own), "users can choose their own wallet on Base Sepolia");
    if (env.BRIDGE_CHAINS.join(",") === "arc,base") {
      check(dests.every((d) => d.chain === "base"), "only Base is offered when BRIDGE_CHAINS=arc,base", dests.map((d) => d.chain));
      try {
        await returnToArc(userId, { chain: "polygon" });
        check(false, "a network that is not open is refused");
      } catch (err) {
        check(err instanceof BridgeUserError && err.status === 404, "a network that is not open is refused");
      }
    }

    // The admin (PAUSE_BYPASS_EMAILS) can still use a paused bridge for live checks
    if (env.PAUSE_BYPASS_EMAILS.includes("tester@example.com")) {
      const was = (await getPauses()).bridgePaused;
      try {
        await setPause("bridgePaused", true);
        check((await pausedMessage("bridgePaused", "Tester@Example.com")) === null, "the admin can use the bridge while it is paused");
        check((await pausedMessage("bridgePaused", "someone@example.com")) !== null, "everyone else sees the paused message");
        check((await pausedMessage("purchasesPaused", "tester@example.com")) === (await pausedMessage("purchasesPaused", "someone@example.com")),
          "the bypass never opens buying airtime and data");
      } finally {
        await setPause("bridgePaused", was);
        if (!was) await db.delete(appSettings).where(eq(appSettings.key, "bridgePaused"));
      }
    }

    const arc = await ensureUserWallet(userId);
    console.log(`Funding the test user's Arc wallet with ${show(FUND_MICRO)} USDC from the treasury...`);
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: t.token.id,
      destinationAddress: arc.address,
      amount: [show(FUND_MICRO)],
      amounts: [show(FUND_MICRO)],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`own-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check((await usdcMicroOf(arc.circleWalletId)) >= FUND_MICRO, "test Arc wallet funded");

    // 1. Arc -> own wallet on Base Sepolia
    const out = await startBridge(userId, { destinationId: "own:base", amount: "0.2" });
    check(Boolean(out?.id) && out?.destinationLabel === "Your wallet", "transfer to their own Base Sepolia wallet started");
    ids.push(out!.id);
    const sent = await waitDone(userId, out!.id, 15);
    check(sent.view?.status === "COMPLETE", `arrived on Base Sepolia in ${sent.seconds} seconds (${sent.view?.mintUrl})`);

    // 2. The dashboard shows it
    let base = (await chainBalances(userId)).find((w) => w.chain === "base");
    for (let i = 0; i < 20 && Number(base?.balance ?? 0) < 0.2; i++) {
      await sleep(3_000);
      base = (await chainBalances(userId)).find((w) => w.chain === "base");
    }
    check(base?.balance === "0.200000", `the dashboard shows 0.2 USDC on Base Sepolia (${base?.address})`);

    // Our transfer fee: from the test user's Arc wallet to the treasury
    const fee = networkFeeMicro();
    if (fee > 0) {
      let row = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      for (let i = 0; i < 40 && row?.networkFeeStatus !== "COMPLETE" && row?.networkFeeStatus !== "FAILED"; i++) {
        await advanceNetworkFee(out!.id);
        await sleep(3_000);
        row = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      }
      check(row?.networkFeeStatus === "COMPLETE" && Boolean(row.networkFeeTxHash) && row.networkFeeMicro === fee,
        `our transfer fee of ${show(fee)} USDC went to the treasury (${env.EXPLORER_TX_URL}${row?.networkFeeTxHash ?? ""})`,
        { status: row?.networkFeeStatus, micro: row?.networkFeeMicro });
      await advanceNetworkFee(out!.id);
      const again = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      check(again?.networkFeeTxId === row?.networkFeeTxId, "the fee is never taken twice");
    }

    // 3. Move it back to Arc (Base Sepolia deposits wait for full finality: about 20 minutes)
    if (withReturn) {
      const arcBefore = await usdcMicroOf(arc.circleWalletId);
      const back = await returnToArc(userId, { chain: "base" });
      check(Boolean(back?.id) && back?.direction === "IN", `"Move to Arc" started: ${back?.amount} USDC after Circle's fee`);
      ids.push(back!.id);
      console.log("Waiting for Base Sepolia finality (up to about 20 minutes)...");
      const home = await waitDone(userId, back!.id, 40);
      check(home.view?.status === "COMPLETE", `back on Arc in ${Math.round(home.seconds / 60)} minutes (${home.view?.mintUrl})`);
      let arcAfter = arcBefore;
      const expected = Math.round(Number(back!.amount) * 1e6);
      for (let i = 0; i < 20 && arcAfter < arcBefore + expected; i++) {
        await sleep(3_000);
        arcAfter = await usdcMicroOf(arc.circleWalletId);
      }
      check(arcAfter - arcBefore === expected, `the Arc wallet received exactly ${back!.amount} USDC`);
    } else {
      console.log("Skipped the 20 minute Move to Arc test.");
    }

    try {
      await returnToArc(userId, { chain: "polygon" });
      check(false, "moving from a network with no USDC is refused");
    } catch (err) {
      check(err instanceof BridgeUserError, "moving from a network with no USDC is refused");
    }
  } finally {
    for (const id of ids) while (driving.has(id)) await sleep(1_000);
    const ts = (await db.select({ id: bridgeTransfers.id }).from(bridgeTransfers).where(eq(bridgeTransfers.userId, userId))).map((r) => r.id);
    if (ts.length) {
      await db.delete(bridgeEvents).where(inArray(bridgeEvents.transferId, ts));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ts));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ts));
    }
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All own wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
DOC_EOF
cat > "backend/scripts/live-report.ts" <<'DOC_EOF'
// Read only: the latest bridge transfers and swaps on the database you point it
// at (the live one in setup/29), to check the live mainnet tests. Changes nothing.
// Run with: TURSO_DATABASE_URL=... TURSO_AUTH_TOKEN=... npx tsx scripts/live-report.ts
import { desc } from "drizzle-orm";
import { db } from "../src/db";
import { bridgeTransfers, swaps } from "../src/db/schema";
import { chainByKey } from "../src/bridge/chains";
import { getPauses } from "../src/settings";

const usdc = (micro: number | null) => (micro === null ? "-" : (micro / 1_000_000).toFixed(6));
const when = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos" });
const label = (key: string) => {
  try {
    return chainByKey(key).label;
  } catch {
    return key;
  }
};

async function main() {
  const p = await getPauses();
  console.log(`Paused for users: bridge ${p.bridgePaused ? "yes" : "no"}, swaps ${p.swapPaused ? "yes" : "no"}, buying ${p.purchasesPaused ? "yes" : "no"}`);

  const ts = await db.select().from(bridgeTransfers).orderBy(desc(bridgeTransfers.createdAt)).limit(10);
  console.log(`\nLatest transfers (${ts.length}):`);
  for (const t of ts) {
    console.log(`  ${when(t.createdAt)}  ${t.status.padEnd(9)} ${usdc(t.amountMicro)} USDC ${label(t.sourceChain)} -> ${label(t.destinationChain)}`);
    console.log(`      Circle fee (max) ${usdc(t.maxFeeMicro)}, our fee ${usdc(t.networkFeeMicro)} (${t.networkFeeStatus ?? "none"})${t.failureReason ? `, reason: ${t.failureReason}` : ""}`);
    if (t.mintTxHash) console.log(`      mint ${chainByKey(t.destinationChain).explorerTx}${t.mintTxHash}`);
    if (t.networkFeeTxHash) console.log(`      fee  ${chainByKey("arc").explorerTx}${t.networkFeeTxHash}`);
  }

  const ss = await db.select().from(swaps).orderBy(desc(swaps.createdAt)).limit(10);
  console.log(`\nLatest swaps (${ss.length}):`);
  for (const s of ss) {
    console.log(`  ${when(s.createdAt)}  ${s.status.padEnd(9)} ${s.amountIn} ${s.tokenIn} -> ${s.amountOut ?? "?"} ${s.tokenOut}${s.txHash ? `  ${chainByKey("arc").explorerTx}${s.txHash}` : ""}`);
    if (s.error) console.log(`      ${s.error.slice(0, 200)}`);
  }
}

main()
  .then(() => process.exit(0))
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
DOC_EOF
cat > "backend/src/bridge/chains.ts" <<'DOC_EOF'
// Chains the bridge supports, with everything Circle Gateway needs for each.
// Sources: developers.circle.com (Gateway contract addresses, USDC contract
// addresses, Wallets supported blockchains). Which of them users can use is set
// by BRIDGE_CHAINS (see openChains).
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

// The networks users can send to and bring USDC back from right now
// (BRIDGE_CHAINS; on mainnet Arc and Base, the networks with a Gas Station policy).
export function openChains(): BridgeChain[] {
  const all = registry();
  if (env.BRIDGE_CHAINS.includes("*")) return all;
  return all.filter((c) => c.key === "arc" || env.BRIDGE_CHAINS.includes(c.key));
}

export function isOpenChain(key: string): boolean {
  return openChains().some((c) => c.key === key);
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
cat > "backend/src/bridge/fees.ts" <<'DOC_EOF'
// Our transfer fee (BRIDGE_NETWORK_FEE_USDC, 0.10 USDC by default) for each
// completed transfer, paid from the user's Arc wallet to the treasury. It covers
// the gas we sponsor for users through Circle Gas Station.
//
// Fee: PENDING -> SENT -> COMPLETE   (or FAILED: reported, never charged twice)
//
// Safety:
//   - only taken after the transfer is COMPLETE, so a failed transfer costs nothing
//   - the Circle transfer uses an idempotency key made from the transfer id, so
//     a retry after a crash can never charge twice
//   - for "Move to Arc" the fee comes out of the USDC that just arrived on Arc
import { randomUUID } from "node:crypto";
import { and, eq, inArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, bridgeTransfers, ledgerEntries } from "../db/schema";
import { env } from "../env";
import { ensureUserWallet, uuidFrom } from "../wallets/service";
import { microFromDecimal } from "./gateway";

type Transfer = typeof bridgeTransfers.$inferSelect;

const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// A fee that still cannot be taken after this long is reported and given up
const GIVE_UP_MS = 48 * 60 * 60_000;

const usdcText = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;

// The fee for a new transfer, in micro USDC (0 when switched off)
export function networkFeeMicro(): number {
  return Math.max(0, Math.round(env.BRIDGE_NETWORK_FEE_USDC * 1_000_000));
}

async function audit(action: string, t: Transfer, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "bridge_transfer", targetId: t.id, details });
}

async function giveUp(t: Transfer, reason: string) {
  const [row] = await db
    .update(bridgeTransfers)
    .set({ networkFeeStatus: "FAILED" })
    .where(and(eq(bridgeTransfers.id, t.id), inArray(bridgeTransfers.networkFeeStatus, ["PENDING", "SENT"])))
    .returning();
  if (row) {
    await audit("bridge.network_fee_failed", t, { reason, feeMicro: t.networkFeeMicro });
    console.error(`[bridge] ${t.id} network fee not taken: ${reason}`);
  }
}

// One step for one transfer's fee. Safe to call as often as you like.
export async function advanceNetworkFee(id: string): Promise<void> {
  const [t] = await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, id)).limit(1);
  if (!t || t.status !== "COMPLETE" || !t.userId || t.networkFeeMicro <= 0) return;
  if (t.networkFeeStatus === "PENDING") await sendFee(t);
  else if (t.networkFeeStatus === "SENT") await checkFee(t);
}

async function sendFee(t: Transfer) {
  const wallet = await ensureUserWallet(t.userId!);
  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const have = usdc ? microFromDecimal(usdc.amount) : 0;
  if (!usdc?.token?.id || have < t.networkFeeMicro) {
    // For "Move to Arc" the USDC may not show in the balance yet: try again later
    if (Date.now() - t.createdAt.getTime() > GIVE_UP_MS) await giveUp(t, `not enough USDC in the Arc wallet (${usdcText(have)})`);
    return;
  }
  const input = {
    walletId: wallet.circleWalletId,
    tokenId: usdc.token.id,
    destinationAddress: env.TREASURY_ADDRESS,
    amount: [usdcText(t.networkFeeMicro)],
    amounts: [usdcText(t.networkFeeMicro)],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`bridge:${t.id}:network-fee`),
    refId: `bridge-fee-${t.id}`,
  };
  const sent = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
  const txId = sent.data?.id;
  if (!txId) throw new Error("Circle did not accept the network fee transfer");
  await db
    .update(bridgeTransfers)
    .set({ networkFeeStatus: "SENT", networkFeeTxId: txId })
    .where(and(eq(bridgeTransfers.id, t.id), eq(bridgeTransfers.networkFeeStatus, "PENDING")));
}

async function checkFee(t: Transfer) {
  if (!t.networkFeeTxId) return;
  const res = await circle.getTransaction({ id: t.networkFeeTxId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (tx?.state === "COMPLETE") {
    const [row] = await db
      .update(bridgeTransfers)
      .set({ networkFeeStatus: "COMPLETE", networkFeeTxHash: tx.txHash ?? null })
      .where(and(eq(bridgeTransfers.id, t.id), eq(bridgeTransfers.networkFeeStatus, "SENT")))
      .returning();
    if (row) {
      const journalId = randomUUID();
      await db.insert(ledgerEntries).values([
        { journalId, account: `customer:${t.userId}`, currency: "USDC", debit: t.networkFeeMicro, memo: `Transfer fee for bridge ${t.id}` },
        { journalId, account: "revenue:bridge_fee", currency: "USDC", credit: t.networkFeeMicro, memo: `Bridge ${t.id} fee ${tx.txHash ?? ""}` },
      ]);
      await audit("bridge.network_fee", t, { feeMicro: t.networkFeeMicro, txHash: tx.txHash ?? null });
    }
  } else if (tx?.state && FAILED_STATES.includes(tx.state)) {
    // The same idempotency key would only return this failed transfer again
    await giveUp(t, `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
  }
}

// For the worker: every completed transfer whose fee is still open
export async function advanceOpenNetworkFees(): Promise<void> {
  const open = await db
    .select({ id: bridgeTransfers.id })
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "COMPLETE"), inArray(bridgeTransfers.networkFeeStatus, ["PENDING", "SENT"])))
    .limit(20);
  for (const { id } of open) {
    try {
      await advanceNetworkFee(id);
    } catch (err) {
      console.error(`[bridge] fee ${id}:`, err instanceof Error ? err.message : err);
    }
  }
}

// Fees taken in a period, and any that could not be taken (for the daily report)
export async function networkFeeSummary(since: Date) {
  const rows = await db
    .select({ id: bridgeTransfers.id, fee: bridgeTransfers.networkFeeMicro, status: bridgeTransfers.networkFeeStatus, updatedAt: bridgeTransfers.updatedAt })
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "COMPLETE"), inArray(bridgeTransfers.networkFeeStatus, ["COMPLETE", "FAILED"])));
  const recent = rows.filter((r) => r.updatedAt >= since);
  return {
    collected: usdcText(recent.filter((r) => r.status === "COMPLETE").reduce((s, r) => s + r.fee, 0)),
    failed: recent.filter((r) => r.status === "FAILED").map((r) => r.id),
  };
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
import { networkFeeSummary } from "./fees";
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

  // Our transfer fees
  const fees = await networkFeeSummary(since);
  lines.push(`Transfer fees taken, last 24 hours: ${fees.collected} USDC.`);
  for (const id of fees.failed) issues.push(`Transfer fee could not be taken for ${id} (see the audit log)`);

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
import { isUniqueViolation } from "../db/errors";
import { approvedDestinations, auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries } from "../db/schema";
import { env } from "../env";
import { uuidFrom } from "../wallets/service";
import { chainByKey, feeCapMicro, isEvmAddress, type BridgeChain } from "./chains";
import { advanceNetworkFee } from "./fees";
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
// A Circle transaction that ended FAILED, DENIED or CANCELLED. Retrying with the
// same idempotency key only returns the same failed transaction, so it is final.
export class ContractCallFailed extends BridgeError {}

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
  // A finished transfer frees the user's "one transfer at a time" slot
  const done = to === "COMPLETE" || to === "FAILED" ? { openKey: null } : {};
  const [row] = await db
    .update(bridgeTransfers)
    .set({ status: to, ...extra, ...done })
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
      throw new ContractCallFailed(`${p.signature} ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
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
  // Our transfer fee, taken from the user's Arc wallet once the transfer completes
  networkFeeMicro?: number;
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

  let row: Transfer | undefined;
  try {
    [row] = await db
    .insert(bridgeTransfers)
    .values({
      userId: p.userId ?? null,
      // One open transfer per user, enforced by the database (a double click cannot start two)
      openKey: p.userId ?? null,
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
      networkFeeMicro: p.userId ? (p.networkFeeMicro ?? 0) : 0,
      networkFeeStatus: p.userId && (p.networkFeeMicro ?? 0) > 0 ? "PENDING" : null,
      salt,
      burnIntent: est.burnIntent,
      status: "QUOTED",
    })
    .returning();
  } catch (err) {
    if (isUniqueViolation(err, "open_key")) {
      throw new BridgeError("You already have a transfer in progress. Please wait for it to finish.");
    }
    throw err;
  }
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

  // From here on the transfer is DEPOSITING (it may have just moved there above)
  const current: Transfer = { ...t, status: "DEPOSITING" };
  const [plan] = await db
    .select()
    .from(bridgeEvents)
    .where(and(eq(bridgeEvents.transferId, t.id), eq(bridgeEvents.step, "deposit_planned")))
    .orderBy(desc(bridgeEvents.createdAt))
    .limit(1);
  const value = (plan?.details as { value?: string } | null)?.value;
  if (!value) {
    await fail(current, "deposit plan missing");
    return;
  }
  const round = plan?.id ?? "first"; // a re-quote makes a new plan, so new idempotency keys
  try {
    await depositCalls(t, source, value, round);
  } catch (err) {
    if (err instanceof ContractCallFailed) {
      // Final: the same call would only fail again. The USDC did not leave the wallet.
      await fail(current, `the deposit into Circle Gateway did not go through (${err.message}). Your USDC is still in your wallet.`);
      return;
    }
    throw err; // slow or unreachable: tried again later
  }
}

async function depositCalls(t: Transfer, source: BridgeChain, value: string, round: string) {
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
    // Our transfer fee: started now, finished by the worker if anything is slow
    try {
      await advanceNetworkFee(t.id);
    } catch (err) {
      console.error(`[bridge] ${t.id} fee:`, err instanceof Error ? err.message : err);
    }
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
cat > "backend/src/bridge/user.ts" <<'DOC_EOF'
// Bridging for signed in users, through Circle Gateway:
//   OUT: from their Arc smart wallet to their OWN wallet on another network,
//        or to an approved (VTU provider) address
//   IN:  "Move to Arc": everything in their wallet on another network goes
//        back to their Arc wallet
import { and, desc, eq, gte, inArray, notInArray, sql } from "drizzle-orm";
import { db } from "../db";
import { approvedDestinations, bridgeEvents, bridgeTransfers, wallets } from "../db/schema";
import { env } from "../env";
import { ensureUserWallet } from "../wallets/service";
import { chainByKey, feeCapMicro, homeChain, isOpenChain, openChains, type BridgeChain } from "./chains";
import { networkFeeMicro } from "./fees";
import { buildSpec, estimate, gatewayBalanceMicro, microFromDecimal, newSalt } from "./gateway";
import { BridgeError, advanceTransfer, createTransfer } from "./service";
import { ensureChainWallet, listChainWallets, usdcMicroOf } from "./wallets";

export class BridgeUserError extends Error {
  constructor(message: string, public status: 400 | 402 | 404 | 409 | 503 = 400) {
    super(message);
  }
}

const OPEN = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"] as const;
const usdcText = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
const micro = (usdc: number) => Math.round(usdc * 1_000_000);
// Moving back to Arc: keep a little extra so a small fee rise cannot leave the deposit short
const RETURN_BUFFER_MICRO = 10_000;
const RETURN_MIN_MICRO = 50_000;

function parseAmount(amount: unknown): number {
  const text = String(amount ?? "").trim();
  if (!/^\d+(\.\d{1,6})?$/.test(text)) throw new BridgeUserError("Enter an amount in USDC, for example 5 or 2.5.");
  const value = microFromDecimal(text);
  if (value < micro(env.BRIDGE_MIN_USDC)) throw new BridgeUserError(`The minimum is ${env.BRIDGE_MIN_USDC} USDC.`);
  if (value > micro(env.BRIDGE_MAX_USDC)) throw new BridgeUserError(`The maximum per transfer is ${env.BRIDGE_MAX_USDC} USDC.`);
  return value;
}

function requireEnabled() {
  if (!env.BRIDGE_ENABLED) throw new BridgeUserError("Sending to other networks is not available yet.", 503);
}

function otherChains(): BridgeChain[] {
  const home = homeChain();
  return openChains().filter((c) => c.key !== home.key);
}

type Target = { chain: BridgeChain; address: string; label: string; own: boolean };

// destinationId is either "own:<chain>" (the user's own wallet) or an approved destination id
async function resolveTarget(userId: string, destinationId: unknown): Promise<Target> {
  const id = String(destinationId ?? "");
  if (id.startsWith("own:")) {
    const key = id.slice(4);
    if (!otherChains().some((c) => c.key === key)) throw new BridgeUserError("Choose one of the listed destinations.", 404);
    const chain = chainByKey(key);
    const w = await ensureChainWallet(userId, key);
    return { chain, address: w.address, label: "Your wallet", own: true };
  }
  const [d] = await db
    .select()
    .from(approvedDestinations)
    .where(and(eq(approvedDestinations.id, id), eq(approvedDestinations.active, true)))
    .limit(1);
  if (!d || !isOpenChain(d.chain)) throw new BridgeUserError("Choose one of the listed destinations.", 404);
  return { chain: chainByKey(d.chain), address: d.address, label: d.label, own: false };
}

async function noOpenTransfer(userId: string) {
  const [open] = await db
    .select({ id: bridgeTransfers.id })
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.userId, userId), inArray(bridgeTransfers.status, [...OPEN])))
    .limit(1);
  if (open) throw new BridgeUserError("You already have a transfer in progress. Please wait for it to finish.", 409);
}

export async function listDestinations() {
  requireEnabled();
  const own = otherChains().map((c) => ({ id: `own:${c.key}`, label: `My wallet on ${c.label}`, chain: c.key, chainLabel: c.label, address: null as string | null, own: true }));
  const rows = await db.select().from(approvedDestinations).where(eq(approvedDestinations.active, true));
  const providers = rows.filter((d) => isOpenChain(d.chain)).map((d) => {
    const chain = chainByKey(d.chain);
    return { id: d.id, label: d.label, chain: chain.key, chainLabel: chain.label, address: d.address as string | null, own: false };
  });
  return [...own, ...providers];
}

// What the user would pay. Nothing is saved (an own wallet may be created).
export async function quoteBridge(userId: string, body: { destinationId?: unknown; amount?: unknown }) {
  requireEnabled();
  const target = await resolveTarget(userId, body.destinationId);
  const amountMicro = parseAmount(body.amount);
  const wallet = await ensureUserWallet(userId);
  const source = homeChain();
  const est = await estimate(
    buildSpec({ source, destination: target.chain, depositor: wallet.address, recipient: target.address, amountMicro, salt: newSalt() }),
    true,
  );
  const [inWallet, inGateway] = await Promise.all([usdcMicroOf(wallet.circleWalletId), gatewayBalanceMicro(wallet.address, source.domain)]);
  const netFee = networkFeeMicro();
  return {
    destination: { id: String(body.destinationId), label: target.label, chainLabel: target.chain.label, address: target.address },
    amount: usdcText(amountMicro),
    fee: usdcText(est.maxFeeMicro),
    networkFee: usdcText(netFee),
    total: usdcText(amountMicro + est.maxFeeMicro + netFee),
    receives: usdcText(amountMicro),
    available: usdcText(inWallet + inGateway),
    enough: covers(inWallet, inGateway, amountMicro + est.maxFeeMicro, netFee),
    allowed: est.maxFeeMicro <= feeCapMicro(target.chain),
    note: netFee > 0
      ? "Circle's fee shown is the most it can charge; any unused part stays in your bridge balance for next time. Our transfer fee covers the network gas we pay for you, and is taken only when the transfer completes."
      : "The fee shown is the most Circle can charge; any unused part stays in your bridge balance for next time.",
  };
}

// Enough for the transfer (wallet plus bridge balance) and, separately, our fee
// from the wallet itself (it is paid from the Arc wallet when the transfer completes)
function covers(inWallet: number, inGateway: number, transferMicro: number, feeMicro: number): boolean {
  const fromWallet = Math.max(0, transferMicro - inGateway);
  return inWallet >= fromWallet + feeMicro;
}

export async function startBridge(userId: string, body: { destinationId?: unknown; amount?: unknown }) {
  requireEnabled();
  const target = await resolveTarget(userId, body.destinationId);
  const amountMicro = parseAmount(body.amount);
  await noOpenTransfer(userId);

  const since = new Date(Date.now() - 24 * 60 * 60_000);
  const today = await db
    .select({ amountMicro: bridgeTransfers.amountMicro })
    .from(bridgeTransfers)
    .where(and(
      eq(bridgeTransfers.userId, userId),
      eq(bridgeTransfers.direction, "OUT"),
      gte(bridgeTransfers.createdAt, since),
      notInArray(bridgeTransfers.status, ["FAILED"]),
    ));
  const used = today.reduce((s, r) => s + r.amountMicro, 0);
  if (used + amountMicro > micro(env.BRIDGE_DAILY_USDC)) {
    throw new BridgeUserError(`The daily limit is ${env.BRIDGE_DAILY_USDC} USDC. You can send ${usdcText(Math.max(0, micro(env.BRIDGE_DAILY_USDC) - used))} more today.`);
  }

  const wallet = await ensureUserWallet(userId);
  const source = homeChain();
  // Check the balance against Circle's current fee before anything is saved
  const est = await estimate(
    buildSpec({ source, destination: target.chain, depositor: wallet.address, recipient: target.address, amountMicro, salt: newSalt() }),
    true,
  );
  const [inWallet, inGateway] = await Promise.all([usdcMicroOf(wallet.circleWalletId), gatewayBalanceMicro(wallet.address, source.domain)]);
  const needed = amountMicro + est.maxFeeMicro;
  const netFee = networkFeeMicro();
  if (!covers(inWallet, inGateway, needed, netFee)) {
    throw new BridgeUserError(
      `Not enough USDC. You need ${usdcText(needed + netFee)} USDC (amount plus fees). You have ${usdcText(inWallet + inGateway)} USDC.`,
      402,
    );
  }

  let transfer;
  try {
    transfer = await createTransfer({
      direction: "OUT",
      userId,
      depositorWalletId: wallet.circleWalletId,
      depositorAddress: wallet.address,
      sourceChain: source.key,
      destinationChain: target.chain.key,
      recipientAddress: target.address,
      amountMicro,
      trustedRecipient: target.own,
      networkFeeMicro: netFee,
    });
  } catch (err) {
    if (err instanceof BridgeError) throw new BridgeUserError(err.message);
    throw err;
  }
  driveTransfer(transfer.id);
  return getBridgeView(userId, transfer.id);
}

// "Move to Arc": everything in the user's wallet on another network goes home.
export async function returnToArc(userId: string, body: { chain?: unknown }) {
  requireEnabled();
  const key = String(body.chain ?? "");
  if (!otherChains().some((c) => c.key === key)) throw new BridgeUserError("Choose one of your networks.", 404);
  await noOpenTransfer(userId);
  const source = chainByKey(key);
  const home = homeChain();
  const from = await ensureChainWallet(userId, key);
  const arc = await ensureUserWallet(userId);

  const [inWallet, inGateway] = await Promise.all([usdcMicroOf(from.circleWalletId), gatewayBalanceMicro(from.address, source.domain)]);
  const total = inWallet + inGateway;
  const est = await estimate(
    buildSpec({ source, destination: home, depositor: from.address, recipient: arc.address, amountMicro: Math.max(total, 1), salt: newSalt() }),
    true,
  );
  const amountMicro = total - est.maxFeeMicro - RETURN_BUFFER_MICRO;
  // Our transfer fee comes out of what arrives on Arc, so it must leave something worth moving
  const netFee = networkFeeMicro();
  if (amountMicro < RETURN_MIN_MICRO + netFee) {
    throw new BridgeUserError(
      `There is not enough USDC on ${source.label} to move. Circle's fee is about ${usdcText(est.maxFeeMicro)} USDC` +
        (netFee > 0 ? ` and our transfer fee is ${usdcText(netFee)} USDC.` : "."),
      402,
    );
  }

  let transfer;
  try {
    transfer = await createTransfer({
      direction: "IN",
      userId,
      depositorWalletId: from.circleWalletId,
      depositorAddress: from.address,
      sourceChain: source.key,
      destinationChain: home.key,
      recipientAddress: arc.address,
      amountMicro,
      networkFeeMicro: netFee,
    });
  } catch (err) {
    if (err instanceof BridgeError) throw new BridgeUserError(err.message);
    throw err;
  }
  driveTransfer(transfer.id);
  return getBridgeView(userId, transfer.id);
}

// Moves a transfer forward in the background until it is done (the worker
// also picks up anything left behind, for example after a restart).
export const driving = new Set<string>();
export function driveTransfer(id: string): void {
  if (driving.has(id)) return;
  driving.add(id);
  void (async () => {
    const started = Date.now();
    try {
      // Deposits on Ethereum based networks can take about 20 minutes to be final
      while (Date.now() - started < 40 * 60_000) {
        const before = await db.select({ status: bridgeTransfers.status }).from(bridgeTransfers).where(eq(bridgeTransfers.id, id)).limit(1);
        const t = await advanceTransfer(id);
        if (t.status === "COMPLETE" || t.status === "FAILED") break;
        if (before[0]?.status === t.status) await new Promise((r) => setTimeout(r, t.status === "DEPOSITED" ? 15_000 : 4_000));
      }
    } catch (err) {
      console.error(`[bridge] drive ${id}:`, err instanceof Error ? err.message : err);
    } finally {
      driving.delete(id);
    }
  })();
}

export async function getBridgeView(userId: string, id: string) {
  const [t] = await db
    .select()
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.id, id), eq(bridgeTransfers.userId, userId)))
    .limit(1);
  if (!t) return null;
  const source = chainByKey(t.sourceChain);
  const destination = chainByKey(t.destinationChain);
  const [own] = await db
    .select({ id: wallets.id })
    .from(wallets)
    .where(and(eq(wallets.userId, userId), eq(wallets.blockchain, destination.circleBlockchain), sql`lower(${wallets.address}) = ${t.recipientAddress.toLowerCase()}`))
    .limit(1);
  const [dest] = own
    ? []
    : await db
        .select({ label: approvedDestinations.label })
        .from(approvedDestinations)
        .where(and(eq(approvedDestinations.chain, t.destinationChain), eq(approvedDestinations.address, t.recipientAddress)))
        .limit(1);
  const events = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(bridgeEvents.createdAt);
  return {
    id: t.id,
    direction: t.direction,
    status: t.status,
    destinationLabel: own ? "Your wallet" : (dest?.label ?? t.recipientAddress),
    sourceLabel: source.label,
    destinationChainLabel: destination.label,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    maxFee: t.maxFeeMicro !== null ? usdcText(t.maxFeeMicro) : null,
    networkFee: t.networkFeeMicro > 0 ? usdcText(t.networkFeeMicro) : null,
    networkFeeStatus: t.networkFeeStatus,
    mintTxHash: t.mintTxHash,
    mintUrl: t.mintTxHash ? `${destination.explorerTx}${t.mintTxHash}` : null,
    failureReason: t.failureReason,
    slowFinality: source.key !== homeChain().key,
    createdAt: t.createdAt.toISOString(),
    steps: events
      .filter((e) => !["error"].includes(e.step))
      .map((e) => {
        const chain = e.chain ? chainByKey(e.chain) : null;
        return {
          step: e.step,
          chainLabel: chain?.label ?? null,
          txHash: e.txHash,
          url: chain && e.txHash ? `${chain.explorerTx}${e.txHash}` : null,
          at: e.createdAt.toISOString(),
        };
      }),
  };
}

export async function listBridges(userId: string) {
  const rows = await db
    .select()
    .from(bridgeTransfers)
    .where(eq(bridgeTransfers.userId, userId))
    .orderBy(desc(bridgeTransfers.createdAt))
    .limit(20);
  return rows.map((t) => ({
    id: t.id,
    direction: t.direction,
    status: t.status,
    sourceChainLabel: chainByKey(t.sourceChain).label,
    destinationChainLabel: chainByKey(t.destinationChain).label,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    createdAt: t.createdAt.toISOString(),
  }));
}

// The user's leftover bridge balance on Arc (unused fees stay in Gateway for next time)
export async function bridgeBalance(walletAddress: string): Promise<string | null> {
  if (!env.BRIDGE_ENABLED) return null;
  try {
    return usdcText(await gatewayBalanceMicro(walletAddress, homeChain().domain));
  } catch {
    return null;
  }
}

// Balances on the user's other network wallets: wallet USDC plus any Gateway leftover there
export async function chainBalances(userId: string) {
  requireEnabled();
  const list = await listChainWallets(userId);
  const out = [];
  for (const w of list) {
    let gateway = 0;
    try {
      gateway = await gatewayBalanceMicro(w.address, chainByKey(w.chain).domain);
    } catch {
      gateway = 0;
    }
    out.push({
      chain: w.chain,
      chainLabel: w.chainLabel,
      address: w.address,
      explorerUrl: w.explorerUrl,
      balance: w.balanceMicro === null ? null : usdcText(w.balanceMicro + gateway),
    });
  }
  return out;
}
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
  // Our transfer fee (USDC) on each completed transfer, paid to the treasury.
  // It covers the gas we sponsor through Circle Gas Station. 0 switches it off.
  BRIDGE_NETWORK_FEE_USDC: optionalNumber("BRIDGE_NETWORK_FEE_USDC") ?? 0.1,
  // Networks users can send to (comma separated keys). Default: all on testnet,
  // Arc and Base on mainnet (the networks with a Gas Station policy).
  BRIDGE_CHAINS: (process.env.BRIDGE_CHAINS?.trim() ||
    ((process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET").endsWith("TESTNET") ? "*" : "arc,base"))
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  // Admin dashboard: the only email that can log in, and the dashboard's address
  // (used in password reset links). Both set on Render.
  ADMIN_EMAIL: process.env.ADMIN_EMAIL?.trim().toLowerCase() || undefined,
  ADMIN_URL: (process.env.ADMIN_URL ?? "http://localhost:3001").trim().replace(/\/$/, ""),
  // Accounts that can still use the bridge and swaps while they are paused,
  // for live checks before opening them to everyone. Default: the admin email.
  PAUSE_BYPASS_EMAILS: (process.env.PAUSE_BYPASS_EMAILS ?? process.env.ADMIN_EMAIL ?? "")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
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
// Accounts in PAUSE_BYPASS_EMAILS (the admin by default) can still use the
// bridge and swaps while they are paused, for live checks. Never purchases.
export async function pausedMessage(key: PauseKey, email?: string | null): Promise<string | null> {
  if (!(await getPauses())[key]) return null;
  if (key !== "purchasesPaused" && email && env.PAUSE_BYPASS_EMAILS.includes(email.trim().toLowerCase())) return null;
  return PAUSE_MESSAGES[key];
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
import { alertStuck, dailyReconcile } from "./bridge/monitor";
import { releaseAbandonedSwaps } from "./swap/service";

const EVERY_MS = 30_000;
// Interrupted payments are looked up on Circle every 5 minutes
const RECOVER_EVERY_MS = 5 * 60_000;
let lastRecovery = 0;

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
cat > "frontend/src/app/bridge/[id]/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { BRIDGE_DONE, BRIDGE_LABELS, STEP_LABELS, type BridgeView } from "@/lib/bridge";
import { toneClass } from "@/lib/orders";
import { SupportLink } from "@/components/SupportLink";

const MILESTONES = [
  { key: "deposit", text: "Moved into Circle Gateway", done: ["DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED"] },
  { key: "finalized", text: "Gateway balance confirmed", done: ["FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED"] },
  { key: "submitted", text: "Signed and sent to Circle", done: ["SUBMITTED", "MINTED", "COMPLETE"] },
  { key: "minted", text: "Arrived at the destination", done: ["MINTED", "COMPLETE"] },
];

export default function BridgeTransferPage() {
  const router = useRouter();
  const { id } = useParams<{ id: string }>();
  const { data: session, isPending } = authClient.useSession();
  const [t, setT] = useState<BridgeView | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session || !id) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ transfer: BridgeView }>(`/bridge/transfers/${id}`);
        if (stop) return;
        setT(r.transfer);
        setError(null);
        if (!BRIDGE_DONE.includes(r.transfer.status)) timer = setTimeout(load, 3000);
      } catch (e) {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this transfer.");
        timer = setTimeout(load, 5000);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session, id]);

  const label = t ? (BRIDGE_LABELS[t.status] ?? { text: t.status, tone: "wait" as const }) : null;

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Transfer</h1>
        {error && !t ? (
          <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
        ) : null}
        {!t && !error ? <p className="mt-6 text-zinc-500">Loading...</p> : null}

        {t && label ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between gap-3">
              <p className="text-lg font-medium text-zinc-900 dark:text-zinc-50">
                {t.amount} USDC to {t.destinationLabel} on {t.destinationChainLabel}
              </p>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
            </div>

            <ol className="space-y-3">
              {MILESTONES.map((m) => {
                const done = m.done.includes(t.status);
                return (
                  <li key={m.key} className="flex items-center gap-3 text-sm">
                    <span
                      className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                        done ? "bg-emerald-700 text-white" : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                      }`}
                    >
                      {done ? "✓" : ""}
                    </span>
                    <span className={done ? "text-zinc-900 dark:text-zinc-100" : "text-zinc-500"}>
                      {m.key === "minted" ? `Arrived on ${t.destinationChainLabel}` : m.text}
                    </span>
                  </li>
                );
              })}
            </ol>

            {t.slowFinality && ["DEPOSITING", "DEPOSITED"].includes(t.status) ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                Waiting for {t.sourceLabel} to confirm the deposit. On this network Circle waits for full finality, which
                can take up to 20 minutes. You can close this page; it keeps going.
              </p>
            ) : null}
            {t.status === "COMPLETE" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Done. {t.amount} USDC arrived at {t.destinationLabel} on {t.destinationChainLabel}.
              </p>
            ) : null}
            {t.status === "FAILED" ? (
              <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
                This transfer stopped: {t.failureReason ?? "unknown reason"}. Any USDC already moved stays in your bridge
                balance and is used for your next transfer.
              </p>
            ) : null}

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">From</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">Your wallet ({t.sourceLabel})</dd>
              <dt className="text-zinc-500">To</dt>
              <dd className="min-w-0 text-zinc-900 dark:text-zinc-100">
                {t.destinationLabel} ({t.destinationChainLabel})
                <span className="block truncate font-mono text-xs text-zinc-500">{t.recipientAddress}</span>
              </dd>
              <dt className="text-zinc-500">Amount</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{t.amount} USDC</dd>
              {t.maxFee ? (
                <>
                  <dt className="text-zinc-500">Circle fee (max)</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">{t.maxFee} USDC</dd>
                </>
              ) : null}
              {t.networkFee ? (
                <>
                  <dt className="text-zinc-500">Our transfer fee</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">
                    {t.networkFee} USDC{" "}
                    <span className="text-xs text-zinc-500">
                      {t.status === "FAILED"
                        ? "(not charged)"
                        : t.networkFeeStatus === "COMPLETE"
                          ? "(paid)"
                          : t.networkFeeStatus === "FAILED"
                            ? "(not charged)"
                            : "(taken when the transfer completes)"}
                    </span>
                  </dd>
                </>
              ) : null}
              {t.mintUrl ? (
                <>
                  <dt className="text-zinc-500">Mint</dt>
                  <dd className="min-w-0">
                    <a href={t.mintUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                      {t.mintTxHash}
                    </a>
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Started</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{new Date(t.createdAt).toLocaleString("en-NG")}</dd>
            </dl>

            <div>
              <h2 className="text-sm font-medium text-zinc-500">Every step</h2>
              <ul className="mt-2 space-y-1.5 text-xs">
                {t.steps.map((s, i) => (
                  <li key={`${s.step}-${i}`} className="flex flex-wrap items-baseline gap-x-2">
                    <span className="text-zinc-500">{new Date(s.at).toLocaleTimeString("en-NG")}</span>
                    <span className="text-zinc-900 dark:text-zinc-100">{STEP_LABELS[s.step] ?? s.step}</span>
                    {s.chainLabel ? <span className="text-zinc-500">({s.chainLabel})</span> : null}
                    {s.url ? (
                      <a href={s.url} target="_blank" rel="noreferrer" className="font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {s.txHash?.slice(0, 10)}...
                      </a>
                    ) : null}
                  </li>
                ))}
              </ul>
            </div>

            <SupportLink block message={`Hello dataonchain, I need help with my transfer ${t.id} (${t.amount} USDC to ${t.destinationChainLabel}, ${label.text}).`}>
              Report a problem on WhatsApp
            </SupportLink>
            <Link
              href="/bridge"
              className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
            >
              Send another
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/bridge/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { BRIDGE_DONE, BRIDGE_LABELS, shortAddress, type BridgeListItem, type BridgeQuote, type BridgeView, type Destination } from "@/lib/bridge";
import { toneClass } from "@/lib/orders";

type Limits = { min: number; max: number; daily: number };

export default function BridgePage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [destinations, setDestinations] = useState<Destination[] | null>(null);
  const [limits, setLimits] = useState<Limits | null>(null);
  const [destinationId, setDestinationId] = useState("");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<BridgeQuote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [history, setHistory] = useState<BridgeListItem[]>([]);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<{ destinations: Destination[]; limits: Limits }>("/bridge/destinations")
      .then((r) => {
        setDestinations(r.destinations);
        setLimits(r.limits);
        if (r.destinations[0]) setDestinationId(r.destinations[0].id);
      })
      .catch((e) => {
        setDestinations([]);
        setError(e instanceof Error ? e.message : "Could not load destinations.");
      });
  }, [session]);

  // Past transfers, refreshed every 10 seconds while any is still moving
  useEffect(() => {
    if (!session) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ transfers: BridgeListItem[] }>("/bridge/transfers");
        if (stop) return;
        setHistory(r.transfers);
        if (r.transfers.some((t) => !BRIDGE_DONE.includes(t.status))) timer = setTimeout(load, 10_000);
      } catch {
        // the list is optional; the form still works
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session]);

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    try {
      const r = await api<{ quote: BridgeQuote }>("/bridge/quote", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function send() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/transfers", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the transfer.");
      setBusy(false);
    }
  }

  const enough = quote ? (quote.enough ?? Number(quote.available) >= Number(quote.total)) : false;

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Send to another network</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Send USDC from your Arc wallet to your own wallet on another network, or to an approved provider, through
          Circle Gateway. You pay no gas on any network. Circle&apos;s fee and our small transfer fee are shown before you
          confirm, and our fee is taken only when the transfer completes.
        </p>

        <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {destinations === null ? <p className="text-sm text-zinc-500">Loading...</p> : null}
          {destinations && destinations.length === 0 && !error ? (
            <p className="text-sm text-zinc-500">No providers are available yet.</p>
          ) : null}

          {destinations && destinations.length > 0 ? (
            <form onSubmit={getQuote} className="space-y-5">
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Send to</p>
                <div className="mt-2 space-y-2">
                  {destinations.map((d) => (
                    <label
                      key={d.id}
                      className={`flex cursor-pointer items-center justify-between gap-3 rounded-lg border px-3 py-2.5 text-sm ${
                        destinationId === d.id
                          ? "border-emerald-700 bg-emerald-50 dark:border-emerald-500 dark:bg-emerald-950"
                          : "border-zinc-300 dark:border-zinc-700"
                      }`}
                    >
                      <span className="flex items-center gap-2">
                        <input
                          type="radio"
                          name="destination"
                          value={d.id}
                          checked={destinationId === d.id}
                          onChange={() => {
                            setDestinationId(d.id);
                            setQuote(null);
                          }}
                        />
                        <span className="font-medium text-zinc-900 dark:text-zinc-100">{d.label}</span>
                      </span>
                      <span className="text-xs text-zinc-500">
                        {d.chainLabel}
                        {d.address ? (
                          <>
                            {" "}· <span className="font-mono">{shortAddress(d.address)}</span>
                          </>
                        ) : null}
                      </span>
                    </label>
                  ))}
                </div>
              </div>

              <div>
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount (USDC)
                </label>
                <input
                  id="amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => {
                    setAmount(e.target.value);
                    setQuote(null);
                  }}
                  placeholder={limits ? `${limits.min} to ${limits.max}` : "5"}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                {limits ? (
                  <p className="mt-1 text-xs text-zinc-500">
                    Minimum {limits.min} USDC, maximum {limits.max} USDC per transfer, {limits.daily} USDC per day.
                  </p>
                ) : null}
              </div>

              {!quote ? (
                <button
                  type="submit"
                  disabled={busy || !amount || !destinationId}
                  className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Checking the fee..." : "See the fee"}
                </button>
              ) : null}
            </form>
          ) : null}

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[9rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">To</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {quote.destination.label} ({quote.destination.chainLabel})
                </dd>
                <dt className="text-zinc-500">Address</dt>
                <dd className="truncate font-mono text-zinc-900 dark:text-zinc-100">{quote.destination.address}</dd>
                <dt className="text-zinc-500">They receive</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.receives} USDC</dd>
                <dt className="text-zinc-500">Circle fee (max)</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.fee} USDC</dd>
                {quote.networkFee && Number(quote.networkFee) > 0 ? (
                  <>
                    <dt className="text-zinc-500">Our transfer fee</dt>
                    <dd className="text-zinc-900 dark:text-zinc-100">{quote.networkFee} USDC</dd>
                  </>
                ) : null}
                <dt className="text-zinc-500">From your wallet</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.total} USDC</dd>
                <dt className="text-zinc-500">You have</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.available} USDC</dd>
              </dl>
              <p className="text-xs text-zinc-500">{quote.note}</p>
              {!quote.allowed ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Circle&apos;s fee to this network is unusually high right now. Please try again later.
                </p>
              ) : null}
              {!enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough USDC in your Arc wallet for this amount plus the fees.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={send}
                  disabled={busy || !enough || !quote.allowed}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Starting..." : `Send ${quote.amount} USDC`}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
            </div>
          ) : null}

          {error ? (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          ) : null}
        </section>

        {history.length > 0 ? (
          <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <h2 className="text-sm font-medium text-zinc-500">Recent transfers</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {history.map((t) => {
                const label = BRIDGE_LABELS[t.status] ?? { text: t.status, tone: "wait" as const };
                return (
                  <li key={t.id}>
                    <Link href={`/bridge/${t.id}`} className="flex flex-wrap items-center justify-between gap-2 py-2.5 hover:opacity-80">
                      <span className="min-w-0">
                        <span className="block text-zinc-900 dark:text-zinc-100">
                          {t.amount} USDC {t.sourceChainLabel} → {t.destinationChainLabel}
                        </span>
                        <span className="block text-xs text-zinc-500">
                          {new Date(t.createdAt).toLocaleString("en-NG")} · <span className="font-mono">{shortAddress(t.recipientAddress)}</span>
                        </span>
                      </span>
                      <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
                    </Link>
                  </li>
                );
              })}
            </ul>
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
    a: "Yes, on Arc mainnet, with real USDC. You can sign up, get your wallet and add USDC today. Sending to Base and swaps open in stages (your dashboard shows what is open), and buying airtime and data opens after our company registration and a live provider are in place.",
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
              Create an account and get your USDC wallet on Arc in a minute. Sending to Base and swaps open in stages,
              and buying airtime and data follows.
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
        <li>Circle charges a fee for each transfer, shown before you confirm. We also charge a small transfer fee (currently 0.10 USDC), shown before you confirm and taken from your Arc wallet only when the transfer completes. It covers the network fees we pay for you.</li>
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
        Every fee is shown before you confirm: the service fee in each airtime or data price, Circle&apos;s fee and our
        transfer fee for transfers, and the swap fee. You do not pay network (gas) fees for your Arc wallet; we cover them. We may change our fees, and
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
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="text-sm font-medium text-zinc-500">Your USDC on other networks</h2>
      <ul className="mt-3 divide-y divide-zinc-100 dark:divide-zinc-800">
        {rows.map((w) => (
          <li key={w.chain} className="flex flex-wrap items-center justify-between gap-3 py-3">
            <div className="min-w-0">
              <p className="text-sm font-medium text-zinc-900 dark:text-zinc-100">{w.chainLabel}</p>
              <a href={w.explorerUrl} target="_blank" rel="noreferrer" className="font-mono text-xs text-emerald-700 hover:underline dark:text-emerald-400">
                {shortAddress(w.address)}
              </a>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-sm font-semibold text-zinc-900 dark:text-zinc-50">
                {w.balance === null ? "unavailable" : `${usdc(w.balance)} USDC`}
              </span>
              {w.balance !== null && Number(w.balance) >= 0.1 + fee ? (
                <button
                  onClick={() => moveToArc(w.chain)}
                  disabled={busy !== null}
                  className="rounded-lg border border-zinc-300 px-3 py-1.5 text-xs font-medium text-zinc-800 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
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
cat > "frontend/src/lib/bridge.ts" <<'DOC_EOF'
// Shared bridge types and labels for the website.
export type Destination = { id: string; label: string; chain: string; chainLabel: string; address: string | null; own: boolean };

export type ChainWallet = { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null };

export type BridgeQuote = {
  destination: { id: string; label: string; chainLabel: string; address: string };
  amount: string;
  fee: string;
  networkFee?: string;
  total: string;
  receives: string;
  available: string;
  enough?: boolean;
  allowed: boolean;
  note: string;
};

export type BridgeStep = { step: string; chainLabel: string | null; txHash: string | null; url: string | null; at: string };

export type BridgeView = {
  id: string;
  direction: "OUT" | "IN";
  status: string;
  slowFinality: boolean;
  destinationLabel: string;
  sourceLabel: string;
  destinationChainLabel: string;
  recipientAddress: string;
  amount: string;
  maxFee: string | null;
  networkFee?: string | null;
  networkFeeStatus?: string | null;
  mintTxHash: string | null;
  mintUrl: string | null;
  failureReason: string | null;
  createdAt: string;
  steps: BridgeStep[];
};

export const BRIDGE_DONE = ["COMPLETE", "FAILED"];

export const BRIDGE_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Starting", tone: "wait" },
  DEPOSITING: { text: "Moving into Gateway", tone: "wait" },
  DEPOSITED: { text: "Waiting for confirmation", tone: "wait" },
  FINALIZED: { text: "Ready to send", tone: "wait" },
  INTENT_SIGNED: { text: "Signed", tone: "wait" },
  SUBMITTED: { text: "Sending", tone: "wait" },
  MINTED: { text: "Arrived", tone: "good" },
  COMPLETE: { text: "Complete", tone: "good" },
  EXPIRED: { text: "Retrying", tone: "wait" },
  FAILED: { text: "Failed", tone: "bad" },
};

export const STEP_LABELS: Record<string, string> = {
  quoted: "Fee checked",
  deposit_planned: "Preparing deposit",
  approve: "USDC approved for Gateway",
  deposit: "Deposited into Circle Gateway",
  finalized: "Gateway balance confirmed",
  requote: "Fee updated",
  signed: "Transfer signed by your wallet",
  submitted: "Sent to Circle",
  minted: "USDC minted at the destination",
  complete: "Complete",
  expired: "Expired before minting (nothing taken), retrying",
  retry: "Signing again",
  failed: "Failed",
};

export const shortAddress = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;

export type BridgeListItem = {
  id: string;
  direction: "OUT" | "IN";
  status: string;
  sourceChainLabel: string;
  destinationChainLabel: string;
  recipientAddress: string;
  amount: string;
  createdAt: string;
};
DOC_EOF
green "OK"

# --- 2. Development database -------------------------------------------------------
step "Database: transfer fee columns"
if ! grep -rqs 'network_fee_micro' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name bridge_network_fee)
fi
grep -rqs 'network_fee_micro' backend/drizzle/*.sql || fail "The database change was not created. Paste the output to Claude."
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

step "Bridge on testnet: 0.2 USDC to Base Sepolia, with the transfer fee (takes a few minutes)"
set +e
(cd backend && BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 BRIDGE_CHAINS=arc,base PAUSE_BYPASS_EMAILS=tester@example.com \
  npx tsx scripts/bridge-own-smoke.ts); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The testnet treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Bridge test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again. Otherwise paste the output to Claude."
fi
green "OK"

step "Website: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 4. Live database (before the new code goes live) -----------------------------
step "Live database: transfer fee columns"
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
git diff --cached --quiet || git commit -q -m "Mainnet bridge and swaps: Arc and Base only, 0.10 USDC transfer fee to the treasury, admin live checks while paused"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"networkFee":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
[[ "$STATUS" == *'"network":"mainnet"'* ]] || fail "Render is not on mainnet. Tell Claude."
curl -s --max-time 30 "$PROD_FRONTEND/" >/dev/null || true
wait_for "the website on Vercel" "$PROD_FRONTEND/" 'blockchains live' 30 || yellow "The website did not show the new wording yet. Check vercel.com later; nothing else depends on it."

# --- 6. Render switches --------------------------------------------------------------
NEED=""
[[ "$STATUS" == *'"bridge":true'* ]] || NEED="$NEED BRIDGE_ENABLED"
[[ "$STATUS" == *'"swap":true'* ]] || NEED="$NEED SWAP_ENABLED"
if [[ -n "$NEED" ]]; then
  echo
  yellow "On Render, these must be true:$NEED"
  echo "  Render > dataonchain > Environment > Edit (the top section, Environment Variables)."
  echo "  For each name above: click the eye icon, change the value to: true"
  echo "  (if the name is not in the list, click '+ Add' and type the name and true)."
  echo "  Then 'Save, rebuild, and deploy'. Bridge and swaps stay paused for users;"
  echo "  this only lets your admin account test them."
  read -r -p "When Render shows 'Deploy live', press Enter... " _
  for name in $NEED; do
    lower="$(printf '%s' "$name" | sed 's/_ENABLED//' | tr '[:upper:]' '[:lower:]')"
    wait_for "$name on Render" "$PROD_API/api/status" "\"$lower\":true" 30 || fail "$name is still not true on Render. Check the value (exactly: true), then run this script again."
  done
fi
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
if [[ "$STATUS" == *'"bridgePaused":false'* || "$STATUS" == *'"swapPaused":false'* ]]; then
  yellow "Note: the bridge or swaps are already OPEN for everyone (admin Settings). Pause them there until your live test passes."
fi

ADMIN="$(env_get ADMIN_EMAIL)"
[[ -n "$ADMIN" ]] || ADMIN="your admin email (the one you use for dashboard.dataonchain.online)"

echo
green "Script 29 complete. Bridge and swaps are ready on Arc mainnet, still paused for users."
echo
bold "Your live test with real USDC (about 3 USDC, 30 minutes):"
echo "  1. On $PROD_FRONTEND log in (or sign up and confirm) with: $ADMIN"
echo "     Only this account can use the bridge and swaps while they are paused."
echo "  2. Dashboard > Add USDC: send 3 USDC on Arc mainnet from your own wallet to the"
echo "     address shown. Check the network is Arc, then wait for it on the dashboard."
echo "  3. Send to another network > My wallet on Base > 1 > See the fee. Check it shows"
echo "     Circle's fee and our 0.10 transfer fee, then Send. Wait for Complete (about 1 to 2 minutes)."
echo "  4. Dashboard > Your USDC on other networks > Base > Move to Arc."
echo "     Base must confirm first: about 20 minutes. You can close the page meanwhile."
echo "  5. Swap: 1 USDC to EURC, then the EURC back to USDC."
echo "  6. See the results (read only):   bash setup/29_live_bridge_swap.sh report"
echo
bold "When it all looks right, open them for everyone:"
echo "  dashboard.dataonchain.online > Settings > Pause switches: click 'Open again' on"
echo "  'Sending to other networks' and on 'Swaps'."
echo "  You can pause them again there at any time."
