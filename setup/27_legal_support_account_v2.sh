#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 27 (v2): legal pages, WhatsApp support, and account tools
#   Use this instead of the first script 27 (safe even if that one already ran).
#
#   1. Terms of Service, Privacy Policy (Nigeria Data Protection Act 2023) and
#      Refund Policy pages; the sign up form links to them (draft for your lawyer)
#   2. WhatsApp support (+234 803 852 6981): "Report a problem" on order and
#      transfer pages with the reference typed in, "Need help?" on the
#      dashboard, the footer and the FAQ
#   3. Add USDC page: wallet address, QR code, copy button, and a clear
#      "only USDC on Arc" warning (plus test USDC steps on testnet)
#   4. Account settings: edit name and phone (checked like at sign up), change
#      password (signs out other devices), sign out on all devices, ask to
#      delete the account
#   5. Email receipts when airtime or data is delivered, and when a refund is sent
#   6. Buy again on finished orders, and recent numbers to pick with one tap
#   7. Full order history with filters and a CSV download
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/27_legal_support_account_v2.sh
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

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
[[ -f frontend/src/components/ThemeToggle.tsx ]] || fail "Run this from ~/dataonchain after script 26 (dark mode)"
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/27_' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Website: QR code package"
(cd frontend && npm install --no-audit --no-fund qrcode@^1.5.4 && npm install --no-audit --no-fund -D @types/qrcode@^1.5.5) \
  || fail "Could not install the QR code package. Check your internet connection and run again."
green "OK"

step "Writing the new pages and backend changes"
mkdir -p "backend/scripts" "backend/src" "backend/src/auth" "backend/src/email" "backend/src/fulfilment" "backend/src/payments" "backend/src/refunds" "frontend/src/app" "frontend/src/app/account" "frontend/src/app/add-usdc" "frontend/src/app/bridge/[id]" "frontend/src/app/buy" "frontend/src/app/dashboard" "frontend/src/app/history" "frontend/src/app/orders/[reference]" "frontend/src/app/privacy" "frontend/src/app/refund-policy" "frontend/src/app/signup" "frontend/src/app/terms" "frontend/src/components" "frontend/src/lib"
cat > "backend/scripts/auth-smoke.ts" <<'DOC_EOF'
// End to end auth test against a running backend, then cleans up.
// The backend must run with EMAIL_OUTBOX_FILE set, so emails land in that file.
// Run with: EMAIL_OUTBOX_FILE=/tmp/outbox.jsonl npx tsx scripts/auth-smoke.ts http://localhost:4000
import { readFile } from "node:fs/promises";
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const base = (process.argv[2] ?? "http://localhost:4000").replace(/\/$/, "");
const origin = (process.env.BETTER_AUTH_URL ?? "http://localhost:3000").replace(/\/$/, "");
const outbox = process.env.EMAIL_OUTBOX_FILE;
const email = `smoketest+${Date.now()}@example.com`;
const password = "Sm0ke-test-password";

type Result = { status: number; body: unknown; cookies: string[]; location: string | null };

async function call(path: string, method: string, body?: unknown, cookie?: string): Promise<Result> {
  const res = await fetch(path.startsWith("http") ? path : base + path, {
    method,
    redirect: "manual",
    headers: {
      "Content-Type": "application/json",
      Origin: origin,
      ...(cookie ? { Cookie: cookie } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // not JSON
  }
  return {
    status: res.status,
    body: parsed,
    cookies: res.headers.getSetCookie(),
    location: res.headers.get("location"),
  };
}

const cookieOf = (r: Result) => r.cookies.map((c) => c.split(";")[0]).join("; ");

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function latestEmailTo(to: string): Promise<{ subject: string; text: string } | null> {
  if (!outbox) throw new Error("EMAIL_OUTBOX_FILE is not set");
  for (let i = 0; i < 20; i++) {
    const lines = (await readFile(outbox, "utf8").catch(() => "")).trim().split("\n").filter(Boolean);
    const found = lines.map((l) => JSON.parse(l) as { to: string; subject: string; text: string }).filter((m) => m.to === to);
    if (found.length > 0) return found[found.length - 1]!;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}

async function cleanup() {
  const db = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });
  const where = "user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com')";
  await db.execute(`DELETE FROM sessions WHERE ${where}`);
  await db.execute(`DELETE FROM accounts WHERE ${where}`);
  await db.execute("DELETE FROM verifications WHERE identifier LIKE '%smoketest+%'");
  await db.execute("DELETE FROM users WHERE email LIKE 'smoketest+%@example.com'");
  db.close();
  console.log("Cleaned up test users");
}

async function main() {
  const bad = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test", email: `bad-${email}`, password, phone: "12345",
  });
  check(bad.status >= 400 && bad.status < 500, "invalid phone number is refused", bad.body);

  const signUp = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test", email, password, phone: "0801 234 5678", callbackURL: "/dashboard",
  });
  check(signUp.status === 200, "sign up", signUp.body);

  const early = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(early.status === 403, "log in is blocked until the email is confirmed", early.body);

  const message = await latestEmailTo(email);
  check(message !== null, "a confirmation email was sent");
  const link = message!.text.match(/https?:\/\/\S+/)?.[0];
  check(Boolean(link && link.includes("verify-email")), "the email contains a confirmation link", message);

  // The link points at the website; in this test we open it on the backend directly.
  const url = new URL(link!);
  const verify = await call(base + url.pathname + url.search, "GET");
  check(verify.status >= 300 && verify.status < 400, "the confirmation link works", verify.body);
  const cookie = cookieOf(verify);
  check(cookie.length > 0, "confirming the email logs the user in");

  const session = await call("/api/auth/get-session", "GET", undefined, cookie);
  const user = (session.body as { user?: { email?: string; emailVerified?: boolean } } | null)?.user;
  check(user?.email === email && user.emailVerified === true, "the email is now marked as confirmed", session.body);

  const me = await call("/api/me", "GET", undefined, cookie);
  const meUser = (me.body as { user?: { phone?: string; role?: string } }).user;
  check(meUser?.phone === "+2348012345678", "phone saved as +2348012345678", me.body);
  check(meUser?.role === "user", "new users get the 'user' role", me.body);

  const anon = await call("/api/me", "GET");
  check(anon.status === 401, "/api/me refuses visitors who are not logged in", anon.body);

  const signOut = await call("/api/auth/sign-out", "POST", {}, cookie);
  check(signOut.status === 200, "sign out", signOut.body);

  const login = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(login.status === 200, "log in after confirming", login.body);

  const wrong = await call("/api/auth/sign-in/email", "POST", { email, password: "wrong-password" });
  check(wrong.status === 401 || wrong.status === 400, "wrong password is refused", wrong.body);

  // Account page: phone number changes are checked like at sign up
  const acct = cookieOf(login);
  const badPhone = await call("/api/auth/update-user", "POST", { phone: "12345" }, acct);
  check(badPhone.status >= 400 && badPhone.status < 500, "an invalid phone number is refused on the account page", badPhone.body);
  const goodPhone = await call("/api/auth/update-user", "POST", { phone: "0803 111 2222", name: "Smoke Tester" }, acct);
  check(goodPhone.status === 200, "name and phone can be updated", goodPhone.body);
  const me2 = await call("/api/me", "GET", undefined, acct);
  const me2User = (me2.body as { user?: { phone?: string; name?: string } }).user;
  check(me2User?.phone === "+2348031112222" && me2User?.name === "Smoke Tester", "the new phone is saved as +2348031112222", me2.body);
  const roleTry = await call("/api/auth/update-user", "POST", { role: "admin" }, acct);
  const me3 = await call("/api/me", "GET", undefined, acct);
  check((me3.body as { user?: { role?: string } }).user?.role === "user", "users cannot make themselves admin", roleTry.body);

  // Order history and CSV download
  const history = await call("/api/history?page=1", "GET", undefined, acct);
  check(history.status === 200 && typeof (history.body as { total?: unknown }).total === "number", "order history loads", history.body);
  const csv = await call("/api/history.csv", "GET", undefined, acct);
  check(csv.status === 200 && typeof csv.body === "string" && (csv.body as string).startsWith('"Date (Lagos)"'), "order history downloads as CSV", csv.body);
  const anonCsv = await call("/api/history.csv", "GET");
  check(anonCsv.status === 401, "the CSV needs a login", anonCsv.status);

  // Forgot password
  const loggedIn = cookieOf(login);
  const ask = await call("/api/auth/request-password-reset", "POST", { email, redirectTo: "/reset-password" });
  check(ask.status === 200, "forgot password answers", ask.body);
  const nobody = await call("/api/auth/request-password-reset", "POST", { email: `nobody-${email}`, redirectTo: "/reset-password" });
  check(nobody.status === 200, "forgot password answers the same for an unknown email", nobody.body);
  let resetMail: { subject: string; text: string } | null = null;
  for (let i = 0; i < 20 && !resetMail; i++) {
    const m = await latestEmailTo(email);
    if (m && /reset/i.test(m.subject)) resetMail = m;
    else await new Promise((r) => setTimeout(r, 250));
  }
  check(resetMail !== null, "a password reset email was sent");
  const resetLink = resetMail!.text.match(/https?:\/\/\S+/)?.[0];
  check(Boolean(resetLink && resetLink.includes("reset-password")), "the email contains a reset link", resetMail);
  const resetUrl = new URL(resetLink!);
  const opened = await call(base + resetUrl.pathname + resetUrl.search, "GET");
  const token = /[?&]token=([^&]+)/.exec(opened.location ?? "")?.[1];
  check(opened.status >= 300 && opened.status < 400 && Boolean(token), "the reset link opens the reset page with a token", opened.location);
  const newPassword = "N3w-smoke-password";
  const reset = await call("/api/auth/reset-password", "POST", { newPassword, token });
  check(reset.status === 200, "a new password can be set", reset.body);
  const reuse = await call("/api/auth/reset-password", "POST", { newPassword: "Another-pass-123", token });
  check(reuse.status >= 400, "the same reset link cannot be used twice", reuse.body);
  const oldPass = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(oldPass.status === 401 || oldPass.status === 400, "the old password no longer works", oldPass.body);
  const newPass = await call("/api/auth/sign-in/email", "POST", { email, password: newPassword });
  check(newPass.status === 200, "the new password works", newPass.body);
  const stale = await call("/api/auth/get-session", "GET", undefined, loggedIn);
  check(!(stale.body as { user?: unknown } | null)?.user, "sessions from before the reset were signed out", stale.body);
}

main()
  .then(cleanup)
  .then(() => console.log("All auth checks passed."))
  .catch(async (err) => {
    await cleanup().catch(() => undefined);
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses() }));

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
cat > "backend/src/auth/index.ts" <<'DOC_EOF'
// Better Auth: signup, login, sessions, email verification.
// All routes live under /api/auth/* (see app.ts).
import { randomUUID } from "node:crypto";
import { betterAuth } from "better-auth";
import { APIError } from "better-auth/api";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import { db } from "../db";
import { accounts, sessions, users, verifications } from "../db/schema";
import { sendEmail } from "../email";
import { resetPasswordEmail, verificationEmail } from "../email/templates";
import { env } from "../env";
import { normalizeNigerianPhone } from "./phone";

export const auth = betterAuth({
  appName: "dataonchain",
  // The address users see. The website passes /api/* through to this server.
  baseURL: env.BETTER_AUTH_URL,
  secret: env.BETTER_AUTH_SECRET,
  trustedOrigins: env.FRONTEND_URLS,

  database: drizzleAdapter(db, {
    provider: "sqlite",
    usePlural: true,
    schema: { users, sessions, accounts, verifications },
  }),

  emailAndPassword: {
    enabled: true,
    minPasswordLength: 8,
    // No login until the email is confirmed.
    requireEmailVerification: true,
    autoSignIn: false,
    // Forgot password: a link by email, valid one hour, used once.
    // Setting a new password signs the user out everywhere.
    resetPasswordTokenExpiresIn: 60 * 60,
    revokeSessionsOnPasswordReset: true,
    sendResetPassword: async ({ user, url }) => {
      const message = resetPasswordEmail(user.name, url);
      // Not awaited on purpose: the response time must not reveal anything.
      void sendEmail({ to: user.email, ...message }).catch((err) => {
        console.error("[email] password reset email failed:", err);
      });
    },
  },

  emailVerification: {
    sendOnSignUp: true,
    // Logging in with an unconfirmed email sends a fresh link.
    sendOnSignIn: true,
    // Clicking the link also logs the user in.
    autoSignInAfterVerification: true,
    sendVerificationEmail: async ({ user, url }) => {
      const message = verificationEmail(user.name, url);
      // Not awaited on purpose: the response time must not reveal anything.
      void sendEmail({ to: user.email, ...message }).catch((err) => {
        console.error("[email] verification email failed:", err);
      });
    },
  },

  user: {
    additionalFields: {
      phone: { type: "string", required: true },
      // Users can never set these themselves.
      role: { type: "string", required: false, defaultValue: "user", input: false },
      status: { type: "string", required: false, defaultValue: "active", input: false },
    },
  },

  databaseHooks: {
    user: {
      create: {
        before: async (user) => {
          const raw = String((user as { phone?: unknown }).phone ?? "");
          const phone = normalizeNigerianPhone(raw);
          if (!phone) {
            throw new APIError("BAD_REQUEST", {
              message: "Enter a valid Nigerian phone number, for example 08012345678",
            });
          }
          return { data: { ...user, phone } };
        },
      },
      // Changing the phone number on the Account page: same check as at sign up
      update: {
        before: async (data) => {
          if (!("phone" in data) || (data as { phone?: unknown }).phone === undefined) return { data };
          const phone = normalizeNigerianPhone(String((data as { phone?: unknown }).phone ?? ""));
          if (!phone) {
            throw new APIError("BAD_REQUEST", {
              message: "Enter a valid Nigerian phone number, for example 08012345678",
            });
          }
          return { data: { ...data, phone } };
        },
      },
    },
  },

  advanced: {
    database: { generateId: () => randomUUID() },
  },
});

export type AuthSession = typeof auth.$Infer.Session;
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

export function resetPasswordEmail(name: string, url: string) {
  const first = name.trim().split(/\s+/)[0] || "there";
  const subject = "Reset your dataonchain password";

  const text = [
    `Hi ${first},`,
    "",
    "Someone asked to reset the password of your dataonchain account. Choose a new password here:",
    url,
    "",
    "This link works once and expires after one hour. If you did not ask for it, ignore this email: your password stays the same.",
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
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">Someone asked to reset the password of your dataonchain account.</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${safeUrl}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">Choose a new password</a>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">
            This link works once and expires after one hour. If the button does not work, copy this address into your browser:<br>
            <span style="word-break:break-all;">${safeUrl}</span>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;color:#71717a;">If you did not ask for this, ignore this email: your password stays the same.</td></tr>
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

// Receipts for customers: a short summary table and a link to the order.
export function receiptEmail(p: { name: string; subject: string; heading: string; rows: [string, string][]; note: string; url: string }) {
  const first = p.name.trim().split(/\s+/)[0] || "there";
  const text = [
    `Hi ${first},`,
    "",
    p.heading,
    "",
    ...p.rows.map(([k, v]) => `${k}: ${v}`),
    "",
    p.note,
    "",
    `View your order: ${p.url}`,
    "",
    "dataonchain",
  ].join("\n");
  const rows = p.rows
    .map(
      ([k, v]) =>
        `<tr><td style="padding:6px 12px 6px 0;color:#71717a;font-size:14px;white-space:nowrap;vertical-align:top;">${escapeHtml(k)}</td><td style="padding:6px 0;font-size:14px;word-break:break-all;">${escapeHtml(v)}</td></tr>`,
    )
    .join("");
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain</td></tr>
          <tr><td style="padding-top:24px;font-size:16px;">Hi ${escapeHtml(first)},</td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">${escapeHtml(p.heading)}</td></tr>
          <tr><td style="padding-top:16px;"><table role="presentation" cellpadding="0" cellspacing="0">${rows}</table></td></tr>
          <tr><td style="padding-top:16px;font-size:14px;line-height:1.5;color:#3f3f46;">${escapeHtml(p.note)}</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${escapeHtml(p.url)}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">View your order</a>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
  return { subject: p.subject, text, html };
}
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
import { sendOrderEmail } from "../email/receipts";
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
    sendOrderEmail(order, "delivered");
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
cat > "backend/src/payments/service.ts" <<'DOC_EOF'
// Paying for an order with USDC, and verifying the payment.
//
// Order:   QUOTED -> PAYMENT_PENDING -> PAYMENT_CONFIRMED   (or FAILED / FLAGGED)
// Payment: INITIATED -> PENDING -> CONFIRMED                (or FAILED / MISMATCH)
//
// Every status change is conditional ("only if it is still X"), so two
// requests at the same time can never pay twice or confirm twice.
import { createHash, randomUUID } from "node:crypto";
import { and, count, desc, eq, gte, inArray, isNotNull, isNull, lt, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { isUniqueViolation } from "../db/errors";
import { auditLogs, dataPlans, ledgerEntries, orders, payments, wallets } from "../db/schema";
import { env } from "../env";
import { fulfilOrder, getDeliveryView, reconcileOrder } from "../fulfilment/service";
import { microToUsdc } from "../pricing/quote";
import { advanceRefund, getRefundView, startRefund } from "../refunds/service";
import { ensureUserWallet, previousWallet } from "../wallets/service";

export class PaymentError extends Error {
  constructor(message: string, public status: 400 | 402 | 404 | 409 = 400) {
    super(message);
  }
}

type Order = typeof orders.$inferSelect;
type Payment = typeof payments.$inferSelect;

const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
const STARTED = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"] as const;

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

// "0.075189" -> 75189. Returns null when the text is not an exact USDC amount.
export function usdcToMicro(amount: string): number | null {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return null;
  const frac = (m[2] ?? "").padEnd(6, "0");
  if (/[1-9]/.test(frac.slice(6))) return null;
  return Number(m[1]) * 1_000_000 + Number(frac.slice(0, 6));
}

// Same, but rounds down extra digits (for balances).
function usdcToMicroFloor(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

export type TransferFacts = {
  state?: string;
  destinationAddress?: string;
  amounts?: string[];
  tokenId?: string;
  blockchain?: string;
  txHash?: string;
  errorReason?: string;
};

// Everything that must be true before a payment counts. Returns the problems found.
export function checkTransfer(
  tx: TransferFacts,
  expected: { destination: string; amountMicro: number; tokenId: string; blockchain: string },
): string[] {
  const problems: string[] = [];
  if (tx.state !== "COMPLETE") problems.push(`transfer state is ${tx.state ?? "unknown"}`);
  if ((tx.destinationAddress ?? "").toLowerCase() !== expected.destination.toLowerCase()) {
    problems.push("sent to the wrong address");
  }
  const sent = tx.amounts?.[0] !== undefined ? usdcToMicro(tx.amounts[0]) : null;
  if (sent !== expected.amountMicro) problems.push(`amount ${tx.amounts?.[0] ?? "missing"} does not match`);
  if (tx.tokenId && tx.tokenId !== expected.tokenId) problems.push("wrong token");
  if (tx.blockchain && tx.blockchain !== expected.blockchain) problems.push("wrong network");
  if (!tx.txHash) problems.push("no transaction hash");
  return problems;
}

async function usdcOf(circleWalletId: string): Promise<{ tokenId: string; balanceMicro: number } | null> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!usdc?.token?.id) return null;
  return { tokenId: usdc.token.id, balanceMicro: usdcToMicroFloor(usdc.amount) };
}

async function findOrder(userId: string, reference: string): Promise<Order | undefined> {
  const [order] = await db
    .select()
    .from(orders)
    .where(and(eq(orders.reference, reference), eq(orders.userId, userId)))
    .limit(1);
  return order;
}

async function audit(action: string, targetId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId, details });
}

export async function payOrder(userId: string, reference: string) {
  const order = await findOrder(userId, reference);
  if (!order) throw new PaymentError("Order not found.", 404);

  if ((STARTED as readonly string[]).includes(order.status)) return getOrderView(userId, reference);
  if (order.status !== "QUOTED") {
    throw new PaymentError(`This order can no longer be paid (it is ${order.status.toLowerCase().replace(/_/g, " ")}).`, 409);
  }
  if (order.quoteExpiresAt.getTime() < Date.now()) {
    await db.update(orders).set({ status: "EXPIRED" }).where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")));
    throw new PaymentError("This price has expired. Please get a new price.", 409);
  }

  const wallet = await ensureUserWallet(userId);
  const usdc = await usdcOf(wallet.circleWalletId);
  // Smart contract wallets: Circle Gas Station pays the network fee
  const gasFree = wallet.accountType === "SCA";
  const buffer = gasFree ? 0 : Math.round(env.PAYMENT_FEE_BUFFER_USDC * 1_000_000);
  const needed = order.usdcAmountMicro + buffer;
  if (!usdc || usdc.balanceMicro < needed) {
    const old = await previousWallet(userId);
    const oldBalance = old ? await usdcOf(old.circleWalletId) : null;
    if (oldBalance && oldBalance.balanceMicro >= 20_000) {
      throw new PaymentError(
        "Your USDC is being moved to your upgraded wallet. This takes about a minute. Please try again shortly.",
        409,
      );
    }
    throw new PaymentError(
      `Not enough USDC. You need ${microToUsdc(needed)} USDC${gasFree ? "" : " (price plus network fee)"}. Your balance is ${microToUsdc(usdc?.balanceMicro ?? 0)} USDC.`,
      402,
    );
  }

  // Claim the order. Only one request can win this.
  const [claimed] = await db
    .update(orders)
    .set({ status: "PAYMENT_PENDING" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")))
    .returning();
  if (!claimed) return getOrderView(userId, reference);

  const [payment] = await db
    .insert(payments)
    .values({
      orderId: order.id,
      walletId: wallet.id,
      fromAddress: wallet.address,
      toAddress: env.TREASURY_ADDRESS,
      token: usdc.tokenId,
      blockchain: wallet.blockchain,
      amountMicro: order.usdcAmountMicro,
      status: "INITIATED",
    })
    .returning();
  if (!payment) throw new Error("Could not save the payment");

  const amount = microToUsdc(order.usdcAmountMicro);
  const input = {
    walletId: wallet.circleWalletId,
    tokenId: usdc.tokenId,
    destinationAddress: env.TREASURY_ADDRESS,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    // Same key for the same order: a retry can never send a second transfer.
    idempotencyKey: uuidFrom(`pay:${order.id}`),
    refId: order.reference,
  };

  let transactionId: string | undefined;
  for (let attempt = 0; attempt < 2 && !transactionId; attempt++) {
    try {
      const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
      transactionId = res.data?.id;
    } catch (err) {
      const detail = (err as { response?: { data?: unknown } }).response?.data;
      console.error(`[pay] ${order.reference} attempt ${attempt + 1} failed:`, err instanceof Error ? err.message : err, detail ?? "");
    }
  }

  if (!transactionId) {
    // Circle may have taken the transfer even though its answer was lost: look for it
    try {
      transactionId = (await findCircleTransfer(order, { ...payment, walletId: wallet.id })) ?? undefined;
    } catch (err) {
      console.error(`[pay] ${order.reference} lookup failed:`, err instanceof Error ? err.message : err);
    }
  }
  if (!transactionId) {
    await db.update(payments).set({ status: "FAILED" }).where(eq(payments.id, payment.id));
    await db.update(orders).set({ status: "QUOTED" }).where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    throw new PaymentError(
      "We could not start the payment. Please try again. If any USDC did leave your wallet, it is matched to this order automatically within a few minutes.",
      409,
    );
  }

  await db
    .update(payments)
    .set({ circleTransactionId: transactionId, status: "PENDING" })
    .where(eq(payments.id, payment.id));
  return getOrderView(userId, reference);
}

// Looks on Circle for the transfer of this order (by its reference), in case
// Circle took it but its answer never reached us. Returns the Circle id or null.
async function findCircleTransfer(order: Order, payment: Pick<Payment, "walletId" | "createdAt">): Promise<string | null> {
  if (!payment.walletId) return null;
  const [w] = await db.select({ circleWalletId: wallets.circleWalletId }).from(wallets).where(eq(wallets.id, payment.walletId)).limit(1);
  if (!w) return null;
  const res = await circle.listTransactions({
    walletIds: [w.circleWalletId],
    from: new Date(payment.createdAt.getTime() - 5 * 60_000).toISOString(),
    pageSize: 50,
  } as unknown as Parameters<typeof circle.listTransactions>[0]);
  const list = (res.data?.transactions ?? []) as unknown as { id?: string; refId?: string }[];
  return list.find((t) => t.refId === order.reference)?.id ?? null;
}

// Worker step (every few minutes): payments whose start was interrupted (server
// restart, or Circle's answer was lost). If Circle has the transfer, it is linked
// and the order continues as normal (delivered, or refunded). If Circle never got
// it, an interrupted payment is closed so the customer can simply pay again.
const RECOVER_AFTER_MS = 2 * 60_000;
const RECOVER_WINDOW_MS = 24 * 60 * 60_000;

export async function recoverInterruptedPayments(): Promise<number> {
  const now = Date.now();
  const rows = await db
    .select({ payment: payments, order: orders })
    .from(payments)
    .innerJoin(orders, eq(payments.orderId, orders.id))
    .where(
      and(
        isNull(payments.circleTransactionId),
        inArray(payments.status, ["INITIATED", "FAILED"]),
        lt(payments.createdAt, new Date(now - RECOVER_AFTER_MS)),
        gte(payments.createdAt, new Date(now - RECOVER_WINDOW_MS)),
        inArray(orders.status, ["QUOTED", "EXPIRED", "PAYMENT_PENDING"]),
      ),
    )
    .orderBy(desc(payments.createdAt))
    .limit(20);
  let linked = 0;
  for (const { payment, order } of rows) {
    // Another payment of this order already holds the Circle transfer: nothing to recover
    const [other] = await db
      .select({ id: payments.id })
      .from(payments)
      .where(and(eq(payments.orderId, order.id), isNotNull(payments.circleTransactionId)))
      .limit(1);
    if (other) {
      if (payment.status === "INITIATED") {
        await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "INITIATED")));
      }
      continue;
    }
    let circleId: string | null;
    try {
      circleId = await findCircleTransfer(order, payment);
    } catch (err) {
      console.error(`[pay] recovery lookup for ${order.reference} failed:`, err instanceof Error ? err.message : err);
      continue;
    }
    if (circleId) {
      let done: Payment | undefined;
      try {
        [done] = await db
          .update(payments)
          .set({ circleTransactionId: circleId, status: "PENDING" })
          .where(and(eq(payments.id, payment.id), isNull(payments.circleTransactionId)))
          .returning();
      } catch (err) {
        if (isUniqueViolation(err)) continue; // linked elsewhere already
        throw err;
      }
      if (!done) continue;
      await db
        .update(orders)
        .set({ status: "PAYMENT_PENDING", failureReason: null })
        .where(and(eq(orders.id, order.id), inArray(orders.status, ["QUOTED", "EXPIRED", "PAYMENT_PENDING"])));
      await audit("payment.recovered", order.id, { paymentId: payment.id, circleTransactionId: circleId });
      console.log(`[pay] ${order.reference}: found its transfer on Circle (${circleId}), continuing`);
      linked++;
    } else if (payment.status === "INITIATED") {
      // Circle never received it: nothing left the wallet. Let the customer pay again.
      await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "INITIATED")));
      await db
        .update(orders)
        .set({ status: order.quoteExpiresAt.getTime() < now ? "EXPIRED" : "QUOTED" })
        .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    }
  }
  return linked;
}

// Checks a pending payment with Circle and moves the order forward.
export async function refreshPayment(order: Order): Promise<void> {
  if (order.status !== "PAYMENT_PENDING") return;
  const [payment] = await db
    .select()
    .from(payments)
    .where(and(eq(payments.orderId, order.id), eq(payments.status, "PENDING")))
    .orderBy(desc(payments.createdAt))
    .limit(1);
  if (!payment?.circleTransactionId) return;

  const res = await circle.getTransaction({ id: payment.circleTransactionId });
  const tx = res.data?.transaction as unknown as TransferFacts | undefined;
  if (!tx?.state) return;

  if (FAILED_STATES.includes(tx.state)) {
    await db.update(payments).set({ status: "FAILED" }).where(and(eq(payments.id, payment.id), eq(payments.status, "PENDING")));
    await db
      .update(orders)
      .set({ status: "FAILED", failureReason: `Payment ${tx.state.toLowerCase()}${tx.errorReason ? `: ${tx.errorReason}` : ""}. No money left your wallet.` })
      .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    return;
  }
  if (tx.state !== "COMPLETE") return;

  const problems = checkTransfer(tx, {
    destination: env.TREASURY_ADDRESS,
    amountMicro: order.usdcAmountMicro,
    tokenId: payment.token,
    blockchain: payment.blockchain,
  });
  if (problems.length > 0) {
    await flag(order, payment, problems.join("; "), tx);
    return;
  }

  let confirmed: Payment | undefined;
  try {
    [confirmed] = await db
      .update(payments)
      .set({ status: "CONFIRMED", txHash: tx.txHash, confirmedAt: new Date() })
      .where(and(eq(payments.id, payment.id), eq(payments.status, "PENDING")))
      .returning();
  } catch (err) {
    if (isUniqueViolation(err)) {
      await flag(order, payment, "transaction hash was already used by another payment", tx);
      return;
    }
    throw err;
  }
  if (!confirmed) return; // another request confirmed it first

  await db
    .update(orders)
    .set({ status: "PAYMENT_CONFIRMED" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));

  const journalId = randomUUID();
  await db.insert(ledgerEntries).values([
    { journalId, account: "treasury:usdc", orderId: order.id, currency: "USDC", debit: order.usdcAmountMicro, memo: `Payment ${order.reference}` },
    { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", credit: order.usdcAmountMicro, memo: `Payment ${order.reference}` },
  ]);

  // Paid: deliver right away (the worker picks it up too if this fails)
  void fulfilOrder(order.id).catch((err) => console.error(`[deliver] ${order.reference} failed:`, err));
}

async function flag(order: Order, payment: Payment, reason: string, tx: TransferFacts) {
  await db.update(payments).set({ status: "MISMATCH", txHash: null }).where(eq(payments.id, payment.id));
  await db
    .update(orders)
    .set({ status: "FLAGGED", failureReason: `Payment needs review: ${reason}` })
    .where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
  await audit("payment.flagged", order.id, { reason, transaction: tx });
  console.error(`[pay] ${order.reference} FLAGGED: ${reason}`);
}

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

export async function getOrderView(userId: string, reference: string) {
  let order = await findOrder(userId, reference);
  if (!order) return null;

  if (order.status === "PAYMENT_PENDING") {
    try {
      await refreshPayment(order);
    } catch (err) {
      console.error(`[pay] refresh ${reference} failed:`, err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FLAGGED"].includes(order.status)) {
    try {
      if (order.status === "PAYMENT_CONFIRMED") await fulfilOrder(order.id);
      else await reconcileOrder(order.id);
    } catch (err) {
      console.error(`[deliver] check ${reference} failed:`, err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (order.status === "FAILED" || order.status === "REFUND_PENDING") {
    try {
      if (order.status === "FAILED") await startRefund(order.id);
      else await advanceRefund(order.id);
    } catch (err) {
      console.error(`[refund] check ${reference} failed:`, err instanceof Error ? err.message : err);
    }
    order = (await findOrder(userId, reference)) ?? order;
  } else if (order.status === "QUOTED" && order.quoteExpiresAt.getTime() < Date.now()) {
    await db.update(orders).set({ status: "EXPIRED" }).where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")));
    order = { ...order, status: "EXPIRED" };
  }

  const [plan] = order.planId
    ? await db.select({ name: dataPlans.name }).from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1)
    : [];
  const [payment] = await db
    .select()
    .from(payments)
    .where(eq(payments.orderId, order.id))
    .orderBy(desc(payments.createdAt))
    .limit(1);

  return {
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName: plan?.name ?? null,
    planId: order.planId,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    expiresAt: order.quoteExpiresAt.toISOString(),
    createdAt: order.createdAt.toISOString(),
    failureReason: order.failureReason,
    delivery: await getDeliveryView(order.id),
    refund: await getRefundView(order.id),
    payment: payment
      ? {
          status: payment.status,
          txHash: payment.txHash,
          explorerUrl: payment.txHash ? `${env.EXPLORER_TX_URL}${payment.txHash}` : null,
        }
      : null,
  };
}

export async function listOrders(userId: string) {
  const rows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.userId, userId), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(20);
  return rows.map(({ order, planName }) => ({
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName: planName ?? null,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    createdAt: order.createdAt.toISOString(),
  }));
}

// Full order history for the History page: 25 per page, optional status filter.
const HISTORY_PAGE = 25;
const HISTORY_GROUPS: Record<string, readonly Order["status"][]> = {
  delivered: ["FULFILLED"],
  refunded: ["REFUNDED", "REFUND_PENDING"],
  failed: ["FAILED"],
  open: ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FLAGGED"],
};

export async function orderHistory(userId: string, page: number, group?: string) {
  const statuses = group && HISTORY_GROUPS[group] ? [...HISTORY_GROUPS[group]!] : null;
  const where = and(
    eq(orders.userId, userId),
    notInArray(orders.status, ["QUOTED", "EXPIRED"]),
    statuses ? inArray(orders.status, statuses) : undefined,
  );
  const [total] = await db.select({ n: count() }).from(orders).where(where);
  const rows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(where)
    .orderBy(desc(orders.createdAt))
    .limit(HISTORY_PAGE)
    .offset((page - 1) * HISTORY_PAGE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: HISTORY_PAGE,
    orders: rows.map(({ order, planName }) => ({
      reference: order.reference,
      status: order.status,
      serviceType: order.serviceType,
      network: order.network,
      planName: planName ?? null,
      phone: localPhone(order.phone),
      ngnAmount: order.ngnAmountKobo / 100,
      usdcAmount: microToUsdc(order.usdcAmountMicro),
      createdAt: order.createdAt.toISOString(),
    })),
  };
}

// Every order as a CSV file (up to 5,000), for the "Download CSV" button.
export async function orderHistoryCsv(userId: string): Promise<string> {
  const rows = await db
    .select({ order: orders, planName: dataPlans.name, txHash: payments.txHash })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .leftJoin(payments, and(eq(payments.orderId, orders.id), eq(payments.status, "CONFIRMED")))
    .where(and(eq(orders.userId, userId), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(5000);
  const cell = (v: string | number | null) => {
    const t = v === null ? "" : String(v);
    // Quote every cell; a leading = + - @ is neutralised so spreadsheets never run it as a formula
    return `"${(/^[=+\-@]/.test(t) ? `'${t}` : t).replace(/"/g, '""')}"`;
  };
  const lines = [
    ["Date (Lagos)", "Reference", "Type", "Network", "Plan", "Phone", "Naira value", "USDC paid", "Status", "Payment transaction"].map(cell).join(","),
    ...rows.map(({ order, planName, txHash }) =>
      [
        order.createdAt.toLocaleString("en-GB", { timeZone: "Africa/Lagos" }),
        order.reference,
        order.serviceType,
        order.network,
        planName,
        localPhone(order.phone),
        (order.ngnAmountKobo / 100).toFixed(2),
        microToUsdc(order.usdcAmountMicro),
        order.status,
        txHash,
      ]
        .map(cell)
        .join(","),
    ),
  ];
  return `${lines.join("\r\n")}\r\n`;
}

// Used by the background worker later: every order still waiting for its payment.
export async function pendingPaymentOrders(): Promise<Order[]> {
  return db.select().from(orders).where(inArray(orders.status, ["PAYMENT_PENDING"])).limit(100);
}
DOC_EOF
cat > "backend/src/refunds/service.ts" <<'DOC_EOF'
// Automatic refunds: when a paid order cannot be delivered, the USDC goes
// back from the treasury wallet to the customer's wallet.
//
// Order:  FAILED -> REFUND_PENDING -> REFUNDED   (or FLAGGED if Circle keeps refusing)
// Refund: PENDING -> SENT -> CONFIRMED           (or FAILED)
//
// Safety:
//   - only orders whose payment was CONFIRMED on Arc are refunded
//   - claiming FAILED -> REFUND_PENDING is conditional, so only one caller wins
//   - one refund row per order (unique order_id)
//   - every Circle transfer uses an idempotency key made from the order id and
//     the attempt number, so a retry can never send the money twice
import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, ledgerEntries, orders, payments, refunds } from "../db/schema";
import { env } from "../env";
import { sendOrderEmail } from "../email/receipts";
import { ensureUserWallet } from "../wallets/service";

const MAX_ATTEMPTS = 3;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// The treasury pays the Arc network fee for refunds, so keep a little extra
const FEE_RESERVE_MICRO = 50_000;

type Order = typeof orders.$inferSelect;
type Refund = typeof refunds.$inferSelect;

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export function microText(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

function microFrom(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

async function audit(action: string, orderId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "order", targetId: orderId, details });
}

async function treasuryBalanceMicro(): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc ? microFrom(usdc.amount) : 0;
}

async function confirmedPayment(orderId: string) {
  const [payment] = await db
    .select()
    .from(payments)
    .where(and(eq(payments.orderId, orderId), eq(payments.status, "CONFIRMED")))
    .orderBy(desc(payments.createdAt))
    .limit(1);
  return payment;
}

// Makes sure the refund row exists. Returns it, or nothing if the order was never paid.
async function ensureRefundRow(order: Order): Promise<Refund | undefined> {
  const [existing] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  if (existing) return existing;
  const payment = await confirmedPayment(order.id);
  if (!payment) return undefined;
  // Refunds go to the user's current wallet (old wallets are retired)
  const wallet = await ensureUserWallet(order.userId);
  await db
    .insert(refunds)
    .values({
      orderId: order.id,
      paymentId: payment.id,
      toAddress: wallet.address,
      token: payment.token,
      blockchain: payment.blockchain,
      amountMicro: payment.amountMicro,
      status: "PENDING",
    })
    .onConflictDoNothing();
  const [row] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  return row;
}

// Starts the refund for a FAILED order. Safe to call many times.
export async function startRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "FAILED") return;
  // A payment that never completed took no money, so there is nothing to refund
  if (!(await confirmedPayment(order.id))) return;

  const [claimed] = await db
    .update(orders)
    .set({ status: "REFUND_PENDING" })
    .where(and(eq(orders.id, order.id), eq(orders.status, "FAILED")))
    .returning();
  if (!claimed) return;
  await audit("refund.started", order.id, { amountMicro: order.usdcAmountMicro });
  await advanceRefund(order.id);
}

// Moves a REFUND_PENDING order forward: sends the transfer, then confirms it.
export async function advanceRefund(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "REFUND_PENDING") return;
  const refund = await ensureRefundRow(order);
  if (!refund) {
    // Should never happen: no confirmed payment. Put it in front of a person.
    await db
      .update(orders)
      .set({ status: "FLAGGED", failureReason: "Refund needs review: no confirmed payment was found." })
      .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
    return;
  }
  if (refund.status === "PENDING") await sendRefund(order, refund);
  else if (refund.status === "SENT") await checkRefund(order, refund);
}

async function sendRefund(order: Order, refund: Refund): Promise<void> {
  const balance = await treasuryBalanceMicro();
  if (balance < refund.amountMicro + FEE_RESERVE_MICRO) {
    console.error(`[refund] ${order.reference}: treasury has ${microText(balance)} USDC, needs ${microText(refund.amountMicro)} plus fees. Will retry.`);
    return;
  }
  const amount = microText(refund.amountMicro);
  const input = {
    walletId: env.TREASURY_WALLET_ID,
    tokenId: refund.token,
    destinationAddress: refund.toAddress,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    // Same order and attempt: same key, so Circle never sends it twice
    idempotencyKey: uuidFrom(`refund:${order.id}:${refund.attempt}`),
    refId: `REFUND-${order.reference}`,
  };
  let transactionId: string | undefined;
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    transactionId = res.data?.id;
  } catch (err) {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[refund] ${order.reference} transfer not accepted yet:`, message, detail ?? "");
    await db.update(refunds).set({ lastError: message.slice(0, 500) }).where(eq(refunds.id, refund.id));
    return;
  }
  if (!transactionId) return;
  await db
    .update(refunds)
    .set({ circleTransactionId: transactionId, status: "SENT", lastError: null })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "PENDING")));
  console.log(`[refund] ${order.reference}: sent ${amount} USDC back to ${refund.toAddress}`);
}

async function checkRefund(order: Order, refund: Refund): Promise<void> {
  if (!refund.circleTransactionId) return;
  const res = await circle.getTransaction({ id: refund.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (!tx?.state) return;

  if (FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`;
    if (refund.attempt >= MAX_ATTEMPTS) {
      await db.update(refunds).set({ status: "FAILED", lastError: reason }).where(eq(refunds.id, refund.id));
      await db
        .update(orders)
        .set({ status: "FLAGGED", failureReason: "Your refund needs a manual check. Our team has been alerted." })
        .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
      await audit("refund.failed", order.id, { reason, attempts: refund.attempt });
      console.error(`[refund] ${order.reference} FAILED after ${refund.attempt} attempts: ${reason}`);
      return;
    }
    // Nothing moved. Try again with the next attempt number (a new idempotency key).
    await db
      .update(refunds)
      .set({ status: "PENDING", circleTransactionId: null, attempt: refund.attempt + 1, lastError: reason })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")));
    return;
  }
  if (tx.state !== "COMPLETE") return;

  const [done] = await db
    .update(refunds)
    .set({ status: "CONFIRMED", txHash: tx.txHash ?? null, confirmedAt: new Date() })
    .where(and(eq(refunds.id, refund.id), eq(refunds.status, "SENT")))
    .returning();
  if (!done) return;
  await db
    .update(orders)
    .set({
      status: "REFUNDED",
      failureReason: `This order could not be delivered. ${microText(refund.amountMicro)} USDC was refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), eq(orders.status, "REFUND_PENDING")));
  const journalId = randomUUID();
  await db.insert(ledgerEntries).values([
    // The customer's money goes back to them out of the treasury
    { journalId, account: `customer:${order.userId}`, orderId: order.id, currency: "USDC", debit: refund.amountMicro, memo: `Refund ${order.reference}` },
    { journalId, account: "treasury:usdc", orderId: order.id, currency: "USDC", credit: refund.amountMicro, memo: `Refund ${order.reference}` },
  ]);
  await audit("refund.confirmed", order.id, { txHash: tx.txHash, amountMicro: refund.amountMicro });
  sendOrderEmail(order, "refunded", tx.txHash ?? null);
}

export async function getRefundView(orderId: string) {
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, orderId)).limit(1);
  if (!refund) return null;
  return {
    status: refund.status,
    amount: microText(refund.amountMicro),
    txHash: refund.txHash,
    explorerUrl: refund.txHash ? `${env.EXPLORER_TX_URL}${refund.txHash}` : null,
  };
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
cat > "frontend/src/app/buy/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Network = "mtn" | "airtel" | "glo" | "9mobile";
type Service = "data" | "airtime";
type Plan = { id: string; name: string; ngnAmount: number; validity: string | null };
type Quote = {
  reference: string;
  status: string;
  serviceType: Service;
  network: Network;
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  expiresAt: string;
  rate?: number;
  marginPercent?: number;
};

const NETWORKS: { id: Network; label: string }[] = [
  { id: "mtn", label: "MTN" },
  { id: "airtel", label: "Airtel" },
  { id: "glo", label: "Glo" },
  { id: "9mobile", label: "9mobile" },
];
const QUICK_AMOUNTS = [100, 200, 500, 1000, 2000];

const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
const localPhone = (p?: string | null) => (p ? (p.startsWith("+234") ? `0${p.slice(4)}` : p) : "");
const networkLabel = (id: Network) => NETWORKS.find((n) => n.id === id)?.label ?? id;

function choiceClass(active: boolean) {
  return `rounded-lg border px-3 py-2 text-sm font-medium transition ${
    active
      ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
  }`;
}

export default function BuyPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [service, setService] = useState<Service>("data");
  const [network, setNetwork] = useState<Network>("mtn");
  const [plans, setPlans] = useState<Plan[]>([]);
  const [plansLoading, setPlansLoading] = useState(false);
  const [planId, setPlanId] = useState("");
  const [amount, setAmount] = useState("");
  const [phone, setPhone] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [balance, setBalance] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [recent, setRecent] = useState<{ phone: string; network: Network }[]>([]);
  // "Buy again" links open this page with the details filled in (?service=&network=&phone=&plan=&amount=)
  const pendingPlan = useRef<string | null>(null);

  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    const s = q.get("service");
    const n = q.get("network");
    if (s === "data" || s === "airtime") setService(s);
    if (n && NETWORKS.some((x) => x.id === n)) setNetwork(n as Network);
    if (q.get("phone")) setPhone(q.get("phone") ?? "");
    if (q.get("amount")) setAmount(q.get("amount") ?? "");
    pendingPlan.current = q.get("plan");
  }, []);

  // Numbers bought for before, newest first, to fill in with one tap
  useEffect(() => {
    if (!session) return;
    api<{ orders: { phone: string; network: Network }[] }>("/orders")
      .then((r) => {
        const seen = new Set<string>();
        const list: { phone: string; network: Network }[] = [];
        for (const o of r.orders) {
          if (seen.has(o.phone)) continue;
          seen.add(o.phone);
          list.push({ phone: o.phone, network: o.network });
          if (list.length === 4) break;
        }
        setRecent(list);
      })
      .catch(() => setRecent([]));
  }, [session]);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  // Start with the user's own number; they can change it.
  useEffect(() => {
    if (session) setPhone((p) => p || localPhone((session.user as { phone?: string }).phone));
  }, [session]);

  useEffect(() => {
    if (!session) return;
    api<{ balance: { usdc: string | null } }>("/wallet")
      .then((r) => setBalance(r.balance.usdc))
      .catch(() => setBalance(null));
  }, [session]);

  useEffect(() => {
    if (!session || service !== "data") return;
    let cancelled = false;
    setPlansLoading(true);
    setPlanId("");
    setError(null);
    api<{ plans: Plan[] }>(`/plans?network=${network}`)
      .then((r) => {
        if (cancelled) return;
        setPlans(r.plans);
        const wanted = pendingPlan.current;
        if (wanted && r.plans.some((p) => p.id === wanted)) setPlanId(wanted);
        pendingPlan.current = null;
      })
      .catch((e: Error) => !cancelled && setError(e.message))
      .finally(() => !cancelled && setPlansLoading(false));
    return () => {
      cancelled = true;
    };
  }, [session, service, network]);

  useEffect(() => {
    if (!quote) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [quote]);

  async function pay() {
    if (!quote) return;
    setError(null);
    setBusy(true);
    try {
      await api(`/orders/${quote.reference}/pay`, { method: "POST" });
      router.push(`/orders/${quote.reference}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Payment could not start. Please try again.");
      setBusy(false);
    }
  }

  async function getPrice(event?: FormEvent<HTMLFormElement>) {
    event?.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const body =
        service === "data"
          ? { serviceType: "data", network, planId, phone }
          : { serviceType: "airtime", network, amountNgn: Number(amount), phone };
      const r = await api<{ quote: Quote }>("/quotes", { method: "POST", body: JSON.stringify(body) });
      setQuote(r.quote);
      setNow(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not get a price. Please try again.");
    } finally {
      setBusy(false);
    }
  }

  if (isPending || !session) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const secondsLeft = quote ? Math.max(0, Math.floor((new Date(quote.expiresAt).getTime() - now) / 1000)) : 0;
  const expired = quote !== null && secondsLeft === 0;
  const notEnough = quote !== null && balance !== null && Number(balance) < Number(quote.usdcAmount);

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Buy airtime or data</h1>
        {balance !== null ? (
          <p className="mt-1 text-sm text-zinc-500">Your balance: {usdc(balance)} USDC</p>
        ) : null}

        {!quote ? (
          <form onSubmit={getPrice} className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">What do you want?</legend>
              <div className="mt-2 grid grid-cols-2 gap-2">
                <button type="button" onClick={() => setService("data")} className={choiceClass(service === "data")}>Data</button>
                <button type="button" onClick={() => setService("airtime")} className={choiceClass(service === "airtime")}>Airtime</button>
              </div>
            </fieldset>

            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Network</legend>
              <div className="mt-2 grid grid-cols-4 gap-2">
                {NETWORKS.map((n) => (
                  <button key={n.id} type="button" onClick={() => setNetwork(n.id)} className={choiceClass(network === n.id)}>
                    {n.label}
                  </button>
                ))}
              </div>
            </fieldset>

            {service === "data" ? (
              <label className="block">
                <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Data plan</span>
                <select
                  value={planId}
                  onChange={(e) => setPlanId(e.target.value)}
                  required
                  disabled={plansLoading}
                  className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                >
                  <option value="">{plansLoading ? "Loading plans..." : "Choose a plan"}</option>
                  {plans.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} ({naira(p.ngnAmount)})
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <div>
                <label className="block">
                  <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Amount in naira</span>
                  <input
                    type="number"
                    inputMode="numeric"
                    min={50}
                    max={50000}
                    step={1}
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="500"
                    required
                    className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                  />
                </label>
                <div className="mt-2 flex flex-wrap gap-2">
                  {QUICK_AMOUNTS.map((a) => (
                    <button key={a} type="button" onClick={() => setAmount(String(a))} className={choiceClass(amount === String(a))}>
                      {naira(a)}
                    </button>
                  ))}
                </div>
              </div>
            )}

            <label className="block">
              <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Phone number to top up</span>
              <input
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="08012345678"
                required
                className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
              />
              <span className="mt-1 block text-xs text-zinc-500">
                Make sure this number is on {networkLabel(network)}.
              </span>
            </label>
            {recent.length > 0 ? (
              <div className="-mt-3 flex flex-wrap gap-2">
                {recent.map((r) => (
                  <button
                    key={r.phone}
                    type="button"
                    onClick={() => {
                      setPhone(r.phone);
                      setNetwork(r.network);
                    }}
                    className={choiceClass(phone === r.phone)}
                  >
                    {r.phone} <span className="text-xs text-zinc-500">{networkLabel(r.network)}</span>
                  </button>
                ))}
              </div>
            ) : null}

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            <button
              type="submit"
              disabled={busy || (service === "data" && !planId)}
              className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white transition hover:bg-emerald-800 disabled:opacity-60"
            >
              {busy ? "Getting your price..." : "Get price in USDC"}
            </button>
          </form>
        ) : (
          <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div>
              <p className="text-sm text-zinc-500">You pay</p>
              <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
                {usdc(quote.usdcAmount)} <span className="text-lg font-medium text-zinc-500">USDC</span>
              </p>
            </div>

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">For</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {networkLabel(quote.network)} {quote.serviceType === "data" ? quote.planName : `airtime ${naira(quote.ngnAmount)}`}
              </dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(quote.ngnAmount)}</dd>
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{quote.phone}</dd>
              {quote.rate ? (
                <>
                  <dt className="text-zinc-500">Rate</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">
                    1 USDC = {naira(quote.rate)}
                    {quote.marginPercent ? ` (includes ${quote.marginPercent}% service fee)` : ""}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{quote.reference}</dd>
            </dl>

            <p className="text-xs text-zinc-500">
              No network fee: the Arc gas for your payment is covered by dataonchain.
            </p>

            {expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                This price has expired. Get a new one to continue.
              </p>
            ) : (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Price held for {Math.floor(secondsLeft / 60)}:{String(secondsLeft % 60).padStart(2, "0")}
              </p>
            )}

            {notEnough && !expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                Your balance is not enough for this purchase. Add USDC to your wallet first.
              </p>
            ) : null}

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            {expired ? (
              <button
                onClick={() => void getPrice()}
                disabled={busy}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a new price..." : "Get a new price"}
              </button>
            ) : (
              <button
                onClick={() => void pay()}
                disabled={busy || notEnough}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Sending payment..." : `Pay ${usdc(quote.usdcAmount)} USDC`}
              </button>
            )}

            <button
              onClick={() => {
                setQuote(null);
                setError(null);
              }}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
            >
              Change details
            </button>
          </section>
        )}
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
cat > "frontend/src/app/orders/[reference]/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { SupportLink } from "@/components/SupportLink";
import { STATUS_LABELS, describe, naira, stillMoving, toneClass, usdc, type OrderView } from "@/lib/orders";

export default function OrderPage() {
  const router = useRouter();
  const params = useParams<{ reference: string }>();
  const reference = params.reference;
  const { data: session, isPending } = authClient.useSession();
  const [order, setOrder] = useState<OrderView | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session || !reference) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ order: OrderView }>(`/orders/${reference}`);
        if (stop) return;
        setOrder(r.order);
        setError(null);
        if (stillMoving(r.order)) timer = setTimeout(load, r.order.status === "FLAGGED" ? 15000 : 3000);
      } catch (e) {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this order.");
        timer = setTimeout(load, 5000);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session, reference]);

  const label = order ? (STATUS_LABELS[order.status] ?? { text: order.status, tone: "wait" as const }) : null;
  const paid = order?.payment?.status === "CONFIRMED";
  const refunding = order ? paid && ["FAILED", "REFUND_PENDING", "REFUNDED"].includes(order.status) : false;
  const what = order?.serviceType === "data" ? "Data" : "Airtime";
  const steps: { text: string; state: "done" | "todo" | "failed" }[] = order
    ? [
        { text: "Payment sent", state: order.payment ? "done" : "todo" },
        { text: "Payment confirmed on Arc", state: paid ? "done" : "todo" },
        refunding
          ? { text: `${what} could not be delivered`, state: "failed" }
          : { text: `${what} delivered`, state: order.status === "FULFILLED" ? "done" : "todo" },
        ...(refunding
          ? [{ text: "USDC refunded to your wallet", state: order.status === "REFUNDED" ? ("done" as const) : ("todo" as const) }]
          : []),
      ]
    : [];

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Order {reference}</h1>

        {error && !order ? (
          <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
        ) : null}
        {!order && !error ? <p className="mt-6 text-zinc-500">Loading...</p> : null}

        {order && label ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between gap-3">
              <p className="text-lg font-medium text-zinc-900 dark:text-zinc-50">{describe(order)}</p>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
            </div>

            <ol className="space-y-3">
              {steps.map((s) => (
                <li key={s.text} className="flex items-center gap-3 text-sm">
                  <span
                    className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                      s.state === "done"
                        ? "bg-emerald-700 text-white"
                        : s.state === "failed"
                          ? "bg-red-600 text-white"
                          : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                    }`}
                  >
                    {s.state === "done" ? "✓" : s.state === "failed" ? "✕" : ""}
                  </span>
                  <span className={s.state === "todo" ? "text-zinc-500" : "text-zinc-900 dark:text-zinc-100"}>{s.text}</span>
                </li>
              ))}
            </ol>

            {order.status === "PAYMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Confirming your payment on Arc. This usually takes a few seconds...</p>
            ) : null}
            {order.status === "PAYMENT_CONFIRMED" || order.status === "FULFILMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Payment received. Sending your {order.serviceType} to {order.phone}...
                {order.delivery?.message ? <span className="mt-1 block text-xs text-zinc-500">Network status: {order.delivery.message}</span> : null}
              </p>
            ) : null}
            {order.status === "REFUND_PENDING" || (order.status === "FAILED" && paid) ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Sending your USDC back to your wallet. This usually takes under a minute...</p>
            ) : null}
            {order.status === "FULFILLED" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Done. Your {order.serviceType} has been sent to {order.phone}.
              </p>
            ) : null}
            {order.failureReason ? (
              <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{order.failureReason}</p>
            ) : null}

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{order.phone}</dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(order.ngnAmount)}</dd>
              <dt className="text-zinc-500">Paid</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{usdc(order.usdcAmount)} USDC</dd>
              <dt className="text-zinc-500">Date</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{new Date(order.createdAt).toLocaleString("en-NG")}</dd>
              {order.delivery?.providerReference ? (
                <>
                  <dt className="text-zinc-500">VTpass ref</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.providerReference}</dd>
                </>
              ) : null}
              {order.delivery?.token ? (
                <>
                  <dt className="text-zinc-500">Token / PIN</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.token}</dd>
                </>
              ) : null}
              {order.refund?.txHash ? (
                <>
                  <dt className="text-zinc-500">Refund</dt>
                  <dd className="min-w-0">
                    {order.refund.explorerUrl ? (
                      <a href={order.refund.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.refund.amount} USDC · {order.refund.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.refund.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              {order.payment?.txHash ? (
                <>
                  <dt className="text-zinc-500">Transaction</dt>
                  <dd className="min-w-0">
                    {order.payment.explorerUrl ? (
                      <a href={order.payment.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.payment.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.payment.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.reference}</dd>
            </dl>

            {order.status === "FULFILLED" ? (
              <button
                onClick={() => window.print()}
                className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                Print or save receipt
              </button>
            ) : null}
            {["FULFILLED", "REFUNDED", "FAILED", "EXPIRED"].includes(order.status) ? (
              <Link
                href={`/buy?${new URLSearchParams({
                  service: order.serviceType,
                  network: order.network,
                  phone: order.phone,
                  ...(order.serviceType === "data" && order.planId ? { plan: order.planId } : {}),
                  ...(order.serviceType === "airtime" ? { amount: String(order.ngnAmount) } : {}),
                }).toString()}`}
                className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center text-sm font-medium text-white hover:bg-emerald-800"
              >
                Buy again
              </Link>
            ) : null}
            <SupportLink block message={`Hello dataonchain, I need help with order ${order.reference} (${label.text}, ${order.phone}).`}>
              Report a problem on WhatsApp
            </SupportLink>
            <Link href="/buy" className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
              Buy something else
            </Link>
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
  { name: "Circle Gateway", text: "One USDC balance that moves to seven other networks: Base, Arbitrum, Ethereum, Avalanche, OP, Polygon and Unichain, with no gas needed on any of them." },
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
];

const ROADMAP = [
  { title: "Company registration", text: "Registering dataonchain with the Corporate Affairs Commission (CAC) in Nigeria.", status: "In progress" },
  { title: "Bridge and swaps on Arc mainnet", text: "Moving crosschain transfers and swaps from Arc Testnet to Arc mainnet.", status: "Next" },
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
    q: "Can I use real money yet?",
    a: "Not yet. dataonchain is in public testing on Arc Testnet, where USDC is free test money with no value, and airtime and data are delivered through our provider's test environment, so nothing reaches a real phone. Real payments and real delivery come with the full launch, after our company registration and a live provider are in place.",
  },
  {
    q: "How do I get test USDC?",
    a: "Log in and copy your wallet address from your dashboard. Then go to faucet.circle.com, choose Arc Testnet and USDC, paste your address and request it. It arrives in your wallet within a minute.",
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
    a: "It moves USDC from your Arc wallet to your own wallet on Base, Arbitrum, Ethereum, Avalanche, OP, Polygon or Unichain, or to an approved provider, through Circle Gateway. You pay no gas on any network, only Circle's fee, which is shown before you confirm. A transfer can take up to about 20 minutes while the networks confirm it, and Move to Arc brings your USDC back.",
  },
  {
    q: "Are there limits on sending?",
    a: "Yes, while we are testing: 1 to 100 USDC per transfer and 200 USDC per day, one transfer at a time.",
  },
  {
    q: "Can I send USDC to any wallet address?",
    a: "Not yet. For safety, USDC can only go to your own wallets on the supported networks or to approved providers. Sending to any address you choose may come later.",
  },
  {
    q: "How do swaps work?",
    a: "On the Swap page, pick two of USDC, EURC and cirBTC and enter an amount. You see what you get, the fee (0.5%) and the minimum you are guaranteed. If the price moves below that minimum, the swap is cancelled and nothing is taken. On the test network some pairs, such as cirBTC, may have no price at times.",
  },
  {
    q: "Is my money safe?",
    a: "Every payment, refund and swap is a real transaction on Arc that you can open in the Arc explorer from your order page. Payments that fail are refunded automatically, and every crosschain transfer is recorded step by step and checked against Circle every day. During testing, only test money is involved.",
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
    a: "Our registration with the Corporate Affairs Commission (CAC) in Nigeria is in progress. Real payments start only after it is complete.",
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
          Public testing on Arc Testnet: test USDC only, no real money
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
            ["8", "blockchains connected"],
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
          <SectionTitle id="milestones" kicker="Milestones" title="What we have built so far" text="All of this is live today on Arc Testnet, open for anyone to test." />
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
            <h2 className="text-3xl font-semibold tracking-tight text-white">Help us test it</h2>
            <p className="mx-auto mt-3 max-w-xl text-emerald-100">
              Create an account, get free test USDC, and try buying airtime, sending USDC to another network or swapping on
              Arc. Your feedback shapes the launch.
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
            <p>Currently on Arc Testnet. Test USDC has no value.</p>
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
cat > "frontend/src/app/signup/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function SignupPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    const email = String(form.get("email")).trim();
    setBusy(true);
    const { error } = await authClient.signUp.email({
      name: String(form.get("name")).trim(),
      email,
      phone: String(form.get("phone")).trim(),
      password,
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not create your account. Please try again.");
      return;
    }
    setSentTo(email);
  }

  async function resend() {
    if (!sentTo) return;
    setBusy(true);
    await authClient.sendVerificationEmail({ email: sentTo, callbackURL: "/dashboard" });
    setBusy(false);
    setResent(true);
  }

  if (sentTo) {
    return (
      <AuthShell
        title="Check your inbox"
        subtitle="One last step to finish setting up your account."
        footer={
          <>
            Already confirmed?{" "}
            <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
              Log in
            </Link>
          </>
        }
      >
        <div className="space-y-4 text-sm text-zinc-700 dark:text-zinc-300">
          <p>
            We sent a confirmation link to <strong className="text-zinc-900 dark:text-zinc-50">{sentTo}</strong>.
            Click it to confirm your email and you will be logged in.
          </p>
          <p className="text-zinc-500">Not there after a minute? Check your spam folder.</p>
          {resent ? (
            <p className="rounded-lg bg-emerald-50 px-3 py-2 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
              We sent a new link.
            </p>
          ) : (
            <button
              type="button"
              onClick={resend}
              disabled={busy}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 font-medium text-zinc-900 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-800"
            >
              {busy ? "Please wait..." : "Send the link again"}
            </button>
          )}
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Create your account"
      subtitle="It takes a minute. No crypto knowledge needed."
      footer={
        <>
          Already have an account?{" "}
          <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Log in
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Full name" name="name" autoComplete="name" required />
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field
          label="Phone number"
          name="phone"
          type="tel"
          autoComplete="tel"
          placeholder="08012345678"
          hint="Nigerian mobile number"
          required
        />
        <Field label="Password" name="password" type="password" autoComplete="new-password" minLength={8} hint="At least 8 characters" required />
        <Field label="Confirm password" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
        <FormError message={error} />
        <p className="text-xs leading-relaxed text-zinc-500">
          By creating an account you agree to our{" "}
          <Link href="/terms" target="_blank" className="underline hover:text-zinc-800 dark:hover:text-zinc-200">Terms of Service</Link> and{" "}
          <Link href="/privacy" target="_blank" className="underline hover:text-zinc-800 dark:hover:text-zinc-200">Privacy Policy</Link>, and
          confirm you are at least 18.
        </p>
        <SubmitButton busy={busy}>Create account</SubmitButton>
      </form>
    </AuthShell>
  );
}
DOC_EOF
cat > "frontend/src/components/RecentOrders.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { STATUS_LABELS, describe, toneClass, usdc, type OrderView } from "@/lib/orders";

export function RecentOrders() {
  const [orders, setOrders] = useState<OrderView[] | null>(null);

  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ orders: OrderView[] }>("/orders");
        if (stop) return;
        setOrders(r.orders);
        // Keep the list live while any order is still changing
        const recent = Date.now() - 15 * 60_000;
        const moving = r.orders.some(
          (o) =>
            ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"].includes(o.status) ||
            (o.status === "FAILED" && new Date(o.createdAt).getTime() > recent),
        );
        if (moving) timer = setTimeout(load, 5000);
      } catch {
        if (!stop) setOrders((prev) => prev ?? []);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, []);

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium text-zinc-500">Recent orders</h2>
        <Link href="/history" className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          See all and download
        </Link>
      </div>
      {orders === null ? <p className="mt-4 text-sm text-zinc-500">Loading...</p> : null}
      {orders && orders.length === 0 ? <p className="mt-4 text-sm text-zinc-500">No orders yet.</p> : null}
      {orders && orders.length > 0 ? (
        <ul className="mt-3 divide-y divide-zinc-100 dark:divide-zinc-800">
          {orders.map((o) => {
            const label = STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" as const };
            return (
              <li key={o.reference}>
                <Link href={`/orders/${o.reference}`} className="flex items-center justify-between gap-3 py-3 hover:opacity-80">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{describe(o)}</p>
                    <p className="text-xs text-zinc-500">
                      {o.phone} · {usdc(o.usdcAmount)} USDC · {new Date(o.createdAt).toLocaleString("en-NG")}
                    </p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
DOC_EOF
cat > "frontend/src/components/WalletCard.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
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

          <Link
            href="/add-usdc"
            className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center font-medium text-white hover:bg-emerald-800"
          >
            Add USDC (address and QR code)
          </Link>

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
cat > "frontend/src/lib/orders.ts" <<'DOC_EOF'
// Shared order types and labels for the website.
export type OrderView = {
  reference: string;
  status: string;
  serviceType: "airtime" | "data";
  network: "mtn" | "airtel" | "glo" | "9mobile";
  planName: string | null;
  planId?: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  createdAt: string;
  expiresAt?: string;
  failureReason?: string | null;
  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;
  delivery?: { status: string; providerReference: string | null; requestId: string; token: string | null; message: string | null } | null;
  refund?: { status: string; amount: string; txHash: string | null; explorerUrl: string | null } | null;
};

export const NETWORK_LABELS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };

export const STATUS_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Not paid", tone: "wait" },
  EXPIRED: { text: "Price expired", tone: "bad" },
  PAYMENT_PENDING: { text: "Payment in progress", tone: "wait" },
  PAYMENT_CONFIRMED: { text: "Paid, delivering", tone: "wait" },
  FULFILMENT_PENDING: { text: "Delivering", tone: "wait" },
  FULFILLED: { text: "Delivered", tone: "good" },
  FAILED: { text: "Failed, refunding", tone: "bad" },
  FLAGGED: { text: "Checking", tone: "wait" },
  REFUND_PENDING: { text: "Refunding", tone: "wait" },
  REFUNDED: { text: "Refunded", tone: "good" },
};

// Orders that can still change on their own (the page keeps checking them)
export function stillMoving(o: Pick<OrderView, "status" | "payment">) {
  if (["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"].includes(o.status)) return true;
  // A failed delivery after a confirmed payment is about to be refunded
  return o.status === "FAILED" && o.payment?.status === "CONFIRMED";
}

export function toneClass(tone: "wait" | "good" | "bad") {
  return tone === "good"
    ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "bad"
      ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
      : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200";
}

export const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
export const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

export function describe(o: OrderView) {
  const net = NETWORK_LABELS[o.network] ?? o.network;
  return o.serviceType === "data" ? `${net} ${o.planName ?? "data"}` : `${net} airtime ${naira(o.ngnAmount)}`;
}
DOC_EOF
cat > "backend/src/email/receipts.ts" <<'DOC_EOF'
// Emails customers get when an order finishes: a receipt when airtime or data
// is delivered, and a notice when a refund reaches their wallet.
// Never blocks the order: any email problem is only logged.
import { eq } from "drizzle-orm";
import { db } from "../db";
import { dataPlans, orders, users } from "../db/schema";
import { env } from "../env";
import { sendEmail } from "./index";
import { receiptEmail } from "./templates";

type Order = typeof orders.$inferSelect;

const NETWORKS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };
const usdc = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
const naira = (kobo: number) => `₦${(kobo / 100).toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
const localPhone = (phone: string) => (phone.startsWith("+234") ? `0${phone.slice(4)}` : phone);
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

async function send(order: Order, kind: "delivered" | "refunded", txHash?: string | null) {
  const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, order.userId)).limit(1);
  // Test accounts (example.com, .local) never get real emails
  if (!user || /@(example\.com|[^@]*\.local)$/i.test(user.email)) return;
  const [plan] = order.planId ? await db.select({ name: dataPlans.name }).from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1) : [];
  const what = order.serviceType === "data" ? `${NETWORKS[order.network] ?? order.network} data${plan ? `, ${plan.name}` : ""}` : `${NETWORKS[order.network] ?? order.network} airtime`;
  // BETTER_AUTH_URL is the website address users open
  const url = `${env.BETTER_AUTH_URL}/orders/${order.reference}`;
  const rows: [string, string][] = [
    ["Order", order.reference],
    ["What", what],
    ["Phone", localPhone(order.phone)],
    ["Value", naira(order.ngnAmountKobo)],
    [kind === "delivered" ? "Paid" : "Refunded", `${usdc(order.usdcAmountMicro)} USDC`],
    ["Date", lagos(new Date())],
  ];
  if (txHash) rows.push(["Transaction", txHash]);
  const message =
    kind === "delivered"
      ? receiptEmail({
          name: user.name,
          subject: `Receipt: ${what} for ${localPhone(order.phone)} (${order.reference})`,
          heading: `Your ${order.serviceType} was delivered.`,
          rows,
          note: "Keep this email as your receipt. If anything looks wrong, reply on WhatsApp with the order number.",
          url,
        })
      : receiptEmail({
          name: user.name,
          subject: `Refund sent: ${usdc(order.usdcAmountMicro)} USDC (${order.reference})`,
          heading: `We could not deliver this order, so your USDC is back in your dataonchain wallet.`,
          rows,
          note: "The refund is a transaction on Arc; you can open it from the order page.",
          url,
        });
  await sendEmail({ to: user.email, ...message });
}

export function sendOrderEmail(order: Order, kind: "delivered" | "refunded", txHash?: string | null): void {
  void send(order, kind, txHash).catch((err) => {
    console.error(`[email] ${kind} email for ${order.reference} failed:`, err instanceof Error ? err.message : err);
  });
}
DOC_EOF
cat > "frontend/src/app/account/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { Field, FormError, SubmitButton } from "@/components/AuthShell";
import { SupportLink } from "@/components/SupportLink";
import { authClient } from "@/lib/auth-client";

type Note = { tone: "good" | "bad"; text: string } | null;

function Message({ note }: { note: Note }) {
  if (!note) return null;
  if (note.tone === "bad") return <FormError message={note.text} />;
  return <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">{note.text}</p>;
}

const localPhone = (p?: string | null) => (p ? (p.startsWith("+234") ? `0${p.slice(4)}` : p) : "");

export default function AccountPage() {
  const router = useRouter();
  const { data: session, isPending, refetch } = authClient.useSession();
  const [profileNote, setProfileNote] = useState<Note>(null);
  const [passwordNote, setPasswordNote] = useState<Note>(null);
  const [busy, setBusy] = useState<"profile" | "password" | "signout" | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  if (isPending || !session) {
    return <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">Loading...</main>;
  }
  const { user } = session;

  async function saveProfile(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setProfileNote(null);
    const form = new FormData(e.currentTarget);
    setBusy("profile");
    const { error } = await authClient.updateUser({
      name: String(form.get("name")).trim(),
      phone: String(form.get("phone")).trim(),
    });
    setBusy(null);
    if (error) {
      setProfileNote({ tone: "bad", text: error.message ?? "Could not save your details." });
      return;
    }
    await refetch?.();
    setProfileNote({ tone: "good", text: "Saved." });
  }

  async function changePassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setPasswordNote(null);
    const formEl = e.currentTarget;
    const form = new FormData(formEl);
    const newPassword = String(form.get("new"));
    if (newPassword !== String(form.get("confirm"))) {
      setPasswordNote({ tone: "bad", text: "The two new passwords do not match." });
      return;
    }
    setBusy("password");
    const { error } = await authClient.changePassword({
      currentPassword: String(form.get("current")),
      newPassword,
      revokeOtherSessions: true,
    });
    setBusy(null);
    if (error) {
      setPasswordNote({ tone: "bad", text: error.message ?? "Could not change your password." });
      return;
    }
    formEl.reset();
    setPasswordNote({ tone: "good", text: "Password changed. You were signed out on your other devices." });
  }

  async function signOutEverywhere() {
    setBusy("signout");
    await authClient.revokeSessions();
    await authClient.signOut().catch(() => null);
    router.replace("/login");
  }

  const card = "mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900";

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Account settings</h1>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Your details</h2>
          <form onSubmit={saveProfile} className="mt-4 space-y-4">
            <div>
              <p className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Email</p>
              <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{user.email} (cannot be changed)</p>
            </div>
            <Field label="Full name" name="name" defaultValue={user.name} autoComplete="name" required />
            <Field label="Phone number" name="phone" type="tel" defaultValue={localPhone(user.phone)} autoComplete="tel" hint="Nigerian mobile number" required />
            <Message note={profileNote} />
            <SubmitButton busy={busy === "profile"}>Save details</SubmitButton>
          </form>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Change password</h2>
          <form onSubmit={changePassword} className="mt-4 space-y-4">
            <Field label="Current password" name="current" type="password" autoComplete="current-password" required />
            <Field label="New password" name="new" type="password" autoComplete="new-password" minLength={8} hint="At least 8 characters" required />
            <Field label="New password again" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
            <Message note={passwordNote} />
            <SubmitButton busy={busy === "password"}>Change password</SubmitButton>
          </form>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Devices</h2>
          <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            Lost a phone, or logged in on someone else&apos;s computer? Sign out everywhere, including here.
          </p>
          <button
            onClick={signOutEverywhere}
            disabled={busy === "signout"}
            className="mt-4 w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
          >
            {busy === "signout" ? "Signing out..." : "Sign out on all devices"}
          </button>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Delete your account</h2>
          <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            Move any USDC, EURC or cirBTC out of your wallets first. Then ask us on WhatsApp and we will close your account
            and delete your personal data, except records the law requires us to keep (see the{" "}
            <Link href="/privacy" className="underline">Privacy Policy</Link>).
          </p>
          <div className="mt-4">
            <SupportLink block message={`Hello dataonchain, please delete my account (${user.email}). I have moved my balance out.`}>
              Ask to delete my account
            </SupportLink>
          </div>
        </section>
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

type WalletResponse = { wallet: { address: string; network: string; testnet: boolean } };

export default function AddUsdcPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [wallet, setWallet] = useState<WalletResponse["wallet"] | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<WalletResponse>("/wallet")
      .then(async (r) => {
        setWallet(r.wallet);
        setQr(await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" }));
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Could not load your wallet."));
  }, [session]);

  async function copy() {
    if (!wallet) return;
    await navigator.clipboard.writeText(wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Add USDC</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Send USDC to your wallet address below. It shows in your balance within a minute.</p>

        {error ? <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
        {!wallet && !error ? <p className="mt-6 text-sm text-zinc-500">Loading your wallet...</p> : null}

        {wallet ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="rounded-xl border-2 border-red-300 bg-red-50 p-4 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <p className="font-semibold">Send only USDC on {wallet.network}.</p>
              <p className="mt-1">
                USDC sent on another network (Ethereum, Base, BNB Chain, Tron, Solana or any other), or any other token, may be lost
                for good. When you withdraw from an exchange or wallet, choose <strong>{wallet.network}</strong> as the network.
              </p>
            </div>

            <div className="flex flex-col items-center gap-4">
              {qr ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={qr} alt="QR code of your wallet address" width={240} height={240} className="rounded-lg border border-zinc-200 bg-white p-2 dark:border-zinc-700" />
              ) : (
                <div className="h-[240px] w-[240px] animate-pulse rounded-lg bg-zinc-100 dark:bg-zinc-800" />
              )}
              <div className="w-full">
                <p className="text-sm text-zinc-500">Your wallet address on {wallet.network}</p>
                <code className="mt-1 block break-all rounded-lg bg-zinc-100 px-3 py-2 font-mono text-sm text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100">
                  {wallet.address}
                </code>
                <button
                  onClick={copy}
                  className="mt-3 w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
                >
                  {copied ? "Copied" : "Copy address"}
                </button>
              </div>
            </div>

            <ul className="list-disc space-y-1 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
              <li>Check the first and last characters of the address after you paste it.</li>
              <li>Send a small amount first if you have not used this address before.</li>
              <li>You pay no network fee to receive. The sender pays their own network&apos;s fee.</li>
            </ul>

            {wallet.testnet ? (
              <div className="rounded-lg bg-amber-50 p-4 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <p className="font-semibold">Test network: get free test USDC</p>
                <ol className="mt-2 list-decimal space-y-1 pl-5">
                  <li>Copy your address above.</li>
                  <li>
                    Open{" "}
                    <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                      faucet.circle.com
                    </a>
                    .
                  </li>
                  <li>Choose USDC and Arc Testnet, paste your address and send.</li>
                </ol>
                <p className="mt-2">Test USDC has no real value.</p>
              </div>
            ) : null}
          </section>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/history/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, toneClass, usdc, type OrderView } from "@/lib/orders";

type History = { total: number; page: number; pageSize: number; orders: OrderView[] };

const FILTERS = [
  { value: "", label: "All" },
  { value: "delivered", label: "Delivered" },
  { value: "refunded", label: "Refunded" },
  { value: "failed", label: "Failed" },
  { value: "open", label: "In progress" },
];

export default function HistoryPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<History | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    let stop = false;
    api<History>(`/history?page=${page}&status=${status}`)
      .then((r) => {
        if (!stop) {
          setData(r);
          setError(null);
        }
      })
      .catch((e: unknown) => !stop && setError(e instanceof Error ? e.message : "Could not load your orders."));
    return () => {
      stop = true;
    };
  }, [session, page, status]);

  const pages = data ? Math.max(1, Math.ceil(data.total / data.pageSize)) : 1;

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-2xl">
        <header className="flex items-center justify-between">
          <Link href="/dashboard" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/dashboard" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Back to dashboard
          </Link>
        </header>

        <div className="mt-8 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Order history</h1>
            {data ? <p className="mt-1 text-sm text-zinc-500">{data.total.toLocaleString("en-US")} order(s)</p> : null}
          </div>
          <a
            href="/api/history.csv"
            download
            className="rounded-lg border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Download CSV
          </a>
        </div>

        <div className="mt-4 flex flex-wrap gap-2">
          {FILTERS.map((f) => (
            <button
              key={f.value}
              onClick={() => {
                setStatus(f.value);
                setPage(1);
              }}
              className={`rounded-full border px-3 py-1 text-sm ${
                status === f.value
                  ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
                  : "border-zinc-300 text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
          {error ? <p className="m-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
          {!data && !error ? <p className="p-4 text-sm text-zinc-500">Loading...</p> : null}
          {data && data.orders.length === 0 ? <p className="p-4 text-sm text-zinc-500">No orders here yet.</p> : null}
          {data && data.orders.length > 0 ? (
            <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {data.orders.map((o) => {
                const label = STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" as const };
                return (
                  <li key={o.reference}>
                    <Link href={`/orders/${o.reference}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:opacity-80">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{describe(o)}</p>
                        <p className="text-xs text-zinc-500">
                          {o.phone} · {naira(o.ngnAmount)} · {usdc(o.usdcAmount)} USDC · {new Date(o.createdAt).toLocaleString("en-NG")}
                        </p>
                      </div>
                      <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
                    </Link>
                  </li>
                );
              })}
            </ul>
          ) : null}
        </section>

        {data && pages > 1 ? (
          <div className="mt-4 flex items-center justify-between text-sm text-zinc-500">
            <span>
              Page {data.page} of {pages}
            </span>
            <div className="flex gap-2">
              <button
                disabled={page <= 1}
                onClick={() => setPage((p) => p - 1)}
                className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300"
              >
                Previous
              </button>
              <button
                disabled={page >= pages}
                onClick={() => setPage((p) => p + 1)}
                className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300"
              >
                Next
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/app/privacy/page.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Privacy Policy · dataonchain" };

export default function PrivacyPage() {
  return (
    <LegalPage
      title="Privacy Policy"
      updated="27 October 2026"
      intro={
        <p>
          This policy explains what personal data dataonchain collects, why, who it is shared with, how long it is kept, and
          the rights you have under the Nigeria Data Protection Act 2023. dataonchain is the data controller for your data.
          Our registration with the Corporate Affairs Commission is in progress; once it is complete, our registered name and
          address will appear here.
        </p>
      }
    >
      <h2>1. What we collect</h2>
      <ul>
        <li><strong>Account details:</strong> your name, email address, Nigerian phone number and password. Your password is stored only in scrambled (hashed) form; we cannot read it.</li>
        <li><strong>Wallet details:</strong> the addresses of the wallets created for you on Arc and on other networks, and their balances.</li>
        <li><strong>Orders:</strong> the phone numbers you top up, the network, the plan or amount, prices, and the delivery reference from our provider.</li>
        <li><strong>Transactions:</strong> your payments, refunds, transfers between networks and swaps, including their blockchain transaction records.</li>
        <li><strong>Technical data:</strong> your IP address and browser type when you log in or use the site, kept with your login session and in server logs for security.</li>
        <li><strong>Messages:</strong> what you send us on WhatsApp when you ask for help.</li>
      </ul>
      <p>We do not collect your BVN, NIN, bank details or card details at this stage.</p>

      <h2>2. Why we use it, and on what basis</h2>
      <ul>
        <li><strong>To provide the service</strong> (create your account and wallets, process purchases, refunds, transfers and swaps, send account emails): this is necessary to perform our contract with you.</li>
        <li><strong>To keep the service and users safe</strong> (prevent fraud and abuse, secure accounts, investigate problems): our legitimate interest in running a safe service.</li>
        <li><strong>To meet legal obligations</strong> (keeping financial records, responding to lawful requests from authorities): legal obligation.</li>
        <li><strong>To improve dataonchain</strong> (understanding how the service is used, fixing problems): our legitimate interest. We do not sell your data.</li>
        <li><strong>Marketing:</strong> we do not send marketing messages. If we ever do, we will ask for your consent first, and you can withdraw it at any time.</li>
      </ul>
      <p>We do not make decisions about you based only on automated processing that have legal or similarly significant effects.</p>

      <h2>3. Who we share it with</h2>
      <p>We share only what each provider needs to do its job for us:</p>
      <ul>
        <li><strong>Circle</strong> (United States): wallets, transfers between networks and swaps. Receives wallet and transaction details.</li>
        <li><strong>Our airtime and data provider</strong> (currently VTpass, Nigeria): receives the phone number, network and amount for each purchase.</li>
        <li><strong>Resend</strong> (United States): sends our emails (confirmation, password reset). Receives your name and email.</li>
        <li><strong>Render</strong> (servers in the European Union), <strong>Vercel</strong> (website hosting) and our cloud database provider: store and run the service, and so hold the data described above.</li>
        <li><strong>Authorities</strong>, when the law requires it.</li>
      </ul>

      <h2>4. Blockchains are public</h2>
      <p>
        Transactions on Arc and the other networks are recorded on public blockchains. Anyone can see wallet addresses,
        amounts and times. They do not show your name, email or phone number, but these records are permanent: neither we
        nor anyone else can change or delete them.
      </p>

      <h2>5. Transfers outside Nigeria</h2>
      <p>
        Some of our providers store or process data outside Nigeria (see section 3). We use providers that protect personal
        data to a standard similar to Nigerian law, and we transfer only what is needed to provide the service you asked for.
      </p>

      <h2>6. How long we keep it</h2>
      <ul>
        <li>Account and wallet details: while your account is open, and then for as long as the law requires us to keep financial records.</li>
        <li>Orders and transactions: for as long as the law requires us to keep financial records, then deleted or anonymised.</li>
        <li>Login sessions: until they expire or you log out. Server logs: for a short period, for security.</li>
        <li>WhatsApp messages: as long as needed to resolve your request.</li>
      </ul>

      <h2>7. Your rights</h2>
      <p>Under the Nigeria Data Protection Act 2023 you have the right to:</p>
      <ul>
        <li>be told how your data is used (this policy);</li>
        <li>get a copy of your personal data;</li>
        <li>have wrong or out of date data corrected;</li>
        <li>have your data deleted when it is no longer needed or there is no lawful basis to keep it (records we must keep by law, and public blockchain records, cannot be deleted);</li>
        <li>restrict or object to some uses of your data;</li>
        <li>withdraw consent where we rely on it;</li>
        <li>receive your data in a common electronic format;</li>
        <li>complain to the Nigeria Data Protection Commission (NDPC).</li>
      </ul>
      <p>To use any of these rights, message us on WhatsApp from the phone number on your account, or tell us your account email. We may need to confirm it is you before we act.</p>

      <h2>8. How we protect it</h2>
      <ul>
        <li>All connections to the website are encrypted (HTTPS).</li>
        <li>Passwords are hashed, emails are confirmed, and every wallet transfer needs your instruction or is a refund to you.</li>
        <li>Wallet keys are held by Circle&apos;s wallet service, never in our database.</li>
        <li>Access to our systems is limited and protected, and admin actions are logged.</li>
      </ul>
      <p>
        If a data breach is likely to put your rights at high risk, we will report it to the NDPC within 72 hours of
        learning about it, and tell you without delay what happened and what you should do.
      </p>

      <h2>9. Cookies and browser storage</h2>
      <p>
        We use one cookie to keep you logged in, and your browser remembers whether you chose light or dark mode. We do not
        use advertising or tracking cookies.
      </p>

      <h2>10. Children</h2>
      <p>dataonchain is not for anyone under 18. We do not knowingly collect data from children; if we learn we have, we delete it.</p>

      <h2>11. Changes to this policy</h2>
      <p>We may update this policy. The date at the top shows the latest version, and we will tell you on the website about significant changes.</p>
    </LegalPage>
  );
}
DOC_EOF
cat > "frontend/src/app/refund-policy/page.tsx" <<'DOC_EOF'
import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Refund Policy · dataonchain" };

export default function RefundPolicyPage() {
  return (
    <LegalPage
      title="Refund Policy"
      updated="27 October 2026"
      intro={
        <p>
          When you pay for something we cannot deliver, you get your money back automatically, without having to ask. This
          page explains when refunds happen, how long they take, and the few cases where a refund is not possible.
        </p>
      }
    >
      <h2>1. Automatic refunds</h2>
      <p>You are refunded in full, automatically, when:</p>
      <ul>
        <li>the mobile network or our provider cannot deliver the airtime or data you paid for;</li>
        <li>our provider confirms it never received or completed the purchase;</li>
        <li>an order that was under review is confirmed as not delivered.</li>
      </ul>
      <p>
        The full USDC amount you paid goes back to your dataonchain wallet on Arc, usually within a minute. The order page
        shows each step, and the refund transaction, which you can open in the Arc explorer.
      </p>

      <h2>2. Orders under review</h2>
      <p>
        Sometimes a network takes a long time to confirm a delivery. The order then shows Checking while we confirm with
        our provider. It always ends as either delivered or refunded. This can take longer than usual, occasionally up to a
        few days.
      </p>

      <h2>3. Payments that did not go through</h2>
      <p>
        If your payment fails, no USDC leaves your wallet, so there is nothing to refund. If a payment was interrupted
        (for example by a connection problem), we check it with Circle automatically: the order then either continues or
        is refunded.
      </p>

      <h2>4. When a refund is not possible</h2>
      <ul>
        <li><strong>Wrong but valid phone number:</strong> airtime or data delivered to a valid number cannot be taken back. Please check the number and network before you pay.</li>
        <li><strong>Delivered orders:</strong> once airtime or data is delivered, it cannot be cancelled or exchanged.</li>
        <li><strong>Problems after delivery</strong> (for example how a network uses or expires your data): please contact your mobile network.</li>
        <li><strong>Circle&apos;s transfer fees</strong> on transfers between networks are paid to Circle and are not refundable. Any unused part of the fee stays in your bridge balance and is used for your next transfer.</li>
        <li><strong>Swaps</strong> that completed at or above the minimum shown cannot be reversed. Swaps that would give less than that minimum are cancelled automatically, and nothing is taken.</li>
      </ul>

      <h2>5. Transfers between networks</h2>
      <p>
        If a transfer to another network fails before it completes, your USDC stays in your wallet or in your bridge
        balance, and is used for your next transfer. If you think a transfer went wrong, contact us with the transfer
        details from your Send to another network page.
      </p>

      <h2>6. How refunds are paid</h2>
      <p>
        Refunds are paid in the same token you paid with (USDC) to your dataonchain wallet on Arc. We do not pay refunds in
        cash, in naira or to a bank account.
      </p>

      <h2>7. If you think something is wrong</h2>
      <p>
        Message us on WhatsApp with your order reference (it starts with ARC and is shown on the order page). The Report a
        problem button on each order page fills it in for you. We will look into it and reply as soon as we can.
      </p>
    </LegalPage>
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
      updated="27 October 2026"
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

      <h2>2. Public testing</h2>
      <p>dataonchain is currently in public testing on Arc Testnet. During this period:</p>
      <ul>
        <li>USDC, EURC and cirBTC on Arc Testnet are test tokens with no real value.</li>
        <li>Airtime and data purchases go through our provider&apos;s test environment and are not delivered to real phones.</li>
        <li>Features, limits and fees may change at any time, and the service may be paused or reset.</li>
      </ul>
      <p>Do not send real money or real tokens to any dataonchain wallet while we are in testing.</p>

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
cat > "frontend/src/components/LegalPage.tsx" <<'DOC_EOF'
import Link from "next/link";
import type { ReactNode } from "react";
import { SupportLink } from "@/components/SupportLink";

const LEGAL = [
  { href: "/terms", label: "Terms of Service" },
  { href: "/privacy", label: "Privacy Policy" },
  { href: "/refund-policy", label: "Refund Policy" },
];

// Shared frame for the Terms, Privacy and Refund pages.
export function LegalPage({ title, updated, intro, children }: { title: string; updated: string; intro: ReactNode; children: ReactNode }) {
  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-3xl">
        <header className="flex items-center justify-between">
          <Link href="/" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Home
          </Link>
        </header>

        <nav className="mt-8 flex flex-wrap gap-2 text-sm">
          {LEGAL.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="rounded-full border border-zinc-300 px-3 py-1 text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
            >
              {l.label}
            </Link>
          ))}
        </nav>

        <article className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 sm:p-10 dark:border-zinc-800 dark:bg-zinc-900 [&_h2]:mt-10 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-zinc-900 dark:[&_h2]:text-zinc-50 [&_li]:mt-1.5 [&_p]:mt-3 [&_p]:leading-relaxed [&_ul]:mt-3 [&_ul]:list-disc [&_ul]:space-y-1 [&_ul]:pl-5 text-zinc-700 dark:text-zinc-300">
          <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h1>
          <p className="!mt-1 text-sm text-zinc-500">Last updated {updated}</p>
          <div className="mt-6 text-base">{intro}</div>
          {children}
          <h2>Contact us</h2>
          <p>
            Questions about this page, your account or an order: <SupportLink />. Please include your order reference if
            it is about a purchase.
          </p>
        </article>
      </div>
    </main>
  );
}
DOC_EOF
cat > "frontend/src/components/SupportLink.tsx" <<'DOC_EOF'
import type { ReactNode } from "react";
import { whatsappUrl } from "@/lib/support";

// "Chat with us on WhatsApp", optionally with a message already typed in
// (for example the order reference, so we can help straight away).
export function SupportLink({ message, children, block = false }: { message?: string; children?: ReactNode; block?: boolean }) {
  return (
    <a
      href={whatsappUrl(message)}
      target="_blank"
      rel="noopener noreferrer"
      className={
        block
          ? "flex w-full items-center justify-center gap-2 rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
          : "inline-flex items-center gap-1.5 font-medium text-emerald-700 hover:underline dark:text-emerald-400"
      }
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" className="shrink-0">
        <path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2c-1.6 0-3.1-.4-4.4-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8-.2-.1-.4-.1-.6.1l-.8 1c-.1.2-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.2-.4.2-.4.7-1.3.1-.2 0-.3 0-.5l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5c-.2 0-.5.1-.7.3-.2.3-.9.9-.9 2.2s.9 2.5 1 2.7c.1.2 1.8 2.8 4.4 3.9 1.6.7 2.3.8 3.1.6.5-.1 1.5-.6 1.7-1.2.2-.6.2-1.1.2-1.2-.1-.1-.3-.2-.5-.3z" />
      </svg>
      {children ?? "Chat with us on WhatsApp"}
    </a>
  );
}
DOC_EOF
cat > "frontend/src/lib/support.ts" <<'DOC_EOF'
// Support is on WhatsApp. Links open a chat with an optional message already typed.
export const SUPPORT_WHATSAPP = "2348038526981";
export const SUPPORT_WHATSAPP_DISPLAY = "+234 803 852 6981";

export function whatsappUrl(message?: string): string {
  const base = `https://wa.me/${SUPPORT_WHATSAPP}`;
  return message ? `${base}?text=${encodeURIComponent(message)}` : base;
}
DOC_EOF
green "OK"

# --- 2. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build) || fail "Backend check failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Logins, account page, history and the admin dashboard"
OUTBOX="$(mktemp)"
(cd backend && ADMIN_EMAIL=admin-smoke@example.com ADMIN_URL=http://localhost:3001 EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 WORKER_ENABLED=false exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
stop_api() { kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"; }
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "Login test failed (details above). Nothing was committed. Paste the output to Claude."
fi
if ! (cd backend && ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/admin-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "Admin test failed (details above). Nothing was committed."
fi
stop_api
green "OK"

step "Delivery: make sure it still works (receipts are skipped for test accounts)"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
green "OK"

step "Website: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 3. Commit, push ---------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Legal pages, WhatsApp support, Add USDC with QR, account settings, email receipts, buy again, order history and CSV"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"accountTools":true' || fail "The API did not come up. Check Events and Logs on Render."
wait_for "the website on Vercel" "$PROD_FRONTEND/privacy" 'Nigeria Data Protection Act' 30 || yellow "The website did not show the new pages yet. Check vercel.com."

echo
green "Script 27 complete."
echo "  Legal:    $PROD_FRONTEND/terms  $PROD_FRONTEND/privacy  $PROD_FRONTEND/refund-policy"
echo "  Account:  $PROD_FRONTEND/account    Add USDC: $PROD_FRONTEND/add-usdc    History: $PROD_FRONTEND/history"
