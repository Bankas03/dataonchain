// User wallets: one Circle wallet per user per blockchain.
import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { wallets } from "../db/schema";
import { env } from "../env";

export type UserWallet = typeof wallets.$inferSelect;

export const NETWORK_NAMES: Record<string, string> = {
  "ARC-TESTNET": "Arc Testnet",
  ARC: "Arc",
};

// The same user always gets the same key, so a retry can never create a
// second wallet on Circle.
function idempotencyKeyFor(userId: string, blockchain: string): string {
  const h = createHash("sha256").update(`wallet:${userId}:${blockchain}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function findWallet(userId: string): Promise<UserWallet | undefined> {
  const rows = await db
    .select()
    .from(wallets)
    .where(and(eq(wallets.userId, userId), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN)))
    .limit(1);
  return rows[0];
}

export async function ensureUserWallet(userId: string): Promise<UserWallet> {
  const existing = await findWallet(userId);
  if (existing) return existing;

  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
    count: 1,
    accountType: "EOA",
    idempotencyKey: idempotencyKeyFor(userId, env.CIRCLE_BLOCKCHAIN),
  });
  const created = res.data?.wallets?.[0];
  if (!created?.id || !created.address) {
    throw new Error("Circle did not return a wallet");
  }

  await db
    .insert(wallets)
    .values({
      userId,
      purpose: "user",
      circleWalletId: created.id,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER",
      blockchain: env.CIRCLE_BLOCKCHAIN,
      address: created.address,
    })
    .onConflictDoNothing();

  const saved = await findWallet(userId);
  if (!saved) throw new Error("Wallet was created on Circle but could not be saved");
  return saved;
}

// USDC balance as a decimal string, for example "12.5". "0" when empty.
export async function getUsdcBalance(circleWalletId: string): Promise<string> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const balances = res.data?.tokenBalances ?? [];
  const usdc = balances.find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc?.amount ?? "0";
}
