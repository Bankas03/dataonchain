// Sending USDC, EURC or cirBTC from a user's Arc wallet to another wallet on Arc,
// or USDC from their own Base wallet to another wallet on Base (for example an
// exchange deposit address).
//
// Send: AWAITING_CODE -> SENDING -> SENT -> COMPLETE
//         |                 |         +--> FAILED (Circle refused it: nothing left the wallet)
//         +--> CANCELLED (code expired, 5 wrong codes, or a new send was started)
//
// Safety:
//   - the user confirms every send with a 6 digit code emailed to them, so a
//     stolen password alone cannot empty a wallet (codes are stored as hashes,
//     expire after 10 minutes, and 5 wrong codes cancel the send)
//   - one open send per user (unique open_key), so a double click cannot send twice
//   - the Circle transfer's idempotency key comes from the send id: a retry after
//     a crash returns the same transfer and can never send twice
//   - limits per send, per token per 24 hours, and sends per day
//   - on one network at a time (Arc, or Base for USDC): never to the user's own
//     wallets, the zero address or a token contract (a common mistake that
//     loses the funds)
//   - an email receipt after every completed send
import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { and, desc, eq, gte, inArray, lt, notInArray, sql } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, ledgerEntries, sends, users, wallets } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { ensureUserWallet, uuidFrom } from "../wallets/service";
import { chainByKey, isOpenChain } from "../bridge/chains";
import { ensureChainWallet } from "../bridge/wallets";

export type SendToken = (typeof SWAP_TOKENS)[number];
export type SendChain = "arc" | "base";
type Send = typeof sends.$inferSelect;

export class SendError extends Error {
  constructor(message: string, public status: 400 | 401 | 402 | 404 | 409 | 429 | 502 | 503 = 400) {
    super(message);
  }
}

const CODE_MINUTES = 10;
const MAX_CODE_ATTEMPTS = 5;
const MAX_STARTS_PER_HOUR = 5;
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];

// Token contracts (testnet and mainnet use the same USDC address on Arc)
const TOKEN_CONTRACTS = [
  "0x3600000000000000000000000000000000000000", // USDC on Arc
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1", // EURC on Arc mainnet
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0", // cirBTC on Arc mainnet
  "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", // USDC on Base
  "0x036cbd53842c5426634e7929541ec2318f3dcf7e", // USDC on Base Sepolia
];

export const SEND_TOKENS: Record<SendToken, { decimals: number; min: number; max: number; daily: number }> = {
  USDC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  EURC: { decimals: 6, min: 0.1, max: env.SEND_MAX_STABLE, daily: env.SEND_DAILY_STABLE },
  cirBTC: { decimals: 8, min: 0.00001, max: env.SEND_MAX_CIRBTC, daily: env.SEND_DAILY_CIRBTC },
};

// The network's name as users know it: Arc, Arc Testnet, Base, Base Sepolia
const network = (chain: string = "arc") => chainByKey(chain).label;

// Arc always; Base only while the bridge is on and Base is open (its Gas Station policy)
function parseChain(value: unknown): SendChain {
  if (value === undefined || value === null || value === "" || value === "arc") return "arc";
  if (value !== "base") throw new SendError("Choose Arc or Base.");
  if (!env.BRIDGE_ENABLED || !isOpenChain("base")) throw new SendError("Sending on Base is not available right now.", 503);
  return "base";
}

// The user's wallet on that network (the Base one is created the first time)
const walletFor = (userId: string, chain: SendChain | string) => (chain === "base" ? ensureChainWallet(userId, "base") : ensureUserWallet(userId));
const isToken = (v: unknown): v is SendToken => typeof v === "string" && (SWAP_TOKENS as readonly string[]).includes(v);
const codeHash = (sendId: string, code: string) => createHmac("sha256", env.BETTER_AUTH_SECRET).update(`send-code:${sendId}:${code}`).digest("hex");
const short = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });
const isTestAccount = (email: string) => /@(example\.com|[^@]*\.local)$/i.test(email);

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

// Token units as an integer (6 or 8 decimals), so sums are exact
function units(token: SendToken, amount: string): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0n;
  const d = SEND_TOKENS[token].decimals;
  return BigInt(m[1]!) * 10n ** BigInt(d) + BigInt((m[2] ?? "").padEnd(d, "0").slice(0, d) || "0");
}
const unitsOf = (token: SendToken, n: number) => units(token, n.toFixed(SEND_TOKENS[token].decimals));
function text(token: SendToken, u: bigint): string {
  const d = BigInt(SEND_TOKENS[token].decimals);
  const whole = u / 10n ** d;
  const frac = (u % 10n ** d).toString().padStart(Number(d), "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : String(whole);
}

function parseAmount(token: SendToken, amount: unknown): string {
  const raw = String(amount ?? "").trim();
  const d = SEND_TOKENS[token].decimals;
  if (!new RegExp(`^\\d+(\\.\\d{1,${d}})?$`).test(raw)) throw new SendError(`Enter an amount of ${token}, with at most ${d} decimals.`);
  const u = units(token, raw);
  if (u < unitsOf(token, SEND_TOKENS[token].min)) throw new SendError(`The minimum is ${SEND_TOKENS[token].min} ${token}.`);
  if (u > unitsOf(token, SEND_TOKENS[token].max)) throw new SendError(`The maximum per send is ${SEND_TOKENS[token].max} ${token}.`);
  return text(token, u);
}

function parseAddress(value: unknown, own: string[]): string {
  const a = String(value ?? "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new SendError("Enter a wallet address: 0x followed by 40 letters and numbers.");
  const lower = a.toLowerCase();
  if (/^0x0{40}$/.test(lower)) throw new SendError("That address cannot receive funds.");
  if (own.some((a) => a.toLowerCase() === lower)) throw new SendError("That is your own dataonchain wallet. Choose another address.");
  if (TOKEN_CONTRACTS.includes(lower)) throw new SendError("That is a token contract, not a wallet. Funds sent there are lost. Check the address.");
  return lower;
}

// The user's Arc balance of one token, with Circle's token id (needed to send it)
async function holding(circleWalletId: string, token: SendToken): Promise<{ tokenId: string | null; units: bigint; amount: string }> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => (t.token?.symbol ?? "").toUpperCase().startsWith(token.toUpperCase()));
  const amount = b?.amount ?? "0";
  return { tokenId: b?.token?.id ?? null, units: units(token, amount), amount };
}

async function audit(action: string, s: Pick<Send, "id" | "userId">, details: unknown) {
  await db.insert(auditLogs).values({ actorType: "user", actorId: s.userId, action, targetType: "send", targetId: s.id, details });
}

// Sent and in progress amounts in the last 24 hours, per token
async function usedToday(userId: string) {
  const rows = await db
    .select({ token: sends.token, amount: sends.amount })
    .from(sends)
    .where(and(eq(sends.userId, userId), gte(sends.createdAt, new Date(Date.now() - 24 * 60 * 60_000)), inArray(sends.status, ["SENDING", "SENT", "COMPLETE"])));
  const used: Record<SendToken, bigint> = { USDC: 0n, EURC: 0n, cirBTC: 0n };
  for (const r of rows) used[r.token] += units(r.token, r.amount);
  return { count: rows.length, used };
}

// Closes codes nobody entered in time (and every waiting code when asked)
async function cancelWaiting(userId: string, all: boolean) {
  await db
    .update(sends)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: all ? "replaced by a new send" : "code expired" })
    .where(and(
      eq(sends.userId, userId),
      eq(sends.status, "AWAITING_CODE"),
      ...(all ? [] : [lt(sends.codeExpiresAt, new Date())]),
    ));
}

// ---------------------------------------------------------------------------
// For the Send page
// ---------------------------------------------------------------------------
export async function sendInfo(userId: string, chainInput?: unknown) {
  const chain = parseChain(chainInput);
  const wallet = await walletFor(userId, chain);
  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const list = res.data?.tokenBalances ?? [];
  const find = (sym: string) => list.find((b) => (b.token?.symbol ?? "").toUpperCase().startsWith(sym.toUpperCase()))?.amount ?? "0";
  const { count, used } = await usedToday(userId);
  return {
    chain,
    network: network(chain),
    baseOpen: env.BRIDGE_ENABLED && isOpenChain("base"),
    tokens: chain === "base" ? (["USDC"] as SendToken[]) : ([...SWAP_TOKENS] as SendToken[]),
    balances: (chain === "base"
      ? { USDC: find("USDC"), EURC: "0", cirBTC: "0" }
      : { USDC: find("USDC"), EURC: find("EURC"), cirBTC: find("CIRBTC") }) as Record<SendToken, string>,
    limits: SEND_TOKENS,
    usedToday: { USDC: text("USDC", used.USDC), EURC: text("EURC", used.EURC), cirBTC: text("cirBTC", used.cirBTC) },
    sendsLeftToday: Math.max(0, env.SEND_DAILY_COUNT - count),
  };
}

// Step 1: checks everything, saves the send and emails the code
export async function startSend(
  user: { id: string; email: string; name: string },
  body: { token?: unknown; amount?: unknown; toAddress?: unknown; confirmNetwork?: unknown; chain?: unknown },
) {
  const chain = parseChain(body.chain);
  if (!isToken(body.token)) throw new SendError("Choose USDC, EURC or cirBTC.");
  const token = body.token;
  if (chain === "base" && token !== "USDC") throw new SendError("Only USDC can be sent on Base.");
  const amount = parseAmount(token, body.amount);
  const wallet = await walletFor(user.id, chain);
  const own = (await db.select({ address: wallets.address }).from(wallets).where(eq(wallets.userId, user.id))).map((w) => w.address);
  const toAddress = parseAddress(body.toAddress, [wallet.address, ...own]);
  if (body.confirmNetwork !== true) throw new SendError(`Confirm that the address is a wallet on ${network(chain)}.`);

  const [open] = await db.select({ id: sends.id }).from(sends).where(and(eq(sends.userId, user.id), inArray(sends.status, ["SENDING", "SENT"]))).limit(1);
  if (open) throw new SendError("You already have a send in progress. Please wait for it to finish.", 409);

  const recent = await db.select({ id: sends.id }).from(sends).where(and(eq(sends.userId, user.id), gte(sends.createdAt, new Date(Date.now() - 60 * 60_000))));
  if (recent.length >= MAX_STARTS_PER_HOUR) throw new SendError("Too many attempts. Please wait an hour and try again.", 429);

  const { count, used } = await usedToday(user.id);
  if (count >= env.SEND_DAILY_COUNT) throw new SendError(`The limit is ${env.SEND_DAILY_COUNT} sends per day.`, 409);
  const want = units(token, amount);
  const daily = unitsOf(token, SEND_TOKENS[token].daily);
  if (used[token] + want > daily) {
    throw new SendError(`The daily limit is ${SEND_TOKENS[token].daily} ${token}. You can send ${text(token, daily > used[token] ? daily - used[token] : 0n)} more today.`, 409);
  }

  const have = await holding(wallet.circleWalletId, token);
  if (have.units < want) throw new SendError(`Not enough ${token}. You have ${have.amount} ${token}.`, 402);

  await cancelWaiting(user.id, true);
  const id = randomUUID();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  try {
    await db.insert(sends).values({
      id,
      userId: user.id,
      walletAddress: wallet.address.toLowerCase(),
      chain,
      token,
      amount,
      toAddress,
      status: "AWAITING_CODE",
      codeHash: codeHash(id, code),
      codeExpiresAt: new Date(Date.now() + CODE_MINUTES * 60_000),
      openKey: user.id,
    });
  } catch {
    throw new SendError("You already have a send in progress. Please wait for it to finish.", 409);
  }

  try {
    const message = noticeEmail({
      brand: "dataonchain",
      subject: `Your code to send ${amount} ${token}`,
      lines: [
        `Hello ${user.name.split(" ")[0]},`,
        `You asked to send ${amount} ${token} from your dataonchain wallet to ${toAddress} on ${network(chain)}.`,
        "Enter this code on the Send page to confirm:",
      ],
      code,
      footer: `The code expires in ${CODE_MINUTES} minutes. Never share it with anyone, including people who say they work for dataonchain. If you did not ask for this, do not enter the code, change your password now and contact us on WhatsApp.`,
    });
    await sendEmail({ to: user.email, ...message });
  } catch (err) {
    console.error("[send] could not email the code:", err instanceof Error ? err.message : err);
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code email failed" }).where(eq(sends.id, id));
    throw new SendError("Could not email your code. Please try again in a moment.", 502);
  }
  await audit("send.started", { id, userId: user.id }, { chain, token, amount, toAddress });
  return getSendView(user.id, id);
}

// Step 2: the code. Sends through Circle, then waits a few seconds for the result.
export async function confirmSend(userId: string, id: string, codeInput: unknown) {
  const [s] = await db.select().from(sends).where(and(eq(sends.id, id), eq(sends.userId, userId))).limit(1);
  if (!s) throw new SendError("Send not found.", 404);
  if (s.status !== "AWAITING_CODE" || !s.codeHash) throw new SendError("This send is no longer waiting for a code. Start a new one.", 409);
  if (!s.codeExpiresAt || s.codeExpiresAt.getTime() < Date.now()) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
    throw new SendError("The code expired. Nothing was sent. Please start again.", 409);
  }
  // Every try is counted in the database first, in one step, so many tries sent
  // at the same moment cannot get past the limit of 5
  const [tried] = await db
    .update(sends)
    .set({ codeAttempts: sql`${sends.codeAttempts} + 1` })
    .where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE"), lt(sends.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning();
  if (!tried) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "too many wrong codes" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
    throw new SendError("Too many wrong codes. Nothing was sent. Please start again.", 401);
  }
  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(s.id, code), s.codeHash)) {
    if (tried.codeAttempts >= MAX_CODE_ATTEMPTS) {
      await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "too many wrong codes" }).where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")));
      await audit("send.code_failed", s, { attempts: tried.codeAttempts });
      throw new SendError("Too many wrong codes. Nothing was sent. Please start again.", 401);
    }
    throw new SendError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.codeAttempts} tries left.`, 401);
  }

  // The balance may have changed since the code was sent
  const wallet = await walletFor(userId, s.chain);
  const have = await holding(wallet.circleWalletId, s.token);
  if (!have.tokenId || have.units < units(s.token, s.amount)) {
    await db.update(sends).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "not enough balance at confirmation" }).where(eq(sends.id, s.id));
    throw new SendError(`Not enough ${s.token} any more. You have ${have.amount} ${s.token}. Nothing was sent.`, 402);
  }
  const [claimed] = await db
    .update(sends)
    .set({ status: "SENDING", codeHash: null })
    .where(and(eq(sends.id, s.id), eq(sends.status, "AWAITING_CODE")))
    .returning();
  if (!claimed) throw new SendError("This send is already being processed.", 409);
  await audit("send.confirmed", s, { token: s.token, amount: s.amount, toAddress: s.toAddress });

  await submit(claimed, wallet.circleWalletId, have.tokenId);
  // Arc is fast: most sends finish within a few seconds
  for (let i = 0; i < 6; i++) {
    const [now] = await db.select().from(sends).where(eq(sends.id, s.id)).limit(1);
    if (!now || now.status !== "SENT") break;
    await new Promise((r) => setTimeout(r, 2_000));
    await checkSent(now);
  }
  return getSendView(userId, s.id);
}

// Asks Circle to send. The same idempotency key every time, so it can only happen once.
async function submit(s: Send, circleWalletId: string, tokenId: string) {
  const input = {
    walletId: circleWalletId,
    tokenId,
    destinationAddress: s.toAddress,
    amount: [s.amount],
    amounts: [s.amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`send:${s.id}`),
    refId: `send-${s.id}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const txId = res.data?.id;
    if (!txId) throw new Error("Circle did not return a transaction id");
    await db.update(sends).set({ status: "SENT", circleTransactionId: txId }).where(and(eq(sends.id, s.id), eq(sends.status, "SENDING")));
  } catch (err) {
    const status = (err as { response?: { status?: number } }).response?.status;
    const detail = JSON.stringify((err as { response?: { data?: unknown } }).response?.data ?? "").slice(0, 300);
    const message = `${err instanceof Error ? err.message : String(err)} ${detail}`.trim().slice(0, 500);
    if (status && status >= 400 && status < 500) {
      // Circle refused it: nothing was sent
      await db.update(sends).set({ status: "FAILED", openKey: null, error: message }).where(and(eq(sends.id, s.id), eq(sends.status, "SENDING")));
      await audit("send.failed", s, { error: message });
      console.error(`[send] ${s.id} refused by Circle: ${message}`);
      return;
    }
    // Unclear (network): stays SENDING, the worker asks again with the same key
    console.error(`[send] ${s.id} will retry: ${message}`);
  }
}

async function checkSent(s: Send) {
  if (!s.circleTransactionId) return;
  const res = await circle.getTransaction({ id: s.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string; errorDetails?: string } | undefined;
  if (tx?.state === "COMPLETE") {
    const [done] = await db
      .update(sends)
      .set({ status: "COMPLETE", txHash: tx.txHash ?? null, openKey: null })
      .where(and(eq(sends.id, s.id), eq(sends.status, "SENT")))
      .returning();
    if (done) await finished(done);
  } else if (tx?.state && FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}${tx.errorDetails ? ` (${tx.errorDetails})` : ""}`.slice(0, 500);
    const [failed] = await db
      .update(sends)
      .set({ status: "FAILED", openKey: null, error: reason, txHash: tx.txHash ?? null })
      .where(and(eq(sends.id, s.id), eq(sends.status, "SENT")))
      .returning();
    if (failed) {
      await audit("send.failed", s, { error: reason });
      console.error(`[send] ${s.id} FAILED: ${reason}`);
    }
  }
}

async function finished(s: Send) {
  if (s.token === "USDC") {
    const micro = Number(units("USDC", s.amount));
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      { journalId, account: `customer:${s.userId}`, currency: "USDC", debit: micro, memo: `Send ${s.id} to ${s.toAddress}` },
      { journalId, account: "external:send", currency: "USDC", credit: micro, memo: `Send ${s.id} tx ${s.txHash ?? ""}` },
    ]);
  }
  await audit("send.complete", s, { token: s.token, amount: s.amount, toAddress: s.toAddress, txHash: s.txHash });
  // A receipt, so the owner notices any send they did not make
  try {
    const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, s.userId)).limit(1);
    if (!user || isTestAccount(user.email)) return;
    const message = noticeEmail({
      brand: "dataonchain",
      subject: `You sent ${s.amount} ${s.token}`,
      lines: [
        `Hello ${user.name.split(" ")[0]},`,
        `${s.amount} ${s.token} left your dataonchain wallet on ${lagos(new Date())}.`,
        `To: ${s.toAddress} (${network(s.chain)})`,
      ],
      button: s.txHash ? { label: "View the transaction", url: `${chainByKey(s.chain).explorerTx}${s.txHash}` } : undefined,
      footer: "If this was not you, change your password now and contact us on WhatsApp.",
    });
    await sendEmail({ to: user.email, ...message });
  } catch (err) {
    console.error(`[send] ${s.id} receipt email failed:`, err instanceof Error ? err.message : err);
  }
}

// For the worker: expired codes, sends waiting for Circle, and retries
export async function advanceSends(): Promise<void> {
  await db
    .update(sends)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" })
    .where(and(eq(sends.status, "AWAITING_CODE"), lt(sends.codeExpiresAt, new Date())));

  const open = await db.select().from(sends).where(inArray(sends.status, ["SENDING", "SENT"])).limit(20);
  for (const s of open) {
    try {
      if (s.status === "SENT") {
        await checkSent(s);
      } else if (Date.now() - s.updatedAt.getTime() > 60_000) {
        const wallet = await walletFor(s.userId, s.chain);
        const have = await holding(wallet.circleWalletId, s.token);
        if (have.tokenId) await submit(s, wallet.circleWalletId, have.tokenId);
      }
    } catch (err) {
      console.error(`[send] ${s.id}:`, err instanceof Error ? err.message : err);
    }
  }
}

// For the daily report
export async function sendSummary(since: Date) {
  const rows = await db.select().from(sends).where(and(gte(sends.createdAt, since), notInArray(sends.status, ["AWAITING_CODE", "CANCELLED"])));
  const stuck = await db.select().from(sends).where(and(inArray(sends.status, ["SENDING", "SENT"]), lt(sends.updatedAt, new Date(Date.now() - 30 * 60_000))));
  return {
    complete: rows.filter((r) => r.status === "COMPLETE").length,
    failed: rows.filter((r) => r.status === "FAILED").length,
    stuck: stuck.map((s) => `${s.id} ${s.amount} ${s.token} to ${s.toAddress} (${s.status})`),
  };
}

export async function getSendView(userId: string, id: string) {
  const [s] = await db.select().from(sends).where(and(eq(sends.id, id), eq(sends.userId, userId))).limit(1);
  if (!s) return null;
  const [user] = await db.select({ email: users.email }).from(users).where(eq(users.id, userId)).limit(1);
  return sendView(s, user ? user.email.replace(/^(.{2}).*(@.*)$/, "$1***$2") : "your email");
}

function sendView(s: typeof sends.$inferSelect, masked: string) {
  return {
    id: s.id,
    status: s.status,
    token: s.token,
    amount: s.amount,
    toAddress: s.toAddress,
    toShort: short(s.toAddress),
    chain: s.chain,
    network: network(s.chain),
    codeSentTo: s.status === "AWAITING_CODE" ? masked : null,
    codeExpiresAt: s.status === "AWAITING_CODE" ? (s.codeExpiresAt?.toISOString() ?? null) : null,
    // A short, safe reason for the user (the full one is kept for the admin)
    failure:
      s.status === "FAILED"
        ? /PAYMASTER_POLICY|policy/i.test(s.error ?? "")
          ? "Sending is busy right now. Nothing was sent. Please try again later."
          : "The send did not go through. Nothing was sent. Please try again, or contact us on WhatsApp."
        : null,
    txHash: s.txHash,
    explorerUrl: s.txHash ? `${chainByKey(s.chain).explorerTx}${s.txHash}` : null,
    createdAt: s.createdAt.toISOString(),
  };
}

// Newest first, in one query (the history page asks for up to 100)
export async function listSends(userId: string, limit = 20) {
  await cancelWaiting(userId, false);
  const rows = await db
    .select()
    .from(sends)
    .where(and(eq(sends.userId, userId), notInArray(sends.status, ["AWAITING_CODE", "CANCELLED"])))
    .orderBy(desc(sends.createdAt))
    .limit(limit);
  return rows.map((s) => sendView(s, "your email"));
}
