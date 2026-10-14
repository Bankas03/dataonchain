#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 11 (Phase 9): delivery through VTpass
#
# What this adds:
#   - As soon as a payment is confirmed, the airtime or data is bought from
#     VTpass with ONE unique request id per order
#   - VTpass answers are read carefully:
#       delivered               -> order FULFILLED
#       definite failure codes  -> order FAILED (waits for a refund)
#       pending / unclear / timeout -> NEVER resent; asked again (requery)
#       still unclear after 30 minutes -> FLAGGED for you to check
#   - A background worker (every 30 seconds) finishes payments and deliveries
#     even if the customer closed their browser
#   - Ledger entries for every delivery (USDC sale and naira cost)
#   - Order page: live delivery status, VTpass reference, receipt
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/11_delivery.sh
# =============================================================================
set -euo pipefail

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
  done < <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  if [[ -n "$found" ]]; then
    git diff --cached --name-only
    git reset -q
    fail "The value of$found is inside one of the files above. Nothing was committed. Delete that file or remove the secret, then run again."
  fi
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
[[ -f backend/src/payments/service.ts ]] || fail "Run this from ~/dataonchain after Phase 8 (script 10)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/11_delivery.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Backend code ------------------------------------------------------------
step "Writing backend files"

cat >> backend/.env.example <<'EOF'

# Background worker (payments and deliveries). On by default in production.
# WORKER_ENABLED=true
EOF
awk '!(/^# Background worker \(payments/ && a++) && !(/^# WORKER_ENABLED=/ && b++)' \
  backend/.env.example > backend/.env.example.tmp && mv backend/.env.example.tmp backend/.env.example

python3 - <<'PY'
import sys
p = "backend/src/env.ts"
s = open(p).read()
if "WORKER_ENABLED" not in s:
    marker = '  EXPLORER_TX_URL: process.env.EXPLORER_TX_URL ?? "https://explorer.testnet.arc.io/tx/",\n'
    if marker not in s:
        sys.exit("could not find EXPLORER_TX_URL in env.ts")
    s = s.replace(marker, marker +
        "  // Background worker: on in production unless WORKER_ENABLED=false\n"
        "  WORKER_ENABLED: (process.env.WORKER_ENABLED ?? (NODE_ENV === \"production\" ? \"true\" : \"false\")) === \"true\",\n", 1)
open(p, "w").write(s)
PY
grep -q 'WORKER_ENABLED:' backend/src/env.ts || fail "Could not update backend/src/env.ts"

# VTpass client: purchase and requery
python3 - <<'PY'
p = "backend/src/vtpass/client.ts"
s = open(p).read()
if "export async function purchase(" not in s:
    s += '''
// ---------------------------------------------------------------------------
// Buying (POST requests use the secret key)
// ---------------------------------------------------------------------------
export type VtOutcome = {
  result: "DELIVERED" | "FAILED" | "PENDING";
  code: string;
  message: string;
  providerReference?: string;
  token?: string;
  raw: unknown;
};

// Codes where VTpass did not complete the purchase (and does not charge).
// 027: server IP not whitelisted. 028: product not whitelisted on the account.
// 040 is a reversal: the money went back to the VTpass wallet.
const FAILED_CODES = new Set(["016", "021", "022", "024", "027", "028", "030", "040", "085", "087", "091"]);

async function vtPost(path: string, body: Record<string, unknown>): Promise<unknown> {
  const res = await fetch(`${env.VTPASS_BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "api-key": env.VTPASS_API_KEY,
      "secret-key": env.VTPASS_SECRET_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(45_000),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`VTpass answered ${res.status} with something that is not JSON: ${text.slice(0, 200)}`);
  }
}

// Turns any VTpass answer into DELIVERED, FAILED or PENDING.
// Anything unclear is PENDING: it is asked about again, never resent.
export function classify(body: unknown): VtOutcome {
  const b = (body && typeof body === "object" ? body : {}) as {
    code?: string | number;
    response_description?: string;
    purchased_code?: string;
    content?: { transactions?: { status?: string; transactionId?: string | number } };
  };
  const code = String(b.code ?? "");
  const status = String(b.content?.transactions?.status ?? "").toLowerCase();
  const id = b.content?.transactions?.transactionId;
  const base = {
    code,
    message: b.response_description || `VTpass code ${code || "none"}`,
    providerReference: id !== undefined && id !== null && id !== "" ? String(id) : undefined,
    token: b.purchased_code ? String(b.purchased_code) : undefined,
    raw: body,
  };
  if (code === "000" && status === "delivered") return { result: "DELIVERED", ...base };
  if (status === "failed" || status === "reversed" || FAILED_CODES.has(code)) return { result: "FAILED", ...base };
  return { result: "PENDING", ...base };
}

export async function purchase(payload: Record<string, unknown>): Promise<VtOutcome> {
  try {
    return classify(await vtPost("/pay", payload));
  } catch (err) {
    return { result: "PENDING", code: "", message: `No clear answer from VTpass: ${err instanceof Error ? err.message : err}`, raw: null };
  }
}

export async function requery(requestId: string): Promise<VtOutcome> {
  try {
    return classify(await vtPost("/requery", { request_id: requestId }));
  } catch (err) {
    return { result: "PENDING", code: "", message: `No clear answer from VTpass: ${err instanceof Error ? err.message : err}`, raw: null };
  }
}
'''
# A file edited by an earlier run of this script: add code 028 to the failure list.
if '"028"' not in s:
    s = s.replace('"027", "030"', '"027", "028", "030"', 1)
open(p, "w").write(s)
PY
grep -q 'export async function purchase(' backend/src/vtpass/client.ts || fail "Could not update the VTpass client"
grep -q '"028"' backend/src/vtpass/client.ts || fail "Could not add code 028 to the VTpass client"

mkdir -p backend/src/fulfilment
cat > backend/src/fulfilment/service.ts <<'EOF'
// Delivering paid orders through VTpass.
//
// Order: PAYMENT_CONFIRMED -> FULFILMENT_PENDING -> FULFILLED  (or FAILED / FLAGGED)
// VTU:   SENT -> DELIVERED                                     (or PENDING / FAILED)
//
// Golden rule: each order is sent to VTpass at most ONCE, with one request id.
// When the answer is unclear we ask VTpass again (requery). We never resend,
// so a customer can never receive twice.
import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray } from "drizzle-orm";
import { db } from "../db";
import { auditLogs, dataPlans, ledgerEntries, orders, vtuTransactions } from "../db/schema";
import { SERVICE_IDS, makeRequestId, purchase, requery, type VtOutcome } from "../vtpass/client";

const REQUERY_AFTER_MS = 15_000;
const FLAG_AFTER_MS = 30 * 60_000;
const OPEN_VTU = ["SENT", "PENDING", "UNKNOWN"] as const;

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

  const outcome = await purchase(payload);
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
      .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")))
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
    return;
  }

  if (outcome.result === "FAILED") {
    const [closed] = await db
      .update(vtuTransactions)
      .set({ status: "FAILED", providerReference: outcome.providerReference ?? null, responsePayload: outcome.raw })
      .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])))
      .returning();
    if (!closed) return;
    if (outcome.code === "027") console.error("[vtpass] code 027: this server's IP address is not whitelisted on VTpass");
    if (outcome.code === "028") console.error("[vtpass] code 028: this product is not whitelisted on the VTpass account (Account Settings > Whitelist Products)");
    await failOrder(order, outcome.message);
    return;
  }

  // PENDING: keep the order waiting; it will be asked about again.
  await db
    .update(vtuTransactions)
    .set({ status: "PENDING", responsePayload: outcome.raw ?? tx.responsePayload, attempt: tx.attempt + 1 })
    .where(and(eq(vtuTransactions.id, tx.id), inArray(vtuTransactions.status, [...OPEN_VTU])));
}

async function failOrder(order: Order, reason: string) {
  const [failed] = await db
    .update(orders)
    .set({
      status: "FAILED",
      failureReason: `Delivery failed (${reason}). Your ${usdcText(order.usdcAmountMicro)} USDC will be refunded.`,
    })
    .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")))
    .returning();
  if (failed) await audit("delivery.failed", order.id, { reason });
}

// Moves a FULFILMENT_PENDING order forward by asking VTpass about it.
export async function reconcileOrder(orderId: string): Promise<void> {
  const [order] = await db.select().from(orders).where(eq(orders.id, orderId)).limit(1);
  if (!order || order.status !== "FULFILMENT_PENDING") return;

  const [tx] = await db
    .select()
    .from(vtuTransactions)
    .where(eq(vtuTransactions.orderId, order.id))
    .orderBy(desc(vtuTransactions.createdAt))
    .limit(1);

  if (!tx) {
    // Claimed but nothing was ever sent (for example the server restarted).
    // Safe to hand back for a first and only attempt.
    if (Date.now() - order.updatedAt.getTime() > 60_000) {
      await db
        .update(orders)
        .set({ status: "PAYMENT_CONFIRMED" })
        .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")));
    }
    return;
  }
  if (!(OPEN_VTU as readonly string[]).includes(tx.status)) return;
  if (Date.now() - tx.updatedAt.getTime() < REQUERY_AFTER_MS) return;

  const outcome = await requery(tx.requestId);
  if (outcome.result === "PENDING" && Date.now() - tx.createdAt.getTime() > FLAG_AFTER_MS) {
    const [flagged] = await db
      .update(orders)
      .set({
        status: "FLAGGED",
        failureReason: `Delivery status still unclear after 30 minutes. Check VTpass request ${tx.requestId}.`,
      })
      .where(and(eq(orders.id, order.id), eq(orders.status, "FULFILMENT_PENDING")))
      .returning();
    if (flagged) await audit("delivery.flagged", order.id, { requestId: tx.requestId, last: outcome.message });
    return;
  }
  await applyOutcome(order, tx, outcome);
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
EOF

cat > backend/src/worker.ts <<'EOF'
// Background worker: every 30 seconds, moves unfinished orders forward
//   PAYMENT_PENDING    -> check the payment with Circle
//   PAYMENT_CONFIRMED  -> send to VTpass
//   FULFILMENT_PENDING -> ask VTpass about it (requery)
// so nothing stays stuck when a customer closes their browser.
import { inArray } from "drizzle-orm";
import { db } from "./db";
import { orders } from "./db/schema";
import { fulfilOrder, reconcileOrder } from "./fulfilment/service";
import { refreshPayment } from "./payments/service";

const EVERY_MS = 30_000;

export async function runWorkerOnce(): Promise<number> {
  const due = await db
    .select()
    .from(orders)
    .where(inArray(orders.status, ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING"]))
    .limit(50);
  for (const order of due) {
    try {
      if (order.status === "PAYMENT_PENDING") await refreshPayment(order);
      else if (order.status === "PAYMENT_CONFIRMED") await fulfilOrder(order.id);
      else await reconcileOrder(order.id);
    } catch (err) {
      console.error(`[worker] ${order.reference} failed:`, err);
    }
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
EOF

cat > backend/src/index.ts <<'EOF'
// Starts the API server (and the background worker in production).
import { serve } from "@hono/node-server";
import { app } from "./app";
import { env } from "./env";
import { startWorker } from "./worker";

serve({ fetch: app.fetch, port: env.PORT }, (info) => {
  console.log(`dataonchain api running on http://localhost:${info.port} (${env.NODE_ENV})`);
  if (env.WORKER_ENABLED) startWorker();
});
EOF

# Payments: hand confirmed orders to delivery, and show delivery on the order view
python3 - <<'PY'
import sys
p = "backend/src/payments/service.ts"
s = open(p).read()
if "fulfilOrder" not in s:
    s = s.replace('import { microToUsdc } from "../pricing/quote";',
                  'import { fulfilOrder, getDeliveryView, reconcileOrder } from "../fulfilment/service";\nimport { microToUsdc } from "../pricing/quote";', 1)

    ledger_end = "memo: `Payment ${order.reference}` },\n  ]);\n}"
    if ledger_end not in s:
        sys.exit("could not find the end of refreshPayment")
    s = s.replace(ledger_end,
        "memo: `Payment ${order.reference}` },\n  ]);\n\n"
        "  // Paid: deliver right away (the worker picks it up too if this fails)\n"
        "  void fulfilOrder(order.id).catch((err) => console.error(`[deliver] ${order.reference} failed:`, err));\n}", 1)

    view_marker = '  } else if (order.status === "QUOTED" && order.quoteExpiresAt.getTime() < Date.now()) {'
    if view_marker not in s:
        sys.exit("could not find the QUOTED branch in getOrderView")
    s = s.replace(view_marker,
        '  } else if (order.status === "PAYMENT_CONFIRMED" || order.status === "FULFILMENT_PENDING") {\n'
        '    try {\n'
        '      if (order.status === "PAYMENT_CONFIRMED") await fulfilOrder(order.id);\n'
        '      else await reconcileOrder(order.id);\n'
        '    } catch (err) {\n'
        '      console.error(`[deliver] check ${reference} failed:`, err);\n'
        '    }\n'
        '    order = (await findOrder(userId, reference)) ?? order;\n'
        + view_marker, 1)

    pay_field = "    failureReason: order.failureReason,\n    payment: payment\n"
    if pay_field not in s:
        sys.exit("could not find the payment field in getOrderView")
    s = s.replace(pay_field, "    failureReason: order.failureReason,\n    delivery: await getDeliveryView(order.id),\n    payment: payment\n", 1)
open(p, "w").write(s)
PY
grep -q 'getDeliveryView(order.id)' backend/src/payments/service.ts || fail "Could not update backend/src/payments/service.ts"

python3 - <<'PY'
import re
p = "backend/src/app.ts"
s = open(p).read()
s = re.sub(r'c\.json\(\{ ok: true[^}]*\}\)',
           'c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true })', s, count=1)
open(p, "w").write(s)
PY
grep -q 'delivery: true' backend/src/app.ts || fail "Could not update /api/status in backend/src/app.ts"

# The payment test: a confirmed payment now starts a delivery, so wait for it
# to finish before cleaning up, and clean up the delivery records too.
python3 - <<'PY'
import sys
p = "backend/scripts/pay-smoke.ts"
s = open(p).read()
if "vtuTransactions" not in s:
    s = s.replace('import { ledgerEntries, orders, payments, users } from "../src/db/schema";',
                  'import { ledgerEntries, orders, payments, users, vtuTransactions } from "../src/db/schema";', 1)
    old = "    if (row) {\n      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, row.id));"
    if old not in s:
        sys.exit("could not find the cleanup in pay-smoke.ts")
    s = s.replace(old,
        "    if (row) {\n"
        "      // Let the automatic delivery finish (VTpass sandbox) before removing the order.\n"
        "      for (let i = 0; i < 30; i++) {\n"
        "        const [now] = await db.select().from(orders).where(eq(orders.id, row.id)).limit(1);\n"
        "        if (!now || !['PAYMENT_CONFIRMED', 'FULFILMENT_PENDING'].includes(now.status)) break;\n"
        "        await new Promise((r) => setTimeout(r, 2_000));\n"
        "      }\n"
        "      await db.delete(vtuTransactions).where(eq(vtuTransactions.orderId, row.id));\n"
        "      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, row.id));", 1)
paid = '["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"]'
s = s.replace('check(started?.status === "PAYMENT_PENDING" || started?.status === "PAYMENT_CONFIRMED", "payment started");',
              'check(["PAYMENT_PENDING", ...' + paid + '].includes(started?.status ?? ""), "payment started");', 1)
s = s.replace('check(view?.status === "PAYMENT_CONFIRMED", `payment confirmed on Arc',
              'check(' + paid + '.includes(view?.status ?? ""), `payment confirmed on Arc', 1)
s = s.replace("const lines = orderId ? await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, orderId)) : [];",
              "const lines = (orderId ? await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, orderId)) : [])\n"
              "      .filter((l) => (l.memo ?? \"\").startsWith(\"Payment\"));", 1)
open(p, "w").write(s)
PY
grep -q 'delete(vtuTransactions)' backend/scripts/pay-smoke.ts || fail "Could not update backend/scripts/pay-smoke.ts"
grep -q 'startsWith("Payment")' backend/scripts/pay-smoke.ts || fail "Could not update the ledger check in pay-smoke.ts"

cat > backend/scripts/delivery-smoke.ts <<'EOF'
// Delivery end to end against the VTpass sandbox and the development database.
// Uses VTpass sandbox test numbers:
//   08011111111 -> delivered, 201000000000 -> pending, any other number -> failed
// Run with: npx tsx scripts/delivery-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { listDataPlans } from "../src/catalog/plans";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, users, vtuTransactions } from "../src/db/schema";
import { fulfilOrder, getDeliveryView } from "../src/fulfilment/service";
import { getCurrentRate } from "../src/pricing/rates";
import { classify } from "../src/vtpass/client";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  // How VTpass answers are read
  check(classify({ code: "000", content: { transactions: { status: "delivered", transactionId: 1 } } }).result === "DELIVERED", "000 + delivered counts as delivered");
  check(classify({ code: "000", content: { transactions: { status: "pending" } } }).result === "PENDING", "000 + pending is asked about again, not resent");
  check(classify({ code: "099" }).result === "PENDING", "099 (processing) is asked about again");
  check(classify({ code: "016" }).result === "FAILED", "016 counts as failed");
  check(classify({ code: "040" }).result === "FAILED", "040 (reversed) counts as failed");
  check(classify({ code: "028" }).result === "FAILED", "028 (product not whitelisted) counts as failed");
  check(classify(null).result === "PENDING", "no answer at all is asked about again, never resent");

  const rate = await getCurrentRate();
  const [plan] = await listDataPlans("mtn");
  if (!plan) throw new Error("No MTN plans");

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId, name: "Delivery Smoke Test", email: `deliverysmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111",
  });

  const ids: string[] = [];
  async function paidOrder(over: Partial<typeof orders.$inferInsert>) {
    const [o] = await db.insert(orders).values({
      reference: `TEST${Date.now()}${ids.length}`,
      userId,
      serviceType: "airtime",
      network: "mtn",
      phone: "+2348011111111",
      ngnAmountKobo: 10_000,
      marginKobo: 200,
      usdcAmountMicro: 80_000,
      exchangeRateId: rate.id,
      status: "PAYMENT_CONFIRMED",
      quoteExpiresAt: new Date(Date.now() + 600_000),
      ...over,
    }).returning();
    if (!o) throw new Error("could not create test order");
    ids.push(o.id);
    return o;
  }
  const statusOf = async (id: string) => (await db.select().from(orders).where(eq(orders.id, id)).limit(1))[0];

  try {
    const data = await paidOrder({ serviceType: "data", planId: plan.id, ngnAmountKobo: plan.priceKobo });
    await fulfilOrder(data.id);
    const view = await getDeliveryView(data.id);
    check((await statusOf(data.id))?.status === "FULFILLED", `MTN data (${plan.name}) delivered by the VTpass sandbox`, view);
    check(view?.status === "DELIVERED" && Boolean(view.providerReference), `VTpass reference saved (${view?.providerReference})`);

    await fulfilOrder(data.id);
    const sent = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, data.id));
    check(sent.length === 1, "a delivered order is never sent to VTpass a second time");
    const lines = await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, data.id));
    const bal = (cur: string) => lines.filter((l) => l.currency === cur).reduce((s, l) => s + l.debit - l.credit, 0);
    check(lines.length === 4 && bal("USDC") === 0 && bal("NGN") === 0, "delivery ledger entries written and balanced");

    const airtime = await paidOrder({ serviceType: "airtime", network: "glo", ngnAmountKobo: 10_000 });
    await fulfilOrder(airtime.id);
    check((await statusOf(airtime.id))?.status === "FULFILLED", "Glo ₦100 airtime delivered by the VTpass sandbox", await getDeliveryView(airtime.id));

    const bad = await paidOrder({ phone: "+2348022222222" });
    await fulfilOrder(bad.id);
    const badOrder = await statusOf(bad.id);
    check(badOrder?.status === "FAILED" && /refunded/.test(badOrder.failureReason ?? ""), "a failed delivery marks the order Failed, waiting for a refund", await getDeliveryView(bad.id));

    const slow = await paidOrder({ phone: "201000000000" });
    await fulfilOrder(slow.id);
    const slowOrder = await statusOf(slow.id);
    check(slowOrder?.status === "FULFILMENT_PENDING", "a pending delivery waits (it is asked about again, not resent)", await getDeliveryView(slow.id));
  } finally {
    if (ids.length) {
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, ids));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(orders).where(inArray(orders.id, ids));
    }
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test orders");
  }
}

main()
  .then(() => {
    console.log("All delivery checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
EOF
green "OK: backend files written"

# --- 2. Frontend code -----------------------------------------------------------
step "Writing frontend files"

python3 - <<'PY'
p = "frontend/src/lib/orders.ts"
s = open(p).read()
if "delivery?:" not in s:
    s = s.replace(
        "  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;\n",
        "  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;\n"
        "  delivery?: { status: string; providerReference: string | null; requestId: string; token: string | null; message: string | null } | null;\n", 1)
s = s.replace('PAYMENT_CONFIRMED: { text: "Paid, waiting for delivery", tone: "good" },',
              'PAYMENT_CONFIRMED: { text: "Paid, delivering", tone: "wait" },')
s = s.replace('FAILED: { text: "Failed", tone: "bad" },', 'FAILED: { text: "Failed, to be refunded", tone: "bad" },')
open(p, "w").write(s)
PY
grep -q 'delivery?:' frontend/src/lib/orders.ts || fail "Could not update frontend/src/lib/orders.ts"

cat > "frontend/src/app/orders/[reference]/page.tsx" <<'EOF'
"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, toneClass, usdc, type OrderView } from "@/lib/orders";

const STILL_MOVING = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING"];

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
        if (STILL_MOVING.includes(r.order.status)) timer = setTimeout(load, 3000);
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
  const paid = order ? ["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"].includes(order.status) : false;
  const steps = order
    ? [
        { text: "Payment sent", done: Boolean(order.payment) },
        { text: "Payment confirmed on Arc", done: paid },
        { text: order.serviceType === "data" ? "Data delivered" : "Airtime delivered", done: order.status === "FULFILLED" },
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
                      s.done ? "bg-emerald-700 text-white" : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                    }`}
                  >
                    {s.done ? "✓" : ""}
                  </span>
                  <span className={s.done ? "text-zinc-900 dark:text-zinc-100" : "text-zinc-500"}>{s.text}</span>
                </li>
              ))}
            </ol>

            {order.status === "PAYMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Confirming your payment on Arc. This usually takes a few seconds...</p>
            ) : null}
            {order.status === "PAYMENT_CONFIRMED" || order.status === "FULFILMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Payment received. Sending your {order.serviceType} to {order.phone}...
              </p>
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
            <Link href="/buy" className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
              Buy something else
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
EOF
green "OK: frontend files written"

# --- 3. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Delivery: real tests with the VTpass sandbox (your sandbox wallet pays, not real money)"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."

step "Payments, pricing, wallets and auth: make sure they still work"
ADDR_FILE="$(mktemp)"
set +e
(cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE")
code=$?
set -e
rm -f "$ADDR_FILE"
if [[ $code -eq 3 ]]; then
  yellow "The payment test wallet is out of test USDC, so the live payment test was skipped."
elif [[ $code -ne 0 ]]; then
  fail "Payment test failed (details above). Nothing was committed."
fi
(cd backend && npx tsx scripts/pricing-smoke.ts) || fail "Pricing test failed (details above). Nothing was committed."
(cd backend && npx tsx scripts/wallet-smoke.ts) || fail "Wallet test failed (details above). Nothing was committed."
OUTBOX="$(mktemp)"
(cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  fail "Auth test failed (details above). Nothing was committed."
fi
kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 4. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub (no new Render settings are needed)"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Phase 9: VTpass delivery, requery, background worker, receipts"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"delivery":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render."
wait_for "the website" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 9 complete. The full journey is live: pay with USDC, receive airtime or data."
echo "  Try it: $PROD_FRONTEND/buy  with phone 08011111111 (the VTpass sandbox success number)"
echo "  On Render > Logs you should see: [worker] started: checking unfinished orders every 30 seconds"
