#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 39: fixes from the audit of the admin dashboard and website
#
#   Admin dashboard
#   - Login: wrong codes or wrong passwords sent all at the same moment now all
#     count (before, a burst could get more than 5 tries at the code)
#   - A login code can be used once only, even if sent twice at once
#   - Deposits and Sends pages: one unknown network can no longer break the
#     whole page; the totals match the rows shown
#   - Overview: new "Deposits in" and "Sends out" boxes (last 30 days)
#   - Sends page wording now covers Base
#   Website
#   - Onchain history: no more gaps (it could show an old swap while newer
#     sends were missing) and it keeps up to 100 items of each kind
#   - Balance card: if Base (or Arc) cannot be read, the total says so
#     instead of silently showing a smaller number
#   - Send page: switching between Arc and Base quickly can no longer show
#     the other network's balance; recent sends show their network
#   No database change.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/39_audit_fixes.sh
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
[[ -f "admin/src/app/(dash)/deposits/page.tsx" ]] || fail "Run this from ~/dataonchain after script 38"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/39_audit_fixes.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
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
  pauses: { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean; sendPaused?: boolean };
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
  sends?: { complete30: number; usdc30: string };
  deposits?: { count30: number; usdc30: string; base30: number };
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
    data.pauses.sendPaused ? "Sends" : null,
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
        {data.deposits ? (
          <Stat
            label="Deposits in"
            value={count(data.deposits.count30)}
            hint={`Last 30 days · ${usdc(data.deposits.usdc30)} USDC · ${count(data.deposits.base30)} on Base`}
            href="/deposits"
          />
        ) : null}
        {data.sends ? (
          <Stat
            label="Sends out"
            value={count(data.sends.complete30)}
            hint={`Last 30 days · ${usdc(data.sends.usdc30)} USDC`}
            href="/sends?status=COMPLETE"
          />
        ) : null}
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
cat > "admin/src/app/(dash)/sends/page.tsx" <<'DOC_EOF'
"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, short, token, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  token: string;
  amount: string;
  toAddress: string;
  network?: string;
  txUrl: string | null;
  error: string | null;
  userId: string;
  email: string;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; sends: Row[] };

export default function SendsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/sends?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle
        title="Sends"
        subtitle="USDC, EURC and cirBTC sent from users' wallets on Arc, and USDC from their Base wallets, to other wallets. Each send is confirmed with an emailed code."
      />
      <Card
        title={data ? `${count(data.total)} send(s)` : "Sends"}
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
              { value: "SENT", label: "Waiting for Circle" },
              { value: "SENDING", label: "Sending" },
              { value: "FAILED", label: "Failed" },
              { value: "CANCELLED", label: "Cancelled" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Customer", "Amount", "To", "Status", "Date"]} empty={data.sends.length === 0}>
              {data.sends.map((s) => (
                <tr key={s.id}>
                  <Td>
                    <RowLink href={`/users/${s.userId}`}>{s.email}</RowLink>
                  </Td>
                  <Td>
                    <ExtLink href={s.txUrl}>
                      {token(s.amount)} {s.token}
                    </ExtLink>
                    {s.network ? <span className="block text-xs text-zinc-500">on {s.network}</span> : null}
                  </Td>
                  <Td className="font-mono text-xs">{short(s.toAddress)}</Td>
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
    for (const path of ["/users", "/orders", "/orders?status=open", "/refunds", "/bridge", "/swaps", "/sends", "/deposits", "/deposits?network=base", "/providers", "/activity", "/settings", "/sessions"]) {
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
import { and, eq, gte, isNull, lt, ne, or, sql } from "drizzle-orm";
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
      // Counted in the database itself, so many wrong passwords sent at the same
      // moment all count
      const [row] = await db
        .update(adminAccounts)
        .set({ failedAttempts: sql`${adminAccounts.failedAttempts} + 1` })
        .where(eq(adminAccounts.id, account.id))
        .returning({ failed: adminAccounts.failedAttempts });
      const failed = row?.failed ?? MAX_FAILED_PASSWORDS;
      if (failed >= MAX_FAILED_PASSWORDS) {
        const until = new Date(Date.now() + LOCK_MINUTES * 60_000);
        await db.update(adminAccounts).set({ failedAttempts: 0, lockedUntil: until }).where(eq(adminAccounts.id, account.id));
        await adminAudit("admin.locked", { ip: meta.ip, until: until.toISOString() }, account.id);
        notifyQuietly("dataonchain admin login locked", [
          `Someone entered the wrong admin password ${MAX_FAILED_PASSWORDS} times. The login is locked until ${lagosTime(until)} (Lagos time).`,
          `Last attempt from IP ${meta.ip}.`,
          'If this was not you, use "Forgot password" to set a new password. That also unlocks the login.',
        ]);
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

  // Every try is counted in the database before the code is checked, so many
  // guesses sent at the same moment cannot get past the limit
  const [tried] = await db
    .update(adminSessions)
    .set({ codeAttempts: sql`${adminSessions.codeAttempts} + 1` })
    .where(and(eq(adminSessions.id, pending.id), lt(adminSessions.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning({ attempts: adminSessions.codeAttempts });
  if (!tried) {
    await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
    throw new AdminAuthError("Too many wrong codes. Please log in again.", 401);
  }

  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(pending.id, code), pending.codeHash)) {
    if (tried.attempts >= MAX_CODE_ATTEMPTS) {
      await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
      await adminAudit("admin.code_failed", { ip: meta.ip }, account.id);
      throw new AdminAuthError("Too many wrong codes. Please log in again.", 401);
    }
    throw new AdminAuthError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.attempts} tries left.`, 401);
  }

  // The pending login is used up (only once, even if the code is sent twice);
  // the real session gets a brand new token
  const used = await db.delete(adminSessions).where(eq(adminSessions.id, pending.id)).returning({ id: adminSessions.id });
  if (!used.length) throw expired;
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
  sends,
  deposits,
  swaps,
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, deposits: true, baseSend: true, totalBalance: true, audit2: true, adminDeposits: true, audit3: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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

export async function listBridges(userId: string, limit = 20) {
  const rows = await db
    .select()
    .from(bridgeTransfers)
    .where(eq(bridgeTransfers.userId, userId))
    .orderBy(desc(bridgeTransfers.createdAt))
    .limit(limit);
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
import { and, desc, eq, gte, inArray, isNull } from "drizzle-orm";
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
  // Only a known answer is kept: a lookup that failed (network) is tried again next scan
  if (info) tokenCache.set(tokenId, info);
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

// Deposits in a period, for the daily report
export async function depositSummary(since: Date) {
  const rows = await db.select({ token: deposits.token, amount: deposits.amount }).from(deposits).where(gte(deposits.receivedAt, since));
  const usdc = rows.filter((r) => r.token === "USDC").reduce((s, r) => s + Number(r.amount), 0);
  return { count: rows.length, usdc: usdc.toFixed(2) };
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
  await retryEmails();
  return added;
}

// A deposit whose email failed (Resend down, network) is emailed on a later scan,
// for up to a day
async function retryEmails() {
  const due = await db
    .select()
    .from(deposits)
    .where(and(isNull(deposits.notifiedAt), gte(deposits.receivedAt, new Date(Date.now() - 24 * 60 * 60_000))))
    .limit(10);
  for (const d of due) {
    let chain: BridgeChain;
    try {
      chain = chainByKey(d.chain);
    } catch {
      continue;
    }
    try {
      await notify(d, chain);
      await db.update(deposits).set({ notifiedAt: new Date() }).where(eq(deposits.id, d.id));
    } catch (err) {
      console.error(`[deposits] ${d.id} email failed again:`, err instanceof Error ? err.message : err);
    }
  }
}

export async function listDeposits(userId: string, limit = 20) {
  const rows = await db.select().from(deposits).where(eq(deposits.userId, userId)).orderBy(desc(deposits.receivedAt)).limit(limit);
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

export async function listOrders(userId: string, limit = 20) {
  const rows = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.userId, userId), notInArray(orders.status, ["QUOTED", "EXPIRED"])))
    .orderBy(desc(orders.createdAt))
    .limit(limit);
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
  return sendView(s, user ? user.email.replace(/^(.{2}).*(@.*)$/, "$1***$2") : "your email");
}

function sendView(s: typeof sends.$inferSelect, masked: string) {
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

// Newest first, in one query (the history page asks for up to 100)
export async function listSends(userId: string, limit = 20) {
  await cancelWaiting(userId, false);
  const rows = await db
    .select()
    .from(sends)
    .where(and(eq(sends.userId, userId), notInArray(sends.status, ["AWAITING_CODE", "CANCELLED"])))
    .orderBy(desc(sends.createdAt))
    .limit(limit);
  return rows.map((s) => sendView(s, "your email"));
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

// The message plus the reasons underneath it (App Kit wraps Circle's and Arc's
// answers several levels deep: the useful part, like a Gas Station limit, is inside)
function errorText(err: unknown): string {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  const parts = [err instanceof Error ? err.message : String(err)];
  if (detail) parts.push(JSON.stringify(detail));
  let e = (err as { cause?: { trace?: { rawError?: unknown } } }).cause?.trace?.rawError ?? (err as { cause?: unknown }).cause;
  for (let i = 0; e && i < 5; i++) {
    const x = e as { details?: unknown; shortMessage?: unknown; message?: unknown; cause?: unknown };
    const piece = String(x.details ?? x.shortMessage ?? x.message ?? "");
    if (piece && !parts.some((p) => p.includes(piece))) parts.push(piece);
    e = x.cause;
  }
  return parts.join(" | ").replace(/0x[0-9a-fA-F]{200,}/g, "0x...").slice(0, 800);
}

function friendly(message: string): string {
  if (/PAYMASTER_POLICY|exceed.*policy/i.test(message)) {
    return "Swaps are busy right now. Nothing was taken. Please try again later.";
  }
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
    // hash in the error itself means something was sent: mark UNKNOWN to be
    // checked. Only the top message is searched, and only a whole 64 character
    // hash counts: the reasons underneath quote transaction data (long hex that
    // was never sent), which must not turn a refused swap into an unclear one.
    const top = `${err instanceof Error ? err.message : String(err)} ${JSON.stringify((err as { response?: { data?: unknown } }).response?.data ?? "")}`;
    const sent = /(?<![0-9a-fA-F])0x[0-9a-fA-F]{64}(?![0-9a-fA-F])/.exec(top)?.[0] ?? null;
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
  return swapView(s);
}

function swapView(s: typeof swaps.$inferSelect) {
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

// Newest first, in one query (the history page asks for up to 100)
export async function listSwaps(userId: string, limit = 20) {
  const rows = await db.select().from(swaps).where(eq(swaps.userId, userId)).orderBy(desc(swaps.createdAt)).limit(limit);
  return rows.map(swapView);
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
cat > "frontend/src/app/send/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
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
  // The network on screen now: an answer for the other network that arrives late is ignored
  const current = useRef<Chain>("arc");
  current.current = chain;

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      const i = await api<Info>(`/send/info?chain=${chain}`);
      if (current.current !== chain) return;
      setInfo(i);
      if (i.baseOpen !== undefined) setBaseOpen(i.baseOpen);
      const r = await api<{ sends: SendView[] }>("/sends");
      setRecent(r.sends);
    } catch (e) {
      if (current.current === chain) setError(e instanceof Error ? e.message : "Could not load your balances.");
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
                      {s.network ? <span className="text-zinc-500"> on {s.network}</span> : null}
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

// Each list comes back with at most `fetched` rows. When a list is full, older
// rows of that kind were left out, so the merged history stops at its oldest row:
// otherwise an old swap could show while newer sends are missing.
function cutoff(lists: { at: number[] }[], fetched: number): number {
  let from = 0;
  for (const l of lists) if (l.at.length >= fetched) from = Math.max(from, Math.min(...l.at));
  return from;
}

function toItems(orders: OrderView[], sends: SendRow[], swaps: SwapRow[], bridges: BridgeListItem[], received: DepositRow[], limit: number, fetched: number): Item[] {
  const ms = (v: string) => new Date(v).getTime();
  const from = cutoff(
    [
      { at: orders.map((o) => ms(o.createdAt)) },
      { at: sends.map((s) => ms(s.createdAt)) },
      { at: swaps.map((s) => ms(s.createdAt)) },
      { at: bridges.map((b) => ms(b.createdAt)) },
      { at: received.map((d) => ms(d.receivedAt)) },
    ],
    fetched,
  );
  const items: Item[] = [];
  for (const d of received) {
    const arc = d.chain === "arc";
    items.push({
      key: `d-${d.id}`,
      kind: "receive",
      title: arc ? `Received ${d.token}` : `Received ${d.token} on ${d.chainLabel}`,
      detail: d.sourceAddress ? `From ${shortAddress(d.sourceAddress)}` : `In your ${d.chainLabel} wallet`,
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
  return items
    .filter((i) => i.at >= from)
    .sort((a, b) => b.at - a.at)
    .slice(0, limit);
}

// Everything the user did onchain, newest first: sends, swaps, transfers and
// purchases. The dashboard shows the latest 8; the history page shows them all.
export function ActivityFeed({ bridgeOn, swapOn, full = false }: { bridgeOn: boolean; swapOn: boolean; full?: boolean }) {
  const limit = full ? 100 : 8;
  // How many of each kind to ask for: enough that the merged list has no gaps
  const fetched = full ? 100 : 20;
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
        safe(api<{ orders: OrderView[] }>(`/orders?limit=${fetched}`), { orders: [] }),
        safe(api<{ sends: SendRow[] }>(`/sends?limit=${fetched}`), { sends: [] }),
        swapOn ? safe(api<{ swaps: (SwapRow | null)[] }>(`/swaps?limit=${fetched}`), { swaps: [] }) : Promise.resolve({ swaps: [] as (SwapRow | null)[] }),
        bridgeOn ? safe(api<{ transfers: BridgeListItem[] }>(`/bridge/transfers?limit=${fetched}`), { transfers: [] }) : Promise.resolve({ transfers: [] as BridgeListItem[] }),
        safe(api<{ deposits: DepositRow[] }>(`/deposits?limit=${fetched}`), { deposits: [] }),
      ]);
      if (stop) return;
      const swapList = w.swaps.filter((x): x is SwapRow => x !== null);
      setItems(toItems(o.orders, s.sends, swapList, b.transfers, d.deposits, limit, fetched));
      // Keep it live while anything is still moving
      const moving =
        o.orders.some((x) => ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"].includes(x.status)) ||
        s.sends.some((x) => ["SENDING", "SENT"].includes(x.status)) ||
        swapList.some((x) => x.status === "PENDING") ||
        b.transfers.some((x) => !BRIDGE_DONE.includes(x.status));
      if (moving) timer = setTimeout(load, 8000);
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [bridgeOn, swapOn, limit, fetched]);

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
cat > "frontend/src/components/WalletCard.tsx" <<'DOC_EOF'
"use client";

import QRCode from "qrcode";
import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean; gasFree?: boolean; previousAddress?: string | null };
  balance: { usdc: string | null };
  bridgeBalance?: string | null;
  tokens?: { EURC: string; cirBTC: string } | null;
  ngnPerUsdc?: number | null;
  networks?: { chain: string; label: string; usdc: string | null }[];
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

function toMicro(v: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(v.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

const tokenText = (v: string, max: number) => Number(v).toLocaleString("en-US", { maximumFractionDigits: max });

// The balance card at the top of the dashboard: USDC balance, its naira value,
// other tokens, and the wallet address to copy.
export function WalletCard() {
  const [data, setData] = useState<WalletResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);
  const [qr, setQr] = useState<string | null>(null);
  const [showQr, setShowQr] = useState(false);

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

  async function toggleQr() {
    if (!data) return;
    if (!qr) setQr(await QRCode.toDataURL(data.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" }));
    setShowQr((v) => !v);
  }

  // The total across networks (Arc plus Base), in micro USDC so it adds up exactly
  const networks = data?.networks?.length ? data.networks : data ? [{ chain: "arc", label: data.wallet.network, usdc: data.balance.usdc }] : [];
  const known = networks.filter((n) => n.usdc !== null);
  const totalMicro = known.reduce((sum, n) => sum + toMicro(n.usdc!), 0);
  const total = known.length ? (totalMicro / 1_000_000).toFixed(6) : null;
  const several = networks.length > 1;
  // A network whose balance could not be read is left out of the total: say so
  const missing = networks.filter((n) => n.usdc === null).map((n) => n.label);
  const amount = split(total);
  const naira = data?.ngnPerUsdc && total !== null ? Math.floor((totalMicro / 1_000_000) * data.ngnPerUsdc).toLocaleString("en-NG") : null;
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
            <p className="text-sm font-medium text-white/70">{several ? "Total USDC balance" : "USDC balance"}</p>
            {data && !several ? (
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

              {several && amount && missing.length ? (
                <p className="mt-2 text-sm text-gold">Without {missing.join(" and ")}: that balance could not be read just now. Tap refresh to try again.</p>
              ) : null}

              {several ? (
                <div className="mt-4 flex flex-wrap gap-2">
                  {networks.map((n) => (
                    <span key={n.chain} className="inline-flex items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-sm text-white/90">
                      <span className={`h-1.5 w-1.5 rounded-full ${n.chain === "arc" ? "bg-mint" : "bg-sky-300"}`} aria-hidden="true" />
                      <span className="font-semibold">{n.label}</span>
                      <span className="tabular-nums">{n.usdc === null ? "unavailable" : `${tokenText(n.usdc, 6)} USDC`}</span>
                    </span>
                  ))}
                </div>
              ) : null}

              <div className="mt-3 flex flex-wrap items-center gap-2">
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

              <div className="mt-6 flex flex-wrap items-center gap-2 border-t border-white/10 pt-4">
                <code className="min-w-0 flex-1 basis-full truncate font-mono text-sm text-white/75 sm:basis-0" title={`Your ${data.wallet.network} address`}>
                  {several ? <span className="mr-2 font-sans font-semibold text-white/55">{data.wallet.network}</span> : null}
                  {data.wallet.address}
                </code>
                <button
                  onClick={toggleQr}
                  aria-expanded={showQr}
                  className="shrink-0 rounded-full bg-white/10 px-3.5 py-1.5 text-sm font-semibold text-white hover:bg-white/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  {showQr ? "Hide QR code" : "Generate QR code"}
                </button>
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

              {showQr && qr ? (
                <div className="mt-4 flex flex-col items-center gap-3 rounded-2xl bg-white p-5 text-center text-ink sm:flex-row sm:text-left">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={qr} alt="QR code of your wallet address" width={180} height={180} className="h-44 w-44 shrink-0" />
                  <div className="space-y-2 text-sm">
                    <p className="font-display text-base font-semibold">Scan to send USDC to this wallet</p>
                    <p className="text-zinc-600">
                      Send only USDC on the <b>{data.wallet.network}</b> network. USDC sent on any other network may be lost.
                    </p>
                    <p className="break-all font-mono text-xs text-zinc-500">{data.wallet.address}</p>
                  </div>
                </div>
              ) : null}
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

step "Website and admin dashboard: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Audit fixes: admin login tries counted atomically, safer admin lists, deposits and sends on the overview, history without gaps, clearer totals"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"audit3":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
echo "Vercel usually finishes the website and admin dashboard a minute or two after the push."

echo
green "Script 39 complete."
