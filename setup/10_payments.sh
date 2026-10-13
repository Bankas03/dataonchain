#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 10 (Phase 8): paying with USDC
#
# What this adds:
#   - A platform TREASURY wallet on Arc (where customer payments arrive)
#   - Pay with USDC: moves the quoted USDC from the user's wallet to the
#     treasury. The user pays the small Arc network fee (option A).
#   - Payment verification: the order is only confirmed when Circle reports the
#     transfer COMPLETE and the address, amount, token, network and transaction
#     hash all check out. Anything odd marks the order FLAGGED for review.
#   - Safe retries: one order can only ever start one transfer
#   - Ledger entries for every confirmed payment
#   - Order page with live status and a link to the transaction on the explorer
#   - Recent orders on the dashboard
#   Delivery through VTpass comes in Phase 9: confirmed orders wait for it.
#
# The script runs one REAL testnet payment of about 0.1 USDC from a test
# wallet. If that wallet is empty, it asks you to fund it from the faucet once.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/10_payments.sh
# =============================================================================
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }
pause()  { read -r -p "$* Press Enter to continue... " _; }

ENV_FILE="backend/.env"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
to_clipboard() { command -v clip.exe >/dev/null 2>&1 && printf '%s' "$1" | clip.exe; }

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
[[ -f backend/src/pricing/quote.ts ]] || fail "Run this from ~/dataonchain after Phase 7 (script 09)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/10_payments.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Treasury wallet ---------------------------------------------------------
step "Creating the platform treasury wallet"
cat > backend/scripts/treasury-setup.ts <<'EOF'
// Creates the platform treasury wallet on Circle (once) and saves it in backend/.env.
// Safe to run again: the same idempotency key always returns the same wallet.
// Run with: npx tsx scripts/treasury-setup.ts
import { createHash } from "node:crypto";
import { appendFileSync } from "node:fs";
import { config } from "dotenv";
import { initiateDeveloperControlledWalletsClient } from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function main() {
  if (process.env.TREASURY_WALLET_ID && process.env.TREASURY_ADDRESS) {
    console.log(`Treasury already set: ${process.env.TREASURY_ADDRESS}`);
    return;
  }
  const apiKey = process.env.CIRCLE_API_KEY;
  const entitySecret = process.env.CIRCLE_ENTITY_SECRET;
  const walletSetId = process.env.CIRCLE_WALLET_SET_ID;
  const blockchain = process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET";
  if (!apiKey || !entitySecret || !walletSetId) throw new Error("Circle settings missing in backend/.env");

  const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });
  const res = await client.createWallets({
    walletSetId,
    blockchains: [blockchain as "ARC-TESTNET"],
    count: 1,
    accountType: "EOA",
    idempotencyKey: uuidFrom(`treasury:${walletSetId}:${blockchain}`),
  });
  const wallet = res.data?.wallets?.[0];
  if (!wallet?.id || !wallet.address) throw new Error("Circle did not return the treasury wallet");
  appendFileSync(".env", `\n# Treasury (customer payments arrive here)\nTREASURY_WALLET_ID=${wallet.id}\nTREASURY_ADDRESS=${wallet.address}\n`);
  console.log(`Treasury wallet created: ${wallet.address}`);
}

main().catch((err) => {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
  process.exit(1);
});
EOF
(cd backend && npx tsx scripts/treasury-setup.ts)
[[ -n "$(env_get TREASURY_WALLET_ID)" && -n "$(env_get TREASURY_ADDRESS)" ]] || fail "Treasury setup did not finish"
green "OK: treasury $(env_get TREASURY_ADDRESS)"

# --- 2. Backend code ------------------------------------------------------------
step "Writing backend files"

cat >> backend/.env.example <<'EOF'

# Treasury: the platform wallet customer payments go to (setup/10_payments.sh creates it)
TREASURY_WALLET_ID=circle-wallet-id
TREASURY_ADDRESS=0x...
# Extra USDC a wallet must hold on top of the price, to cover the network fee
PAYMENT_FEE_BUFFER_USDC=0.02
EXPLORER_TX_URL=https://explorer.testnet.arc.io/tx/
EOF
awk '!(/^# Treasury: the platform/ && a++) && !(/^TREASURY_WALLET_ID=/ && b++) && !(/^TREASURY_ADDRESS=/ && c++) && !(/^# Extra USDC a wallet/ && d++) && !(/^PAYMENT_FEE_BUFFER_USDC=/ && e++) && !(/^EXPLORER_TX_URL=/ && f++)' \
  backend/.env.example > backend/.env.example.tmp && mv backend/.env.example.tmp backend/.env.example

python3 - <<'PY'
import sys
p = "backend/src/env.ts"
s = open(p).read()
if "TREASURY_ADDRESS" not in s:
    marker = "  NGN_PER_USDC: optionalNumber(\"NGN_PER_USDC\"),\n"
    if marker not in s:
        sys.exit("could not find NGN_PER_USDC in env.ts")
    s = s.replace(marker, marker +
        "  // Payments\n"
        "  TREASURY_WALLET_ID: required(\"TREASURY_WALLET_ID\"),\n"
        "  TREASURY_ADDRESS: required(\"TREASURY_ADDRESS\"),\n"
        "  PAYMENT_FEE_BUFFER_USDC: optionalNumber(\"PAYMENT_FEE_BUFFER_USDC\") ?? 0.02,\n"
        "  EXPLORER_TX_URL: process.env.EXPLORER_TX_URL ?? \"https://explorer.testnet.arc.io/tx/\",\n", 1)
open(p, "w").write(s)
PY
grep -q 'TREASURY_ADDRESS: required' backend/src/env.ts || fail "Could not update backend/src/env.ts"

mkdir -p backend/src/payments
cat > backend/src/payments/service.ts <<'EOF'
// Paying for an order with USDC, and verifying the payment.
//
// Order:   QUOTED -> PAYMENT_PENDING -> PAYMENT_CONFIRMED   (or FAILED / FLAGGED)
// Payment: INITIATED -> PENDING -> CONFIRMED                (or FAILED / MISMATCH)
//
// Every status change is conditional ("only if it is still X"), so two
// requests at the same time can never pay twice or confirm twice.
import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq, inArray, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, dataPlans, ledgerEntries, orders, payments } from "../db/schema";
import { env } from "../env";
import { microToUsdc } from "../pricing/quote";
import { ensureUserWallet } from "../wallets/service";

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
  const buffer = Math.round(env.PAYMENT_FEE_BUFFER_USDC * 1_000_000);
  const needed = order.usdcAmountMicro + buffer;
  if (!usdc || usdc.balanceMicro < needed) {
    throw new PaymentError(
      `Not enough USDC. You need ${microToUsdc(needed)} USDC (price plus network fee). Your balance is ${microToUsdc(usdc?.balanceMicro ?? 0)} USDC.`,
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
    await db.update(payments).set({ status: "FAILED" }).where(eq(payments.id, payment.id));
    await db.update(orders).set({ status: "QUOTED" }).where(and(eq(orders.id, order.id), eq(orders.status, "PAYMENT_PENDING")));
    throw new PaymentError("We could not start the payment. No money was taken. Please try again.", 409);
  }

  await db
    .update(payments)
    .set({ circleTransactionId: transactionId, status: "PENDING" })
    .where(eq(payments.id, payment.id));
  return getOrderView(userId, reference);
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
    if (err instanceof Error && /UNIQUE/i.test(err.message)) {
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
EOF

cat > backend/scripts/pay-smoke.ts <<'EOF'
// A real testnet payment, end to end, from a dedicated test wallet.
// Exit code 3 means the test wallet needs USDC; its address is written to argv[2].
// Run with: npx tsx scripts/pay-smoke.ts /tmp/payer-address.txt
import { writeFileSync } from "node:fs";
import { eq } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { ledgerEntries, orders, payments, users } from "../src/db/schema";
import { createQuote } from "../src/pricing/quote";
import { PaymentError, checkTransfer, getOrderView, payOrder, usdcToMicro } from "../src/payments/service";
import { ensureUserWallet } from "../src/wallets/service";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  // Pure checks first: the verifier must catch every kind of bad transfer.
  const expected = { destination: "0xAbC0000000000000000000000000000000000001", amountMicro: 75_189, tokenId: "tok", blockchain: "ARC-TESTNET" };
  const good = { state: "COMPLETE", destinationAddress: "0xabc0000000000000000000000000000000000001", amounts: ["0.075189"], tokenId: "tok", blockchain: "ARC-TESTNET", txHash: "0x1" };
  check(checkTransfer(good, expected).length === 0, "a correct transfer passes verification");
  check(checkTransfer({ ...good, destinationAddress: "0x0000000000000000000000000000000000000002" }, expected).length > 0, "a transfer to the wrong address is caught");
  check(checkTransfer({ ...good, amounts: ["0.07"] }, expected).length > 0, "a wrong amount is caught");
  check(checkTransfer({ ...good, tokenId: "other" }, expected).length > 0, "a wrong token is caught");
  check(checkTransfer({ ...good, txHash: undefined }, expected).length > 0, "a missing transaction hash is caught");
  check(checkTransfer({ ...good, state: "SENT" }, expected).length > 0, "an unfinished transfer is not counted");
  check(usdcToMicro("1.5") === 1_500_000 && usdcToMicro("0.0000001") === null, "USDC amounts are read exactly");

  // The test payer: one user in the development database, kept between runs.
  let [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (!payer) {
    [payer] = await db
      .insert(users)
      .values({ name: "Payment Test", email: PAYER_EMAIL, emailVerified: true, phone: "+2348011111111" })
      .returning();
  }
  if (!payer) throw new Error("Could not create the test payer");
  const wallet = await ensureUserWallet(payer.id);

  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const balance = Number(usdc?.amount ?? 0);
  console.log(`Test wallet ${wallet.address} holds ${balance} USDC`);
  if (balance < 0.5) {
    if (process.argv[2]) writeFileSync(process.argv[2], wallet.address);
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }

  const quote = await createQuote(payer.id, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "08011111111" });
  console.log(`Quote ${quote.reference}: ${quote.usdcAmount} USDC`);
  let orderId: string | undefined;

  try {
    const started = await payOrder(payer.id, quote.reference);
    check(started?.status === "PAYMENT_PENDING" || started?.status === "PAYMENT_CONFIRMED", "payment started");
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    orderId = row?.id;

    const again = await payOrder(payer.id, quote.reference);
    check(again?.reference === quote.reference, "paying the same order twice does not start a second transfer");
    const all = orderId ? await db.select().from(payments).where(eq(payments.orderId, orderId)) : [];
    check(all.length === 1, "exactly one payment exists for the order");

    let view = started;
    for (let i = 0; i < 60 && view?.status === "PAYMENT_PENDING"; i++) {
      await new Promise((r) => setTimeout(r, 3_000));
      view = await getOrderView(payer.id, quote.reference);
      process.stdout.write(".");
    }
    console.log("");
    check(view?.status === "PAYMENT_CONFIRMED", `payment confirmed on Arc (status ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""})`);
    check(Boolean(view?.payment?.txHash), `transaction hash recorded (${view?.payment?.txHash})`);
    if (view?.payment?.explorerUrl) console.log(`See it on the explorer: ${view.payment.explorerUrl}`);

    const lines = orderId ? await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, orderId)) : [];
    const debit = lines.reduce((s, l) => s + l.debit, 0);
    const credit = lines.reduce((s, l) => s + l.credit, 0);
    check(lines.length === 2 && debit === credit, "ledger entries written and balanced");

    try {
      await payOrder(payer.id, "ARC00000000");
      check(false, "paying an unknown order is refused");
    } catch (err) {
      check(err instanceof PaymentError && err.status === 404, "paying an unknown order is refused");
    }
  } finally {
    // Remove the test order so Phase 9 never tries to deliver it. The USDC stays in the treasury.
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    if (row) {
      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, row.id));
      await db.delete(payments).where(eq(payments.orderId, row.id));
      await db.delete(orders).where(eq(orders.id, row.id));
      console.log("Cleaned up the test order");
    }
  }
}

main()
  .then(() => {
    console.log("All payment checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
EOF

python3 - <<'PY'
import re, sys
p = "backend/src/app.ts"
s = open(p).read()
if "payOrder" not in s:
    s = s.replace(
        'import { env } from "./env";',
        'import { env } from "./env";\n'
        'import { PaymentError, getOrderView, listOrders, payOrder } from "./payments/service";',
        1,
    )
    routes = '''// Pay for a quoted order with USDC (user's wallet -> treasury)
app.post("/api/orders/:reference/pay", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) {
    return c.json({ error: "Please confirm your email first" }, 403);
  }
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

'''
    marker = "app.notFound("
    if marker not in s:
        sys.exit("could not find app.notFound in app.ts")
    s = s.replace(marker, routes + marker, 1)
s = re.sub(r'c\.json\(\{ ok: true[^}]*\}\)',
           'c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true })', s, count=1)
open(p, "w").write(s)
PY
grep -q 'payments: true' backend/src/app.ts || fail "Could not update /api/status in backend/src/app.ts"
grep -q '"/api/orders/:reference/pay"' backend/src/app.ts || fail "Could not add the payment routes to backend/src/app.ts"
green "OK: backend files written"

# --- 3. Frontend code -----------------------------------------------------------
step "Writing frontend files"

# Buy page: real Pay button, network fee note
python3 - <<'PY'
import sys
p = "frontend/src/app/buy/page.tsx"
s = open(p).read()
if "async function pay()" not in s:
    s = s.replace(
        "  async function getPrice(event?: FormEvent<HTMLFormElement>) {",
        '''  async function pay() {
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

  async function getPrice(event?: FormEvent<HTMLFormElement>) {''', 1)
    old_start = s.find("<button\n                disabled\n                title=\"Paying with USDC arrives in the next update\"")
    if old_start < 0:
        sys.exit("could not find the disabled Pay button in buy/page.tsx")
    old_end = s.find("</button>", old_start) + len("</button>")
    s = s[:old_start] + '''<button
                onClick={() => void pay()}
                disabled={busy || notEnough}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Sending payment..." : `Pay ${usdc(quote.usdcAmount)} USDC`}
              </button>''' + s[old_end:]
    note_anchor = "{expired ? (\n              <p className=\"rounded-lg bg-amber-50"
    i = s.find(note_anchor)
    if i < 0:
        sys.exit("could not find the expiry message in buy/page.tsx")
    s = s[:i] + '''<p className="text-xs text-zinc-500">
              A small Arc network fee (usually well under 0.01 USDC) is also paid from your wallet.
            </p>

            ''' + s[i:]
open(p, "w").write(s)
PY
grep -q 'async function pay()' frontend/src/app/buy/page.tsx || fail "Could not update the Buy page"

mkdir -p "frontend/src/app/orders/[reference]" frontend/src/components
cat > frontend/src/lib/orders.ts <<'EOF'
// Shared order types and labels for the website.
export type OrderView = {
  reference: string;
  status: string;
  serviceType: "airtime" | "data";
  network: "mtn" | "airtel" | "glo" | "9mobile";
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  createdAt: string;
  expiresAt?: string;
  failureReason?: string | null;
  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;
};

export const NETWORK_LABELS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };

export const STATUS_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Not paid", tone: "wait" },
  EXPIRED: { text: "Price expired", tone: "bad" },
  PAYMENT_PENDING: { text: "Payment in progress", tone: "wait" },
  PAYMENT_CONFIRMED: { text: "Paid, waiting for delivery", tone: "good" },
  FULFILMENT_PENDING: { text: "Delivering", tone: "wait" },
  FULFILLED: { text: "Delivered", tone: "good" },
  FAILED: { text: "Failed", tone: "bad" },
  FLAGGED: { text: "Under review", tone: "bad" },
  REFUNDED: { text: "Refunded", tone: "good" },
};

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
EOF

cat > "frontend/src/app/orders/[reference]/page.tsx" <<'EOF'
"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, toneClass, usdc, type OrderView } from "@/lib/orders";

const STILL_MOVING = ["PAYMENT_PENDING", "FULFILMENT_PENDING"];

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
        { text: "Airtime or data delivered", done: order.status === "FULFILLED" },
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
            {order.status === "PAYMENT_CONFIRMED" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Payment received. Automatic delivery is being switched on in the next update.
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
            </dl>

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

cat > frontend/src/components/RecentOrders.tsx <<'EOF'
"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { STATUS_LABELS, describe, toneClass, usdc, type OrderView } from "@/lib/orders";

export function RecentOrders() {
  const [orders, setOrders] = useState<OrderView[] | null>(null);

  useEffect(() => {
    api<{ orders: OrderView[] }>("/orders")
      .then((r) => setOrders(r.orders))
      .catch(() => setOrders([]));
  }, []);

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="text-sm font-medium text-zinc-500">Recent orders</h2>
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
EOF

python3 - <<'PY'
import sys
p = "frontend/src/app/dashboard/page.tsx"
s = open(p).read()
if "RecentOrders" not in s:
    s = s.replace('import { WalletCard } from "@/components/WalletCard";',
                  'import { RecentOrders } from "@/components/RecentOrders";\nimport { WalletCard } from "@/components/WalletCard";', 1)
    if "<WalletCard />" not in s:
        sys.exit("could not find <WalletCard /> in dashboard/page.tsx")
    s = s.replace("<WalletCard />", "<WalletCard />\n        <RecentOrders />", 1)
open(p, "w").write(s)
PY
grep -q '<RecentOrders />' frontend/src/app/dashboard/page.tsx || fail "Could not add recent orders to the dashboard"
green "OK: frontend files written"

# --- 4. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Payments: a REAL testnet payment from a test wallet to the treasury"
ADDR_FILE="$(mktemp)"
while true; do
  set +e
  (cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE")
  code=$?
  set -e
  [[ $code -eq 0 ]] && break
  if [[ $code -eq 3 ]]; then
    PAYER="$(cat "$ADDR_FILE")"
    echo
    bold "The test wallet needs some test USDC (one time only)."
    echo "  1. Open https://faucet.circle.com"
    echo "  2. Choose Arc Testnet and USDC"
    echo "  3. Paste this address: $PAYER"
    to_clipboard "$PAYER" && echo "     (it is already on your clipboard)"
    echo "  4. Send, then wait about a minute"
    read -r -p "Press Enter to check again, or type skip to skip the live payment test: " ans
    if [[ "$ans" == "skip" ]]; then
      yellow "Skipped the live payment test. Test it yourself on the website after deploying."
      break
    fi
  else
    rm -f "$ADDR_FILE"
    fail "Payment test failed (details above). Nothing was committed."
  fi
done
rm -f "$ADDR_FILE"

step "Pricing, wallets and auth: make sure they still work"
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

# --- 5. Render settings -------------------------------------------------------------
step "Adding 2 settings on Render"
read -r -p "Have you already added TREASURY_WALLET_ID and TREASURY_ADDRESS on Render? (y/n) " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  echo
  bold "In your browser: Render > your API service > Environment > add these 2:"
  echo
  echo "     TREASURY_WALLET_ID   $(env_get TREASURY_WALLET_ID)"
  echo "     TREASURY_ADDRESS     $(env_get TREASURY_ADDRESS)"
  echo
  echo "  (Neither is a secret.) Then click 'Save, rebuild, and deploy' (or 'Save Changes')."
  pause "When both are saved,"
fi
green "OK"

# --- 6. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Phase 8: pay with USDC, treasury wallet, payment verification, order pages"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"payments":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render (missing TREASURY_ settings stop it starting)."
wait_for "the website" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 8 complete. Paying with USDC is live."
echo "  Treasury wallet: $(env_get TREASURY_ADDRESS)"
echo "  Try it: $PROD_FRONTEND/buy  > choose a plan > Get price > Pay"
echo "  Your order page shows the payment confirming on Arc in a few seconds."
