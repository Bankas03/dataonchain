#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 41: fixes from the audit of the treasury withdrawals
#
#   - Withdrawals keep back enough for every refund that is still owed: also
#     failed orders that were paid and whose refund has not gone out yet
#   - TREASURY_RESERVE_USDC=0 on Render no longer stops the API from starting
#   - Overview: a withdrawal stuck with Circle over 30 minutes shows under
#     "Needs attention"; low treasury alerts open the Treasury page
#   - Treasury page explains the cash out route correctly: To Base (to your own
#     Base wallet), then Send on Base to your exchange
#   No database change.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/41_treasury_fixes.sh
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
[[ -f backend/src/treasury/withdraw.ts ]] || fail "Run this from ~/dataonchain after script 40"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/41_treasury_fixes.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
cat > "admin/src/app/(dash)/treasury/page.tsx" <<'DOC_EOF'
"use client";

import { useState, type FormEvent } from "react";
import { Badge, Card, DefList, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { token as fmt, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKENS: Token[] = ["USDC", "EURC", "cirBTC"];
type Withdrawal = {
  id: string;
  status: string;
  token: Token;
  amount: string;
  toAddress: string;
  txUrl: string | null;
  error: string | null;
  codeExpiresAt: string | null;
  createdAt: string;
};
type View = {
  treasuryAddress: string;
  payoutAddress: string | null;
  payoutProblem: string | null;
  payoutUrl: string | null;
  reserveUsdc: number;
  balances: Record<Token, string> | null;
  available: Record<Token, string> | null;
  heldBack: { reserve: string; owed: string } | null;
  balanceError: string | null;
  withdrawals: Withdrawal[];
};

const input =
  "w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100";
const button = "rounded-lg bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-800 disabled:opacity-50";

export default function TreasuryPage() {
  const { data, error, reload } = useLoad<View>("/treasury");
  const [token, setToken] = useState<Token>("USDC");
  const [amount, setAmount] = useState("");
  const [pending, setPending] = useState<Withdrawal | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ tone: "good" | "bad" | "wait"; text: string } | null>(null);

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;

  async function start(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMessage(null);
    try {
      const r = await post<{ withdrawal: Withdrawal }>("/treasury/withdraw", { token, amount: amount.trim() });
      setPending(r.withdrawal);
      setCode("");
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not start the withdrawal." });
    } finally {
      setBusy(false);
    }
  }

  async function confirm(e: FormEvent) {
    e.preventDefault();
    if (!pending) return;
    setBusy(true);
    setMessage(null);
    try {
      const r = await post<{ withdrawal: Withdrawal }>(`/treasury/withdraw/${pending.id}/confirm`, { code });
      const w = r.withdrawal;
      setPending(null);
      setAmount("");
      setMessage(
        w.status === "COMPLETE"
          ? { tone: "good", text: `Sent ${fmt(w.amount)} ${w.token} to your payout address.` }
          : w.status === "FAILED"
            ? { tone: "bad", text: `The withdrawal failed: ${w.error ?? "unknown reason"}. Nothing left the treasury.` }
            : { tone: "wait", text: "Sent to Circle. It usually finishes within a minute; refresh this page to see it complete." },
      );
      reload();
    } catch (err) {
      const text = err instanceof Error ? err.message : "Could not confirm.";
      setMessage({ tone: "bad", text });
      if (/start again|Start a new one|Nothing was sent/i.test(text)) setPending(null);
    } finally {
      setBusy(false);
    }
  }

  const free = data.available?.[token];

  return (
    <>
      <PageTitle
        title="Treasury"
        subtitle="Fees and payments collect here. Withdraw what is not needed for refunds, to your payout address only."
        right={
          <button onClick={reload} className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900">
            Refresh
          </button>
        }
      />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Balances">
          {data.balanceError ? <Notice>{data.balanceError}</Notice> : null}
          {data.balances && data.available ? (
            <Table head={["Token", "In the treasury", "Can withdraw"]}>
              {TOKENS.map((t) => (
                <tr key={t}>
                  <Td>{t}</Td>
                  <Td className="tabular-nums">{fmt(data.balances![t])}</Td>
                  <Td className="tabular-nums font-medium">{fmt(data.available![t])}</Td>
                </tr>
              ))}
            </Table>
          ) : null}
          {data.heldBack ? (
            <p className="mt-3 text-xs text-zinc-500">
              Kept back from USDC: the reserve of {fmt(data.heldBack.reserve)} USDC (TREASURY_RESERVE_USDC), {fmt(data.heldBack.owed)} USDC for open orders that may
              still need a refund, and 0.05 USDC for the network fee.
            </p>
          ) : null}
        </Card>

        <Card title="Payout address">
          {data.payoutAddress ? (
            <DefList
              items={[
                ["Sends to", <ExtLink key="p" href={data.payoutUrl}><span className="font-mono text-xs">{data.payoutAddress}</span></ExtLink>],
                ["Network", "Arc"],
              ]}
            />
          ) : (
            <Notice tone="warn">{data.payoutProblem}</Notice>
          )}
          <p className="mt-3 text-xs text-zinc-500">
            Set on Render as TREASURY_PAYOUT_ADDRESS. It cannot be changed here, so nobody who gets into this dashboard can send the treasury anywhere else.
            It must be a wallet that works on Arc. Your own dataonchain wallet works: to cash out, use To Base on its dashboard (to your own Base
            wallet), then Send on Base to your exchange&apos;s USDC deposit address on Base.
          </p>
        </Card>
      </div>

      {data.payoutAddress && data.balances ? (
        <Card title="Withdraw" className="mt-6">
          {!pending ? (
            <form onSubmit={start} className="max-w-md space-y-4">
              <div className="flex gap-2">
                {TOKENS.map((t) => (
                  <button
                    type="button"
                    key={t}
                    onClick={() => {
                      setToken(t);
                      setAmount("");
                    }}
                    className={`rounded-lg border px-3 py-1.5 text-sm font-medium ${
                      token === t
                        ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
                        : "border-zinc-300 text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
                    }`}
                  >
                    {t}
                  </button>
                ))}
              </div>
              <div>
                <div className="flex items-center justify-between">
                  <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                    Amount of {token}
                  </label>
                  {free && Number(free) > 0 ? (
                    <button type="button" onClick={() => setAmount(free)} className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400">
                      Use all I can ({fmt(free)})
                    </button>
                  ) : null}
                </div>
                <input id="amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" className={`mt-1 ${input}`} />
              </div>
              <button type="submit" disabled={busy || !amount.trim()} className={button}>
                {busy ? "Checking..." : "Continue"}
              </button>
              <p className="text-xs text-zinc-500">Next, we email a code to the admin email. Nothing moves until you enter it.</p>
            </form>
          ) : (
            <form onSubmit={confirm} className="max-w-md space-y-4">
              <p className="text-sm text-zinc-700 dark:text-zinc-300">
                Withdraw <b>{fmt(pending.amount)} {pending.token}</b> to <span className="break-all font-mono text-xs">{pending.toAddress}</span> on Arc.
              </p>
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
                  className={`mt-1 tracking-widest ${input}`}
                />
                <p className="mt-1 text-xs text-zinc-500">It expires in 10 minutes.</p>
              </div>
              <div className="flex gap-2">
                <button type="submit" disabled={busy || code.replace(/\s/g, "").length !== 6} className={button}>
                  {busy ? "Sending..." : "Confirm and withdraw"}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => setPending(null)}
                  className="rounded-lg border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
                >
                  Cancel
                </button>
              </div>
            </form>
          )}
          {message ? (
            <div className="mt-4">
              <Notice tone={message.tone}>{message.text}</Notice>
            </div>
          ) : null}
        </Card>
      ) : null}

      <Card title="Past withdrawals" className="mt-6">
        <Table head={["Amount", "To", "Status", "Date"]} empty={data.withdrawals.length === 0}>
          {data.withdrawals.map((w) => (
            <tr key={w.id}>
              <Td>
                <ExtLink href={w.txUrl}>
                  {fmt(w.amount)} {w.token}
                </ExtLink>
              </Td>
              <Td className="font-mono text-xs">{`${w.toAddress.slice(0, 6)}...${w.toAddress.slice(-4)}`}</Td>
              <Td>
                <Badge status={w.status} />
                {w.error && w.status !== "CANCELLED" ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{w.error}</span> : null}
              </Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(w.createdAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
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

    // Many wrong codes sent at the same moment still count: the login ends
    {
      const raceBefore = (await mails()).length;
      const start = await call("/login", "POST", { email: adminEmail, password: PASSWORD });
      check(start.status === 200, "a second login asks for a code", start.body);
      const raceMail = await waitForMail("login code", raceBefore);
      const raceCode = /\b(\d{6})\b/.exec(raceMail.text)?.[1];
      const bad = raceCode === "000000" ? "111111" : "000000";
      await Promise.all(Array.from({ length: 8 }, () => call("/login/code", "POST", { code: bad })));
      const late = await call("/login/code", "POST", { code: raceCode });
      check(late.status === 401, "8 wrong codes at once end the login (the limit is 5)", late.body);
      check((await call("/me")).status === 200, "the first session is still logged in");
    }

    // Every page of the dashboard answers
    const overview = await call("/overview");
    check(overview.status === 200 && typeof (overview.body.users as { total?: unknown })?.total === "number", "overview loads", overview.body);
    check(Array.isArray(overview.body.days) && (overview.body.days as unknown[]).length === 14, "overview has 14 days of volume");
    check(typeof (overview.body.deposits as { count30?: unknown })?.count30 === "number", "overview counts deposits", overview.body.deposits);
    check(typeof (overview.body.sends as { complete30?: unknown })?.complete30 === "number", "overview counts sends", overview.body.sends);
    for (const path of ["/users", "/orders", "/orders?status=open", "/refunds", "/bridge", "/swaps", "/sends", "/deposits", "/deposits?network=base", "/treasury", "/providers", "/activity", "/settings", "/sessions"]) {
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

    // Five wrong passwords lock the login, even for the right password, also
    // when they are all sent at the same moment
    await Promise.all(Array.from({ length: 6 }, (_, i) => call("/login", "POST", { email: adminEmail, password: `wrong ${i} password` })));
    const locked = await call("/login", "POST", { email: adminEmail, password: PASSWORD2 });
    check(locked.status === 423, "wrong passwords sent at once still lock the login", locked.body);
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
  sends,
  deposits,
  swaps,
  treasuryWithdrawals,
  users,
  vtuTransactions,
  walletSweeps,
  wallets,
  BRIDGE_STATUSES,
  REFUND_STATUSES,
  SWAP_STATUSES,
  SEND_STATUSES,
} from "../db/schema";
import { env } from "../env";
import { chainByKey, openChains, type BridgeChain } from "../bridge/chains";
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

// A transaction link on the explorer of the network it happened on
function txOn(chainKey: string, hash: string | null | undefined): string | null {
  const chain = safeChain(chainKey);
  return chain && hash ? `${chain.explorerTx}${hash}` : null;
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

  // Sends out and deposits in, last 30 days (USDC totals; other tokens counted only)
  const sendRows30 = await db
    .select({ token: sends.token, amount: sends.amount })
    .from(sends)
    .where(and(eq(sends.status, "COMPLETE"), gte(sends.createdAt, new Date(d30))));
  const depositRows30 = await db
    .select({ token: deposits.token, amount: deposits.amount, chain: deposits.chain })
    .from(deposits)
    .where(gte(deposits.receivedAt, new Date(d30)));
  const usdcSum = (rows: { token: string; amount: string }[]) =>
    rows.filter((r) => r.token === "USDC").reduce((sum, r) => sum + (Number(r.amount) || 0), 0).toFixed(2);
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
  const [sendStuck] = await db
    .select({ n: count() })
    .from(sends)
    .where(and(inArray(sends.status, ["SENDING", "SENT"]), sql`${sends.updatedAt} < ${Date.now() - 30 * 60_000}`));
  if (sendStuck?.n) issues.push({ text: `${sendStuck.n} send(s) waiting for Circle over 30 minutes`, href: "/sends?status=SENT" });
  if (treasuryBalances && Number(treasuryBalances.USDC) < LOW_TREASURY_USDC) {
    issues.push({ text: `Treasury is low: ${treasuryBalances.USDC} USDC (refunds need USDC)`, href: "/treasury" });
  }
  if (treasury.status === "rejected") issues.push({ text: "Could not read the treasury balance from Circle", href: "/treasury" });
  const [withdrawStuck] = await db
    .select({ n: count() })
    .from(treasuryWithdrawals)
    .where(and(inArray(treasuryWithdrawals.status, ["SENDING", "SENT"]), sql`${treasuryWithdrawals.updatedAt} < ${Date.now() - 30 * 60_000}`));
  if (withdrawStuck?.n) issues.push({ text: `${withdrawStuck.n} treasury withdrawal(s) waiting for Circle over 30 minutes`, href: "/treasury" });
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
    sends: { complete30: sendRows30.length, usdc30: usdcSum(sendRows30) },
    deposits: {
      count30: depositRows30.length,
      usdc30: usdcSum(depositRows30),
      base30: depositRows30.filter((r) => r.chain === "base").length,
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
  const sendRows = await db
    .select()
    .from(sends)
    .where(and(eq(sends.userId, id), notInArray(sends.status, ["AWAITING_CODE"])))
    .orderBy(desc(sends.createdAt))
    .limit(20);
  const depositRows = await db.select().from(deposits).where(eq(deposits.userId, id)).orderBy(desc(deposits.receivedAt)).limit(20);
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
    sends: sendRows.map(sendRow),
    deposits: depositRows.map((d) => ({
      id: d.id,
      token: d.token,
      amount: d.amount,
      network: safeChain(d.chain)?.label ?? d.chain,
      fromAddress: d.sourceAddress,
      txUrl: txOn(d.chain, d.txHash),
      emailed: Boolean(d.notifiedAt),
      receivedAt: d.receivedAt.toISOString(),
    })),
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
      failAndRefund: order.status === "FLAGGED" && confirmedPayment && !refund,
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
// Sends to other wallets on Arc
// ---------------------------------------------------------------------------
function sendRow(s: typeof sends.$inferSelect) {
  return {
    id: s.id,
    status: s.status,
    token: s.token,
    amount: s.amount,
    toAddress: s.toAddress,
    network: safeChain(s.chain)?.label ?? s.chain,
    // The explorer of the network the send was on (Arc or Base)
    txUrl: txOn(s.chain, s.txHash),
    error: s.error,
    createdAt: s.createdAt.toISOString(),
  };
}

// Deposits: money that arrived in users' wallets from outside, newest first
export async function listDepositsAdmin(chain: string | undefined, page: number) {
  const where = chain === "arc" || chain === "base" ? eq(deposits.chain, chain) : undefined;
  const [total] = await db.select({ n: count() }).from(deposits).innerJoin(users, eq(deposits.userId, users.id)).where(where);
  const rows = await db
    .select({ d: deposits, email: users.email })
    .from(deposits)
    .innerJoin(users, eq(deposits.userId, users.id))
    .where(where)
    .orderBy(desc(deposits.receivedAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    deposits: rows.map(({ d, email }) => ({
      id: d.id,
      userId: d.userId,
      email,
      token: d.token,
      amount: d.amount,
      network: safeChain(d.chain)?.label ?? d.chain,
      fromAddress: d.sourceAddress,
      txUrl: txOn(d.chain, d.txHash),
      emailed: Boolean(d.notifiedAt),
      receivedAt: d.receivedAt.toISOString(),
    })),
  };
}

export async function listSendsAdmin(status: string | undefined, page: number) {
  const where =
    status && (SEND_STATUSES as readonly string[]).includes(status)
      ? eq(sends.status, status as (typeof SEND_STATUSES)[number])
      : notInArray(sends.status, ["AWAITING_CODE"]);
  const [total] = await db.select({ n: count() }).from(sends).innerJoin(users, eq(sends.userId, users.id)).where(where);
  const rows = await db
    .select({ s: sends, email: users.email })
    .from(sends)
    .innerJoin(users, eq(sends.userId, users.id))
    .where(where)
    .orderBy(desc(sends.createdAt))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  return {
    total: total?.n ?? 0,
    page,
    pageSize: PAGE_SIZE,
    sends: rows.map(({ s, email }) => ({ ...sendRow(s), userId: s.userId, email })),
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
      bridgeChains: env.BRIDGE_ENABLED ? openChains().map((c) => c.label) : [],
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
import { ensureChainWallet, listChainWallets } from "./bridge/wallets";
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, deposits: true, baseSend: true, totalBalance: true, audit2: true, adminDeposits: true, audit3: true, treasuryWithdraw: true, audit4: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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
    // USDC on each network the user has a wallet on (Arc first), for the total
    networks: [
      { chain: "arc", label: NETWORK_NAMES[wallet.blockchain] ?? wallet.blockchain, usdc },
      ...(await otherNetworks(user.id)),
    ],
  });
});

// The user's USDC on Base (and any other open network) where they have a wallet
async function otherNetworks(userId: string): Promise<{ chain: string; label: string; usdc: string | null }[]> {
  if (!env.BRIDGE_ENABLED) return [];
  try {
    const list = await listChainWallets(userId);
    return list
      .filter((w) => isOpenChain(w.chain))
      .map((w) => ({
        chain: w.chain,
        label: w.chainLabel,
        usdc: w.balanceMicro === null ? null : (w.balanceMicro / 1_000_000).toFixed(6).replace(/\.?0+$/, ""),
      }));
  } catch {
    return [];
  }
}

// How many rows a list returns: 20 unless asked (the history page asks for 100)
function listLimit(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? Math.min(n, 100) : 20;
}

// USDC that arrived from outside dataonchain, newest first
app.get("/api/deposits", requireAuth, async (c) => {
  const { user } = c.get("auth");
  return c.json({ deposits: await listDeposits(user.id, listLimit(c.req.query("limit"))) });
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
  return c.json({ orders: await listOrders(user.id, listLimit(c.req.query("limit"))) });
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
  return c.json({ transfers: await listBridges(user.id, listLimit(c.req.query("limit"))) });
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
  return c.json({ swaps: await listSwaps(user.id, listLimit(c.req.query("limit"))) });
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
  return c.json({ sends: await listSends(user.id, listLimit(c.req.query("limit"))) });
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

// Like optionalNumber, but 0 is allowed (for example a reserve of nothing)
function optionalAmount(name: string): number | undefined {
  const raw = process.env[name]?.trim();
  if (!raw) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be 0 or more`);
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
  // Treasury withdrawals from the admin dashboard: they only ever go to this
  // address (on Arc), set on Render, never typed in the dashboard. Unset = off.
  TREASURY_PAYOUT_ADDRESS: process.env.TREASURY_PAYOUT_ADDRESS?.trim().toLowerCase() || undefined,
  // USDC that always stays in the treasury for refunds, on top of open orders
  TREASURY_RESERVE_USDC: optionalAmount("TREASURY_RESERVE_USDC") ?? 10,
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
  // Sends to other Arc wallets: limits per send and per 24 hours
  SEND_MAX_STABLE: optionalNumber("SEND_MAX_STABLE") ?? 50, // USDC or EURC per send
  SEND_DAILY_STABLE: optionalNumber("SEND_DAILY_STABLE") ?? 100, // per token, per 24 hours
  SEND_MAX_CIRBTC: optionalNumber("SEND_MAX_CIRBTC") ?? 0.0005,
  SEND_DAILY_CIRBTC: optionalNumber("SEND_DAILY_CIRBTC") ?? 0.001,
  SEND_DAILY_COUNT: wholeNumber("SEND_DAILY_COUNT", 10, 1, 1000),
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
cat > "backend/src/treasury/withdraw.ts" <<'DOC_EOF'
// Treasury withdrawals: the admin takes fees out of the treasury for running costs.
//
// Safety:
//   - money only ever goes to TREASURY_PAYOUT_ADDRESS (on Arc), set on Render.
//     It cannot be typed or changed in the dashboard, so someone who got into
//     the admin login still could not send the money anywhere else
//   - every withdrawal is confirmed with a code emailed to the admin (5 tries,
//     10 minutes), counted in the database so a burst of guesses cannot get past it
//   - USDC never goes below the reserve: TREASURY_RESERVE_USDC plus every open
//     order that may still need a refund, plus a little for gas
//   - one withdrawal at a time; each one is logged and emailed
import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { and, desc, eq, inArray, lt, sql } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, ledgerEntries, orders, treasuryWithdrawals } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { uuidFrom } from "../wallets/service";

type Token = (typeof SWAP_TOKENS)[number];
type Withdrawal = typeof treasuryWithdrawals.$inferSelect;

export class WithdrawError extends Error {
  constructor(message: string, public status: 400 | 401 | 404 | 409 | 502 | 503 = 400) {
    super(message);
  }
}

const CODE_MINUTES = 10;
const MAX_CODE_ATTEMPTS = 5;
const GAS_MICRO = 50_000n; // 0.05 USDC kept for the network fee (the treasury pays gas in USDC)
const DECIMALS: Record<Token, number> = { USDC: 6, EURC: 6, cirBTC: 8 };
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// Orders whose payment sits in the treasury and may still be refunded
const OWED_STATUSES = ["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"] as const;
const TOKEN_CONTRACTS = [
  "0x3600000000000000000000000000000000000000",
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1",
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0",
];

const isToken = (v: unknown): v is Token => typeof v === "string" && (SWAP_TOKENS as readonly string[]).includes(v);
const codeHash = (id: string, code: string) => createHmac("sha256", env.BETTER_AUTH_SECRET).update(`withdraw-code:${id}:${code}`).digest("hex");
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

function units(token: Token, amount: string): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0n;
  const d = DECIMALS[token];
  return BigInt(m[1]!) * 10n ** BigInt(d) + BigInt((m[2] ?? "").padEnd(d, "0").slice(0, d) || "0");
}

function text(token: Token, u: bigint): string {
  if (u < 0n) u = 0n;
  const d = BigInt(DECIMALS[token]);
  const whole = u / 10n ** d;
  const frac = (u % 10n ** d).toString().padStart(Number(d), "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : String(whole);
}

// The payout address, or null with the reason it is not usable
export function payout(): { address: string | null; problem: string | null } {
  const a = env.TREASURY_PAYOUT_ADDRESS;
  if (!a) return { address: null, problem: "Withdrawals are off: TREASURY_PAYOUT_ADDRESS is not set on Render." };
  if (!/^0x[0-9a-f]{40}$/.test(a) || /^0x0{40}$/.test(a)) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS on Render is not a valid wallet address." };
  if (a === env.TREASURY_ADDRESS.toLowerCase()) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS is the treasury itself. Set your own wallet." };
  if (TOKEN_CONTRACTS.includes(a)) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS is a token contract, not a wallet." };
  return { address: a, problem: null };
}

// Treasury balances with Circle's token ids (needed to send)
async function holdings(): Promise<Record<Token, { tokenId: string | null; units: bigint }>> {
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const list = res.data?.tokenBalances ?? [];
  const pick = (t: Token) => {
    const b = list.find((x) => (x.token?.symbol ?? "").toUpperCase().startsWith(t.toUpperCase()));
    return { tokenId: b?.token?.id ?? null, units: units(t, b?.amount ?? "0") };
  };
  return { USDC: pick("USDC"), EURC: pick("EURC"), cirBTC: pick("cirBTC") };
}

// USDC that must stay: the reserve plus open orders that may need a refund,
// including failed orders that were paid and whose refund has not gone out yet
async function heldBackMicro(): Promise<{ reserve: bigint; owed: bigint }> {
  const [open] = await db
    .select({ micro: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number) })
    .from(orders)
    .where(inArray(orders.status, [...OWED_STATUSES]));
  const [failed] = await db
    .select({ micro: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number) })
    .from(orders)
    .where(
      and(
        eq(orders.status, "FAILED"),
        // Written out in full so each column clearly belongs to its own table
        sql`exists (select 1 from "payments" "p" where "p"."order_id" = "orders"."id" and "p"."status" = 'CONFIRMED')`,
        sql`not exists (select 1 from "refunds" "r" where "r"."order_id" = "orders"."id" and "r"."status" = 'CONFIRMED')`,
      ),
    );
  return {
    reserve: units("USDC", env.TREASURY_RESERVE_USDC.toFixed(6)),
    owed: BigInt(open?.micro ?? 0) + BigInt(failed?.micro ?? 0),
  };
}

async function available() {
  const [have, held] = await Promise.all([holdings(), heldBackMicro()]);
  const usdcFree = have.USDC.units - held.reserve - held.owed - GAS_MICRO;
  const canPayGas = have.USDC.units >= GAS_MICRO;
  return {
    have,
    held,
    free: {
      USDC: usdcFree > 0n ? usdcFree : 0n,
      EURC: canPayGas ? have.EURC.units : 0n,
      cirBTC: canPayGas ? have.cirBTC.units : 0n,
    } as Record<Token, bigint>,
  };
}

async function audit(action: string, w: Pick<Withdrawal, "id" | "adminId">, details: Record<string, unknown>) {
  await db.insert(auditLogs).values({ actorType: "admin", actorId: w.adminId, action, targetType: "withdrawal", targetId: w.id, details });
}

async function emailAdmin(subject: string, lines: string[], extra: { code?: string; footer?: string; button?: { label: string; url: string } } = {}) {
  if (!env.ADMIN_EMAIL) throw new WithdrawError("ADMIN_EMAIL is not set on the server.", 503);
  await sendEmail({ to: env.ADMIN_EMAIL, ...noticeEmail({ subject, lines, ...extra }) });
}

function view(w: Withdrawal) {
  return {
    id: w.id,
    status: w.status,
    token: w.token,
    amount: w.amount,
    toAddress: w.toAddress,
    txUrl: w.txHash ? `${env.EXPLORER_TX_URL}${w.txHash}` : null,
    error: w.error,
    codeExpiresAt: w.status === "AWAITING_CODE" ? (w.codeExpiresAt?.toISOString() ?? null) : null,
    createdAt: w.createdAt.toISOString(),
  };
}

// ---------------------------------------------------------------------------
// The Treasury page
// ---------------------------------------------------------------------------
export async function treasuryView() {
  const p = payout();
  const recent = await db.select().from(treasuryWithdrawals).orderBy(desc(treasuryWithdrawals.createdAt)).limit(20);
  let balances: Record<Token, string> | null = null;
  let free: Record<Token, string> | null = null;
  let held: { reserve: string; owed: string } | null = null;
  let balanceError: string | null = null;
  try {
    const a = await available();
    balances = { USDC: text("USDC", a.have.USDC.units), EURC: text("EURC", a.have.EURC.units), cirBTC: text("cirBTC", a.have.cirBTC.units) };
    free = { USDC: text("USDC", a.free.USDC), EURC: text("EURC", a.free.EURC), cirBTC: text("cirBTC", a.free.cirBTC) };
    held = { reserve: text("USDC", a.held.reserve), owed: text("USDC", a.held.owed) };
  } catch (err) {
    balanceError = `Could not read the treasury from Circle: ${err instanceof Error ? err.message : String(err)}`.slice(0, 300);
  }
  return {
    treasuryAddress: env.TREASURY_ADDRESS,
    payoutAddress: p.address,
    payoutProblem: p.problem,
    payoutUrl: p.address ? `${env.EXPLORER_TX_URL.replace(/\/tx\/?$/, "/address/")}${p.address}` : null,
    reserveUsdc: env.TREASURY_RESERVE_USDC,
    balances,
    available: free,
    heldBack: held,
    balanceError,
    withdrawals: recent.map(view),
  };
}

// ---------------------------------------------------------------------------
// Step 1: checks the amount and emails the code to the admin
// ---------------------------------------------------------------------------
export async function startWithdraw(adminId: string | null, body: { token?: unknown; amount?: unknown }) {
  const p = payout();
  if (!p.address) throw new WithdrawError(p.problem ?? "Withdrawals are off.", 503);
  if (!isToken(body.token)) throw new WithdrawError("Choose USDC, EURC or cirBTC.");
  const token = body.token;
  const raw = String(body.amount ?? "").trim();
  const d = DECIMALS[token];
  if (!new RegExp(`^\\d+(\\.\\d{1,${d}})?$`).test(raw)) throw new WithdrawError(`Enter an amount of ${token}, with at most ${d} decimals.`);
  const want = units(token, raw);
  if (want <= 0n) throw new WithdrawError("Enter an amount above zero.");
  const amount = text(token, want);

  const a = await available();
  if (want > a.free[token]) {
    throw new WithdrawError(
      token === "USDC"
        ? `You can withdraw up to ${text("USDC", a.free.USDC)} USDC. The rest stays for refunds (reserve ${text("USDC", a.held.reserve)} plus ${text("USDC", a.held.owed)} for open orders) and gas.`
        : `You can withdraw up to ${text(token, a.free[token])} ${token}.${a.have.USDC.units < GAS_MICRO ? " The treasury needs at least 0.05 USDC to pay the network fee." : ""}`,
      409,
    );
  }

  // A new request replaces one still waiting for its code
  await db
    .update(treasuryWithdrawals)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "replaced by a new request" })
    .where(eq(treasuryWithdrawals.status, "AWAITING_CODE"));

  const id = randomUUID();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  try {
    await db.insert(treasuryWithdrawals).values({
      id,
      adminId,
      token,
      amount,
      toAddress: p.address,
      status: "AWAITING_CODE",
      codeHash: codeHash(id, code),
      codeExpiresAt: new Date(Date.now() + CODE_MINUTES * 60_000),
      openKey: "treasury",
    });
  } catch {
    throw new WithdrawError("A withdrawal is already in progress. Wait for it to finish.", 409);
  }
  try {
    await emailAdmin(
      `Your code to withdraw ${amount} ${token} from the treasury`,
      [`You asked to withdraw ${amount} ${token} from the dataonchain treasury to ${p.address} on Arc.`, "Enter this code on the Treasury page to confirm:"],
      { code, footer: `The code expires in ${CODE_MINUTES} minutes. If you did not ask for this, do not enter it and change your admin password now.` },
    );
  } catch (err) {
    console.error("[withdraw] could not email the code:", err instanceof Error ? err.message : err);
    await db.update(treasuryWithdrawals).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code email failed" }).where(eq(treasuryWithdrawals.id, id));
    throw new WithdrawError("Could not email the code. Please try again in a moment.", 502);
  }
  await audit("treasury.withdraw_started", { id, adminId }, { token, amount, toAddress: p.address });
  const [row] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, id)).limit(1);
  return view(row!);
}

// ---------------------------------------------------------------------------
// Step 2: the code. Sends through Circle, then waits a few seconds for the result.
// ---------------------------------------------------------------------------
export async function confirmWithdraw(id: string, codeInput: unknown) {
  const [w] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, id)).limit(1);
  if (!w) throw new WithdrawError("Withdrawal not found.", 404);
  const cancel = (error: string) =>
    db
      .update(treasuryWithdrawals)
      .set({ status: "CANCELLED", codeHash: null, openKey: null, error })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE")));
  if (w.status !== "AWAITING_CODE" || !w.codeHash) throw new WithdrawError("This withdrawal is no longer waiting for a code. Start a new one.", 409);
  if (!w.codeExpiresAt || w.codeExpiresAt.getTime() < Date.now()) {
    await cancel("code expired");
    throw new WithdrawError("The code expired. Nothing was sent. Please start again.", 409);
  }
  // Every try is counted first, in one step, so a burst of guesses cannot get past 5
  const [tried] = await db
    .update(treasuryWithdrawals)
    .set({ codeAttempts: sql`${treasuryWithdrawals.codeAttempts} + 1` })
    .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE"), lt(treasuryWithdrawals.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning();
  if (!tried) {
    await cancel("too many wrong codes");
    throw new WithdrawError("Too many wrong codes. Nothing was sent. Please start again.", 401);
  }
  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(w.id, code), w.codeHash)) {
    if (tried.codeAttempts >= MAX_CODE_ATTEMPTS) {
      await cancel("too many wrong codes");
      await audit("treasury.withdraw_code_failed", w, { attempts: tried.codeAttempts });
      throw new WithdrawError("Too many wrong codes. Nothing was sent. Please start again.", 401);
    }
    throw new WithdrawError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.codeAttempts} tries left.`, 401);
  }

  // The payout address must still be the one on Render, and the money still free
  const p = payout();
  if (!p.address || p.address !== w.toAddress) {
    await cancel("payout address changed");
    throw new WithdrawError("The payout address changed since you started. Nothing was sent. Please start again.", 409);
  }
  const a = await available();
  const tokenId = a.have[w.token].tokenId;
  if (!tokenId || units(w.token, w.amount) > a.free[w.token]) {
    await cancel("not enough free balance at confirmation");
    throw new WithdrawError(`Only ${text(w.token, a.free[w.token])} ${w.token} can be withdrawn now. Nothing was sent.`, 409);
  }
  const [claimed] = await db
    .update(treasuryWithdrawals)
    .set({ status: "SENDING", codeHash: null })
    .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE")))
    .returning();
  if (!claimed) throw new WithdrawError("This withdrawal is already being processed.", 409);
  await audit("treasury.withdraw_confirmed", w, { token: w.token, amount: w.amount, toAddress: w.toAddress });

  await submit(claimed, tokenId);
  for (let i = 0; i < 6; i++) {
    const [now] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, w.id)).limit(1);
    if (!now || now.status !== "SENT") break;
    await new Promise((r) => setTimeout(r, 2_000));
    await check(now);
  }
  const [done] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, w.id)).limit(1);
  return view(done!);
}

// Asks Circle to send. The same idempotency key every time, so it happens once.
async function submit(w: Withdrawal, tokenId: string) {
  const input = {
    walletId: env.TREASURY_WALLET_ID,
    tokenId,
    destinationAddress: w.toAddress,
    amount: [w.amount],
    amounts: [w.amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`treasury-withdraw:${w.id}`),
    refId: `withdraw-${w.id}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const txId = res.data?.id;
    if (!txId) throw new Error("Circle did not return a transaction id");
    await db
      .update(treasuryWithdrawals)
      .set({ status: "SENT", circleTransactionId: txId })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENDING")));
  } catch (err) {
    const status = (err as { response?: { status?: number } }).response?.status;
    const detail = JSON.stringify((err as { response?: { data?: unknown } }).response?.data ?? "").slice(0, 300);
    const message = `${err instanceof Error ? err.message : String(err)} ${detail}`.trim().slice(0, 500);
    if (status && status >= 400 && status < 500) {
      await db
        .update(treasuryWithdrawals)
        .set({ status: "FAILED", openKey: null, error: message })
        .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENDING")));
      await audit("treasury.withdraw_failed", w, { error: message });
      console.error(`[withdraw] ${w.id} refused by Circle: ${message}`);
      return;
    }
    // Unclear (network): stays SENDING, the worker asks again with the same key
    console.error(`[withdraw] ${w.id} will retry: ${message}`);
  }
}

async function check(w: Withdrawal) {
  if (!w.circleTransactionId) return;
  const res = await circle.getTransaction({ id: w.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (tx?.state === "COMPLETE") {
    const [done] = await db
      .update(treasuryWithdrawals)
      .set({ status: "COMPLETE", txHash: tx.txHash ?? null, openKey: null })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENT")))
      .returning();
    if (done) await finished(done);
  } else if (tx?.state && FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`.slice(0, 500);
    const [failed] = await db
      .update(treasuryWithdrawals)
      .set({ status: "FAILED", openKey: null, error: reason, txHash: tx.txHash ?? null })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENT")))
      .returning();
    if (failed) {
      await audit("treasury.withdraw_failed", w, { error: reason });
      console.error(`[withdraw] ${w.id} FAILED: ${reason}`);
    }
  }
}

async function finished(w: Withdrawal) {
  if (w.token === "USDC") {
    const micro = Number(units("USDC", w.amount));
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      { journalId, account: "owner:withdrawals", currency: "USDC", debit: micro, memo: `Treasury withdrawal ${w.id}` },
      { journalId, account: "treasury:usdc", currency: "USDC", credit: micro, memo: `Treasury withdrawal ${w.id} tx ${w.txHash ?? ""}` },
    ]);
  }
  await audit("treasury.withdraw_complete", w, { token: w.token, amount: w.amount, toAddress: w.toAddress, txHash: w.txHash });
  try {
    await emailAdmin(
      `Treasury withdrawal sent: ${w.amount} ${w.token}`,
      [`${w.amount} ${w.token} left the dataonchain treasury on ${lagos(new Date())}.`, `To: ${w.toAddress} (Arc)`],
      {
        button: w.txHash ? { label: "View the transaction", url: `${env.EXPLORER_TX_URL}${w.txHash}` } : undefined,
        footer: "If this was not you, change your admin password now and remove TREASURY_PAYOUT_ADDRESS on Render.",
      },
    );
  } catch (err) {
    console.error(`[withdraw] ${w.id} receipt email failed:`, err instanceof Error ? err.message : err);
  }
}

// For the worker: expired codes, withdrawals waiting for Circle, and retries
export async function advanceWithdrawals(): Promise<void> {
  await db
    .update(treasuryWithdrawals)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" })
    .where(and(eq(treasuryWithdrawals.status, "AWAITING_CODE"), lt(treasuryWithdrawals.codeExpiresAt, new Date())));
  const open = await db.select().from(treasuryWithdrawals).where(inArray(treasuryWithdrawals.status, ["SENDING", "SENT"])).limit(5);
  for (const w of open) {
    try {
      if (w.status === "SENT") {
        await check(w);
      } else if (Date.now() - w.updatedAt.getTime() > 60_000) {
        const have = await holdings();
        const tokenId = have[w.token].tokenId;
        if (tokenId) await submit(w, tokenId);
      }
    } catch (err) {
      console.error(`[withdraw] ${w.id}:`, err instanceof Error ? err.message : err);
    }
  }
}
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
if ! (cd backend && ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/admin-smoke.ts http://localhost:4099); then
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  stop_api
  fail "A test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again."
fi
stop_api
green "OK"

step "Treasury withdrawal on testnet: 0.1 test USDC with the emailed code"
W_OUTBOX="$(mktemp)"
set +e
(cd backend && ADMIN_EMAIL=withdraw-smoke@example.com EMAIL_OUTBOX_FILE="$W_OUTBOX" TREASURY_RESERVE_USDC=0.01 \
  TREASURY_PAYOUT_ADDRESS=0x000000000000000000000000000000000000dEaD npx tsx scripts/withdraw-smoke.ts); code=$?
set -e
rm -f "$W_OUTBOX"
if [[ $code -eq 3 ]]; then
  fail "The testnet treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Withdrawal test failed (details above). Nothing was committed. If it says ECONNRESET or fetch failed, it was the internet: run again. Otherwise paste the output to Claude."
fi
green "OK"

step "Admin dashboard: build"
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Treasury fixes: hold back owed refunds, allow a zero reserve, stuck withdrawal alerts, clearer cash out steps"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"audit4":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
echo "Vercel usually finishes the admin dashboard a minute or two after the push."

echo
green "Script 41 complete."
