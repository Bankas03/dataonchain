// Bridging OUT for signed in users: from their Arc smart wallet to an approved
// (VTU provider) address on another chain, through Circle Gateway.
import { and, desc, eq, gte, inArray, notInArray } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { approvedDestinations, bridgeEvents, bridgeTransfers } from "../db/schema";
import { env } from "../env";
import { ensureUserWallet } from "../wallets/service";
import { chainByKey, feeCapMicro, homeChain } from "./chains";
import { buildSpec, estimate, gatewayBalanceMicro, microFromDecimal, newSalt } from "./gateway";
import { BridgeError, advanceTransfer, createTransfer } from "./service";

export class BridgeUserError extends Error {
  constructor(message: string, public status: 400 | 402 | 404 | 409 | 503 = 400) {
    super(message);
  }
}

const OPEN = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "EXPIRED"] as const;
const usdcText = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
const micro = (usdc: number) => Math.round(usdc * 1_000_000);

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

async function findDestination(id: unknown) {
  const [d] = await db
    .select()
    .from(approvedDestinations)
    .where(and(eq(approvedDestinations.id, String(id ?? "")), eq(approvedDestinations.active, true)))
    .limit(1);
  if (!d) throw new BridgeUserError("Choose one of the listed destinations.", 404);
  return d;
}

async function usdcInWallet(walletId: string): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return b ? microFromDecimal(b.amount) : 0;
}

export async function listDestinations() {
  requireEnabled();
  const rows = await db.select().from(approvedDestinations).where(eq(approvedDestinations.active, true));
  return rows.map((d) => {
    const chain = chainByKey(d.chain);
    return { id: d.id, label: d.label, chain: chain.key, chainLabel: chain.label, address: d.address };
  });
}

// What the user would pay. Nothing is saved.
export async function quoteBridge(userId: string, body: { destinationId?: unknown; amount?: unknown }) {
  requireEnabled();
  const dest = await findDestination(body.destinationId);
  const amountMicro = parseAmount(body.amount);
  const wallet = await ensureUserWallet(userId);
  const source = homeChain();
  const destination = chainByKey(dest.chain);
  const est = await estimate(
    buildSpec({ source, destination, depositor: wallet.address, recipient: dest.address, amountMicro, salt: newSalt() }),
    true,
  );
  const [inWallet, inGateway] = await Promise.all([usdcInWallet(wallet.circleWalletId), gatewayBalanceMicro(wallet.address, source.domain)]);
  return {
    destination: { id: dest.id, label: dest.label, chainLabel: destination.label, address: dest.address },
    amount: usdcText(amountMicro),
    fee: usdcText(est.maxFeeMicro),
    total: usdcText(amountMicro + est.maxFeeMicro),
    receives: usdcText(amountMicro),
    available: usdcText(inWallet + inGateway),
    allowed: est.maxFeeMicro <= feeCapMicro(destination),
    note: "The fee shown is the most Circle can charge; any unused part stays in your bridge balance for next time.",
  };
}

export async function startBridge(userId: string, body: { destinationId?: unknown; amount?: unknown }) {
  requireEnabled();
  const dest = await findDestination(body.destinationId);
  const amountMicro = parseAmount(body.amount);

  const [open] = await db
    .select({ id: bridgeTransfers.id })
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.userId, userId), inArray(bridgeTransfers.status, [...OPEN])))
    .limit(1);
  if (open) throw new BridgeUserError("You already have a transfer in progress. Please wait for it to finish.", 409);

  const since = new Date(Date.now() - 24 * 60 * 60_000);
  const today = await db
    .select({ amountMicro: bridgeTransfers.amountMicro })
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.userId, userId), gte(bridgeTransfers.createdAt, since), notInArray(bridgeTransfers.status, ["FAILED"])));
  const used = today.reduce((s, r) => s + r.amountMicro, 0);
  if (used + amountMicro > micro(env.BRIDGE_DAILY_USDC)) {
    throw new BridgeUserError(`The daily limit is ${env.BRIDGE_DAILY_USDC} USDC. You can send ${usdcText(Math.max(0, micro(env.BRIDGE_DAILY_USDC) - used))} more today.`);
  }

  const wallet = await ensureUserWallet(userId);
  const source = homeChain();
  const destination = chainByKey(dest.chain);
  // Check the balance against Circle's current fee before anything is saved
  const est = await estimate(
    buildSpec({ source, destination, depositor: wallet.address, recipient: dest.address, amountMicro, salt: newSalt() }),
    true,
  );
  const [inWallet, inGateway] = await Promise.all([usdcInWallet(wallet.circleWalletId), gatewayBalanceMicro(wallet.address, source.domain)]);
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
      destinationChain: dest.chain,
      recipientAddress: dest.address,
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
      while (Date.now() - started < 20 * 60_000) {
        const before = await db.select({ status: bridgeTransfers.status }).from(bridgeTransfers).where(eq(bridgeTransfers.id, id)).limit(1);
        const t = await advanceTransfer(id);
        if (t.status === "COMPLETE" || t.status === "FAILED") break;
        if (before[0]?.status === t.status) await new Promise((r) => setTimeout(r, 4_000));
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
  const [dest] = await db
    .select({ label: approvedDestinations.label })
    .from(approvedDestinations)
    .where(and(eq(approvedDestinations.chain, t.destinationChain), eq(approvedDestinations.address, t.recipientAddress)))
    .limit(1);
  const events = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(bridgeEvents.createdAt);
  return {
    id: t.id,
    status: t.status,
    destinationLabel: dest?.label ?? t.recipientAddress,
    sourceLabel: source.label,
    destinationChainLabel: destination.label,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    maxFee: t.maxFeeMicro !== null ? usdcText(t.maxFeeMicro) : null,
    mintTxHash: t.mintTxHash,
    mintUrl: t.mintTxHash ? `${destination.explorerTx}${t.mintTxHash}` : null,
    failureReason: t.failureReason,
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
    status: t.status,
    destinationChainLabel: chainByKey(t.destinationChain).label,
    recipientAddress: t.recipientAddress,
    amount: usdcText(t.amountMicro),
    createdAt: t.createdAt.toISOString(),
  }));
}

// The user's leftover bridge balance (unused fees stay in Gateway for next time)
export async function bridgeBalance(walletAddress: string): Promise<string | null> {
  if (!env.BRIDGE_ENABLED) return null;
  try {
    return usdcText(await gatewayBalanceMicro(walletAddress, homeChain().domain));
  } catch {
    return null;
  }
}
