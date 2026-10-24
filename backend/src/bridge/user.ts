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
