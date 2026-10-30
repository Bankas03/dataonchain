#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 35: send USDC on Base (withdraw to an exchange on Base)
#
#   - The Send page gets an Arc or Base choice. On Base, users send USDC from
#     their own Base wallet to any Base address, for example an exchange
#     deposit address, with the same emailed code, limits and receipts
#   - Never to their own wallets, a token contract or the zero address; USDC only
#   - Activity shows "Sent USDC on Base"; gas on Base is sponsored like on Arc
#   Database: a "chain" column on sends (existing sends are Arc).
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/35_send_on_base.sh
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
[[ -f backend/src/deposits/service.ts ]] || fail "Run this from ~/dataonchain after script 34"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/35_send_on_base.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "backend/scripts" "backend/src" "backend/src/db" "backend/src/send" "frontend/src/app/send" "frontend/src/components"
cat > "backend/scripts/live-report.ts" <<'DOC_EOF'
// Read only: the latest bridge transfers and swaps on the database you point it
// at (the live one in setup/29), to check the live mainnet tests. Changes nothing.
// Run with: TURSO_DATABASE_URL=... TURSO_AUTH_TOKEN=... npx tsx scripts/live-report.ts
import { desc } from "drizzle-orm";
import { db } from "../src/db";
import { bridgeTransfers, sends, swaps } from "../src/db/schema";
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
  console.log(`Paused for users: bridge ${p.bridgePaused ? "yes" : "no"}, swaps ${p.swapPaused ? "yes" : "no"}, sends ${p.sendPaused ? "yes" : "no"}, buying ${p.purchasesPaused ? "yes" : "no"}`);

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

  const sd = await db.select().from(sends).orderBy(desc(sends.createdAt)).limit(10);
  console.log(`\nLatest sends to other wallets (${sd.length}):`);
  for (const s of sd) {
    console.log(`  ${when(s.createdAt)}  ${s.status.padEnd(13)} ${s.amount} ${s.token} on ${s.chain} -> ${s.toAddress}${s.txHash ? `  ${chainByKey(s.chain).explorerTx}${s.txHash}` : ""}`);
    if (s.error) console.log(`      ${s.error.slice(0, 300)}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF
cat > "backend/scripts/send-smoke.ts" <<'DOC_EOF'
// Sends to other wallets, on testnet and the development database:
//   - wrong addresses, amounts and a missing network check are refused
//   - a real 0.2 USDC send to the treasury, confirmed with the emailed code
//     (a wrong code first), arrives with a transaction hash
//   - a new send replaces one still waiting for its code
//   - the admin can still send while sending is paused (nobody else can)
// Exit code 3 means the testnet treasury needs more test USDC.
// Run with: EMAIL_OUTBOX_FILE=/tmp/x PAUSE_BYPASS_EMAILS=tester@example.com npx tsx scripts/send-smoke.ts
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { appSettings, auditLogs, ledgerEntries, sends, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { SendError, advanceSends, confirmSend, getSendView, sendInfo, startSend } from "../src/send/service";
import { getPauses, pausedMessage, setPause } from "../src/settings";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND = "0.5";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function refused(label: string, fn: () => Promise<unknown>) {
  try {
    await fn();
    check(false, label);
  } catch (err) {
    check(err instanceof SendError, label, err instanceof Error ? err.message : err);
  }
}

// The code in the last email to this address (the outbox file the test server writes)
function lastCode(email: string): string {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox) throw new Error("Set EMAIL_OUTBOX_FILE");
  const mails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; text: string });
  const mine = mails.filter((m) => m.to === email);
  const code = /\n(\d{6})\n/.exec(mine[mine.length - 1]?.text ?? "")?.[1];
  if (!code) throw new Error("No code email found");
  return code;
}

async function usdcOf(walletId: string): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return b ? Number(b.amount) : 0;
}

async function main() {
  const treasury = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (treasury.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!t?.token?.id || Number(t.amount) < Number(FUND) + 0.1) {
    console.log(`NEEDS_FUNDING: treasury has ${t?.amount ?? 0} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  const email = `sendsmoke+${Date.now()}@example.com`;
  const user = { id: userId, email, name: "Send Smoke" };
  await db.insert(users).values({ id: userId, name: user.name, email, emailVerified: true, phone: "+2348011111111" });
  try {
    const wallet = await ensureUserWallet(userId);
    console.log(`Funding the test wallet with ${FUND} USDC from the treasury...`);
    const fund = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: t.token.id,
      destinationAddress: wallet.address,
      amount: [FUND],
      amounts: [FUND],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`send-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: fund.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    for (let i = 0; i < 20 && (await usdcOf(wallet.circleWalletId)) < Number(FUND); i++) await sleep(3_000);
    const before = await usdcOf(wallet.circleWalletId);
    check(before >= Number(FUND), `test wallet funded (${before} USDC)`);

    const ok = { token: "USDC", amount: "0.2", toAddress: env.TREASURY_ADDRESS, confirmNetwork: true };
    await refused("a bad address is refused", () => startSend(user, { ...ok, toAddress: "0x1234" }));
    await refused("their own wallet is refused", () => startSend(user, { ...ok, toAddress: wallet.address }));
    await refused("the USDC token contract is refused", () => startSend(user, { ...ok, toAddress: "0x3600000000000000000000000000000000000000" }));
    await refused("the network must be confirmed", () => startSend(user, { ...ok, confirmNetwork: false }));
    await refused("more than the per send limit is refused", () => startSend(user, { ...ok, amount: String(env.SEND_MAX_STABLE + 1) }));
    await refused("more than the balance is refused", () => startSend(user, { ...ok, amount: "5" }));

    // A new send replaces one still waiting for its code
    const first = await startSend(user, ok);
    const second = await startSend(user, ok);
    const [old] = await db.select().from(sends).where(eq(sends.id, first!.id));
    check(old?.status === "CANCELLED" && second?.status === "AWAITING_CODE", "a new send replaces the one waiting for its code");
    check(second?.codeSentTo?.includes("***") === true, "the page shows where the code went (hidden)", second?.codeSentTo);

    // Many wrong codes sent at the same moment still count: the send is cancelled
    const secondCode = lastCode(email);
    const badCode = secondCode === "000000" ? "111111" : "000000";
    await Promise.allSettled(Array.from({ length: 8 }, () => confirmSend(userId, second!.id, badCode)));
    const [raced] = await db.select().from(sends).where(eq(sends.id, second!.id));
    check(raced?.status === "CANCELLED", "8 wrong codes at once cancel the send (the limit is 5)", raced?.status);
    await refused("the right code no longer works after that", () => confirmSend(userId, second!.id, secondCode));

    const third = await startSend(user, ok);
    const code = lastCode(email);
    const wrong = code === "000000" ? "111111" : "000000";
    try {
      await confirmSend(userId, third!.id, wrong);
      check(false, "a wrong code is refused");
    } catch (err) {
      check(err instanceof SendError && err.status === 401 && /tries left/.test(err.message), "a wrong code is refused");
    }
    let view = await confirmSend(userId, third!.id, code);
    for (let i = 0; i < 30 && view && ["SENDING", "SENT"].includes(view.status); i++) {
      await sleep(3_000);
      await advanceSends();
      view = await getSendView(userId, third!.id);
    }
    check(view?.status === "COMPLETE" && Boolean(view.explorerUrl), `0.2 USDC sent (${view?.explorerUrl})`, view);
    await refused("the same code cannot be used twice", () => confirmSend(userId, third!.id, code));

    let after = await usdcOf(wallet.circleWalletId);
    for (let i = 0; i < 20 && after > before - 0.2; i++) {
      await sleep(3_000);
      after = await usdcOf(wallet.circleWalletId);
    }
    check(Math.abs(before - 0.2 - after) < 0.000001, `the wallet went down by exactly 0.2 USDC (${before} -> ${after})`);

    // Base: USDC only, from their own Base wallet, never to their own wallets
    if (env.BRIDGE_ENABLED) {
      const baseInfo = await sendInfo(userId, "base");
      check(baseInfo.chain === "base" && baseInfo.tokens.join(",") === "USDC", "on Base only USDC can be sent", baseInfo.tokens);
      await refused("EURC on Base is refused", () => startSend(user, { ...ok, chain: "base", token: "EURC" }));
      await refused("their own Arc wallet is refused as a Base address", () => startSend(user, { ...ok, chain: "base", toAddress: wallet.address }));
      await refused("more than their Base balance is refused", () => startSend(user, { ...ok, chain: "base", amount: "0.2" }));
      await refused("an unknown network is refused", () => startSend(user, { ...ok, chain: "polygon" }));
    }

    // Paused: only the admin (PAUSE_BYPASS_EMAILS) can still send
    if (env.PAUSE_BYPASS_EMAILS.includes("tester@example.com")) {
      const was = (await getPauses()).sendPaused;
      try {
        await setPause("sendPaused", true);
        check((await pausedMessage("sendPaused", "tester@example.com")) === null, "the admin can send while sending is paused");
        check((await pausedMessage("sendPaused", email)) !== null, "everyone else sees the paused message");
      } finally {
        await setPause("sendPaused", was);
        if (!was) await db.delete(appSettings).where(eq(appSettings.key, "sendPaused"));
      }
    }
  } finally {
    const ids = (await db.select({ id: sends.id }).from(sends).where(eq(sends.userId, userId))).map((r) => r.id);
    if (ids.length) await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
    await db.delete(sends).where(eq(sends.userId, userId));
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user (its leftover test USDC stays in a test wallet)");
  }
}

main()
  .then(() => {
    console.log("All send checks passed.");
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, deposits: true, baseSend: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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
  try {
    return c.json({ ...(await sendInfo(user.id, c.req.query("chain"))), paused: await pausedMessage("sendPaused", user.email) });
  } catch (err) {
    return sendErrors(err, c);
  }
});

app.post("/api/send", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) return c.json({ error: "Please confirm your email first" }, 403);
  const paused = await pausedMessage("sendPaused", user.email);
  if (paused) return c.json({ error: paused }, 503);
  const body = (await c.req.json().catch(() => ({}))) as { token?: unknown; amount?: unknown; toAddress?: unknown; confirmNetwork?: unknown; chain?: unknown };
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
    // Which network the send is on: arc (any token), or base (USDC from their Base wallet)
    chain: text("chain").notNull().default("arc"),
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
cat > "backend/src/send/service.ts" <<'DOC_EOF'
// Sending USDC, EURC or cirBTC from a user's Arc wallet to another wallet on Arc,
// or USDC from their own Base wallet to another wallet on Base (for example an
// exchange deposit address).
//
// Send: AWAITING_CODE -> SENDING -> SENT -> COMPLETE
//         |                 |         +--> FAILED (Circle refused it: nothing left the wallet)
//         +--> CANCELLED (code expired, 5 wrong codes, or a new send was started)
//
// Safety:
//   - the user confirms every send with a 6 digit code emailed to them, so a
//     stolen password alone cannot empty a wallet (codes are stored as hashes,
//     expire after 10 minutes, and 5 wrong codes cancel the send)
//   - one open send per user (unique open_key), so a double click cannot send twice
//   - the Circle transfer's idempotency key comes from the send id: a retry after
//     a crash returns the same transfer and can never send twice
//   - limits per send, per token per 24 hours, and sends per day
//   - on one network at a time (Arc, or Base for USDC): never to the user's own
//     wallets, the zero address or a token contract (a common mistake that
//     loses the funds)
//   - an email receipt after every completed send
import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { and, desc, eq, gte, inArray, lt, notInArray, sql } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, ledgerEntries, sends, users, wallets } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { ensureUserWallet, uuidFrom } from "../wallets/service";
import { chainByKey, isOpenChain } from "../bridge/chains";
import { ensureChainWallet } from "../bridge/wallets";

export type SendToken = (typeof SWAP_TOKENS)[number];
export type SendChain = "arc" | "base";
type Send = typeof sends.$inferSelect;

export class SendError extends Error {
  constructor(message: string, public status: 400 | 401 | 402 | 404 | 409 | 429 | 502 | 503 = 400) {
    super(message);
  }
}

const CODE_MINUTES = 10;
const MAX_CODE_ATTEMPTS = 5;
const MAX_STARTS_PER_HOUR = 5;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

// Token contracts (testnet and mainnet use the same USDC address on Arc)
const TOKEN_CONTRACTS = [
  "0x3600000000000000000000000000000000000000", // USDC on Arc
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1", // EURC on Arc mainnet
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0", // cirBTC on Arc mainnet
  "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", // USDC on Base
  "0x036cbd53842c5426634e7929541ec2318f3dcf7e", // USDC on Base Sepolia
];

export const SEND_TOKENS: Record<SendToken, { decimals: number; min: number; max: number; daily: number }> = {
  USDC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  EURC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  cirBTC: { decimals: 8, min: 0.00001, max: env.SEND_MAX_CIRBTC, daily: env.SEND_DAILY_CIRBTC },
};

// The network's name as users know it: Arc, Arc Testnet, Base, Base Sepolia
const network = (chain: string = "arc") => chainByKey(chain).label;

// Arc always; Base only while the bridge is on and Base is open (its Gas Station policy)
function parseChain(value: unknown): SendChain {
  if (value === undefined || value === null || value === "" || value === "arc") return "arc";
  if (value !== "base") throw new SendError("Choose Arc or Base.");
  if (!env.BRIDGE_ENABLED || !isOpenChain("base")) throw new SendError("Sending on Base is not available right now.", 503);
  return "base";
}

// The user's wallet on that network (the Base one is created the first time)
const walletFor = (userId: string, chain: SendChain | string) => (chain === "base" ? ensureChainWallet(userId, "base") : ensureUserWallet(userId));
const isToken = (v: unknown): v is SendToken => typeof v === "string" && (SWAP_TOKENS as readonly string[]).includes(v);
const codeHash = (sendId: string, code: string) => createHmac("sha256", env.BETTER_AUTH_SECRET).update(`send-code:${sendId}:${code}`).digest("hex");
const short = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });
const isTestAccount = (email: string) => /@(example\.com|[^@]*\.local)$/i.test(email);

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

// Token units as an integer (6 or 8 decimals), so sums are exact
function units(token: SendToken, amount: string): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0n;
  const d = SEND_TOKENS[token].decimals;
  return BigInt(m[1]!) * 10n ** BigInt(d) + BigInt((m[2] ?? "").padEnd(d, "0").slice(0, d) || "0");
}
const unitsOf = (token: SendToken, n: number) => units(token, n.toFixed(SEND_TOKENS[token].decimals));
function text(token: SendToken, u: bigint): string {
  const d = BigInt(SEND_TOKENS[token].decimals);
  const whole = u / 10n ** d;
  const frac = (u % 10n ** d).toString().padStart(Number(d), "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : String(whole);
}

function parseAmount(token: SendToken, amount: unknown): string {
  const raw = String(amount ?? "").trim();
  const d = SEND_TOKENS[token].decimals;
  if (!new RegExp(`^\\d+(\\.\\d{1,${d}})?$`).test(raw)) throw new SendError(`Enter an amount of ${token}, with at most ${d} decimals.`);
  const u = units(token, raw);
  if (u < unitsOf(token, SEND_TOKENS[token].min)) throw new SendError(`The minimum is ${SEND_TOKENS[token].min} ${token}.`);
  if (u > unitsOf(token, SEND_TOKENS[token].max)) throw new SendError(`The maximum per send is ${SEND_TOKENS[token].max} ${token}.`);
  return text(token, u);
}

function parseAddress(value: unknown, own: string[]): string {
  const a = String(value ?? "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new SendError("Enter a wallet address: 0x followed by 40 letters and numbers.");
  const lower = a.toLowerCase();
  if (/^0x0{40}$/.test(lower)) throw new SendError("That address cannot receive funds.");
  if (own.some((a) => a.toLowerCase() === lower)) throw new SendError("That is your own dataonchain wallet. Choose another address.");
  if (TOKEN_CONTRACTS.includes(lower)) throw new SendError("That is a token contract, not a wallet. Funds sent there are lost. Check the address.");
  return lower;
}

// The user's Arc balance of one token, with Circle's token id (needed to send it)
async function holding(circleWalletId: string, token: SendToken): Promise<{ tokenId: string | null; units: bigint; amount: string }> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => (t.token?.symbol ?? "").toUpperCase().startsWith(token.toUpperCase()));
  const amount = b?.amount ?? "0";
  return { tokenId: b?.token?.id ?? null, units: units(token, amount), amount };
}

async function audit(action: string, s: Pick<Send, "id" | "userId">, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "user", actorId: s.userId, action, targetType: "send", targetId: s.id, details });
}

// Sent and in progress amounts in the last 24 hours, per token
async function usedToday(userId: string) {
  const rows = await db
    .select({ token: sends.token, amount: sends.amount })
    .from(sends)
    .where(and(eq(sends.userId, userId), gte(sends.createdAt, new Date(Date.now() - 24 * 60 * 60_000)), inArray(sends.status, ["SENDING", "SENT", "COMPLETE"])));
  const used: Record<SendToken, bigint> = { USDC: 0n, EURC: 0n, cirBTC: 0n };
  for (const r of rows) used[r.token] += units(r.token, r.amount);
  return { count: rows.length, used };
}

// Closes codes nobody entered in time (and every waiting code when asked)
async function cancelWaiting(userId: string, all: boolean) {
  await db
    .update(sends)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: all ? "replaced by a new send" : "code expired" })
    .where(and(
      eq(sends.userId, userId),
      eq(sends.status, "AWAITING_CODE"),
      ...(all ? [] : [lt(sends.codeExpiresAt, new Date())]),
    ));
}

// ---------------------------------------------------------------------------
// For the Send page
// ---------------------------------------------------------------------------
export async function sendInfo(userId: string, chainInput?: unknown) {
  const chain = parseChain(chainInput);
  const wallet = await walletFor(userId, chain);
  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const list = res.data?.tokenBalances ?? [];
  const find = (sym: string) => list.find((b) => (b.token?.symbol ?? "").toUpperCase().startsWith(sym.toUpperCase()))?.amount ?? "0";
  const { count, used } = await usedToday(userId);
  return {
    chain,
    network: network(chain),
    baseOpen: env.BRIDGE_ENABLED && isOpenChain("base"),
    tokens: chain === "base" ? (["USDC"] as SendToken[]) : ([...SWAP_TOKENS] as SendToken[]),
    balances: (chain === "base"
      ? { USDC: find("USDC"), EURC: "0", cirBTC: "0" }
      : { USDC: find("USDC"), EURC: find("EURC"), cirBTC: find("CIRBTC") }) as Record<SendToken, string>,
    limits: SEND_TOKENS,
    usedToday: { USDC: text("USDC", used.USDC), EURC: text("EURC", used.EURC), cirBTC: text("cirBTC", used.cirBTC) },
    sendsLeftToday: Math.max(0, env.SEND_DAILY_COUNT - count),
  };
}

// Step 1: checks everything, saves the send and emails the code
export async function startSend(
  user: { id: string; email: string; name: string },
  body: { token?: unknown; amount?: unknown; toAddress?: unknown; confirmNetwork?: unknown; chain?: unknown },
) {
  const chain = parseChain(body.chain);
  if (!isToken(body.token)) throw new SendError("Choose USDC, EURC or cirBTC.");
  const token = body.token;
  if (chain === "base" && token !== "USDC") throw new SendError("Only USDC can be sent on Base.");
  const amount = parseAmount(token, body.amount);
  const wallet = await walletFor(user.id, chain);
  const own = (await db.select({ address: wallets.address }).from(wallets).where(eq(wallets.userId, user.id))).map((w) => w.address);
  const toAddress = parseAddress(body.toAddress, [wallet.address, ...own]);
  if (body.confirmNetwork !== true) throw new SendError(`Confirm that the address is a wallet on ${network(chain)}.`);

  const [open] = await db.select({ id: sends.id }).from(sends).where(and(eq(sends.userId, user.id), inArray(sends.status, ["SENDING", "SENT"]))).limit(1);
  if (open) throw new SendError("You already have a send in progress. Please wait for it to finish.", 409);

  const recent = await db.select({ id: sends.id }).from(sends).where(and(eq(sends.userId, user.id), gte(sends.createdAt, new Date(Date.now() - 60 * 60_000))));
  if (recent.length >= MAX_STARTS_PER_HOUR) throw new SendError("Too many attempts. Please wait an hour and try again.", 429);

  const { count, used } = await usedToday(user.id);
  if (count >= env.SEND_DAILY_COUNT) throw new SendError(`The limit is ${env.SEND_DAILY_COUNT} sends per day.`, 409);
  const want = units(token, amount);
  const daily = unitsOf(token, SEND_TOKENS[token].daily);
  if (used[token] + want > daily) {
    throw new SendError(`The daily limit is ${SEND_TOKENS[token].daily} ${token}. You can send ${text(token, daily > used[token] ? daily - used[token] : 0n)} more today.`, 409);
  }

  const have = await holding(wallet.circleWalletId, token);
  if (have.units < want) throw new SendError(`Not enough ${token}. You have ${have.amount} ${token}.`, 402);

  await cancelWaiting(user.id, true);
  const id = randomUUID();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  try {
    await db.insert(sends).values({
      id,
      userId: user.id,
      walletAddress: wallet.address.toLowerCase(),
      chain,
      token,
      amount,
      toAddress,
      status: "AWAITING_CODE",
      codeHash: codeHash(id, code),
      codeExpiresAt: new Date(Date.now() + CODE_MINUTES * 60_000),
      openKey: user.id,
    });
  } catch {
    throw new SendError("You already have a send in progress. Please wait for it to finish.", 409);
  }

  try {
    const message = noticeEmail({
      brand: "dataonchain",
      subject: `Your code to send ${amount} ${token}`,
      lines: [
        `Hello ${user.name.split(" ")[0]},`,
        `You asked to send ${amount} ${token} from your dataonchain wallet to ${toAddress} on ${network(chain)}.`,
        "Enter this code on the Send page to confirm:",
      ],
      code,
      footer: `The code expires in ${CODE_MINUTES} minutes. Never share it with anyone, including people who say they work for dataonchain. If you did not ask for this, do not enter the code, change your password now and contact us on WhatsApp.`,
    });
    await sendEmail({ to: user.email, ...message });
  } catch (err) {
    console.error("[send] could not email the code:", err instanceof Error ? err.message : err);
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code email failed" }).where(eq(sends.id, id));
    throw new SendError("Could not email your code. Please try again in a moment.", 502);
  }
  await audit("send.started", { id, userId: user.id }, { chain, token, amount, toAddress });
  return getSendView(user.id, id);
}

// Step 2: the code. Sends through Circle, then waits a few seconds for the result.
export async function confirmSend(userId: string, id: string, codeInput: unknown) {
  const [s] = await db.select().from(sends).where(and(eq(sends.id, id), eq(sends.userId, userId))).limit(1);
  if (!s) throw new SendError("Send not found.", 404);
  if (s.status !== "AWAITING_CODE" || !s.codeHash) throw new SendError("This send is no longer waiting for a code. Start a new one.", 409);
  if (!s.codeExpiresAt || s.codeExpiresAt.getTime() < Date.now()) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
    throw new SendError("The code expired. Nothing was sent. Please start again.", 409);
  }
  // Every try is counted in the database first, in one step, so many tries sent
  // at the same moment cannot get past the limit of 5
  const [tried] = await db
    .update(sends)
    .set({ codeAttempts: sql`${sends.codeAttempts} + 1` })
    .where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE"), lt(sends.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning();
  if (!tried) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "too many wrong codes" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
    throw new SendError("Too many wrong codes. Nothing was sent. Please start again.", 401);
  }
  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(s.id, code), s.codeHash)) {
    if (tried.codeAttempts >= MAX_CODE_ATTEMPTS) {
      await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "too many wrong codes" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
      await audit("send.code_failed", s, { attempts: tried.codeAttempts });
      throw new SendError("Too many wrong codes. Nothing was sent. Please start again.", 401);
    }
    throw new SendError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.codeAttempts} tries left.`, 401);
  }

  // The balance may have changed since the code was sent
  const wallet = await walletFor(userId, s.chain);
  const have = await holding(wallet.circleWalletId, s.token);
  if (!have.tokenId || have.units < units(s.token, s.amount)) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "not enough balance at confirmation" }).where(eq(sends.id, s.id));
    throw new SendError(`Not enough ${s.token} any more. You have ${have.amount} ${s.token}. Nothing was sent.`, 402);
  }
  const [claimed] = await db
    .update(sends)
    .set({ status: "SENDING", codeHash: null })
    .where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")))
    .returning();
  if (!claimed) throw new SendError("This send is already being processed.", 409);
  await audit("send.confirmed", s, { token: s.token, amount: s.amount, toAddress: s.toAddress });

  await submit(claimed, wallet.circleWalletId, have.tokenId);
  // Arc is fast: most sends finish within a few seconds
  for (let i = 0; i < 6; i++) {
    const [now] = await db.select().from(sends).where(eq(sends.id, s.id)).limit(1);
    if (!now || now.status !== "SENT") break;
    await new Promise((r) => setTimeout(r, 2_000));
    await checkSent(now);
  }
  return getSendView(userId, s.id);
}

// Asks Circle to send. The same idempotency key every time, so it can only happen once.
async function submit(s: Send, circleWalletId: string, tokenId: string) {
  const input = {
    walletId: circleWalletId,
    tokenId,
    destinationAddress: s.toAddress,
    amount: [s.amount],
    amounts: [s.amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`send:${s.id}`),
    refId: `send-${s.id}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const txId = res.data?.id;
    if (!txId) throw new Error("Circle did not return a transaction id");
    await db.update(sends).set({ status: "SENT", circleTransactionId: txId }).where(and(eq(sends.id, s.id), eq(sends.status, "SENDING")));
  } catch (err) {
    const status = (err as { response?: { status?: number } }).response?.status;
    const detail = JSON.stringify((err as { response?: { data?: unknown } }).response?.data ?? "").slice(0, 300);
    const message = `${err instanceof Error ? err.message : String(err)} ${detail}`.trim().slice(0, 500);
    if (status && status >= 400 && status < 500) {
      // Circle refused it: nothing was sent
      await db.update(sends).set({ status: "FAILED", openKey: null, error: message }).where(and(eq(sends.id, s.id), eq(sends.status, "SENDING")));
      await audit("send.failed", s, { error: message });
      console.error(`[send] ${s.id} refused by Circle: ${message}`);
      return;
    }
    // Unclear (network): stays SENDING, the worker asks again with the same key
    console.error(`[send] ${s.id} will retry: ${message}`);
  }
}

async function checkSent(s: Send) {
  if (!s.circleTransactionId) return;
  const res = await circle.getTransaction({ id: s.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string; errorDetails?: string } | undefined;
  if (tx?.state === "COMPLETE") {
    const [done] = await db
      .update(sends)
      .set({ status: "COMPLETE", txHash: tx.txHash ?? null, openKey: null })
      .where(and(eq(sends.id, s.id), eq(sends.status, "SENT")))
      .returning();
    if (done) await finished(done);
  } else if (tx?.state && FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}${tx.errorDetails ? ` (${tx.errorDetails})` : ""}`.slice(0, 500);
    const [failed] = await db
      .update(sends)
      .set({ status: "FAILED", openKey: null, error: reason, txHash: tx.txHash ?? null })
      .where(and(eq(sends.id, s.id), eq(sends.status, "SENT")))
      .returning();
    if (failed) {
      await audit("send.failed", s, { error: reason });
      console.error(`[send] ${s.id} FAILED: ${reason}`);
    }
  }
}

async function finished(s: Send) {
  if (s.token === "USDC") {
    const micro = Number(units("USDC", s.amount));
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      { journalId, account: `customer:${s.userId}`, currency: "USDC", debit: micro, memo: `Send ${s.id} to ${s.toAddress}` },
      { journalId, account: "external:send", currency: "USDC", credit: micro, memo: `Send ${s.id} tx ${s.txHash ?? ""}` },
    ]);
  }
  await audit("send.complete", s, { token: s.token, amount: s.amount, toAddress: s.toAddress, txHash: s.txHash });
  // A receipt, so the owner notices any send they did not make
  try {
    const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, s.userId)).limit(1);
    if (!user || isTestAccount(user.email)) return;
    const message = noticeEmail({
      brand: "dataonchain",
      subject: `You sent ${s.amount} ${s.token}`,
      lines: [
        `Hello ${user.name.split(" ")[0]},`,
        `${s.amount} ${s.token} left your dataonchain wallet on ${lagos(new Date())}.`,
        `To: ${s.toAddress} (${network(s.chain)})`,
      ],
      button: s.txHash ? { label: "View the transaction", url: `${chainByKey(s.chain).explorerTx}${s.txHash}` } : undefined,
      footer: "If this was not you, change your password now and contact us on WhatsApp.",
    });
    await sendEmail({ to: user.email, ...message });
  } catch (err) {
    console.error(`[send] ${s.id} receipt email failed:`, err instanceof Error ? err.message : err);
  }
}

// For the worker: expired codes, sends waiting for Circle, and retries
export async function advanceSends(): Promise<void> {
  await db
    .update(sends)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" })
    .where(and(eq(sends.status, "AWAITING_CODE"), lt(sends.codeExpiresAt, new Date())));

  const open = await db.select().from(sends).where(inArray(sends.status, ["SENDING", "SENT"])).limit(20);
  for (const s of open) {
    try {
      if (s.status === "SENT") {
        await checkSent(s);
      } else if (Date.now() - s.updatedAt.getTime() > 60_000) {
        const wallet = await walletFor(s.userId, s.chain);
        const have = await holding(wallet.circleWalletId, s.token);
        if (have.tokenId) await submit(s, wallet.circleWalletId, have.tokenId);
      }
    } catch (err) {
      console.error(`[send] ${s.id}:`, err instanceof Error ? err.message : err);
    }
  }
}

// For the daily report
export async function sendSummary(since: Date) {
  const rows = await db.select().from(sends).where(and(gte(sends.createdAt, since), notInArray(sends.status, ["AWAITING_CODE", "CANCELLED"])));
  const stuck = await db.select().from(sends).where(and(inArray(sends.status, ["SENDING", "SENT"]), lt(sends.updatedAt, new Date(Date.now() - 30 * 60_000))));
  return {
    complete: rows.filter((r) => r.status === "COMPLETE").length,
    failed: rows.filter((r) => r.status === "FAILED").length,
    stuck: stuck.map((s) => `${s.id} ${s.amount} ${s.token} to ${s.toAddress} (${s.status})`),
  };
}

export async function getSendView(userId: string, id: string) {
  const [s] = await db.select().from(sends).where(and(eq(sends.id, id), eq(sends.userId, userId))).limit(1);
  if (!s) return null;
  const [user] = await db.select({ email: users.email }).from(users).where(eq(users.id, userId)).limit(1);
  const masked = user ? user.email.replace(/^(.{2}).*(@.*)$/, "$1***$2") : "your email";
  return {
    id: s.id,
    status: s.status,
    token: s.token,
    amount: s.amount,
    toAddress: s.toAddress,
    toShort: short(s.toAddress),
    chain: s.chain,
    network: network(s.chain),
    codeSentTo: s.status === "AWAITING_CODE" ? masked : null,
    codeExpiresAt: s.status === "AWAITING_CODE" ? (s.codeExpiresAt?.toISOString() ?? null) : null,
    // A short, safe reason for the user (the full one is kept for the admin)
    failure:
      s.status === "FAILED"
        ? /PAYMASTER_POLICY|policy/i.test(s.error ?? "")
          ? "Sending is busy right now. Nothing was sent. Please try again later."
          : "The send did not go through. Nothing was sent. Please try again, or contact us on WhatsApp."
        : null,
    txHash: s.txHash,
    explorerUrl: s.txHash ? `${chainByKey(s.chain).explorerTx}${s.txHash}` : null,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSends(userId: string) {
  await cancelWaiting(userId, false);
  const rows = await db
    .select({ id: sends.id })
    .from(sends)
    .where(and(eq(sends.userId, userId), notInArray(sends.status, ["AWAITING_CODE", "CANCELLED"])))
    .orderBy(desc(sends.createdAt))
    .limit(20);
  return (await Promise.all(rows.map((r) => getSendView(userId, r.id)))).filter(Boolean);
}
DOC_EOF
cat > "frontend/src/app/send/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Chain = "arc" | "base";
type Info = {
  chain?: Chain;
  network: string;
  baseOpen?: boolean;
  tokens?: Token[];
  balances: Record<Token, string>;
  limits: Record<Token, { decimals: number; min: number; max: number; daily: number }>;
  usedToday: Record<Token, string>;
  sendsLeftToday: number;
  paused: string | null;
};
type SendView = {
  id: string;
  status: string;
  token: Token;
  amount: string;
  toAddress: string;
  toShort: string;
  network: string;
  codeSentTo: string | null;
  codeExpiresAt: string | null;
  failure: string | null;
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

const STATUS_TEXT: Record<string, string> = {
  SENDING: "Sending",
  SENT: "Sending",
  COMPLETE: "Sent",
  FAILED: "Not sent",
};

export default function SendPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [info, setInfo] = useState<Info | null>(null);
  const [chain, setChain] = useState<Chain>("arc");
  const [baseOpen, setBaseOpen] = useState(false);
  const [token, setToken] = useState<Token>("USDC");
  const [amount, setAmount] = useState("");
  const [toAddress, setToAddress] = useState("");
  const [confirmNetwork, setConfirmNetwork] = useState(false);
  const [pending, setPending] = useState<SendView | null>(null);
  const [code, setCode] = useState("");
  const [result, setResult] = useState<SendView | null>(null);
  const [recent, setRecent] = useState<SendView[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      const i = await api<Info>(`/send/info?chain=${chain}`);
      setInfo(i);
      if (i.baseOpen !== undefined) setBaseOpen(i.baseOpen);
      const r = await api<{ sends: SendView[] }>("/sends");
      setRecent(r.sends);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, [chain]);

  useEffect(() => {
    if (session) void load();
  }, [session, load]);

  // A send still on its way: check again every few seconds
  useEffect(() => {
    if (!result || !["SENDING", "SENT"].includes(result.status)) return;
    const timer = setTimeout(async () => {
      try {
        const r = await api<{ send: SendView }>(`/sends/${result.id}`);
        setResult(r.send);
        if (!["SENDING", "SENT"].includes(r.send.status)) void load();
      } catch {
        // tried again on the next tick
      }
    }, 4_000);
    return () => clearTimeout(timer);
  }, [result, load]);

  async function start(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      const r = await api<{ send: SendView }>("/send", {
        method: "POST",
        body: JSON.stringify({ chain, token, amount, toAddress: toAddress.trim(), confirmNetwork }),
      });
      setPending(r.send);
      setCode("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the send.");
    } finally {
      setBusy(false);
    }
  }

  async function confirm(e: FormEvent) {
    e.preventDefault();
    if (!pending) return;
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ send: SendView }>(`/send/${pending.id}/confirm`, { method: "POST", body: JSON.stringify({ code }) });
      setResult(r.send);
      setPending(null);
      setAmount("");
      setToAddress("");
      setConfirmNetwork(false);
      await load();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Could not confirm.";
      setError(message);
      // A cancelled send (expired or too many wrong codes) needs a fresh start
      if (/start again|start a new one|Nothing was sent/i.test(message)) setPending(null);
    } finally {
      setBusy(false);
    }
  }

  const limit = info?.limits[token];
  const network = info?.network ?? (chain === "base" ? "Base" : "Arc");
  const tokens: Token[] = info?.tokens ?? (chain === "base" ? ["USDC"] : TOKEN_LIST);

  function pickChain(next: Chain) {
    if (next === chain) return;
    setChain(next);
    setInfo(null);
    setToken("USDC");
    setAmount("");
    setConfirmNetwork(false);
    setError(null);
    setResult(null);
  }

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Send to another wallet</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          {chain === "base"
            ? "Send USDC from your own Base wallet to any wallet or exchange address on Base. "
            : `Send USDC, EURC or cirBTC from your wallet to any wallet on ${network}. `}
          No gas to pay. You confirm every send with a code we email you.
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have on {network}: {tokens.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(", ")}
          </p>
        ) : null}

        {info?.paused ? (
          <p className="mt-4 rounded-lg bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">{info.paused}</p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {!pending ? (
            <form onSubmit={start} className="space-y-5">
              {baseOpen ? (
                <div>
                  <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Network</p>
                  <div className="mt-2 flex gap-2">
                    <button type="button" onClick={() => pickChain("arc")} className={choiceClass(chain === "arc")}>
                      Arc
                    </button>
                    <button type="button" onClick={() => pickChain("base")} className={choiceClass(chain === "base")}>
                      Base
                    </button>
                  </div>
                  {chain === "base" ? (
                    <p className="mt-2 text-xs text-zinc-500">
                      Sends from your Base wallet. To send from your Arc balance, first use To Base on the dashboard.
                    </p>
                  ) : null}
                </div>
              ) : null}
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Token</p>
                <div className="mt-2 flex gap-2">
                  {tokens.map((t) => (
                    <button
                      type="button"
                      key={t}
                      onClick={() => {
                        setToken(t);
                        setAmount("");
                      }}
                      className={choiceClass(token === t)}
                    >
                      {t}
                    </button>
                  ))}
                </div>
              </div>

              <div>
                <div className="flex items-center justify-between">
                  <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                    Amount of {token}
                  </label>
                  {info ? (
                    <button
                      type="button"
                      onClick={() => setAmount(info.balances[token])}
                      className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                    >
                      Use all ({fmt(info.balances[token], token)})
                    </button>
                  ) : null}
                </div>
                <input
                  id="amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder={limit ? `${limit.min} to ${limit.max}` : ""}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                {limit && info ? (
                  <p className="mt-1 text-xs text-zinc-500">
                    Up to {limit.max} {token} per send and {limit.daily} {token} per day ({fmt(info.usedToday[token], token)} used
                    today). {info.sendsLeftToday} send{info.sendsLeftToday === 1 ? "" : "s"} left today.
                  </p>
                ) : null}
              </div>

              <div>
                <label htmlFor="to" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Wallet address on {network}
                </label>
                <input
                  id="to"
                  value={toAddress}
                  onChange={(e) => setToAddress(e.target.value)}
                  placeholder="0x..."
                  autoComplete="off"
                  spellCheck={false}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 font-mono text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
              </div>

              <label className="flex items-start gap-2 rounded-lg bg-amber-50 px-3 py-2.5 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <input type="checkbox" checked={confirmNetwork} onChange={(e) => setConfirmNetwork(e.target.checked)} className="mt-0.5" />
                <span>
                  This address can receive {token} on <strong>{network}</strong>. I understand that sends cannot be reversed,
                  and funds sent to a wrong address or to an exchange that does not support {network} are lost.
                </span>
              </label>

              <button
                type="submit"
                disabled={busy || !amount || !toAddress || !confirmNetwork || Boolean(info?.paused)}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Checking..." : "Continue"}
              </button>
            </form>
          ) : (
            <form onSubmit={confirm} className="space-y-5">
              <dl className="grid grid-cols-[7rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">You send</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">
                  {fmt(pending.amount, pending.token)} {pending.token}
                </dd>
                <dt className="text-zinc-500">To</dt>
                <dd className="break-all font-mono text-xs text-zinc-900 dark:text-zinc-100">{pending.toAddress}</dd>
                <dt className="text-zinc-500">Network</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{pending.network}</dd>
                <dt className="text-zinc-500">Fee</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">None. We pay the gas.</dd>
              </dl>
              <div>
                <label htmlFor="code" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Code from your email
                </label>
                <input
                  id="code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  maxLength={7}
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  placeholder="6 digits"
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-lg tracking-widest text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                <p className="mt-1 text-xs text-zinc-500">
                  We sent it to {pending.codeSentTo}. It expires in 10 minutes. Check the address above once more before you confirm.
                </p>
              </div>
              <div className="flex gap-3">
                <button
                  type="submit"
                  disabled={busy || code.replace(/\s/g, "").length !== 6}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Sending..." : `Confirm and send ${fmt(pending.amount, pending.token)} ${pending.token}`}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setPending(null);
                    setError(null);
                  }}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Cancel
                </button>
              </div>
            </form>
          )}

          {result ? (
            <div
              className={`rounded-lg px-3 py-2 text-sm ${
                result.status === "COMPLETE"
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : result.status === "FAILED"
                    ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
                    : "bg-sky-50 text-sky-900 dark:bg-sky-950 dark:text-sky-200"
              }`}
            >
              {result.status === "COMPLETE"
                ? `Sent. ${fmt(result.amount, result.token)} ${result.token} went to ${result.toShort}.`
                : result.status === "FAILED"
                  ? result.failure
                  : `Sending ${fmt(result.amount, result.token)} ${result.token} to ${result.toShort}. This usually takes a few seconds.`}
              {result.explorerUrl ? (
                <a href={result.explorerUrl} target="_blank" rel="noreferrer" className="ml-1 font-medium underline">
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
            <h2 className="text-sm font-medium text-zinc-500">Recent sends</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {recent.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <span className="min-w-0">
                    <span className="block text-zinc-900 dark:text-zinc-100">
                      {fmt(s.amount, s.token)} {s.token} to <span className="font-mono">{s.toShort}</span>
                    </span>
                    <span className="block text-xs text-zinc-500">{new Date(s.createdAt).toLocaleString("en-NG")}</span>
                  </span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    {STATUS_TEXT[s.status] ?? s.status}
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
type SendRow = { id: string; status: string; token: string; amount: string; toShort: string; network?: string; chain?: string; createdAt: string };
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
      title: s.chain === "base" ? `Sent ${s.token} on ${s.network ?? "Base"}` : `Sent ${s.token}`,
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
step "Database: the network of each send"
if ! grep -rqs 'ALTER TABLE `sends` ADD `chain`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name send_chain)
fi
grep -rqs 'ALTER TABLE `sends` ADD `chain`' backend/drizzle/*.sql || fail "The database change was not created. Paste the output to Claude."
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

step "Sends on testnet: Arc send with the emailed code, and the Base checks"
SEND_OUTBOX="$(mktemp)"
set +e
(cd backend && EMAIL_OUTBOX_FILE="$SEND_OUTBOX" PAUSE_BYPASS_EMAILS=tester@example.com BRIDGE_ENABLED=true BRIDGE_CHAINS=arc,base npx tsx scripts/send-smoke.ts); code=$?
set -e
rm -f "$SEND_OUTBOX"
if [[ $code -eq 3 ]]; then
  fail "The testnet treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Send test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again. Otherwise paste the output to Claude."
fi
green "OK"

step "Website and admin dashboard: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 4. Live database (before the new code goes live) -----------------------------
step "Live database: the network of each send"
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
git diff --cached --quiet || git commit -q -m "Send USDC on Base from the user's Base wallet, with the emailed code"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"baseSend":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
[[ "$STATUS" == *'"network":"mainnet"'* ]] || fail "Render is not on mainnet. Tell Claude."
echo "Vercel usually finishes the website a minute or two after the push."

echo
green "Script 35 complete. The Send page now has an Arc or Base choice."
echo
bold "Your live test (about 2 USDC):"
echo "  1. Dashboard > To Base > My wallet on Base > 1 USDC > Send. Wait for Complete."
echo "  2. Send > Base > 0.5 USDC > the Base deposit address of an exchange or a wallet you"
echo "     control > tick the Base box > Continue > enter the emailed code."
echo "  3. Check it arrives, then:   bash setup/29_live_bridge_swap.sh report"
