#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 30: send USDC, EURC and cirBTC to another wallet on Arc
#
#   - "Send to a wallet" on the dashboard: any Arc address, confirmed with a
#     6 digit code emailed to the user (a stolen password alone cannot empty a
#     wallet), a receipt email after each send, no fee (gas is sponsored)
#   - Safety: one send at a time, limits per send and per day (50 USDC or EURC
#     per send and 100 per day at launch), never to the user's own wallet or a
#     token contract, and a "this is an Arc address" check
#   - Starts PAUSED on mainnet; your admin email can test it while paused
#   - Admin dashboard: a Sends page, sends on each user's page, and a
#     "Sending to other wallets" pause switch in Settings
#   - Swaps: a Gas Station limit now shows "busy, try again later", and the
#     full reason is saved for you in the admin Swaps page
#   - FAQ and terms (section 7) describe sending to other wallets
#   Tested on testnet first: a real 0.2 USDC send confirmed with its emailed code.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/30_send_to_wallet.sh
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
[[ -f backend/scripts/live-report.ts ]] || fail "Run this from ~/dataonchain after script 29"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/30_send_to_wallet.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "admin/src/app/(dash)" "admin/src/app/(dash)/sends" "admin/src/app/(dash)/settings" "admin/src/app/(dash)/users/[id]" "admin/src/components" "admin/src/lib" "backend/scripts" "backend/src" "backend/src/admin" "backend/src/bridge" "backend/src/db" "backend/src/email" "backend/src/send" "backend/src/swap" "frontend/src/app" "frontend/src/app/dashboard" "frontend/src/app/send" "frontend/src/app/terms"
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
        subtitle="USDC, EURC and cirBTC sent from users' Arc wallets to other wallets, each confirmed with an emailed code."
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
cat > "admin/src/app/(dash)/settings/page.tsx" <<'DOC_EOF'
"use client";

import { useState, type FormEvent } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { ago, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Pauses = { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean; sendPaused: boolean };
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
  { key: "sendPaused", title: "Sending to other wallets", text: "New sends of USDC, EURC and cirBTC to other Arc wallets. Sends already confirmed keep going." },
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
  sends?: { id: string; status: string; token: string; amount: string; toAddress: string; txUrl: string | null; error: string | null; createdAt: string }[];
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

      {data.sends && data.sends.length ? (
        <Card title="Sends to other wallets" className="mt-6">
          <Table head={["Amount", "To", "Status", "Date"]}>
            {data.sends.map((s) => (
              <tr key={s.id}>
                <Td><ExtLink href={s.txUrl}>{token(s.amount)} {s.token}</ExtLink></Td>
                <Td className="font-mono text-xs">{short(s.toAddress)}</Td>
                <Td>
                  <Badge status={s.status} />
                  {s.error ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{s.error}</span> : null}
                </Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
      ) : null}

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
  { href: "/sends", label: "Sends" },
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
const PLAIN = ["QUOTED", "EXPIRED", "CANCELLED"];

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
    console.log(`  ${when(s.createdAt)}  ${s.status.padEnd(13)} ${s.amount} ${s.token} -> ${s.toAddress}${s.txHash ? `  ${chainByKey("arc").explorerTx}${s.txHash}` : ""}`);
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
import { SendError, advanceSends, confirmSend, getSendView, startSend } from "../src/send/service";
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

    const code = lastCode(email);
    const wrong = code === "000000" ? "111111" : "000000";
    try {
      await confirmSend(userId, second!.id, wrong);
      check(false, "a wrong code is refused");
    } catch (err) {
      check(err instanceof SendError && err.status === 401 && /tries left/.test(err.message), "a wrong code is refused");
    }
    let view = await confirmSend(userId, second!.id, code);
    for (let i = 0; i < 30 && view && ["SENDING", "SENT"].includes(view.status); i++) {
      await sleep(3_000);
      await advanceSends();
      view = await getSendView(userId, second!.id);
    }
    check(view?.status === "COMPLETE" && Boolean(view.explorerUrl), `0.2 USDC sent (${view?.explorerUrl})`, view);
    await refused("the same code cannot be used twice", () => confirmSend(userId, second!.id, code));

    let after = await usdcOf(wallet.circleWalletId);
    for (let i = 0; i < 20 && after > before - 0.2; i++) {
      await sleep(3_000);
      after = await usdcOf(wallet.circleWalletId);
    }
    check(Math.abs(before - 0.2 - after) < 0.000001, `the wallet went down by exactly 0.2 USDC (${before} -> ${after})`);

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
  const sendRows = await db
    .select()
    .from(sends)
    .where(and(eq(sends.userId, id), notInArray(sends.status, ["AWAITING_CODE"])))
    .orderBy(desc(sends.createdAt))
    .limit(20);
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
    txUrl: arcTx(s.txHash),
    error: s.error,
    createdAt: s.createdAt.toISOString(),
  };
}

export async function listSendsAdmin(status: string | undefined, page: number) {
  const where =
    status && (SEND_STATUSES as readonly string[]).includes(status)
      ? eq(sends.status, status as (typeof SEND_STATUSES)[number])
      : notInArray(sends.status, ["AWAITING_CODE"]);
  const [total] = await db.select({ n: count() }).from(sends).where(where);
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
import { AdminActionError, failAndRefund, recheckOrder, retryRefund, setPauseSwitch, setProviderActive, setUserStatus } from "./actions";
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
  listSendsAdmin,
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

adminApp.get("/sends", requireAdmin, async (c) => c.json(await listSendsAdmin(c.req.query("status"), pageOf(c.req.query("page")))));

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

adminApp.post("/orders/:key/fail-refund", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await failAndRefund(c.get("admin").account.id, c.req.param("key"), b.reason));
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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

// ---------------------------------------------------------------------------
// Send USDC, EURC or cirBTC to another wallet on Arc, confirmed with an emailed code
// ---------------------------------------------------------------------------
function sendErrors(err: unknown, c: Context) {
  if (err instanceof SendError) return c.json({ error: err.message }, err.status);
  throw err;
}

app.get("/api/send/info", requireAuth, async (c) => {
  const { user } = c.get("auth");
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
import { sendSummary } from "../send/service";

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

  // Sends to other wallets
  const sd = await sendSummary(since);
  lines.push(`Sends to other wallets, last 24 hours: ${sd.complete} complete, ${sd.failed} failed (nothing sent).`);
  for (const u of sd.stuck) issues.push(`Send waiting for Circle over 30 minutes: ${u}`);

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
export function noticeEmail(p: { subject: string; lines: string[]; code?: string; button?: { label: string; url: string }; footer?: string; brand?: string }) {
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
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">${escapeHtml(p.brand ?? "dataonchain admin")}</td></tr>
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
cat > "backend/src/send/service.ts" <<'DOC_EOF'
// Sending USDC, EURC or cirBTC from a user's Arc wallet to another wallet on Arc.
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
//   - only Arc addresses: never to the user's own wallet, the zero address or a
//     token contract (a common mistake that loses the funds)
//   - an email receipt after every completed send
import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { and, desc, eq, gte, inArray, lt, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, ledgerEntries, sends, users } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { ensureUserWallet, uuidFrom } from "../wallets/service";

export type SendToken = (typeof SWAP_TOKENS)[number];
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

// Token contracts on Arc (testnet and mainnet use the same USDC address)
const TOKEN_CONTRACTS = [
  "0x3600000000000000000000000000000000000000", // USDC
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1", // EURC mainnet
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0", // cirBTC mainnet
];

export const SEND_TOKENS: Record<SendToken, { decimals: number; min: number; max: number; daily: number }> = {
  USDC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  EURC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  cirBTC: { decimals: 8, min: 0.00001, max: env.SEND_MAX_CIRBTC, daily: env.SEND_DAILY_CIRBTC },
};

const network = () => (env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "Arc Testnet" : "Arc");
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

function parseAddress(value: unknown, own: string): string {
  const a = String(value ?? "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new SendError("Enter a wallet address: 0x followed by 40 letters and numbers.");
  const lower = a.toLowerCase();
  if (/^0x0{40}$/.test(lower)) throw new SendError("That address cannot receive funds.");
  if (lower === own.toLowerCase()) throw new SendError("That is your own dataonchain wallet. Choose another address.");
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
export async function sendInfo(userId: string) {
  const wallet = await ensureUserWallet(userId);
  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const list = res.data?.tokenBalances ?? [];
  const find = (sym: string) => list.find((b) => (b.token?.symbol ?? "").toUpperCase().startsWith(sym.toUpperCase()))?.amount ?? "0";
  const { count, used } = await usedToday(userId);
  return {
    network: network(),
    balances: { USDC: find("USDC"), EURC: find("EURC"), cirBTC: find("CIRBTC") } as Record<SendToken, string>,
    limits: SEND_TOKENS,
    usedToday: { USDC: text("USDC", used.USDC), EURC: text("EURC", used.EURC), cirBTC: text("cirBTC", used.cirBTC) },
    sendsLeftToday: Math.max(0, env.SEND_DAILY_COUNT - count),
  };
}

// Step 1: checks everything, saves the send and emails the code
export async function startSend(user: { id: string; email: string; name: string }, body: { token?: unknown; amount?: unknown; toAddress?: unknown; confirmNetwork?: unknown }) {
  if (!isToken(body.token)) throw new SendError("Choose USDC, EURC or cirBTC.");
  const token = body.token;
  const amount = parseAmount(token, body.amount);
  const wallet = await ensureUserWallet(user.id);
  const toAddress = parseAddress(body.toAddress, wallet.address);
  if (body.confirmNetwork !== true) throw new SendError(`Confirm that the address is a wallet on ${network()}.`);

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
        `You asked to send ${amount} ${token} from your dataonchain wallet to ${toAddress} on ${network()}.`,
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
  await audit("send.started", { id, userId: user.id }, { token, amount, toAddress });
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
  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(s.id, code), s.codeHash)) {
    const attempts = s.codeAttempts + 1;
    if (attempts >= MAX_CODE_ATTEMPTS) {
      await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, codeAttempts: attempts, error: "too many wrong codes" }).where(eq(sends.id, s.id));
      await audit("send.code_failed", s, { attempts });
      throw new SendError("Too many wrong codes. Nothing was sent. Please start again.", 401);
    }
    await db.update(sends).set({ codeAttempts: attempts }).where(eq(sends.id, s.id));
    throw new SendError(`Wrong code. ${MAX_CODE_ATTEMPTS - attempts} tries left.`, 401);
  }

  // The balance may have changed since the code was sent
  const wallet = await ensureUserWallet(userId);
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
        `To: ${s.toAddress} (${network()})`,
      ],
      button: s.txHash ? { label: "View the transaction", url: `${env.EXPLORER_TX_URL}${s.txHash}` } : undefined,
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
        const wallet = await ensureUserWallet(s.userId);
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
    network: network(),
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
    explorerUrl: s.txHash ? `${env.EXPLORER_TX_URL}${s.txHash}` : null,
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
cat > "backend/src/settings.ts" <<'DOC_EOF'
// Switches the admin can flip from the dashboard, without a redeploy.
// Pausing only stops NEW purchases, transfers or swaps. Anything already
// started (payments, deliveries, refunds, bridge transfers) keeps going.
import { db } from "./db";
import { appSettings } from "./db/schema";
import { env } from "./env";

export const PAUSE_KEYS = ["purchasesPaused", "bridgePaused", "swapPaused", "sendPaused"] as const;
export type PauseKey = (typeof PAUSE_KEYS)[number];
export type Pauses = Record<PauseKey, boolean>;

const TESTNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data is paused for a short maintenance. Please try again later.",
  bridgePaused: "Sending to other networks is paused for a short maintenance. Please try again later.",
  swapPaused: "Swaps are paused for a short maintenance. Please try again later.",
  sendPaused: "Sending to other wallets is paused for a short maintenance. Please try again later.",
};
// On mainnet a paused part is one that has not opened yet
const MAINNET_MESSAGES: Record<PauseKey, string> = {
  purchasesPaused: "Buying airtime and data with real USDC is coming soon. Until then you can add USDC to your wallet.",
  bridgePaused: "Sending to other networks opens soon on Arc mainnet.",
  swapPaused: "Swaps open soon on Arc mainnet.",
  sendPaused: "Sending to other wallets opens soon on Arc mainnet.",
};
export const PAUSE_MESSAGES: Record<PauseKey, string> = env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? TESTNET_MESSAGES : MAINNET_MESSAGES;

const CACHE_MS = 10_000;
let cache: { at: number; value: Pauses } | null = null;

export function isPauseKey(value: unknown): value is PauseKey {
  return typeof value === "string" && (PAUSE_KEYS as readonly string[]).includes(value);
}

export async function getPauses(): Promise<Pauses> {
  if (cache && Date.now() - cache.at < CACHE_MS) return cache.value;
  // A switch never set is open, except sending to other wallets on mainnet:
  // it starts paused until the admin opens it after a live check
  const value: Pauses = { purchasesPaused: false, bridgePaused: false, swapPaused: false, sendPaused: !env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") };
  try {
    const rows = await db.select().from(appSettings);
    for (const key of PAUSE_KEYS) {
      const row = rows.find((r) => r.key === key);
      if (row) value[key] = row.value === "true";
    }
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
  const on: Record<PauseKey, boolean> = { purchasesPaused: true, bridgePaused: env.BRIDGE_ENABLED, swapPaused: env.SWAP_ENABLED, sendPaused: true };
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
  // Sends to other wallets: expired codes, results from Circle, retries
  try {
    await advanceSends();
  } catch (err) {
    console.error("[worker] sends failed:", err instanceof Error ? err.message : err);
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
      .then((s: { bridge?: boolean; swap?: boolean; network?: string; notices?: string[]; paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean; sendPaused?: boolean } }) => {
        setBridgeOn(Boolean(s.bridge));
        setSwapOn(Boolean(s.swap));
        setMainnet(s.network === "mainnet");
        setNotices(s.notices ?? []);
        setBuyPaused(Boolean(s.paused?.purchasesPaused));
        const parts: string[] = [];
        if (s.paused?.purchasesPaused) parts.push("buying airtime and data");
        if (s.paused?.bridgePaused && s.bridge) parts.push("sending to other networks");
        if (s.paused?.swapPaused && s.swap) parts.push("swaps");
        if (s.paused?.sendPaused) parts.push("sending to other wallets");
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
          <Link
            href="/send"
            className="inline-block rounded-lg border border-emerald-700 px-4 py-2.5 font-medium text-emerald-800 hover:bg-emerald-50 dark:border-emerald-500 dark:text-emerald-300 dark:hover:bg-emerald-950"
          >
            Send to a wallet
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
cat > "frontend/src/app/send/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Info = {
  network: string;
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
      setInfo(await api<Info>("/send/info"));
      const r = await api<{ sends: SendView[] }>("/sends");
      setRecent(r.sends);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, []);

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
        body: JSON.stringify({ token, amount, toAddress: toAddress.trim(), confirmNetwork }),
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
  const network = info?.network ?? "Arc";

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
          Send USDC, EURC or cirBTC from your wallet to any wallet on {network}. No gas to pay. You confirm every send
          with a code we email you.
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have: {TOKEN_LIST.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(" · ")}
          </p>
        ) : null}

        {info?.paused ? (
          <p className="mt-4 rounded-lg bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">{info.paused}</p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {!pending ? (
            <form onSubmit={start} className="space-y-5">
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Token</p>
                <div className="mt-2 flex gap-2">
                  {TOKEN_LIST.map((t) => (
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
        <li>Sending to other networks, sending to other wallets and swaps open when we announce them on the website.</li>
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

      <h2>7. Sending to other networks and wallets</h2>
      <ul>
        <li>You can send USDC from Arc to your own wallets on the supported networks, or to approved providers, through Circle Gateway. You can also bring it back to Arc.</li>
        <li>Circle charges a fee for each transfer, shown before you confirm. We also charge a small transfer fee (currently 0.10 USDC), shown before you confirm and taken from your Arc wallet only when the transfer completes. It covers the network fees we pay for you.</li>
        <li>Transfers can take up to about 20 minutes. Limits apply per transfer and per day, and you can have one transfer in progress at a time.</li>
        <li>We may refuse or pause transfers, for example when Circle&apos;s fee is unusually high or for security reasons.</li>
        <li>You can also send USDC, EURC or cirBTC from your wallet to any wallet address on Arc. You confirm each send with a code we email to you. Never share that code with anyone.</li>
        <li>Sends on a blockchain are final and cannot be reversed. You are responsible for the address you enter and for checking that it can receive the token on Arc. Funds sent to a wrong address, or to an exchange or wallet that does not support Arc, are lost and we cannot recover them.</li>
        <li>Limits apply per send and per day. We may refuse, delay or pause a send for security reasons or where the law requires it.</li>
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
green "OK"

# --- 2. Development database -------------------------------------------------------
step "Database: the sends table"
if ! grep -rqs 'CREATE TABLE `sends`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name sends)
fi
grep -rqs 'CREATE TABLE `sends`' backend/drizzle/*.sql || fail "The database change was not created. Paste the output to Claude."
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

step "Send on testnet: 0.2 USDC to the treasury, confirmed with the emailed code"
SEND_OUTBOX="$(mktemp)"
set +e
(cd backend && EMAIL_OUTBOX_FILE="$SEND_OUTBOX" PAUSE_BYPASS_EMAILS=tester@example.com npx tsx scripts/send-smoke.ts); code=$?
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
step "Live database: the sends table"
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
git diff --cached --quiet || git commit -q -m "Send USDC, EURC and cirBTC to other Arc wallets with an emailed code; admin Sends page; clearer swap errors"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"sendReady":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
[[ "$STATUS" == *'"network":"mainnet"'* ]] || fail "Render is not on mainnet. Tell Claude."
curl -s --max-time 30 "$PROD_FRONTEND/" >/dev/null || true
wait_for "the website on Vercel" "$PROD_FRONTEND/send" 'Send to another wallet' 30 || yellow "The website did not show the new wording yet. Check vercel.com later; nothing else depends on it."

ADMIN="$(env_get ADMIN_EMAIL)"
[[ -n "$ADMIN" ]] || ADMIN="your admin email (the one you use for dashboard.dataonchain.online)"

echo
green "Script 30 complete. Send to a wallet is live on Arc mainnet, still paused for users."
echo
bold "Your live test (about 1 USDC, 5 minutes):"
echo "  1. Log in on $PROD_FRONTEND with: $ADMIN"
echo "  2. Dashboard > Send to a wallet > USDC > 0.5 > paste the address of a wallet"
echo "     you control on Arc mainnet > tick the Arc box > Continue."
echo "  3. Enter the 6 digit code from your email > Confirm. It should say Sent within"
echo "     a few seconds, with a transaction link, and you get a receipt email."
echo "  4. Try a wrong code once on a second send: it must refuse it."
echo "  5. See the results (read only):   bash setup/29_live_bridge_swap.sh report"
echo
bold "When it all looks right, open what you want for everyone:"
echo "  dashboard.dataonchain.online > Settings > Pause switches > 'Open again' on"
echo "  'Sending to other networks', 'Swaps' and 'Sending to other wallets'."
