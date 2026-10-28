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
  const sent = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
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
