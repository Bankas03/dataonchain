// Moves USDC from a user's retired (old EOA) wallet into their current SCA wallet.
//
// Sweep: PENDING -> SENT -> CONFIRMED   (or FAILED, then tried again later)
//
// Safety:
//   - only one open sweep per old wallet (unique open_key)
//   - the Circle transfer uses an idempotency key made from the sweep id, so a
//     retry after a crash can never send twice
//   - never sweeps while a payment from the old wallet is still in progress
//   - the old wallet pays its own small Arc fee, so a little USDC is left for it
import { and, eq, inArray, isNotNull, isNull, lt, or } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { auditLogs, payments, walletSweeps, wallets } from "../db/schema";
import { ensureUserWallet, uuidFrom } from "./service";

// Keep this much in the old wallet for the Arc network fee of the sweep itself
const FEE_RESERVE_MICRO = 10_000; // 0.01 USDC
// Do not bother moving less than this
const MIN_SWEEP_MICRO = 20_000; // 0.02 USDC
// How often a retired wallet is checked for new USDC
const RECHECK_MS = 10 * 60_000;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

type Wallet = typeof wallets.$inferSelect;
type Sweep = typeof walletSweeps.$inferSelect;
export type SweepResult = "nothing" | "busy" | "sent" | "waiting" | "confirmed" | "failed";

const text = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;

function microFrom(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

async function usdcOf(circleWalletId: string): Promise<{ tokenId?: string; micro: number }> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: b ? microFrom(b.amount) : 0 };
}

async function audit(action: string, walletId: string, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "system", action, targetType: "wallet", targetId: walletId, details });
}

// One step for one retired wallet. Safe to call as often as you like.
export async function sweepWallet(oldWalletId: string): Promise<SweepResult> {
  const [old] = await db.select().from(wallets).where(eq(wallets.id, oldWalletId)).limit(1);
  if (!old || old.accountType !== "EOA" || !old.retiredAt || !old.userId) return "nothing";

  const [open] = await db.select().from(walletSweeps).where(eq(walletSweeps.openKey, old.id)).limit(1);
  if (open) return open.status === "PENDING" ? sendSweep(old, open) : checkSweep(old, open);

  // A payment from the old wallet still in progress: leave its USDC alone for now
  const [busy] = await db
    .select({ id: payments.id })
    .from(payments)
    .where(and(eq(payments.walletId, old.id), inArray(payments.status, ["INITIATED", "PENDING"])))
    .limit(1);
  if (busy) return "busy";

  const balance = await usdcOf(old.circleWalletId);
  await db.update(wallets).set({ checkedAt: new Date() }).where(eq(wallets.id, old.id));
  if (!balance.tokenId || balance.micro < MIN_SWEEP_MICRO) return "nothing";

  const target = await ensureUserWallet(old.userId);
  await db
    .insert(walletSweeps)
    .values({
      userId: old.userId,
      fromWalletId: old.id,
      toWalletId: target.id,
      toAddress: target.address,
      token: balance.tokenId,
      amountMicro: balance.micro - FEE_RESERVE_MICRO,
      openKey: old.id,
      status: "PENDING",
    })
    .onConflictDoNothing();
  const [created] = await db.select().from(walletSweeps).where(eq(walletSweeps.openKey, old.id)).limit(1);
  return created ? sendSweep(old, created) : "busy";
}

async function sendSweep(old: Wallet, sweep: Sweep): Promise<SweepResult> {
  const amount = text(sweep.amountMicro);
  const input = {
    walletId: old.circleWalletId,
    tokenId: sweep.token,
    destinationAddress: sweep.toAddress,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`sweep:${sweep.id}`),
    refId: `SWEEP-${sweep.id.slice(0, 8)}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const transactionId = res.data?.id;
    if (!transactionId) return "waiting";
    await db
      .update(walletSweeps)
      .set({ circleTransactionId: transactionId, status: "SENT", lastError: null })
      .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "PENDING")));
    console.log(`[sweep] moving ${amount} USDC from old wallet ${old.address} to ${sweep.toAddress}`);
    return "sent";
  } catch (err) {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[sweep] ${old.address} not accepted yet:`, message, detail ?? "");
    await db.update(walletSweeps).set({ lastError: message.slice(0, 500) }).where(eq(walletSweeps.id, sweep.id));
    return "waiting";
  }
}

async function checkSweep(old: Wallet, sweep: Sweep): Promise<SweepResult> {
  if (!sweep.circleTransactionId) return "waiting";
  const res = await circle.getTransaction({ id: sweep.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (!tx?.state) return "waiting";

  if (FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`;
    // Nothing moved. Close it; the wallet is checked again later with a new sweep.
    await db
      .update(walletSweeps)
      .set({ status: "FAILED", openKey: null, lastError: reason })
      .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "SENT")));
    await audit("wallet.sweep_failed", old.id, { reason });
    console.error(`[sweep] ${old.address} failed: ${reason}`);
    return "failed";
  }
  if (tx.state !== "COMPLETE") return "waiting";

  const [done] = await db
    .update(walletSweeps)
    .set({ status: "CONFIRMED", txHash: tx.txHash ?? null, openKey: null })
    .where(and(eq(walletSweeps.id, sweep.id), eq(walletSweeps.status, "SENT")))
    .returning();
  if (done) await audit("wallet.swept", old.id, { amountMicro: sweep.amountMicro, to: sweep.toAddress, txHash: tx.txHash });
  return "confirmed";
}

// Worker step: upgrade a few users still on an old wallet, then sweep retired
// wallets that have an open sweep or are due for a check.
export async function runWalletUpgrades(): Promise<void> {
  const notUpgraded = await db
    .select({ userId: wallets.userId })
    .from(wallets)
    .where(and(eq(wallets.accountType, "EOA"), isNull(wallets.retiredAt), isNotNull(wallets.userId)))
    .limit(10);
  for (const row of notUpgraded) {
    try {
      if (row.userId) await ensureUserWallet(row.userId);
    } catch (err) {
      console.error(`[sweep] could not upgrade user ${row.userId}:`, err instanceof Error ? err.message : err);
    }
  }

  const openSweeps = await db
    .select({ walletId: walletSweeps.fromWalletId })
    .from(walletSweeps)
    .where(isNotNull(walletSweeps.openKey))
    .limit(20);
  const due = await db
    .select({ walletId: wallets.id })
    .from(wallets)
    .where(
      and(
        eq(wallets.accountType, "EOA"),
        isNotNull(wallets.retiredAt),
        or(isNull(wallets.checkedAt), lt(wallets.checkedAt, new Date(Date.now() - RECHECK_MS))),
      ),
    )
    .limit(20);
  const ids = new Set([...openSweeps.map((r) => r.walletId), ...due.map((r) => r.walletId)]);
  for (const id of ids) {
    try {
      await sweepWallet(id);
    } catch (err) {
      console.error(`[sweep] wallet ${id}:`, err instanceof Error ? err.message : err);
    }
  }
}
