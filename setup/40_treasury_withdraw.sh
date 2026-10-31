#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 40: Treasury page with a Withdraw button (admin dashboard)
#
#   - New "Treasury" item in the admin menu: what is in the treasury, what can
#     be withdrawn, and past withdrawals
#   - Withdraw USDC, EURC or cirBTC, ONLY to TREASURY_PAYOUT_ADDRESS (on Arc),
#     which you set on Render. It cannot be changed in the dashboard.
#   - Each withdrawal is confirmed with a code emailed to the admin, logged,
#     and a receipt is emailed when it lands
#   - USDC never goes below the reserve (TREASURY_RESERVE_USDC, default 10)
#     plus open orders that may still need a refund, plus 0.05 for gas
#   - Database: one new table (treasury_withdrawals)
#
# Withdrawals stay OFF until you add TREASURY_PAYOUT_ADDRESS on Render.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/40_treasury_withdraw.sh
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
[[ -f "admin/src/app/(dash)/deposits/page.tsx" ]] || fail "Run this from ~/dataonchain after script 39"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/40_treasury_withdraw.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "admin/src/app/(dash)/treasury" "admin/src/components" "backend/scripts" "backend/src" "backend/src/admin" "backend/src/db" "backend/src/treasury"
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
            It must be a wallet that works on Arc (your own dataonchain wallet works: then use To Base to reach an exchange).
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
  { href: "/deposits", label: "Deposits" },
  { href: "/treasury", label: "Treasury" },
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
  "treasury_withdrawals",
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
cat > "backend/scripts/withdraw-smoke.ts" <<'DOC_EOF'
// Treasury withdrawals, on testnet and the development database:
//   - wrong tokens and amounts, and more than can be withdrawn, are refused
//   - 6 wrong codes sent at once cancel the withdrawal; the right code then fails
//   - a real 0.1 USDC withdrawal (a wrong code first) completes with a transaction
// Exit code 3 means the testnet treasury needs more test USDC.
// Run with:
//   ADMIN_EMAIL=withdraw-smoke@example.com EMAIL_OUTBOX_FILE=/tmp/x TREASURY_RESERVE_USDC=0.01 \
//   TREASURY_PAYOUT_ADDRESS=0x000000000000000000000000000000000000dEaD npx tsx scripts/withdraw-smoke.ts
import { readFileSync } from "node:fs";
import { eq, inArray, like } from "drizzle-orm";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, treasuryWithdrawals } from "../src/db/schema";
import { env } from "../src/env";
import { WithdrawError, advanceWithdrawals, confirmWithdraw, startWithdraw, treasuryView } from "../src/treasury/withdraw";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
    check(err instanceof WithdrawError, label, err instanceof Error ? err.message : err);
  }
}

function lastCode(): string {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox) throw new Error("Set EMAIL_OUTBOX_FILE");
  const mails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; text: string });
  const mine = mails.filter((m) => m.to === env.ADMIN_EMAIL);
  const code = /\n(\d{6})\n/.exec(mine[mine.length - 1]?.text ?? "")?.[1];
  if (!code) throw new Error("No code email found");
  return code;
}

async function main() {
  if (!env.ADMIN_EMAIL?.endsWith("@example.com") || !env.TREASURY_PAYOUT_ADDRESS) throw new Error("Run with a test ADMIN_EMAIL and TREASURY_PAYOUT_ADDRESS (see the top of this file)");
  if (!env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) throw new Error("This test only runs on testnet");
  const startedAt = new Date();
  const ids: string[] = [];
  try {
    const before = await treasuryView();
    check(before.payoutAddress === env.TREASURY_PAYOUT_ADDRESS, "the payout address comes from the server settings", before.payoutAddress);
    if (!before.available || Number(before.available.USDC) < 0.2) {
      console.log(`NEEDS_FUNDING: treasury can give ${before.available?.USDC ?? 0} USDC`);
      process.exit(3);
    }
    check(Number(before.available.USDC) <= Number(before.balances!.USDC) - 0.05 + 1e-9, "0.05 USDC always stays for gas", before.available);

    await refused("an unknown token is refused", () => startWithdraw(null, { token: "DOGE", amount: "1" }));
    await refused("a bad amount is refused", () => startWithdraw(null, { token: "USDC", amount: "1.1234567" }));
    await refused("zero is refused", () => startWithdraw(null, { token: "USDC", amount: "0" }));
    await refused("more than can be withdrawn is refused", () => startWithdraw(null, { token: "USDC", amount: (Number(before.available!.USDC) + 1).toFixed(6) }));

    // A burst of wrong codes still counts: the withdrawal is cancelled
    const first = await startWithdraw(null, { token: "USDC", amount: "0.1" });
    ids.push(first.id);
    check(first.status === "AWAITING_CODE", "a withdrawal waits for the emailed code");
    const firstCode = lastCode();
    const bad = firstCode === "000000" ? "111111" : "000000";
    await Promise.allSettled(Array.from({ length: 6 }, () => confirmWithdraw(first.id, bad)));
    const [raced] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, first.id));
    check(raced?.status === "CANCELLED", "6 wrong codes at once cancel it (the limit is 5)", raced?.status);
    await refused("the right code no longer works after that", () => confirmWithdraw(first.id, firstCode));

    // The real one
    const second = await startWithdraw(null, { token: "USDC", amount: "0.1" });
    ids.push(second.id);
    const code = lastCode();
    await refused("a wrong code is refused", () => confirmWithdraw(second.id, code === "000000" ? "111111" : "000000"));
    let w = await confirmWithdraw(second.id, code);
    for (let i = 0; i < 20 && ["SENDING", "SENT"].includes(w.status); i++) {
      await sleep(3_000);
      await advanceWithdrawals();
      const [row] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, second.id));
      w = { ...w, status: row!.status, txUrl: row!.txHash ? `${env.EXPLORER_TX_URL}${row!.txHash}` : null };
    }
    check(w.status === "COMPLETE" && Boolean(w.txUrl), `0.1 USDC withdrawn (${w.txUrl})`, w);
    await refused("the same code cannot be used twice", () => confirmWithdraw(second.id, code));
    const after = await treasuryView();
    check(after.withdrawals.some((x) => x.id === second.id && x.status === "COMPLETE"), "it shows in the list of withdrawals");
  } finally {
    if (ids.length) {
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      for (const id of ids) await db.delete(ledgerEntries).where(like(ledgerEntries.memo, `%withdrawal ${id}%`));
      await db.delete(treasuryWithdrawals).where(inArray(treasuryWithdrawals.id, ids));
    }
    console.log(`Cleaned up the test withdrawals (started ${startedAt.toISOString()})`);
  }
}

main()
  .then(() => {
    console.log("All treasury withdrawal checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
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
import { WithdrawError, confirmWithdraw, startWithdraw, treasuryView } from "../treasury/withdraw";
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
  listDepositsAdmin,
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
  if (err instanceof AdminAuthError || err instanceof AdminActionError || err instanceof WithdrawError) return c.json({ error: err.message }, err.status);
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

adminApp.get("/deposits", requireAdmin, async (c) => c.json(await listDepositsAdmin(c.req.query("network"), pageOf(c.req.query("page")))));

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

// Treasury: balances, what can be withdrawn, and withdrawals to the payout address
adminApp.get("/treasury", requireAdmin, async (c) => c.json(await treasuryView()));

adminApp.post("/treasury/withdraw", requireAdmin, async (c) => {
  if (tooMany(c, "withdraw", 10, 60)) return c.json({ error: "Too many requests. Please wait an hour." }, 429);
  const b = await body(c);
  try {
    return c.json({ withdrawal: await startWithdraw(c.get("admin").account.id, { token: b.token, amount: b.amount }) });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/treasury/withdraw/:id/confirm", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json({ withdrawal: await confirmWithdraw(c.req.param("id"), b.code) });
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, dashboardV2: true, deposits: true, baseSend: true, totalBalance: true, audit2: true, adminDeposits: true, audit3: true, treasuryWithdraw: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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
// Treasury withdrawals: the admin taking fees out of the treasury, always to
// TREASURY_PAYOUT_ADDRESS on Arc, confirmed with a code emailed to the admin.
// Same statuses as sends. One open at a time (openKey).
// ---------------------------------------------------------------------------
export const treasuryWithdrawals = sqliteTable(
  "treasury_withdrawals",
  {
    id: id(),
    adminId: text("admin_id"),
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
  (t) => [index("treasury_withdrawals_status_idx").on(t.status)],
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
  // Treasury withdrawals from the admin dashboard: they only ever go to this
  // address (on Arc), set on Render, never typed in the dashboard. Unset = off.
  TREASURY_PAYOUT_ADDRESS: process.env.TREASURY_PAYOUT_ADDRESS?.trim().toLowerCase() || undefined,
  // USDC that always stays in the treasury for refunds, on top of open orders
  TREASURY_RESERVE_USDC: optionalNumber("TREASURY_RESERVE_USDC") ?? 10,
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

// USDC that must stay: the reserve plus open orders that may need a refund
async function heldBackMicro(): Promise<{ reserve: bigint; owed: bigint }> {
  const [row] = await db
    .select({ micro: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number) })
    .from(orders)
    .where(inArray(orders.status, [...OWED_STATUSES]));
  return { reserve: units("USDC", env.TREASURY_RESERVE_USDC.toFixed(6)), owed: BigInt(row?.micro ?? 0) };
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
import { advanceWithdrawals } from "./treasury/withdraw";
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
  // Treasury withdrawals by the admin: expired codes, results from Circle, retries
  try {
    await advanceWithdrawals();
  } catch (err) {
    console.error("[worker] treasury withdrawals failed:", err instanceof Error ? err.message : err);
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
green "OK"

# --- Development database ------------------------------------------------------------
step "Database: the treasury withdrawals table"
if ! grep -rqs 'CREATE TABLE `treasury_withdrawals`' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name treasury_withdrawals)
fi
grep -rqs 'CREATE TABLE `treasury_withdrawals`' backend/drizzle/*.sql || fail "The database change was not created. Paste the output to Claude."
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

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

# --- Live database (before the new code goes live) -----------------------------------
step "Live database: the treasury withdrawals table"
PROD_TOKEN="$(prod_token)"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the live database. Nothing was committed. Run again."
unset PROD_TOKEN
green "OK (the site keeps working: the old code ignores the new table)"

step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Admin dashboard: Treasury page with withdrawals to the payout address"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"treasuryWithdraw":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
echo "Vercel usually finishes the admin dashboard a minute or two after the push."

echo
green "Script 40 complete. Open dashboard.dataonchain.online > Treasury."
echo "Withdrawals stay off until you add TREASURY_PAYOUT_ADDRESS on Render (Environment)."
