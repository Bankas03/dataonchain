#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 31: fixes from the full audit of the mainnet code
#
#   1. Send codes: many wrong codes sent at the same moment could each be
#      counted as the first try, so the "5 tries" limit could be bypassed by
#      someone holding the password. Every try is now counted in one step.
#   2. Swaps: a refused swap whose error quoted transaction data could be shown
#      as "result not clear" instead of "nothing was taken". Only a real
#      transaction hash now counts.
#   3. Transfer fees: a fee transfer Circle keeps refusing is now reported after
#      48 hours instead of being retried forever.
#   4. Admin overview: sends waiting for Circle over 30 minutes are flagged.
#   5. Send page: needs a confirmed email (like the other money pages), and the
#      transfer page says "being taken now" for a fee in progress.
#   No database change. Tested on testnet first.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/31_mainnet_audit_fixes.sh
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
[[ -f backend/src/send/service.ts ]] || fail "Run this from ~/dataonchain after script 30"
[[ "$(env_get CIRCLE_BLOCKCHAIN)" == "ARC-TESTNET" ]] || fail "backend/.env must stay on ARC-TESTNET (tests run there). Tell Claude."
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
green "OK"

if [[ -n "$(git status --porcelain | grep -v 'setup/31_mainnet_audit_fixes.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed (check your internet connection, then run again)"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the code"
mkdir -p "backend/scripts" "backend/src" "backend/src/admin" "backend/src/bridge" "backend/src/send" "backend/src/swap" "frontend/src/app/bridge/[id]"
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, accountTools: true, mainnetReady: true, networkFee: true, sendReady: true, mainnetAudit: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses(), notices: await pauseNotices(), network: env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET") ? "testnet" : "mainnet" }));

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
  let sent;
  try {
    sent = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
  } catch (err) {
    // Retried with the same key on every worker run; reported after 48 hours
    if (Date.now() - t.createdAt.getTime() > GIVE_UP_MS) {
      await giveUp(t, `Circle refused the fee transfer: ${err instanceof Error ? err.message : String(err)}`.slice(0, 300));
      return;
    }
    throw err;
  }
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
import { and, desc, eq, gte, inArray, lt, notInArray, sql } from "drizzle-orm";
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
                            : t.status === "COMPLETE"
                              ? "(being taken now)"
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
green "OK"

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

step "Send on testnet: 8 wrong codes at once, then a real 0.2 USDC send"
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

# --- 5. Commit and push --------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.mainnet|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git diff --cached --quiet || git commit -q -m "Mainnet audit fixes: send code tries counted atomically, swap hash detection, fee retries reported, stuck sends flagged"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"mainnetAudit":true' || fail "The API did not come up. Check Events and Logs on Render, then run this script again."
STATUS="$(curl -s --max-time 30 "$PROD_API/api/status" || true)"
[[ "$STATUS" == *'"network":"mainnet"'* ]] || fail "Render is not on mainnet. Tell Claude."

echo
green "Script 31 complete. The audit fixes are live. Nothing else to do."
echo "Bridge, swaps and sends stay as you set them in admin Settings."
