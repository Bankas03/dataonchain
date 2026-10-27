#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 22: fixes from the code audit
#
# What this fixes:
#   1. Customers can reset a forgotten password ("Forgot password?" on the
#      login page, a link by email, valid one hour, signs out every device)
#   3. A payment interrupted by a restart, or whose answer from Circle was
#      lost, is found on Circle and continues (delivered or refunded), or is
#      closed so the customer can pay again. Nothing is left in limbo.
#   4. Slow bridge transfers no longer hold up deliveries and refunds
#   5. A bridge deposit that fails onchain is marked failed (it no longer
#      retries forever), and the customer can start a new one
#   6. Swaps never give less than the minimum shown on the quote
#   7. Only one open bridge transfer per user, enforced by the database
#   8. Admin: "Mark failed and refund" for orders stuck under review
#   9. Data plan prices refresh every hour instead of every 6 hours
#  10. Swap settings on Render are checked at startup
#   +  Duplicate errors from the database are recognised correctly again
#      (they were missed, which could leave a payment check failing forever)
#   (2, Render's paid plan, is done on Render: see the end of this script)
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/22_audit_fixes.sh
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

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
command -v turso >/dev/null || fail "Turso CLI not found (it was installed in script 01)"
[[ -f backend/src/admin/routes.ts && -f admin/package.json ]] || fail "Run this from ~/dataonchain after script 21 (admin dashboard)"
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/22_audit_fixes.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
git pull -q || fail "git pull failed"
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing the fixes"
mkdir -p "admin/src/app/(dash)/orders/[key]" "backend/scripts" "backend/src" "backend/src/admin" "backend/src/auth" "backend/src/bridge" "backend/src/catalog" "backend/src/db" "backend/src/email" "backend/src/payments" "backend/src/pricing" "backend/src/swap" "frontend/src/app/forgot-password" "frontend/src/app/login" "frontend/src/app/reset-password" "frontend/src/app/swap"
cat > "admin/src/app/(dash)/orders/[key]/page.tsx" <<'DOC_EOF'
"use client";

import { useParams } from "next/navigation";
import { useState } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { label, naira, short, usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  order: {
    id: string;
    reference: string;
    status: string;
    serviceType: string;
    network: string;
    planName: string | null;
    phone: string;
    ngnAmount: number;
    marginNgn: number;
    usdcAmount: string;
    rateNgnPerUsdc: number | null;
    rateSource: string | null;
    failureReason: string | null;
    createdAt: string;
    updatedAt: string;
  };
  user: { id: string; name: string; email: string; status: string };
  payments: { id: string; status: string; amount: string; fromAddress: string | null; toAddress: string; txUrl: string | null; txHash: string | null; confirmedAt: string | null; createdAt: string }[];
  deliveries: { id: string; provider: string; requestId: string; providerReference: string | null; status: string; request: unknown; response: unknown; createdAt: string; updatedAt: string }[];
  refund: { status: string; amount: string; toAddress: string; attempt: number; txUrl: string | null; lastError: string | null; confirmedAt: string | null; createdAt: string } | null;
  ledger: { account: string; currency: string; debit: string; credit: string; memo: string | null; createdAt: string }[];
  activity: { id: string; actorType: string; action: string; details: unknown; at: string }[];
  actions: { requery: boolean; retryRefund: boolean; failAndRefund: boolean };
};

export default function OrderPage() {
  const { key } = useParams<{ key: string }>();
  const { data, error, reload } = useLoad<Detail>(key ? `/orders/${key}` : null);
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [checked, setChecked] = useState("");

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const { order } = data;

  async function act(path: string, what: string, data: unknown = {}) {
    setMessage(null);
    try {
      const r = await post<{ before: string; after: string }>(path, data);
      setMessage({ tone: "good", text: `${what}: ${label(r.before)} → ${label(r.after)}` });
      reload();
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "That did not work." });
    }
  }

  return (
    <>
      <PageTitle
        title={`Order ${order.reference}`}
        subtitle={`${order.network.toUpperCase()} ${order.serviceType}${order.planName ? `, ${order.planName}` : ""} to ${order.phone}`}
        right={<Badge status={order.status} />}
      />

      {data.actions.requery || data.actions.retryRefund || data.actions.failAndRefund || message ? (
        <Card title="Actions" className="mb-6">
          <div className="flex flex-wrap items-center gap-3">
            {data.actions.requery ? (
              <ConfirmButton confirmText="Ask VTpass now" onConfirm={() => act(`/orders/${order.reference}/recheck`, "Checked with VTpass")}>
                Check with VTpass now
              </ConfirmButton>
            ) : null}
            {data.actions.retryRefund ? (
              <ConfirmButton confirmText="Yes, refund" onConfirm={() => act(`/orders/${order.reference}/refund`, "Refund")}>
                {order.status === "FLAGGED" ? "Retry the failed refund" : "Push the refund now"}
              </ConfirmButton>
            ) : null}
          </div>
          {data.actions.failAndRefund ? (
            <div className="mt-4 space-y-2 border-t border-zinc-100 pt-4 dark:border-zinc-800">
              <p className="text-sm text-zinc-700 dark:text-zinc-300">
                VTpass never gave a clear answer for this order. First check the VTpass dashboard for request id{" "}
                <span className="font-mono text-xs">{data.deliveries[0]?.requestId ?? "?"}</span>. Only if it did not go through:
              </p>
              <input
                value={checked}
                onChange={(e) => setChecked(e.target.value)}
                placeholder="What you checked (kept in the history)"
                className="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950"
              />
              <ConfirmButton
                danger
                disabled={!checked.trim()}
                confirmText="Yes, fail and refund"
                onConfirm={() => act(`/orders/${order.reference}/fail-refund`, "Closed and refunded", { reason: checked })}
              >
                Mark failed and refund
              </ConfirmButton>
              <p className="text-xs text-zinc-500">VTpass is asked one last time first. If it answers, the order follows that answer instead.</p>
            </div>
          ) : null}
          <p className="mt-3 text-xs text-zinc-500">
            The background worker does these automatically; use them to check now. A delivery is never sent twice, and a refund can never be paid twice.
          </p>
          {message ? <div className="mt-3"><Notice tone={message.tone}>{message.text}</Notice></div> : null}
        </Card>
      ) : null}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Order">
          <DefList
            items={[
              ["Customer", <RowLink key="u" href={`/users/${data.user.id}`}>{data.user.name} ({data.user.email})</RowLink>],
              ["Price", `${naira(order.ngnAmount)} = ${usdc(order.usdcAmount)} USDC`],
              ["Our margin", naira(order.marginNgn)],
              ["Rate", order.rateNgnPerUsdc ? `${naira(order.rateNgnPerUsdc)} per USDC (${order.rateSource ?? "?"})` : "—"],
              ["Created", when(order.createdAt)],
              ["Last change", when(order.updatedAt)],
              ["Note to customer", order.failureReason ?? "—"],
              ["Order id", <span key="i" className="font-mono text-xs">{order.id}</span>],
            ]}
          />
        </Card>
        <Card title="Refund">
          {data.refund ? (
            <DefList
              items={[
                ["Status", <Badge key="s" status={data.refund.status} />],
                ["Amount", `${usdc(data.refund.amount)} USDC`],
                ["To", <span key="t" className="font-mono text-xs">{data.refund.toAddress}</span>],
                ["Attempt", String(data.refund.attempt)],
                ["Transaction", <ExtLink key="x" href={data.refund.txUrl}>{data.refund.txUrl ? "View on explorer" : "Not sent yet"}</ExtLink>],
                ["Last error", data.refund.lastError ?? "—"],
                ["Started", when(data.refund.createdAt)],
                ["Confirmed", when(data.refund.confirmedAt)],
              ]}
            />
          ) : (
            <p className="text-sm text-zinc-500">No refund for this order.</p>
          )}
        </Card>
      </div>

      <Card title="Payment on Arc" className="mt-6">
        <Table head={["Status", "Amount", "From", "Transaction", "Confirmed"]} empty={data.payments.length === 0}>
          {data.payments.map((p) => (
            <tr key={p.id}>
              <Td><Badge status={p.status} /></Td>
              <Td className="tabular-nums">{usdc(p.amount)} USDC</Td>
              <Td className="font-mono text-xs">{short(p.fromAddress)}</Td>
              <Td><ExtLink href={p.txUrl}>{short(p.txHash, 10)}</ExtLink></Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(p.confirmedAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>

      <Card title="Delivery (VTpass)" className="mt-6">
        <Table head={["Status", "Request id", "VTpass ref", "Sent", "Last update", "Request", "Answer"]} empty={data.deliveries.length === 0}>
          {data.deliveries.map((d) => (
            <tr key={d.id}>
              <Td><Badge status={d.status} /></Td>
              <Td className="font-mono text-xs">{d.requestId}</Td>
              <Td className="font-mono text-xs">{d.providerReference ?? "—"}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.createdAt)}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.updatedAt)}</Td>
              <Td><Json value={d.request} /></Td>
              <Td><Json value={d.response} /></Td>
            </tr>
          ))}
        </Table>
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card title="Ledger">
          <Table head={["Account", "Debit", "Credit", "Memo"]} empty={data.ledger.length === 0}>
            {data.ledger.map((l, i) => (
              <tr key={i}>
                <Td className="font-mono text-xs">{l.account}</Td>
                <Td className="tabular-nums">{l.debit !== "0.000000" && l.debit !== "0" ? `${l.debit} ${l.currency}` : ""}</Td>
                <Td className="tabular-nums">{l.credit !== "0.000000" && l.credit !== "0" ? `${l.credit} ${l.currency}` : ""}</Td>
                <Td className="text-zinc-500">{l.memo ?? ""}</Td>
              </tr>
            ))}
          </Table>
        </Card>
        <Card title="History">
          <Table head={["When", "Who", "What", "Details"]} empty={data.activity.length === 0}>
            {data.activity.map((a) => (
              <tr key={a.id}>
                <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
                <Td>{a.actorType}</Td>
                <Td>{a.action}</Td>
                <Td><Json value={a.details} /></Td>
              </tr>
            ))}
          </Table>
        </Card>
      </div>
    </>
  );
}
DOC_EOF
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
cat > "backend/src/admin/actions.ts" <<'DOC_EOF'
// Things the admin can do from the dashboard. Each one is small, safe to
// repeat, and written to the audit log with the admin as the actor.
import { and, eq, inArray } from "drizzle-orm";
import { db } from "../db";
import { approvedDestinations, orders, payments, refunds, sessions, users, vtuTransactions } from "../db/schema";
import { reconcileOrder } from "../fulfilment/service";
import { advanceRefund, microText, startRefund } from "../refunds/service";
import { setPause, type PauseKey } from "../settings";
import { adminAudit } from "./auth";

export class AdminActionError extends Error {
  constructor(message: string, public status: 400 | 404 | 409 = 400) {
    super(message);
  }
}

async function findOrder(key: string) {
  const [order] = await db.select().from(orders).where(eq(orders.id, key)).limit(1);
  if (order) return order;
  const [byRef] = await db.select().from(orders).where(eq(orders.reference, key.toUpperCase())).limit(1);
  if (!byRef) throw new AdminActionError("Order not found.", 404);
  return byRef;
}

async function statusOf(orderId: string): Promise<string> {
  const [o] = await db.select({ status: orders.status }).from(orders).where(eq(orders.id, orderId)).limit(1);
  return o?.status ?? "UNKNOWN";
}

// Ask VTpass about the order right now (normally the worker waits between checks).
export async function recheckOrder(adminId: string, key: string) {
  const order = await findOrder(key);
  if (order.status !== "FULFILMENT_PENDING" && order.status !== "FLAGGED") {
    throw new AdminActionError("This order is not waiting for VTpass.", 409);
  }
  await reconcileOrder(order.id, true);
  const after = await statusOf(order.id);
  await adminAudit("admin.order_recheck", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// Start or push a refund. A refund that failed 3 times gets a new attempt:
// Circle never sent it (each attempt has its own idempotency key), so this
// cannot pay twice.
export async function retryRefund(adminId: string, key: string) {
  const order = await findOrder(key);
  const [refund] = await db.select().from(refunds).where(eq(refunds.orderId, order.id)).limit(1);

  if (order.status === "FAILED") {
    const [paid] = await db
      .select({ id: payments.id })
      .from(payments)
      .where(and(eq(payments.orderId, order.id), eq(payments.status, "CONFIRMED")))
      .limit(1);
    if (!paid) throw new AdminActionError("This order was never paid, so there is nothing to refund.", 409);
    await startRefund(order.id);
  } else if (order.status === "REFUND_PENDING") {
    await advanceRefund(order.id);
  } else if (order.status === "FLAGGED" && refund?.status === "FAILED") {
    const [reopened] = await db
      .update(refunds)
      .set({ status: "PENDING", attempt: refund.attempt + 1, circleTransactionId: null, lastError: "Retried by the admin" })
      .where(and(eq(refunds.id, refund.id), eq(refunds.status, "FAILED")))
      .returning();
    if (!reopened) throw new AdminActionError("The refund changed in the meantime. Reload and try again.", 409);
    await db
      .update(orders)
      .set({ status: "REFUND_PENDING" })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FLAGGED")));
    await advanceRefund(order.id);
  } else {
    throw new AdminActionError("There is no refund to retry for this order.", 409);
  }
  const after = await statusOf(order.id);
  await adminAudit("admin.refund_retry", { reference: order.reference, before: order.status, after }, adminId, { type: "order", id: order.id });
  return { before: order.status, after };
}

// For an order stuck under review because VTpass never gave a clear answer:
// ask VTpass one last time, and if it is still unclear, close the delivery as
// failed and refund the customer. Only do this after checking the VTpass
// dashboard shows the purchase did not go through, or the customer could get
// both the airtime/data and the refund.
export async function failAndRefund(adminId: string, key: string, reason: unknown) {
  const note = typeof reason === "string" ? reason.trim().slice(0, 300) : "";
  if (!note) throw new AdminActionError("Write what you checked (for example: not found on the VTpass dashboard).");
  const order = await findOrder(key);
  if (order.status !== "FLAGGED") throw new AdminActionError("Only orders under review (flagged) can be closed this way.", 409);
  const [paid] = await db
    .select({ id: payments.id })
    .from(payments)
    .where(and(eq(payments.orderId, order.id), eq(payments.status, "CONFIRMED")))
    .limit(1);
  if (!paid) throw new AdminActionError("This order has no confirmed payment, so there is nothing to refund. Check the payment on the explorer.", 409);
  const [refund] = await db.select({ id: refunds.id }).from(refunds).where(eq(refunds.orderId, order.id)).limit(1);
  if (refund) throw new AdminActionError("This order already has a refund. Use the refund button instead.", 409);

  // One last answer from VTpass first
  await reconcileOrder(order.id, true);
  const now = await statusOf(order.id);
  if (now !== "FLAGGED") {
    await adminAudit("admin.order_recheck", { reference: order.reference, before: order.status, after: now }, adminId, { type: "order", id: order.id });
    return { before: order.status, after: now };
  }

  await db
    .update(vtuTransactions)
    .set({ status: "FAILED" })
    .where(and(eq(vtuTransactions.orderId, order.id), inArray(vtuTransactions.status, ["SENT", "PENDING", "UNKNOWN"])));
  const [failed] = await db
    .update(orders)
    .set({
      status: "FAILED",
      failureReason: `The network could not confirm this delivery. Your ${microText(order.usdcAmountMicro)} USDC is being refunded to your wallet.`,
    })
    .where(and(eq(orders.id, order.id), eq(orders.status, "FLAGGED")))
    .returning();
  if (!failed) throw new AdminActionError("The order changed in the meantime. Reload and try again.", 409);
  await adminAudit("admin.order_failed_refunded", { reference: order.reference, reason: note }, adminId, { type: "order", id: order.id });
  await startRefund(order.id);
  return { before: order.status, after: await statusOf(order.id) };
}

// Suspended users cannot log in to anything new (orders, bridge, swaps).
// Their orders already in progress still finish, and refunds still go out.
export async function setUserStatus(adminId: string, userId: string, status: unknown, reason: unknown) {
  if (status !== "active" && status !== "suspended") throw new AdminActionError("Choose active or suspended.");
  const note = typeof reason === "string" ? reason.trim().slice(0, 300) : "";
  if (status === "suspended" && !note) throw new AdminActionError("Write a short reason for the suspension.");
  const [user] = await db.select().from(users).where(eq(users.id, userId)).limit(1);
  if (!user) throw new AdminActionError("User not found.", 404);
  if (user.status === status) return { status };
  await db.update(users).set({ status }).where(eq(users.id, userId));
  if (status === "suspended") await db.delete(sessions).where(eq(sessions.userId, userId));
  await adminAudit(
    status === "suspended" ? "admin.user_suspended" : "admin.user_restored",
    { email: user.email, reason: note || null },
    adminId,
    { type: "user", id: userId },
  );
  return { status };
}

export async function setProviderActive(adminId: string, id: string, active: unknown) {
  if (typeof active !== "boolean") throw new AdminActionError("Choose on or off.");
  const [row] = await db.update(approvedDestinations).set({ active }).where(eq(approvedDestinations.id, id)).returning();
  if (!row) throw new AdminActionError("Provider not found.", 404);
  await adminAudit(active ? "admin.provider_enabled" : "admin.provider_disabled", { label: row.label, chain: row.chain, address: row.address }, adminId, {
    type: "destination",
    id,
  });
  return { active };
}

export async function setPauseSwitch(adminId: string, key: PauseKey, paused: unknown) {
  if (typeof paused !== "boolean") throw new AdminActionError("Choose paused or open.");
  await setPause(key, paused);
  await adminAudit(paused ? "admin.paused" : "admin.resumed", { what: key }, adminId, { type: "setting", id: key });
  return { [key]: paused };
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
  swaps,
  users,
  vtuTransactions,
  walletSweeps,
  wallets,
  BRIDGE_STATUSES,
  REFUND_STATUSES,
  SWAP_STATUSES,
} from "../db/schema";
import { env } from "../env";
import { bridgeChains, chainByKey, type BridgeChain } from "../bridge/chains";
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
      bridgeChains: env.BRIDGE_ENABLED ? bridgeChains().map((c) => c.label) : [],
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
import { PaymentError, getOrderView, listOrders, payOrder } from "./payments/service";
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
app.get("/api/status", async (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridgeMonitor: true, swapCode: true, admin: true, auditFixes: true, adminConfigured: Boolean(env.ADMIN_EMAIL), bridge: env.BRIDGE_ENABLED, swap: env.SWAP_ENABLED, paused: await getPauses() }));

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
    },
  },

  advanced: {
    database: { generateId: () => randomUUID() },
  },
});

export type AuthSession = typeof auth.$Infer.Session;
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
cat > "backend/src/catalog/plans.ts" <<'DOC_EOF'
// Data plans, copied from VTpass into our database and refreshed every hour,
// so prices stay close to what VTpass charges at delivery.
import { and, asc, eq, lt, max } from "drizzle-orm";
import { db } from "../db";
import { NETWORKS, dataPlans } from "../db/schema";
import { getDataVariations, type Network } from "../vtpass/client";

const REFRESH_AFTER_MS = 60 * 60 * 1000;
const syncing = new Map<Network, Promise<void>>();

export type DataPlan = typeof dataPlans.$inferSelect;

export function isNetwork(value: unknown): value is Network {
  return typeof value === "string" && (NETWORKS as readonly string[]).includes(value);
}

export async function syncDataPlans(network: Network): Promise<number> {
  const startedAt = new Date();
  const variations = await getDataVariations(network);
  let saved = 0;
  for (const v of variations) {
    const priceKobo = Math.round(Number.parseFloat(v.variation_amount) * 100);
    const name = String(v.name ?? "").trim();
    if (!v.variation_code || !name || !Number.isFinite(priceKobo) || priceKobo <= 0) continue;
    await db
      .insert(dataPlans)
      .values({
        provider: "vtpass",
        serviceType: "data",
        network,
        planCode: v.variation_code,
        name,
        priceKobo,
        active: true,
        syncedAt: startedAt,
      })
      .onConflictDoUpdate({
        target: [dataPlans.provider, dataPlans.network, dataPlans.planCode],
        set: { name, priceKobo, active: true, syncedAt: startedAt },
      });
    saved++;
  }
  // Plans VTpass no longer offers are hidden, never deleted (old orders point at them).
  await db
    .update(dataPlans)
    .set({ active: false })
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network), lt(dataPlans.syncedAt, startedAt)));
  return saved;
}

async function refreshIfStale(network: Network): Promise<void> {
  const [row] = await db
    .select({ last: max(dataPlans.syncedAt) })
    .from(dataPlans)
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network)));
  const last = row?.last ? new Date(row.last).getTime() : 0;
  if (Date.now() - last < REFRESH_AFTER_MS) return;

  let running = syncing.get(network);
  if (!running) {
    running = syncDataPlans(network)
      .then(() => undefined)
      .finally(() => syncing.delete(network));
    syncing.set(network, running);
  }
  try {
    await running;
  } catch (err) {
    // Keep selling with the plans we already have; only fail if we have none.
    console.error(`[plans] refresh for ${network} failed:`, err);
    if (!last) throw err;
  }
}

export async function listDataPlans(network: Network): Promise<DataPlan[]> {
  await refreshIfStale(network);
  return db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .orderBy(asc(dataPlans.priceKobo));
}

export async function getActivePlan(planId: string, network: Network): Promise<DataPlan | undefined> {
  const [plan] = await db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.id, planId), eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .limit(1);
  return plan;
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
  // Where bridge alerts and the daily bridge report are emailed (optional)
  ALERT_EMAIL: process.env.ALERT_EMAIL?.trim() || undefined,
  // Limits for users bridging out (USDC)
  BRIDGE_MIN_USDC: optionalNumber("BRIDGE_MIN_USDC") ?? 1,
  BRIDGE_MAX_USDC: optionalNumber("BRIDGE_MAX_USDC") ?? 100,
  BRIDGE_DAILY_USDC: optionalNumber("BRIDGE_DAILY_USDC") ?? 200,
  // The most Circle may take in fees for one bridge transfer (safety cap)
  BRIDGE_MAX_FEE_USDC: optionalNumber("BRIDGE_MAX_FEE_USDC") ?? 0.5,
  // Admin dashboard: the only email that can log in, and the dashboard's address
  // (used in password reset links). Both set on Render.
  ADMIN_EMAIL: process.env.ADMIN_EMAIL?.trim().toLowerCase() || undefined,
  ADMIN_URL: (process.env.ADMIN_URL ?? "http://localhost:3001").trim().replace(/\/$/, ""),
  // Background worker: on in production unless WORKER_ENABLED=false
  WORKER_ENABLED: (process.env.WORKER_ENABLED ?? (NODE_ENV === "production" ? "true" : "false")) === "true",
};
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
import { and, desc, eq, gte, inArray, isNotNull, isNull, lt, notInArray } from "drizzle-orm";
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

// Used by the background worker later: every order still waiting for its payment.
export async function pendingPaymentOrders(): Promise<Order[]> {
  return db.select().from(orders).where(inArray(orders.status, ["PAYMENT_PENDING"])).limit(100);
}
DOC_EOF
cat > "backend/src/pricing/quote.ts" <<'DOC_EOF'
// Price quotes. A quote is an order in QUOTED status with a USDC price
// that is held until quoteExpiresAt.
import { randomInt } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { normalizeNigerianPhone } from "../auth/phone";
import { getActivePlan, isNetwork } from "../catalog/plans";
import { db } from "../db";
import { isUniqueViolation } from "../db/errors";
import { dataPlans, orders } from "../db/schema";
import { env } from "../env";
import { getCurrentRate } from "./rates";

export const AIRTIME_MIN_NGN = 50;
export const AIRTIME_MAX_NGN = 50_000;

export class QuoteError extends Error {}

type Order = typeof orders.$inferSelect;

// All money is whole numbers: kobo for naira, micro USDC (6 decimals) for USDC.
// Rounding always goes up, so the platform never sells below cost.
export function priceInUsdc(ngnKobo: number, koboPerUsdc: number, marginBps: number) {
  const marginKobo = Math.ceil((ngnKobo * marginBps) / 10_000);
  const usdcMicro = Math.ceil(((ngnKobo + marginKobo) * 1_000_000) / koboPerUsdc);
  return { marginKobo, usdcMicro };
}

export function microToUsdc(micro: number): string {
  return `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
}

function localPhone(phone: string): string {
  return phone.startsWith("+234") ? `0${phone.slice(4)}` : phone;
}

function present(order: Order, planName: string | null) {
  return {
    reference: order.reference,
    status: order.status,
    serviceType: order.serviceType,
    network: order.network,
    planName,
    phone: localPhone(order.phone),
    ngnAmount: order.ngnAmountKobo / 100,
    usdcAmount: microToUsdc(order.usdcAmountMicro),
    expiresAt: order.quoteExpiresAt.toISOString(),
  };
}

export async function createQuote(userId: string, body: unknown) {
  const input = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;

  const serviceType = input.serviceType;
  if (serviceType !== "airtime" && serviceType !== "data") throw new QuoteError("Choose airtime or data.");
  const network = input.network;
  if (!isNetwork(network)) throw new QuoteError("Choose a network: MTN, Airtel, Glo or 9mobile.");
  const phone = normalizeNigerianPhone(String(input.phone ?? ""));
  if (!phone) throw new QuoteError("Enter a valid Nigerian phone number, for example 08012345678.");

  let ngnKobo: number;
  let planId: string | null = null;
  let planName: string | null = null;
  if (serviceType === "data") {
    const plan = await getActivePlan(String(input.planId ?? ""), network);
    if (!plan) throw new QuoteError("That data plan is not available. Please choose another one.");
    ngnKobo = plan.priceKobo;
    planId = plan.id;
    planName = plan.name;
  } else {
    const amount = Number(input.amountNgn);
    if (!Number.isInteger(amount) || amount < AIRTIME_MIN_NGN || amount > AIRTIME_MAX_NGN) {
      throw new QuoteError(
        `Airtime must be a whole naira amount from ₦${AIRTIME_MIN_NGN} to ₦${AIRTIME_MAX_NGN.toLocaleString("en-NG")}.`,
      );
    }
    ngnKobo = amount * 100;
  }

  const rate = await getCurrentRate();
  const { marginKobo, usdcMicro } = priceInUsdc(ngnKobo, rate.koboPerUsdc, env.PRICING_MARGIN_BPS);
  const quoteExpiresAt = new Date(Date.now() + env.QUOTE_TTL_MINUTES * 60_000);

  for (let attempt = 0; attempt < 5; attempt++) {
    const reference = `ARC${randomInt(10_000_000, 100_000_000)}`;
    try {
      const [order] = await db
        .insert(orders)
        .values({
          reference,
          userId,
          serviceType,
          network,
          planId,
          phone,
          ngnAmountKobo: ngnKobo,
          marginKobo,
          usdcAmountMicro: usdcMicro,
          exchangeRateId: rate.id,
          status: "QUOTED",
          quoteExpiresAt,
        })
        .returning();
      if (!order) throw new Error("Could not save the quote");
      return {
        ...present(order, planName),
        rate: rate.koboPerUsdc / 100,
        marginPercent: env.PRICING_MARGIN_BPS / 100,
      };
    } catch (err) {
      if (isUniqueViolation(err, "reference") && attempt < 4) continue;
      throw err;
    }
  }
  throw new Error("Could not create a quote reference");
}

export async function getQuote(userId: string, reference: string) {
  const [row] = await db
    .select({ order: orders, planName: dataPlans.name })
    .from(orders)
    .leftJoin(dataPlans, eq(orders.planId, dataPlans.id))
    .where(and(eq(orders.reference, reference), eq(orders.userId, userId)))
    .limit(1);
  if (!row) return null;

  let order = row.order;
  if (order.status === "QUOTED" && order.quoteExpiresAt.getTime() < Date.now()) {
    const [updated] = await db
      .update(orders)
      .set({ status: "EXPIRED" })
      .where(and(eq(orders.id, order.id), eq(orders.status, "QUOTED")))
      .returning();
    order = updated ?? { ...order, status: "EXPIRED" };
  }
  return present(order, row.planName ?? null);
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
  USDC: { decimals: 6, min: 0.5, max: 500, label: "USDC" },
  EURC: { decimals: 6, min: 0.5, max: 500, label: "EURC" },
  cirBTC: { decimals: 8, min: 0.000005, max: 0.01, label: "cirBTC" },
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

function errorText(err: unknown): string {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  const base = err instanceof Error ? err.message : String(err);
  return (detail ? `${base} ${JSON.stringify(detail)}` : base).slice(0, 500);
}

function friendly(message: string): string {
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
cat > "frontend/src/app/login/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function LoginPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Arriving from an expired or used confirmation link
  useEffect(() => {
    if (new URLSearchParams(window.location.search).get("error") === "link") {
      setNotice("That confirmation link has expired or was already used. Log in and we will send you a new one.");
    }
  }, []);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setNotice(null);
    setBusy(true);
    const form = new FormData(event.currentTarget);
    const email = String(form.get("email")).trim();
    const { error } = await authClient.signIn.email({
      email,
      password: String(form.get("password")),
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      if (error.status === 403) {
        setNotice(`Please confirm your email first. We just sent a new link to ${email}.`);
        return;
      }
      setError(error.message ?? "Could not log you in. Check your email and password.");
      return;
    }
    router.push("/dashboard");
  }

  return (
    <AuthShell
      title="Welcome back"
      subtitle="Log in to buy airtime and data."
      footer={
        <>
          New here?{" "}
          <Link href="/signup" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Create an account
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field label="Password" name="password" type="password" autoComplete="current-password" required />
        <p className="-mt-2 text-right text-sm">
          <Link href="/forgot-password" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Forgot password?
          </Link>
        </p>
        {notice ? (
          <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">{notice}</p>
        ) : null}
        <FormError message={error} />
        <SubmitButton busy={busy}>Log in</SubmitButton>
      </form>
    </AuthShell>
  );
}
DOC_EOF
cat > "frontend/src/app/swap/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Limits = Record<Token, { decimals: number; min: number; max: number }>;
type TokensResponse = { balances: Record<Token, string>; limits: Limits; feePercent: number; slippagePercent: number };
type Quote = {
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  feePercent: number;
  slippagePercent: number;
  balance: string;
  enough: boolean;
};
type SwapView = {
  id: string;
  status: string;
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  amountOut: string | null;
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

export default function SwapPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [info, setInfo] = useState<TokensResponse | null>(null);
  const [tokenIn, setTokenIn] = useState<Token>("USDC");
  const [tokenOut, setTokenOut] = useState<Token>("EURC");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [done, setDone] = useState<SwapView | null>(null);
  const [recent, setRecent] = useState<SwapView[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      setInfo(await api<TokensResponse>("/swap/tokens"));
      const r = await api<{ swaps: SwapView[] }>("/swaps");
      setRecent(r.swaps.filter(Boolean));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, []);

  useEffect(() => {
    if (session) void load();
  }, [session, load]);

  function pick(side: "in" | "out", t: Token) {
    setQuote(null);
    setDone(null);
    if (side === "in") {
      if (t === tokenOut) setTokenOut(tokenIn);
      setTokenIn(t);
    } else {
      if (t === tokenIn) setTokenIn(tokenOut);
      setTokenOut(t);
    }
  }

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    setDone(null);
    try {
      const r = await api<{ quote: Quote }>("/swap/quote", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount }) });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ swap: SwapView }>("/swap", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount, minOut: quote?.minOut ?? null }) });
      setDone(r.swap);
      setQuote(null);
      setAmount("");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "The swap could not be completed.");
    } finally {
      setBusy(false);
    }
  }

  const limit = info?.limits[tokenIn];

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Swap</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Swap between USDC, EURC and cirBTC in your Arc wallet. No gas to pay.
          {info ? ` Fee ${info.feePercent}%; if the price moves more than ${info.slippagePercent}% against you, the swap is cancelled.` : ""}
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have: {TOKEN_LIST.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(" · ")}
          </p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <form onSubmit={getQuote} className="space-y-5">
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">From</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("in", t)} className={choiceClass(tokenIn === t)}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">To</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("out", t)} disabled={t === tokenIn} className={`${choiceClass(tokenOut === t)} disabled:opacity-40`}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="flex items-center justify-between">
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount of {tokenIn}
                </label>
                {info ? (
                  <button
                    type="button"
                    onClick={() => {
                      setAmount(info.balances[tokenIn]);
                      setQuote(null);
                    }}
                    className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                  >
                    Use all ({fmt(info.balances[tokenIn], tokenIn)})
                  </button>
                ) : null}
              </div>
              <input
                id="amount"
                inputMode="decimal"
                value={amount}
                onChange={(e) => {
                  setAmount(e.target.value);
                  setQuote(null);
                  setDone(null);
                }}
                placeholder={limit ? `${limit.min} to ${limit.max}` : ""}
                className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
              />
            </div>
            {!quote ? (
              <button
                type="submit"
                disabled={busy || !amount}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a price..." : "Get a price"}
              </button>
            ) : null}
          </form>

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[10rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">You swap</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.amountIn, quote.tokenIn)} {quote.tokenIn}</dd>
                <dt className="text-zinc-500">You get about</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.estimatedOut, quote.tokenOut)} {quote.tokenOut}</dd>
                <dt className="text-zinc-500">At least</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {fmt(quote.minOut, quote.tokenOut)} {quote.tokenOut} <span className="text-xs text-zinc-500">(or it is cancelled)</span>
                </dd>
                <dt className="text-zinc-500">Fees</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.feePercent}% dataonchain + 0.02% swap provider, included above</dd>
              </dl>
              {!quote.enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough {quote.tokenIn}. You have {fmt(quote.balance, quote.tokenIn)}.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={confirm}
                  disabled={busy || !quote.enough}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Swapping..." : "Confirm swap"}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
              <p className="text-xs text-zinc-500">Prices on the test network can move a lot. If the swap is cancelled, nothing is taken.</p>
            </div>
          ) : null}

          {done ? (
            <div
              className={`rounded-lg px-3 py-2 text-sm ${
                done.status === "COMPLETE"
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
              }`}
            >
              {done.status === "COMPLETE"
                ? `Done. ${fmt(done.amountIn, done.tokenIn)} ${done.tokenIn} swapped for ${fmt(done.amountOut ?? done.estimatedOut, done.tokenOut)} ${done.tokenOut}.`
                : "The swap was sent but its result is not clear yet. Check your balance in a minute; our team is notified."}
              {done.explorerUrl ? (
                <a href={done.explorerUrl} target="_blank" rel="noreferrer" className="ml-1 font-medium underline">
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
            <h2 className="text-sm font-medium text-zinc-500">Recent swaps</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {recent.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <span className="text-zinc-900 dark:text-zinc-100">
                    {fmt(s.amountIn, s.tokenIn)} {s.tokenIn} → {s.amountOut ? `${fmt(s.amountOut, s.tokenOut)} ` : ""}
                    {s.tokenOut}
                  </span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    {s.status === "COMPLETE" ? "Done" : s.status === "FAILED" ? "Cancelled" : s.status === "UNKNOWN" ? "Checking" : "In progress"}
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
cat > "backend/scripts/fixes-smoke.ts" <<'DOC_EOF'
// Checks for the script 22 fixes, on the development database:
//   - an interrupted payment that never reached Circle is closed, so the
//     customer can pay again (and the Circle lookup itself works)
//   - an interrupted payment is left alone when another payment of the same
//     order already holds the Circle transfer
//   - the admin "fail and refund" refuses orders without a confirmed payment,
//     and closes a stuck order and starts its refund (a 0.000001 USDC refund,
//     from the treasury to itself)
//   - the database allows only one open bridge transfer per user
// Run with: npx tsx scripts/fixes-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray, or } from "drizzle-orm";
import { db } from "../src/db";
import { isUniqueViolation } from "../src/db/errors";
import { auditLogs, bridgeTransfers, ledgerEntries, orders, payments, refunds, users, vtuTransactions, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { AdminActionError, failAndRefund } from "../src/admin/actions";
import { recoverInterruptedPayments } from "../src/payments/service";
import { getCurrentRate } from "../src/pricing/rates";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

const ago = (minutes: number) => new Date(Date.now() - minutes * 60_000);
const ref = () => `ARCT${Math.floor(Math.random() * 1e9)}`;

async function main() {
  const userId = randomUUID();
  const orderIds: string[] = [];
  const walletRowId = randomUUID();
  try {
    await db.insert(users).values({ id: userId, name: "Fixes Smoke", email: `fixes-smoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
    // A wallet row so refunds have somewhere to go: the treasury's own address (it pays itself)
    await db.insert(wallets).values({
      id: walletRowId,
      userId,
      purpose: "user",
      circleWalletId: `fixes-smoke-${walletRowId}`,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      blockchain: env.CIRCLE_BLOCKCHAIN,
      address: env.TREASURY_ADDRESS,
      accountType: "SCA",
    });
    const rate = await getCurrentRate();
    const base = {
      userId,
      serviceType: "airtime" as const,
      network: "mtn" as const,
      phone: "+2348011111111",
      ngnAmountKobo: 5_000,
      marginKobo: 0,
      usdcAmountMicro: 1,
      exchangeRateId: rate.id,
      quoteExpiresAt: new Date(Date.now() + 10 * 60_000),
    };

    // 1. Interrupted payment that never reached Circle (a real user wallet is used for the lookup)
    const [realWallet] = await db.select().from(wallets).where(eq(wallets.accountType, "SCA")).limit(1);
    const [o1] = await db.insert(orders).values({ ...base, reference: ref(), status: "PAYMENT_PENDING" }).returning();
    orderIds.push(o1!.id);
    await db.insert(payments).values({
      orderId: o1!.id,
      walletId: realWallet?.id ?? null,
      toAddress: env.TREASURY_ADDRESS,
      token: "test",
      blockchain: env.CIRCLE_BLOCKCHAIN,
      amountMicro: 1,
      status: "INITIATED",
      createdAt: ago(3),
    });

    // 2. Interrupted payment, but another payment of the same order holds the transfer
    const [o2] = await db.insert(orders).values({ ...base, reference: ref(), status: "QUOTED" }).returning();
    orderIds.push(o2!.id);
    await db.insert(payments).values([
      { orderId: o2!.id, walletId: null, toAddress: env.TREASURY_ADDRESS, token: "test", blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "INITIATED", createdAt: ago(3) },
      { orderId: o2!.id, walletId: null, toAddress: env.TREASURY_ADDRESS, token: "test", blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "FAILED", circleTransactionId: `fixes-smoke-${randomUUID()}`, createdAt: ago(3) },
    ]);

    await recoverInterruptedPayments();
    const [p1] = await db.select().from(payments).where(eq(payments.orderId, o1!.id));
    const [after1] = await db.select().from(orders).where(eq(orders.id, o1!.id));
    check(p1?.status === "FAILED" && after1?.status === "QUOTED", "an interrupted payment Circle never got is closed and the order can be paid again", { p: p1?.status, o: after1?.status });
    const p2 = await db.select().from(payments).where(eq(payments.orderId, o2!.id));
    check(p2.every((p) => p.status === "FAILED") && p2.filter((p) => p.circleTransactionId === null).length === 1, "an interrupted payment is left closed when the order's transfer is held elsewhere", p2.map((p) => p.status));

    // 3. Fail and refund: refused without a confirmed payment
    const [o3] = await db.insert(orders).values({ ...base, reference: ref(), status: "FLAGGED" }).returning();
    orderIds.push(o3!.id);
    let refused = false;
    try {
      await failAndRefund("fixes-smoke-admin", o3!.reference, "checked on VTpass");
    } catch (err) {
      refused = err instanceof AdminActionError && err.status === 409;
    }
    check(refused, "fail and refund is refused when there is no confirmed payment");

    // 4. Fail and refund on a stuck, paid order
    const [o4] = await db.insert(orders).values({ ...base, reference: ref(), status: "FLAGGED" }).returning();
    orderIds.push(o4!.id);
    await db.insert(payments).values({
      orderId: o4!.id, walletId: walletRowId, toAddress: env.TREASURY_ADDRESS, token: (await usdcTokenId()) ?? "test",
      blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "CONFIRMED", txHash: `0xfixes${randomUUID().replace(/-/g, "")}`, confirmedAt: new Date(),
    });
    await db.insert(vtuTransactions).values({ orderId: o4!.id, provider: "vtpass", requestId: `fixes-smoke-${randomUUID()}`, status: "PENDING" });
    let noReason = false;
    try {
      await failAndRefund("fixes-smoke-admin", o4!.reference, "  ");
    } catch (err) {
      noReason = err instanceof AdminActionError;
    }
    check(noReason, "fail and refund needs a note of what was checked");
    const result = await failAndRefund("fixes-smoke-admin", o4!.reference, "smoke test: not on the VTpass dashboard");
    const [vtu] = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, o4!.id));
    check(["REFUND_PENDING", "REFUNDED"].includes(result.after), "the stuck order is closed and its refund starts", result);
    check(vtu?.status === "FAILED", "the unclear delivery is marked failed", vtu?.status);
    let again = false;
    try {
      await failAndRefund("fixes-smoke-admin", o4!.reference, "again");
    } catch (err) {
      again = err instanceof AdminActionError;
    }
    check(again, "it cannot be done twice");

    // 5. One open bridge transfer per user
    const t = {
      userId,
      direction: "OUT" as const,
      sourceChain: "arc",
      destinationChain: "base",
      sourceDomain: 26,
      destinationDomain: 6,
      depositorWalletId: "fixes-smoke",
      depositorAddress: "0x000000000000000000000000000000000000dead",
      recipientAddress: "0x000000000000000000000000000000000000beef",
      amountMicro: 1_000_000,
      status: "QUOTED" as const,
      openKey: userId,
    };
    await db.insert(bridgeTransfers).values({ ...t, salt: `0x${randomUUID().replace(/-/g, "")}` });
    let blocked: unknown = null;
    try {
      await db.insert(bridgeTransfers).values({ ...t, salt: `0x${randomUUID().replace(/-/g, "")}` });
    } catch (err) {
      blocked = err;
    }
    check(isUniqueViolation(blocked, "open_key"), "the database refuses a second open transfer for the same user", String(blocked));
  } finally {
    await db.delete(bridgeTransfers).where(eq(bridgeTransfers.userId, userId));
    if (orderIds.length) {
      await db.delete(refunds).where(inArray(refunds.orderId, orderIds));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, orderIds));
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, orderIds));
      await db.delete(payments).where(inArray(payments.orderId, orderIds));
      await db.delete(auditLogs).where(or(inArray(auditLogs.targetId, orderIds), eq(auditLogs.actorId, "fixes-smoke-admin")));
      await db.delete(orders).where(inArray(orders.id, orderIds));
    }
    await db.delete(wallets).where(eq(wallets.id, walletRowId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test data");
  }
}

// The treasury's USDC token id on Circle, so the tiny refund can really be sent
async function usdcTokenId(): Promise<string | null> {
  const { circle } = await import("../src/circle/client");
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  return (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"))?.token?.id ?? null;
}

main()
  .then(() => {
    console.log("All fix checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
DOC_EOF
cat > "backend/src/db/errors.ts" <<'DOC_EOF'
// Database error helpers.
//
// Drizzle wraps database errors: the message is "Failed query: ..." and the
// real reason ("UNIQUE constraint failed: table.column") is in err.cause.
// So the whole chain of causes is checked, not just the top message.
function reasons(err: unknown): string {
  const parts: string[] = [];
  let e: unknown = err;
  for (let i = 0; i < 5 && e; i++) {
    if (e instanceof Error) {
      parts.push(e.message);
      e = (e as { cause?: unknown }).cause;
    } else {
      parts.push(String(e));
      break;
    }
  }
  return parts.join(" | ");
}

// True when the error is a duplicate value on a unique column (optionally a
// given column, for example "open_key" or "orders.reference").
export function isUniqueViolation(err: unknown, column?: string): boolean {
  const m = /UNIQUE constraint failed: ([^|\n]+)/i.exec(reasons(err));
  if (!m) return false;
  return column ? m[1]!.includes(column) : true;
}
DOC_EOF
cat > "frontend/src/app/forgot-password/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function ForgotPasswordPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const email = String(new FormData(event.currentTarget).get("email")).trim();
    setBusy(true);
    const { error } = await authClient.requestPasswordReset({ email, redirectTo: "/reset-password" });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not send the link. Please try again.");
      return;
    }
    setSentTo(email);
  }

  return (
    <AuthShell
      title="Forgot your password?"
      subtitle="Enter your email and we will send you a link to choose a new password."
      footer={
        <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Back to log in
        </Link>
      }
    >
      {sentTo ? (
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          If {sentTo} has a dataonchain account, a link is on its way. It works once and expires after one hour. Check
          your spam folder too.
        </p>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="Email" name="email" type="email" autoComplete="email" required autoFocus />
          <FormError message={error} />
          <SubmitButton busy={busy}>Email me a link</SubmitButton>
        </form>
      )}
    </AuthShell>
  );
}
DOC_EOF
cat > "frontend/src/app/reset-password/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useEffect, useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function ResetPasswordPage() {
  const [token, setToken] = useState<string | null>(null);
  const [linkError, setLinkError] = useState(false);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  // The email link lands here with ?token=... (or ?error=INVALID_TOKEN if it expired)
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    setToken(params.get("token"));
    setLinkError(params.has("error"));
    setReady(true);
  }, []);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const newPassword = String(form.get("password"));
    if (newPassword !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    if (!token) return;
    setBusy(true);
    const { error } = await authClient.resetPassword({ newPassword, token });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not set the new password. Ask for a new link and try again.");
      return;
    }
    setDone(true);
  }

  const footer = (
    <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      Back to log in
    </Link>
  );

  if (!ready) {
    return (
      <AuthShell title="Choose a new password" subtitle="Loading..." footer={footer}>
        <span />
      </AuthShell>
    );
  }
  if (done) {
    return (
      <AuthShell title="Password changed" subtitle="You can log in with your new password now." footer={footer}>
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          Your password was changed and you were signed out on every device. Your wallet and balance are unchanged.
        </p>
      </AuthShell>
    );
  }
  if (!token || linkError) {
    return (
      <AuthShell title="This link has expired" subtitle="Reset links work once and expire after one hour." footer={footer}>
        <Link
          href="/forgot-password"
          className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center font-medium text-white hover:bg-emerald-800"
        >
          Send me a new link
        </Link>
      </AuthShell>
    );
  }
  return (
    <AuthShell title="Choose a new password" subtitle="At least 8 characters." footer={footer}>
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="New password" name="password" type="password" autoComplete="new-password" minLength={8} required autoFocus />
        <Field label="New password again" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
        <FormError message={error} />
        <SubmitButton busy={busy}>Save new password</SubmitButton>
      </form>
    </AuthShell>
  );
}
DOC_EOF
green "OK"

# --- 2. Database --------------------------------------------------------------------
step "Database: one open bridge transfer per user"
if ! grep -rqs 'bridge_transfers_open_key_idx' backend/drizzle/*.sql; then
  (cd backend && npx drizzle-kit generate --name bridge_open_key)
fi
grep -rqs 'bridge_transfers_open_key_idx' backend/drizzle/*.sql || fail "The bridge migration was not created"
(cd backend && npx drizzle-kit migrate && npm run db:check) || fail "Could not update the development database"
green "OK: development database updated"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build) || fail "Backend check failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Logins: customer forgot password, and the admin dashboard"
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
  fail "Admin test failed (details above). Nothing was committed. Paste the output to Claude."
fi
stop_api
green "OK"

step "The fixes: interrupted payments, fail and refund, one transfer at a time"
(cd backend && npx tsx scripts/fixes-smoke.ts) || fail "Fix test failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

step "Delivery and refunds: make sure they still work"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
set +e
(cd backend && npx tsx scripts/refund-smoke.ts); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury needs more test USDC. Send at least 2 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Refund test failed (details above). Nothing was committed. Paste the output to Claude."
fi
green "OK"

step "Bridge: a real 0.2 USDC transfer to Base Sepolia (takes a few minutes)"
set +e
(cd backend && BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 npx tsx scripts/bridge-smoke.ts); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Bridge test failed (details above). Nothing was committed. Paste the output to Claude."
fi
green "OK"

step "Website and admin dashboard: build"
(cd frontend && npm run build) || fail "Website build failed (details above). Nothing was committed. Paste the output to Claude."
(cd admin && npm run build) || fail "Admin dashboard build failed (details above). Nothing was committed. Paste the output to Claude."
green "OK"

# --- 4. Production database ---------------------------------------------------------
step "Production database: one open bridge transfer per user"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a production database token"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate \
  && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check) \
  || fail "Could not update the production database. Nothing was committed."
unset PROD_TOKEN
green "OK"

# --- 5. Commit, push ---------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Audit fixes: customer password reset, payment recovery, bridge worker and deposit failures, swap minimum, one open transfer, admin fail and refund"
git push
green "OK: pushed."

wait_for "the new API on Render" "$PROD_API/api/status" '"auditFixes":true' || fail "The API did not come up. Check Events and Logs on Render."
curl -s --max-time 30 "$PROD_FRONTEND/forgot-password" >/dev/null || true
wait_for "the website on Vercel" "$PROD_FRONTEND/forgot-password" 'Forgot your password' 30 || yellow "The website did not show the new page yet. Check vercel.com, then open $PROD_FRONTEND/forgot-password."

echo
green "Script 22 complete. All the audit fixes are live."
echo
bold "One thing only you can do: keep the server awake (fix 2)"
echo "  Render's free plan pauses the server after 15 minutes without visitors, and"
echo "  while it sleeps nothing moves: refunds, deliveries, bridge transfers, alerts."
echo "  On Render > your dataonchain service > Settings > Instance Type, choose a"
echo "  paid instance (the smallest one is enough for now), and confirm."
echo
echo "Try the new page: $PROD_FRONTEND/forgot-password"
