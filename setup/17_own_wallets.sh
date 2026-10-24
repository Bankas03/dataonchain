#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 17: users' own wallets on other networks
#
# What this adds:
#   - every user can send USDC from Arc to their OWN wallet on Base, Arbitrum,
#     Ethereum, Avalanche, OP, Polygon or Unichain (testnets); the wallet is a
#     Circle smart wallet created the first time they use that network
#   - dashboard card "Your USDC on other networks": balance, address, explorer
#   - "Move to Arc" button: brings everything on that network back to the Arc
#     wallet through Circle Gateway; Gas Station pays the gas on that network
#     (deposits on Ethereum based networks wait for finality: about 20 minutes)
#   - the shared "Test provider" is switched off for users
#   - fees get a small safety margin (10%, at least 0.005 USDC) so a tiny rise
#     in Circle's forwarding fee no longer stops a transfer; unused fee stays
#     in the user's bridge balance
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/17_own_wallets.sh
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

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
command -v turso >/dev/null || fail "Turso CLI not found (it was installed in script 01)"
[[ -f backend/src/bridge/user.ts ]] || fail "Run this from ~/dataonchain after script 16 (bridge out)"
[[ -n "$(env_get GATEWAY_PROBE_RECIPIENT_ADDRESS)" ]] || fail "GATEWAY_PROBE_RECIPIENT_ADDRESS missing in $ENV_FILE (script 15 creates it)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
[[ -n "$(env_get TREASURY_WALLET_ID)" ]] || fail "TREASURY_WALLET_ID missing in $ENV_FILE (script 10 sets it)"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this script again."
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not find the production database '$PROD_DB'"
if [[ -n "$(git status --porcelain | grep -v 'setup/17_own_wallets.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Code ---------------------------------------------------------------------
step "Writing backend and frontend files"
mkdir -p backend/src/bridge "frontend/src/app/bridge/[id]" frontend/src/components
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
import { NETWORK_NAMES, ensureUserWallet, getUsdcBalance, previousWallet } from "./wallets/service";
import { BridgeUserError, bridgeBalance, chainBalances, getBridgeView, listBridges, listDestinations, quoteBridge, returnToArc, startBridge } from "./bridge/user";

export const app = new Hono();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: env.FRONTEND_URLS,
    credentials: true,
    allowHeaders: ["Content-Type", "Authorization"],
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
app.get("/api/status", (c) => c.json({ ok: true, auth: true, email: true, wallets: true, pricing: true, payments: true, delivery: true, refunds: true, sca: true, gateway: true, bridgeOut: true, bridgeOwnWallets: true, bridge: env.BRIDGE_ENABLED }));

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
  try {
    usdc = await getUsdcBalance(wallet.circleWalletId);
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
  });
});

// Data plans for one network (refreshed from VTpass every 6 hours)
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

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
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

type Transfer = typeof bridgeTransfers.$inferSelect;
type Status = Transfer["status"];

const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

async function event(transferId: string, step: string, fields: { chain?: string; txHash?: string | null; circleTransactionId?: string | null; details?: unknown } = {}) {
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
  const [row] = await db
    .update(bridgeTransfers)
    .set({ status: to, ...extra })
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
  for (let i = 0; i < 60; i++) {
    const t = await circle.getTransaction({ id });
    const tx = t.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
    if (tx?.state === "COMPLETE") return { id, txHash: tx.txHash };
    if (tx?.state && FAILED_STATES.includes(tx.state)) {
      throw new BridgeError(`${p.signature} ${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`);
    }
    await new Promise((r) => setTimeout(r, 3_000));
  }
  throw new BridgeError(`${p.signature} did not finish in 3 minutes`);
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

  const [row] = await db
    .insert(bridgeTransfers)
    .values({
      userId: p.userId ?? null,
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

  const [plan] = await db
    .select()
    .from(bridgeEvents)
    .where(and(eq(bridgeEvents.transferId, t.id), eq(bridgeEvents.step, "deposit_planned")))
    .orderBy(desc(bridgeEvents.createdAt))
    .limit(1);
  const value = (plan?.details as { value?: string } | null)?.value;
  if (!value) {
    await fail(t, "deposit plan missing");
    return;
  }
  const round = plan?.id ?? "first"; // a re-quote makes a new plan, so new idempotency keys
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

cat > "backend/src/bridge/gateway.ts" <<'DOC_EOF'
// Circle Gateway API client and burn intent helpers.
// Docs: developers.circle.com/gateway (technical guide, forwarding service,
// ERC-1271 transfers). Amounts are in micro USDC (6 decimals) everywhere.
import { randomBytes } from "node:crypto";
import { env } from "../env";
import type { BridgeChain } from "./chains";

const MAX_UINT256 = ((1n << 256n) - 1n).toString();
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export class GatewayError extends Error {
  constructor(message: string, public status?: number, public body?: string) {
    super(message);
  }
}

export function toBytes32(address: string): `0x${string}` {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
}

export function microFromDecimal(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) throw new Error(`Not a USDC amount: ${amount}`);
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

const json = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v));

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${env.GATEWAY_API_URL}${path}`, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : json(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new GatewayError(`Gateway ${method} ${path} answered ${res.status}: ${text.slice(0, 300)}`, res.status, text);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new GatewayError(`Gateway ${path} sent something that is not JSON: ${text.slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------------------
// Balances and deposits
// ---------------------------------------------------------------------------
// Available (finalized) Gateway balance of a depositor on one chain, in micro USDC
export async function gatewayBalanceMicro(depositor: string, domain: number): Promise<number> {
  const res = await call<{ balances?: { domain: number; depositor: string; balance: string }[] }>("POST", "/v1/balances", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  const row = (res.balances ?? []).find((b) => b.domain === domain);
  return row ? microFromDecimal(row.balance) : 0;
}

// Deposits seen onchain but not final yet
export async function pendingDeposits(depositor: string, domain: number) {
  const res = await call<{ deposits?: { transactionHash: string; amount: string; status: string }[] }>("POST", "/v1/deposits", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  return res.deposits ?? [];
}

// ---------------------------------------------------------------------------
// Burn intents
// ---------------------------------------------------------------------------
export type TransferSpec = {
  version: 1;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: `0x${string}`;
  destinationContract: `0x${string}`;
  sourceToken: `0x${string}`;
  destinationToken: `0x${string}`;
  sourceDepositor: `0x${string}`;
  destinationRecipient: `0x${string}`;
  sourceSigner: `0x${string}`;
  destinationCaller: `0x${string}`;
  value: string;
  salt: `0x${string}`;
  hookData: `0x${string}`;
};

export type BurnIntent = { maxBlockHeight: string; maxFee: string; spec: TransferSpec };

export function newSalt(): `0x${string}` {
  return `0x${randomBytes(32).toString("hex")}`;
}

// The depositor wallet both holds the Gateway balance and signs (ERC-1271 for SCA wallets).
export function buildSpec(p: {
  source: BridgeChain;
  destination: BridgeChain;
  depositor: string;
  recipient: string;
  amountMicro: number;
  salt: `0x${string}`;
}): TransferSpec {
  return {
    version: 1,
    sourceDomain: p.source.domain,
    destinationDomain: p.destination.domain,
    sourceContract: toBytes32(p.source.gatewayWallet),
    destinationContract: toBytes32(p.destination.gatewayMinter),
    sourceToken: toBytes32(p.source.usdc),
    destinationToken: toBytes32(p.destination.usdc),
    sourceDepositor: toBytes32(p.depositor),
    destinationRecipient: toBytes32(p.recipient),
    sourceSigner: toBytes32(p.depositor),
    destinationCaller: toBytes32(ZERO_ADDRESS),
    value: String(p.amountMicro),
    salt: p.salt,
    hookData: "0x",
  };
}

export type Estimate = { burnIntent: BurnIntent; maxFeeMicro: number; quotedFeeMicro: number; forwardingFeeMicro: number | null; raw: unknown };

// Circle's forwarding fee follows destination gas prices and can rise in the
// seconds between the estimate and the submission. We allow a margin of 10%
// (at least 0.005 USDC). Circle only takes what it needs; the rest stays in the
// depositor's Gateway balance and is used first next time.
export function withMargin(feeMicro: number): number {
  return feeMicro + Math.max(Math.ceil(feeMicro * 0.1), 5_000);
}

// Asks Gateway for the fee. Forwarding: Circle submits the mint on the destination chain.
export async function estimate(spec: TransferSpec, forward = true): Promise<Estimate> {
  const res = await call<{
    body?: { burnIntent?: { maxFee: string | number; maxBlockHeight: string | number } }[];
    fees?: { forwardingFee?: string; token?: string; total?: string };
  }>("POST", `/v1/estimate?enableForwarder=${forward}`, [{ spec }]);
  const est = res.body?.[0]?.burnIntent;
  if (!est) throw new GatewayError(`Gateway estimate returned no burn intent: ${json(res).slice(0, 300)}`);
  const quoted = Number(est.maxFee);
  const maxFeeMicro = withMargin(quoted);
  return {
    burnIntent: { maxBlockHeight: String(est.maxBlockHeight ?? MAX_UINT256), maxFee: String(maxFeeMicro), spec },
    maxFeeMicro,
    quotedFeeMicro: quoted,
    forwardingFeeMicro: res.fees?.forwardingFee ? microFromDecimal(String(res.fees.forwardingFee)) : null,
    raw: res,
  };
}

// EIP-712 typed data for the burn intent, as Circle's signTypedData expects (a JSON string)
export function typedData(burnIntent: BurnIntent): string {
  return json({
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
      ],
      TransferSpec: [
        { name: "version", type: "uint32" },
        { name: "sourceDomain", type: "uint32" },
        { name: "destinationDomain", type: "uint32" },
        { name: "sourceContract", type: "bytes32" },
        { name: "destinationContract", type: "bytes32" },
        { name: "sourceToken", type: "bytes32" },
        { name: "destinationToken", type: "bytes32" },
        { name: "sourceDepositor", type: "bytes32" },
        { name: "destinationRecipient", type: "bytes32" },
        { name: "sourceSigner", type: "bytes32" },
        { name: "destinationCaller", type: "bytes32" },
        { name: "value", type: "uint256" },
        { name: "salt", type: "bytes32" },
        { name: "hookData", type: "bytes" },
      ],
      BurnIntent: [
        { name: "maxBlockHeight", type: "uint256" },
        { name: "maxFee", type: "uint256" },
        { name: "spec", type: "TransferSpec" },
      ],
    },
    domain: { name: "GatewayWallet", version: "1" },
    primaryType: "BurnIntent",
    message: burnIntent,
  });
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------
export async function submitTransfer(burnIntent: BurnIntent, signature: string, forward = true): Promise<string> {
  const res = await call<{ transferId?: string }>("POST", `/v1/transfer?enableForwarder=${forward}`, [
    // contractSigner: Gateway checks the signature with ERC-1271 on the SCA wallet
    { burnIntent, signature, contractSigner: true },
  ]);
  if (!res.transferId) throw new GatewayError(`Gateway accepted the transfer but sent no transferId: ${json(res).slice(0, 300)}`);
  return res.transferId;
}

export type TransferStatus = {
  status: "pending" | "confirmed" | "finalized" | "failed" | "expired" | string;
  transactionHash?: string; // the mint on the destination chain
  forwardingDetails?: { forwardingEnabled: boolean; failureReason?: string };
  fees?: unknown;
};

export async function getTransfer(transferId: string): Promise<TransferStatus> {
  return call<TransferStatus>("GET", `/v1/transfer/${transferId}`);
}
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
import { bridgeChains, chainByKey, feeCapMicro, homeChain, type BridgeChain } from "./chains";
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
  return bridgeChains().filter((c) => c.key !== home.key);
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
  if (!d) throw new BridgeUserError("Choose one of the listed destinations.", 404);
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
  const providers = rows.map((d) => {
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
  return {
    destination: { id: String(body.destinationId), label: target.label, chainLabel: target.chain.label, address: target.address },
    amount: usdcText(amountMicro),
    fee: usdcText(est.maxFeeMicro),
    total: usdcText(amountMicro + est.maxFeeMicro),
    receives: usdcText(amountMicro),
    available: usdcText(inWallet + inGateway),
    allowed: est.maxFeeMicro <= feeCapMicro(target.chain),
    note: "The fee shown is the most Circle can charge; any unused part stays in your bridge balance for next time.",
  };
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
  if (inWallet + inGateway < needed) {
    throw new BridgeUserError(`Not enough USDC. You need ${usdcText(needed)} USDC (amount plus fee). You have ${usdcText(inWallet + inGateway)} USDC.`, 402);
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
  if (amountMicro < RETURN_MIN_MICRO) {
    throw new BridgeUserError(`There is not enough USDC on ${source.label} to move. Circle's fee is about ${usdcText(est.maxFeeMicro)} USDC.`, 402);
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

export async function listBridges(userId: string) {
  const rows = await db
    .select()
    .from(bridgeTransfers)
    .where(eq(bridgeTransfers.userId, userId))
    .orderBy(desc(bridgeTransfers.createdAt))
    .limit(20);
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

cat > "backend/src/bridge/wallets.ts" <<'DOC_EOF'
// Each user's own smart wallets on the other bridge networks (Base, Arbitrum, ...).
// Created the first time they are needed, one per user per network, never twice.
// Their gas is paid by Circle Gas Station (default testnet policies).
import { and, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { wallets } from "../db/schema";
import { env } from "../env";
import { uuidFrom } from "../wallets/service";
import { bridgeChains, chainByKey, homeChain, type BridgeChain } from "./chains";
import { microFromDecimal } from "./gateway";

export type ChainWallet = typeof wallets.$inferSelect;

async function findChainWallet(userId: string, chain: BridgeChain): Promise<ChainWallet | undefined> {
  const [w] = await db
    .select()
    .from(wallets)
    .where(and(eq(wallets.userId, userId), eq(wallets.blockchain, chain.circleBlockchain), eq(wallets.accountType, "SCA")))
    .limit(1);
  return w;
}

export async function ensureChainWallet(userId: string, chainKey: string): Promise<ChainWallet> {
  const chain = chainByKey(chainKey);
  if (chain.key === homeChain().key) throw new Error("Use ensureUserWallet for the Arc wallet");
  const existing = await findChainWallet(userId, chain);
  if (existing) return existing;

  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [chain.circleBlockchain as "ARC-TESTNET"],
    count: 1,
    accountType: "SCA",
    idempotencyKey: uuidFrom(`wallet:sca:${userId}:${chain.circleBlockchain}`),
  });
  const created = res.data?.wallets?.[0];
  if (!created?.id || !created.address) throw new Error(`Circle did not create a wallet on ${chain.label}`);
  await db
    .insert(wallets)
    .values({
      userId,
      purpose: "user",
      circleWalletId: created.id,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER",
      blockchain: chain.circleBlockchain,
      address: created.address,
      accountType: "SCA",
    })
    .onConflictDoNothing();
  const saved = await findChainWallet(userId, chain);
  if (!saved) throw new Error("The wallet was created on Circle but could not be saved");
  return saved;
}

export async function usdcMicroOf(circleWalletId: string): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return b ? microFromDecimal(b.amount) : 0;
}

const addressUrl = (chain: BridgeChain, address: string) => `${chain.explorerTx.replace(/\/tx\/$/, "/address/")}${address}`;

// The user's wallets on other networks (only those already created), with balances
export async function listChainWallets(userId: string) {
  const home = homeChain();
  const rows = await db.select().from(wallets).where(and(eq(wallets.userId, userId), eq(wallets.accountType, "SCA")));
  const result = [];
  for (const chain of bridgeChains()) {
    if (chain.key === home.key) continue;
    const w = rows.find((r) => r.blockchain === chain.circleBlockchain);
    if (!w) continue;
    let balance: number | null = null;
    try {
      balance = await usdcMicroOf(w.circleWalletId);
    } catch {
      balance = null;
    }
    result.push({
      chain: chain.key,
      chainLabel: chain.label,
      address: w.address,
      explorerUrl: addressUrl(chain, w.address),
      balanceMicro: balance,
    });
  }
  return result;
}

// Is this address one of the user's own wallets on that network?
export async function isOwnWallet(userId: string, chainKey: string, address: string): Promise<boolean> {
  const chain = chainByKey(chainKey);
  const w = await findChainWallet(userId, chain);
  return Boolean(w && w.address.toLowerCase() === address.toLowerCase());
}
DOC_EOF

cat > "backend/scripts/bridge-own-smoke.ts" <<'DOC_EOF'
// Own wallets on other networks, on testnet and the development database:
//   1. a test user sends 0.2 USDC from Arc to their OWN new wallet on Base Sepolia
//   2. the dashboard balance for Base Sepolia shows it
//   3. (optional, about 20 minutes) "Move to Arc" brings it back to their Arc wallet
// Exit code 3 means the treasury needs more test USDC.
// Run with: BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 npx tsx scripts/bridge-own-smoke.ts [--with-return]
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { BridgeUserError, chainBalances, driving, getBridgeView, listDestinations, returnToArc, startBridge } from "../src/bridge/user";
import { usdcMicroOf } from "../src/bridge/wallets";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND_MICRO = 400_000;
const withReturn = process.argv.includes("--with-return");

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function waitDone(userId: string, id: string, minutes: number) {
  let view = await getBridgeView(userId, id);
  let last = "";
  const t0 = Date.now();
  while (view && !["COMPLETE", "FAILED"].includes(view.status) && Date.now() - t0 < minutes * 60_000) {
    if (view.status !== last) {
      console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view.status}`);
      last = view.status;
    }
    await sleep(5_000);
    view = await getBridgeView(userId, id);
  }
  console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""}`);
  return { view, seconds: Math.round((Date.now() - t0) / 1000) };
}

async function main() {
  if (!env.BRIDGE_ENABLED) throw new Error("Run with BRIDGE_ENABLED=true");
  const treasuryRes = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (treasuryRes.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const treasuryMicro = t ? Math.round(Number(t.amount) * 1e6) : 0;
  if (!t?.token?.id || treasuryMicro < FUND_MICRO + 100_000) {
    console.log(`NEEDS_FUNDING: treasury has ${show(treasuryMicro)} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Own Wallet Smoke Test", email: `ownsmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  const ids: string[] = [];
  try {
    const dests = await listDestinations();
    check(dests.some((d) => d.id === "own:base" && d.own), "users can choose their own wallet on Base Sepolia");

    const arc = await ensureUserWallet(userId);
    console.log(`Funding the test user's Arc wallet with ${show(FUND_MICRO)} USDC from the treasury...`);
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: t.token.id,
      destinationAddress: arc.address,
      amount: [show(FUND_MICRO)],
      amounts: [show(FUND_MICRO)],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`own-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check((await usdcMicroOf(arc.circleWalletId)) >= FUND_MICRO, "test Arc wallet funded");

    // 1. Arc -> own wallet on Base Sepolia
    const out = await startBridge(userId, { destinationId: "own:base", amount: "0.2" });
    check(Boolean(out?.id) && out?.destinationLabel === "Your wallet", "transfer to their own Base Sepolia wallet started");
    ids.push(out!.id);
    const sent = await waitDone(userId, out!.id, 15);
    check(sent.view?.status === "COMPLETE", `arrived on Base Sepolia in ${sent.seconds} seconds (${sent.view?.mintUrl})`);

    // 2. The dashboard shows it
    let base = (await chainBalances(userId)).find((w) => w.chain === "base");
    for (let i = 0; i < 20 && Number(base?.balance ?? 0) < 0.2; i++) {
      await sleep(3_000);
      base = (await chainBalances(userId)).find((w) => w.chain === "base");
    }
    check(base?.balance === "0.200000", `the dashboard shows 0.2 USDC on Base Sepolia (${base?.address})`);

    // 3. Move it back to Arc (Base Sepolia deposits wait for full finality: about 20 minutes)
    if (withReturn) {
      const arcBefore = await usdcMicroOf(arc.circleWalletId);
      const back = await returnToArc(userId, { chain: "base" });
      check(Boolean(back?.id) && back?.direction === "IN", `"Move to Arc" started: ${back?.amount} USDC after Circle's fee`);
      ids.push(back!.id);
      console.log("Waiting for Base Sepolia finality (up to about 20 minutes)...");
      const home = await waitDone(userId, back!.id, 40);
      check(home.view?.status === "COMPLETE", `back on Arc in ${Math.round(home.seconds / 60)} minutes (${home.view?.mintUrl})`);
      let arcAfter = arcBefore;
      const expected = Math.round(Number(back!.amount) * 1e6);
      for (let i = 0; i < 20 && arcAfter < arcBefore + expected; i++) {
        await sleep(3_000);
        arcAfter = await usdcMicroOf(arc.circleWalletId);
      }
      check(arcAfter - arcBefore === expected, `the Arc wallet received exactly ${back!.amount} USDC`);
    } else {
      console.log("Skipped the 20 minute Move to Arc test.");
    }

    try {
      await returnToArc(userId, { chain: "polygon" });
      check(false, "moving from a network with no USDC is refused");
    } catch (err) {
      check(err instanceof BridgeUserError, "moving from a network with no USDC is refused");
    }
  } finally {
    for (const id of ids) while (driving.has(id)) await sleep(1_000);
    const ts = (await db.select({ id: bridgeTransfers.id }).from(bridgeTransfers).where(eq(bridgeTransfers.userId, userId))).map((r) => r.id);
    if (ts.length) {
      await db.delete(bridgeEvents).where(inArray(bridgeEvents.transferId, ts));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ts));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ts));
    }
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All own wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
DOC_EOF

cat > "frontend/src/lib/bridge.ts" <<'DOC_EOF'
// Shared bridge types and labels for the website.
export type Destination = { id: string; label: string; chain: string; chainLabel: string; address: string | null; own: boolean };

export type ChainWallet = { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null };

export type BridgeQuote = {
  destination: { id: string; label: string; chainLabel: string; address: string };
  amount: string;
  fee: string;
  total: string;
  receives: string;
  available: string;
  allowed: boolean;
  note: string;
};

export type BridgeStep = { step: string; chainLabel: string | null; txHash: string | null; url: string | null; at: string };

export type BridgeView = {
  id: string;
  direction: "OUT" | "IN";
  status: string;
  slowFinality: boolean;
  destinationLabel: string;
  sourceLabel: string;
  destinationChainLabel: string;
  recipientAddress: string;
  amount: string;
  maxFee: string | null;
  mintTxHash: string | null;
  mintUrl: string | null;
  failureReason: string | null;
  createdAt: string;
  steps: BridgeStep[];
};

export const BRIDGE_DONE = ["COMPLETE", "FAILED"];

export const BRIDGE_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Starting", tone: "wait" },
  DEPOSITING: { text: "Moving into Gateway", tone: "wait" },
  DEPOSITED: { text: "Waiting for confirmation", tone: "wait" },
  FINALIZED: { text: "Ready to send", tone: "wait" },
  INTENT_SIGNED: { text: "Signed", tone: "wait" },
  SUBMITTED: { text: "Sending", tone: "wait" },
  MINTED: { text: "Arrived", tone: "good" },
  COMPLETE: { text: "Complete", tone: "good" },
  EXPIRED: { text: "Retrying", tone: "wait" },
  FAILED: { text: "Failed", tone: "bad" },
};

export const STEP_LABELS: Record<string, string> = {
  quoted: "Fee checked",
  deposit_planned: "Preparing deposit",
  approve: "USDC approved for Gateway",
  deposit: "Deposited into Circle Gateway",
  finalized: "Gateway balance confirmed",
  requote: "Fee updated",
  signed: "Transfer signed by your wallet",
  submitted: "Sent to Circle",
  minted: "USDC minted at the destination",
  complete: "Complete",
  expired: "Expired before minting (nothing taken), retrying",
  retry: "Signing again",
  failed: "Failed",
};

export const shortAddress = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;
DOC_EOF

cat > "frontend/src/app/bridge/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { shortAddress, type BridgeQuote, type BridgeView, type Destination } from "@/lib/bridge";

type Limits = { min: number; max: number; daily: number };

export default function BridgePage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [destinations, setDestinations] = useState<Destination[] | null>(null);
  const [limits, setLimits] = useState<Limits | null>(null);
  const [destinationId, setDestinationId] = useState("");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<BridgeQuote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<{ destinations: Destination[]; limits: Limits }>("/bridge/destinations")
      .then((r) => {
        setDestinations(r.destinations);
        setLimits(r.limits);
        if (r.destinations[0]) setDestinationId(r.destinations[0].id);
      })
      .catch((e) => {
        setDestinations([]);
        setError(e instanceof Error ? e.message : "Could not load destinations.");
      });
  }, [session]);

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    try {
      const r = await api<{ quote: BridgeQuote }>("/bridge/quote", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function send() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/transfers", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the transfer.");
      setBusy(false);
    }
  }

  const enough = quote ? Number(quote.available) >= Number(quote.total) : false;

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Send to another network</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Send USDC from your Arc wallet to your own wallet on another network, or to an approved provider, through
          Circle Gateway. You pay no gas on any network; Circle&apos;s fee is shown before you confirm.
        </p>

        <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {destinations === null ? <p className="text-sm text-zinc-500">Loading...</p> : null}
          {destinations && destinations.length === 0 && !error ? (
            <p className="text-sm text-zinc-500">No providers are available yet.</p>
          ) : null}

          {destinations && destinations.length > 0 ? (
            <form onSubmit={getQuote} className="space-y-5">
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Send to</p>
                <div className="mt-2 space-y-2">
                  {destinations.map((d) => (
                    <label
                      key={d.id}
                      className={`flex cursor-pointer items-center justify-between gap-3 rounded-lg border px-3 py-2.5 text-sm ${
                        destinationId === d.id
                          ? "border-emerald-700 bg-emerald-50 dark:border-emerald-500 dark:bg-emerald-950"
                          : "border-zinc-300 dark:border-zinc-700"
                      }`}
                    >
                      <span className="flex items-center gap-2">
                        <input
                          type="radio"
                          name="destination"
                          value={d.id}
                          checked={destinationId === d.id}
                          onChange={() => {
                            setDestinationId(d.id);
                            setQuote(null);
                          }}
                        />
                        <span className="font-medium text-zinc-900 dark:text-zinc-100">{d.label}</span>
                      </span>
                      <span className="text-xs text-zinc-500">
                        {d.chainLabel}
                        {d.address ? (
                          <>
                            {" "}· <span className="font-mono">{shortAddress(d.address)}</span>
                          </>
                        ) : null}
                      </span>
                    </label>
                  ))}
                </div>
              </div>

              <div>
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount (USDC)
                </label>
                <input
                  id="amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => {
                    setAmount(e.target.value);
                    setQuote(null);
                  }}
                  placeholder={limits ? `${limits.min} to ${limits.max}` : "5"}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                {limits ? (
                  <p className="mt-1 text-xs text-zinc-500">
                    Minimum {limits.min} USDC, maximum {limits.max} USDC per transfer, {limits.daily} USDC per day.
                  </p>
                ) : null}
              </div>

              {!quote ? (
                <button
                  type="submit"
                  disabled={busy || !amount || !destinationId}
                  className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Checking the fee..." : "See the fee"}
                </button>
              ) : null}
            </form>
          ) : null}

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[9rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">To</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {quote.destination.label} ({quote.destination.chainLabel})
                </dd>
                <dt className="text-zinc-500">Address</dt>
                <dd className="truncate font-mono text-zinc-900 dark:text-zinc-100">{quote.destination.address}</dd>
                <dt className="text-zinc-500">They receive</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.receives} USDC</dd>
                <dt className="text-zinc-500">Circle fee (max)</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.fee} USDC</dd>
                <dt className="text-zinc-500">From your wallet</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.total} USDC</dd>
                <dt className="text-zinc-500">You have</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.available} USDC</dd>
              </dl>
              <p className="text-xs text-zinc-500">{quote.note}</p>
              {!quote.allowed ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Circle&apos;s fee to this network is unusually high right now. Please try again later.
                </p>
              ) : null}
              {!enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough USDC for this amount plus the fee.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={send}
                  disabled={busy || !enough || !quote.allowed}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Starting..." : `Send ${quote.amount} USDC`}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
            </div>
          ) : null}

          {error ? (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          ) : null}
        </section>
      </div>
    </main>
  );
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

cat > "frontend/src/app/dashboard/page.tsx" <<'DOC_EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ChainWallets } from "@/components/ChainWallets";
import { RecentOrders } from "@/components/RecentOrders";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [bridgeOn, setBridgeOn] = useState(false);

  // The "Send to a provider" button appears only when bridging is switched on
  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean }) => setBridgeOn(Boolean(s.bridge)))
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
          <button
            onClick={logOut}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Log out
          </button>
        </header>

        <h1 className="mt-10 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          Hello, {user.name.split(" ")[0]}
        </h1>

        <div className="mt-4 flex flex-wrap gap-3">
          <Link
            href="/buy"
            className="inline-block rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
          >
            Buy airtime or data
          </Link>
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
          <h2 className="text-sm font-medium text-zinc-500">Your account</h2>
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
      </div>
    </main>
  );
}
DOC_EOF

cat > "frontend/src/components/ChainWallets.tsx" <<'DOC_EOF'
"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { shortAddress, type BridgeView, type ChainWallet } from "@/lib/bridge";

const usdc = (s: string) => Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

// The user's own wallets on other networks (created the first time they send there)
export function ChainWallets() {
  const router = useRouter();
  const [rows, setRows] = useState<ChainWallet[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api<{ wallets: ChainWallet[] }>("/bridge/wallets")
      .then((r) => setRows(r.wallets))
      .catch(() => setRows([]));
  }, []);

  async function moveToArc(chain: string) {
    setBusy(chain);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/return", { method: "POST", body: JSON.stringify({ chain }) });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not start the transfer.");
      setBusy(null);
    }
  }

  if (!rows || rows.length === 0) return null;

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <h2 className="text-sm font-medium text-zinc-500">Your USDC on other networks</h2>
      <ul className="mt-3 divide-y divide-zinc-100 dark:divide-zinc-800">
        {rows.map((w) => (
          <li key={w.chain} className="flex flex-wrap items-center justify-between gap-3 py-3">
            <div className="min-w-0">
              <p className="text-sm font-medium text-zinc-900 dark:text-zinc-100">{w.chainLabel}</p>
              <a href={w.explorerUrl} target="_blank" rel="noreferrer" className="font-mono text-xs text-emerald-700 hover:underline dark:text-emerald-400">
                {shortAddress(w.address)}
              </a>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-sm font-semibold text-zinc-900 dark:text-zinc-50">
                {w.balance === null ? "unavailable" : `${usdc(w.balance)} USDC`}
              </span>
              {w.balance !== null && Number(w.balance) >= 0.1 ? (
                <button
                  onClick={() => moveToArc(w.chain)}
                  disabled={busy !== null}
                  className="rounded-lg border border-zinc-300 px-3 py-1.5 text-xs font-medium text-zinc-800 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  {busy === w.chain ? "Starting..." : "Move to Arc"}
                </button>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
      <p className="mt-2 text-xs text-zinc-500">
        Move to Arc sends everything on that network back to your Arc wallet, minus Circle&apos;s fee. No gas needed.
      </p>
      {error ? (
        <p className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
      ) : null}
    </section>
  );
}
DOC_EOF

grep -q 'returnToArc' backend/src/bridge/user.ts || fail "Could not write backend/src/bridge/user.ts"
green "OK: files written (no database changes in this script)"

# --- 2. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Own wallets: real test (0.2 test USDC Arc Testnet -> the test user's own Base Sepolia wallet)"
echo "The full test also moves it back to Arc. Base Sepolia deposits wait for finality,"
echo "so that part takes about 20 minutes. Recommended: y (you can leave it running)."
read -r -p "Include the 20 minute Move to Arc test? (y/n) " ans
RETURN_FLAG=""
[[ "$ans" == "y" || "$ans" == "Y" ]] && RETURN_FLAG="--with-return"
set +e
(cd backend && BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 npx tsx scripts/bridge-own-smoke.ts $RETURN_FLAG); code=$?
set -e
if [[ $code -eq 3 ]]; then
  fail "The treasury needs more test USDC. Send at least 1 to $(env_get TREASURY_ADDRESS) from faucet.circle.com (Arc Testnet), then run again."
elif [[ $code -ne 0 ]]; then
  fail "Own wallet test failed (details above). Nothing was committed. Paste the output to Claude."
fi

step "Delivery, refunds, payments, pricing, wallets and auth: make sure they still work"
(cd backend && npx tsx scripts/delivery-smoke.ts) || fail "Delivery test failed (details above). Nothing was committed."
set +e
(cd backend && npx tsx scripts/refund-smoke.ts); code=$?
set -e
[[ $code -eq 0 || $code -eq 3 ]] || fail "Refund test failed (details above). Nothing was committed."
ADDR_FILE="$(mktemp)"
set +e
(cd backend && npx tsx scripts/pay-smoke.ts "$ADDR_FILE"); code=$?
set -e
rm -f "$ADDR_FILE"
if [[ $code -eq 3 ]]; then
  yellow "The payment test wallet has less than 0.5 test USDC, so the live payment test was skipped."
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

# --- 3. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Own wallets on other networks: send to self, balances on the dashboard, Move to Arc"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url text
  local label="$1" url="$2" want="$3" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *"$want"* ]]; then echo; green "OK: $label"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}
wait_for "the new API on Render" "$PROD_API/api/status" '"bridgeOwnWallets":true' || fail "The API did not come up. Check Events and Logs on Render."
wait_for "the website" "$PROD_FRONTEND/api/status" '"bridgeOwnWallets":true' || fail "The website cannot reach the new API yet. Check vercel.com."

# --- 4. Switch off the shared test provider ---------------------------------------------
step "Switching off the shared test provider for users"
bash setup/destinations.sh prod disable "$(env_get GATEWAY_PROBE_RECIPIENT_ADDRESS)" \
  || yellow "Could not switch it off. Run later: bash setup/destinations.sh prod disable $(env_get GATEWAY_PROBE_RECIPIENT_ADDRESS)"

echo
green "Script 17 complete. Users can send USDC to their own wallets on 7 networks and move it back to Arc."
echo "  Try it: $PROD_FRONTEND/dashboard > 'Send to another network' > 'My wallet on Base Sepolia'"
