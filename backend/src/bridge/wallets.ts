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
