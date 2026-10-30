// Deposits: USDC, EURC or cirBTC arriving in a user's wallet from outside
// dataonchain (an exchange, another wallet, another dataonchain user).
//
// Every minute the worker asks Circle for inbound transfers of the last 3 hours
// (one call for all wallets, not one per user), keeps the completed ones that
// went to a user's wallet, leaves out our own money movements (swaps, transfers
// between networks, refunds, wallet upgrades), and records each once. The user
// sees "Received" in their activity and gets one email.
//
// Safety: only real USDC, EURC and cirBTC count (checked by contract address on
// mainnet), so a fake token named "USDC" sent to a wallet never shows as money.
import { and, desc, eq, gte, inArray, isNull } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { bridgeTransfers, deposits, refunds, swaps, users, walletSweeps, wallets } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { bridgeChains, chainByKey, isMainnet, type BridgeChain } from "../bridge/chains";

const LOOKBACK_MS = 3 * 60 * 60_000;
// Our own flows record their transaction a moment after it lands: wait this
// long before deciding a transfer came from outside
const SETTLE_MS = Number(process.env.DEPOSIT_SETTLE_MS ?? 2 * 60_000);
const MAX_PAGES = 10;

// Mainnet token contracts on Arc beside USDC
const ARC_MAINNET_TOKENS: Record<string, "EURC" | "cirBTC"> = {
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1": "EURC",
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0": "cirBTC",
};
// Senders that are our own flows, never a deposit
const INTERNAL_SENDERS = new Set([
  "0x0000000000000000000000000000000000000000",
  "0x7fb8c7260b63934d8da38af902f87ae6e284a845", // App Kit swap contract on Arc
]);

type CircleTx = {
  id: string;
  walletId?: string;
  blockchain: string;
  tokenId?: string;
  amounts?: string[];
  sourceAddress?: string;
  txHash?: string;
  state: string;
  createDate: string;
};
type TokenInfo = { symbol: string; address: string | null; native: boolean };

const tokenCache = new Map<string, TokenInfo | null>();

async function tokenInfo(tokenId: string, circleWalletId: string): Promise<TokenInfo | null> {
  if (tokenCache.has(tokenId)) return tokenCache.get(tokenId) ?? null;
  let info: TokenInfo | null = null;
  try {
    const getToken = (circle as unknown as { getToken?: (i: { id: string }) => Promise<{ data?: { token?: { symbol?: string; tokenAddress?: string; isNative?: boolean } } }> }).getToken;
    if (getToken) {
      const t = (await getToken.call(circle, { id: tokenId })).data?.token;
      if (t?.symbol) info = { symbol: t.symbol, address: t.tokenAddress?.toLowerCase() ?? null, native: Boolean(t.isNative) };
    }
  } catch {
    info = null;
  }
  if (!info) {
    // Fallback: the wallet's own balances list the token while it still holds some
    const res = await circle.getWalletTokenBalance({ id: circleWalletId });
    const b = (res.data?.tokenBalances ?? []).find((x) => x.token?.id === tokenId);
    const t = b?.token as unknown as { symbol?: string; tokenAddress?: string; isNative?: boolean } | undefined;
    if (t?.symbol) info = { symbol: t.symbol, address: t.tokenAddress?.toLowerCase() ?? null, native: Boolean(t.isNative) };
  }
  // Only a known answer is kept: a lookup that failed (network) is tried again next scan
  if (info) tokenCache.set(tokenId, info);
  return info;
}

// The token's name in dataonchain, or null when it is not one we show
function knownToken(chain: BridgeChain, info: TokenInfo): "USDC" | "EURC" | "cirBTC" | null {
  const sym = info.symbol.toUpperCase();
  if (info.address && info.address === chain.usdc.toLowerCase()) return "USDC";
  if (chain.key === "arc" && info.native && sym.startsWith("USDC")) return "USDC";
  if (chain.key !== "arc") return null;
  if (isMainnet()) return info.address ? (ARC_MAINNET_TOKENS[info.address] ?? null) : null;
  // Testnet: no real value, so the symbol is enough for EURC and cirBTC
  if (sym.startsWith("EURC")) return "EURC";
  if (sym.startsWith("CIRBTC")) return "cirBTC";
  return null;
}

// Hashes of transactions our own flows made (they also bring money into wallets)
async function ownHashes(hashes: string[]): Promise<Set<string>> {
  const own = new Set<string>();
  if (!hashes.length) return own;
  const lower = hashes.map((h) => h.toLowerCase());
  const all = [...new Set([...hashes, ...lower])];
  const add = (rows: { h: string | null }[]) => rows.forEach((r) => r.h && own.add(r.h.toLowerCase()));
  add(await db.select({ h: swaps.txHash }).from(swaps).where(inArray(swaps.txHash, all)));
  add(await db.select({ h: bridgeTransfers.mintTxHash }).from(bridgeTransfers).where(inArray(bridgeTransfers.mintTxHash, all)));
  add(await db.select({ h: refunds.txHash }).from(refunds).where(inArray(refunds.txHash, all)));
  add(await db.select({ h: walletSweeps.txHash }).from(walletSweeps).where(inArray(walletSweeps.txHash, all)));
  return own;
}

async function notify(d: typeof deposits.$inferSelect, chain: BridgeChain) {
  const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, d.userId)).limit(1);
  if (!user || /@(example\.com|[^@]*\.local)$/i.test(user.email)) return;
  const onArc = chain.key === "arc";
  const message = noticeEmail({
    brand: "dataonchain",
    subject: `You received ${d.amount} ${d.token}`,
    lines: [
      `Hello ${user.name.split(" ")[0]},`,
      `${d.amount} ${d.token} arrived in your dataonchain wallet on ${chain.label}.`,
      ...(d.sourceAddress ? [`From: ${d.sourceAddress}`] : []),
      onArc
        ? "It is in your balance now."
        : `To use it, open your dashboard and tap Move to Arc next to ${chain.label}. It takes about 20 minutes.`,
    ],
    button: { label: "Open your wallet", url: `${env.BETTER_AUTH_URL}/dashboard` },
    footer: "Did not expect this? You do not need to do anything. Never send funds back to someone who asks you to after an unexpected deposit.",
  });
  await sendEmail({ to: user.email, ...message });
}

// Deposits in a period, for the daily report
export async function depositSummary(since: Date) {
  const rows = await db.select({ token: deposits.token, amount: deposits.amount }).from(deposits).where(gte(deposits.receivedAt, since));
  const usdc = rows.filter((r) => r.token === "USDC").reduce((s, r) => s + Number(r.amount), 0);
  return { count: rows.length, usdc: usdc.toFixed(2) };
}

// One pass for the worker. Safe to run as often as you like.
export async function scanDeposits(): Promise<number> {
  const userWallets = await db
    .select({ id: wallets.id, userId: wallets.userId, circleWalletId: wallets.circleWalletId, blockchain: wallets.blockchain, address: wallets.address })
    .from(wallets)
    .where(eq(wallets.purpose, "user"));
  const byCircleId = new Map(userWallets.filter((w) => w.userId).map((w) => [w.circleWalletId, w]));
  if (!byCircleId.size) return 0;
  const chains = bridgeChains();
  const gatewayMinters = new Set(chains.map((c) => c.gatewayMinter.toLowerCase()));

  const from = new Date(Date.now() - LOOKBACK_MS).toISOString();
  const settled = Date.now() - SETTLE_MS;
  const found: CircleTx[] = [];
  let pageAfter: string | undefined;
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await circle.listTransactions({
      txType: "INBOUND",
      from,
      order: "ASC",
      pageSize: 50,
      includeAll: true,
      ...(pageAfter ? { pageAfter } : {}),
    } as unknown as Parameters<typeof circle.listTransactions>[0]);
    const list = (res.data?.transactions ?? []) as unknown as CircleTx[];
    found.push(...list);
    if (list.length < 50) break;
    pageAfter = list[list.length - 1]!.id;
  }

  const candidates = found.filter(
    (t) => t.state === "COMPLETE" && t.walletId && byCircleId.has(t.walletId) && new Date(t.createDate).getTime() < settled,
  );
  if (!candidates.length) return 0;
  const seen = new Set(
    (await db.select({ id: deposits.circleTransactionId }).from(deposits).where(inArray(deposits.circleTransactionId, candidates.map((t) => t.id)))).map((r) => r.id),
  );
  const fresh = candidates.filter((t) => !seen.has(t.id));
  if (!fresh.length) return 0;
  const own = await ownHashes(fresh.map((t) => t.txHash).filter((h): h is string => Boolean(h)));

  let added = 0;
  for (const t of fresh) {
    const w = byCircleId.get(t.walletId!)!;
    const chain = chains.find((c) => c.circleBlockchain === w.blockchain);
    if (!chain || !t.tokenId || !t.amounts?.[0]) continue;
    const source = t.sourceAddress?.toLowerCase() ?? "";
    if (t.txHash && own.has(t.txHash.toLowerCase())) continue;
    if (INTERNAL_SENDERS.has(source) || gatewayMinters.has(source) || source === env.TREASURY_ADDRESS.toLowerCase()) continue;
    if (userWallets.some((x) => x.userId === w.userId && x.address.toLowerCase() === source)) continue; // their own other wallet
    const info = await tokenInfo(t.tokenId, w.circleWalletId);
    const token = info ? knownToken(chain, info) : null;
    if (!token || Number(t.amounts[0]) <= 0) continue;

    const [row] = await db
      .insert(deposits)
      .values({
        circleTransactionId: t.id,
        userId: w.userId!,
        walletId: w.id,
        chain: chain.key,
        token,
        amount: t.amounts[0],
        sourceAddress: t.sourceAddress ?? null,
        txHash: t.txHash ?? null,
        receivedAt: new Date(t.createDate),
      })
      .onConflictDoNothing()
      .returning();
    if (!row) continue;
    added++;
    try {
      await notify(row, chain);
      await db.update(deposits).set({ notifiedAt: new Date() }).where(eq(deposits.id, row.id));
    } catch (err) {
      console.error(`[deposits] ${row.id} email failed:`, err instanceof Error ? err.message : err);
    }
  }
  if (added) console.log(`[deposits] ${added} new deposit(s)`);
  await retryEmails();
  return added;
}

// A deposit whose email failed (Resend down, network) is emailed on a later scan,
// for up to a day
async function retryEmails() {
  const due = await db
    .select()
    .from(deposits)
    .where(and(isNull(deposits.notifiedAt), gte(deposits.receivedAt, new Date(Date.now() - 24 * 60 * 60_000))))
    .limit(10);
  for (const d of due) {
    let chain: BridgeChain;
    try {
      chain = chainByKey(d.chain);
    } catch {
      continue;
    }
    try {
      await notify(d, chain);
      await db.update(deposits).set({ notifiedAt: new Date() }).where(eq(deposits.id, d.id));
    } catch (err) {
      console.error(`[deposits] ${d.id} email failed again:`, err instanceof Error ? err.message : err);
    }
  }
}

export async function listDeposits(userId: string, limit = 20) {
  const rows = await db.select().from(deposits).where(eq(deposits.userId, userId)).orderBy(desc(deposits.receivedAt)).limit(limit);
  return rows.map((d) => {
    let chain: BridgeChain | null = null;
    try {
      chain = chainByKey(d.chain);
    } catch {
      chain = null;
    }
    return {
      id: d.id,
      chain: d.chain,
      chainLabel: chain?.label ?? d.chain,
      token: d.token,
      amount: d.amount,
      sourceAddress: d.sourceAddress,
      explorerUrl: chain && d.txHash ? `${chain.explorerTx}${d.txHash}` : null,
      receivedAt: d.receivedAt.toISOString(),
    };
  });
}
