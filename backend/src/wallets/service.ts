// User wallets: one active Circle wallet per user per blockchain.
//
// New and existing users get a smart contract account (SCA). Its network
// fees are paid by Circle Gas Station, so users never need extra USDC for gas.
// Users who had a plain (EOA) wallet before keep it as a retired wallet; the
// worker moves its USDC into the SCA wallet (see wallets/sweep.ts).
import { createHash } from "node:crypto";
import { and, eq, isNull } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { wallets } from "../db/schema";
import { env } from "../env";

export type UserWallet = typeof wallets.$inferSelect;

export const NETWORK_NAMES: Record<string, string> = {
  "ARC-TESTNET": "Arc Testnet",
  ARC: "Arc",
};

// The same input always gives the same key, so a retry can never create a
// second wallet on Circle.
export function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function findWallet(userId: string, accountType: "EOA" | "SCA"): Promise<UserWallet | undefined> {
  const rows = await db
    .select()
    .from(wallets)
    .where(
      and(eq(wallets.userId, userId), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN), eq(wallets.accountType, accountType)),
    )
    .limit(1);
  return rows[0];
}

// The user's active wallet (always an SCA). Creates it on first use and
// retires any older EOA wallet the user had.
export async function ensureUserWallet(userId: string): Promise<UserWallet> {
  const existing = await findWallet(userId, "SCA");
  if (existing) return existing;

  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
    count: 1,
    accountType: "SCA",
    idempotencyKey: uuidFrom(`wallet:sca:${userId}:${env.CIRCLE_BLOCKCHAIN}`),
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
      accountType: "SCA",
    })
    .onConflictDoNothing();

  const saved = await findWallet(userId, "SCA");
  if (!saved) throw new Error("Wallet was created on Circle but could not be saved");

  // The old wallet stops being used. Its USDC is moved across by the worker.
  await db
    .update(wallets)
    .set({ retiredAt: new Date() })
    .where(
      and(
        eq(wallets.userId, userId),
        eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN),
        eq(wallets.accountType, "EOA"),
        isNull(wallets.retiredAt),
      ),
    );
  return saved;
}

// The user's old wallet, if they had one before smart accounts.
export async function previousWallet(userId: string): Promise<UserWallet | undefined> {
  return findWallet(userId, "EOA");
}

// USDC balance as a decimal string, for example "12.5". "0" when empty.
export async function getUsdcBalance(circleWalletId: string): Promise<string> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const balances = res.data?.tokenBalances ?? [];
  const usdc = balances.find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc?.amount ?? "0";
}
