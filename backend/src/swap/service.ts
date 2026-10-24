// Swaps on Arc between USDC, EURC and cirBTC, through Circle App Kit.
//
// Swap: PENDING -> COMPLETE   (or FAILED: nothing swapped, or UNKNOWN: check onchain)
//
// Safety:
//   - one swap at a time per user (unique open_key), so a double click cannot swap twice
//   - the user never gets less than the quote minus the slippage (1% by default):
//     otherwise the swap reverts and nothing changes
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

type Params = { tokenIn?: unknown; tokenOut?: unknown; amount?: unknown };

function readParams(body: Params) {
  if (!isToken(body.tokenIn) || !isToken(body.tokenOut)) throw new SwapError("Choose two of USDC, EURC and cirBTC.");
  if (body.tokenIn === body.tokenOut) throw new SwapError("Choose two different tokens.");
  return { tokenIn: body.tokenIn, tokenOut: body.tokenOut, amountIn: parseAmount(body.tokenIn, body.amount) };
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

  const params = swapParams(wallet.address, tokenIn, tokenOut, amountIn);
  try {
    const estimate = (await appKit().kit.estimateSwap(params as never)) as { estimatedOutput?: unknown; stopLimit?: unknown };
    await db.update(swaps).set({ estimatedOut: amountOf(estimate.estimatedOutput), minOut: amountOf(estimate.stopLimit) }).where(eq(swaps.id, row.id));
  } catch (err) {
    const message = errorText(err);
    await db.update(swaps).set({ status: "FAILED", error: message, openKey: null }).where(eq(swaps.id, row.id));
    console.error(`[swap] ${row.id} no quote:`, message);
    throw new SwapError("No price is available for this swap right now. Nothing was taken. Please try again shortly.", 502);
  }

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
