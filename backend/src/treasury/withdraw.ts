// Treasury withdrawals: the admin takes fees out of the treasury for running costs.
//
// Safety:
//   - money only ever goes to TREASURY_PAYOUT_ADDRESS (on Arc), set on Render.
//     It cannot be typed or changed in the dashboard, so someone who got into
//     the admin login still could not send the money anywhere else
//   - every withdrawal is confirmed with a code emailed to the admin (5 tries,
//     10 minutes), counted in the database so a burst of guesses cannot get past it
//   - USDC never goes below the reserve: TREASURY_RESERVE_USDC plus every open
//     order that may still need a refund, plus a little for gas
//   - one withdrawal at a time; each one is logged and emailed
import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import { and, desc, eq, inArray, lt, sql } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { SWAP_TOKENS, auditLogs, ledgerEntries, orders, treasuryWithdrawals } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";
import { uuidFrom } from "../wallets/service";

type Token = (typeof SWAP_TOKENS)[number];
type Withdrawal = typeof treasuryWithdrawals.$inferSelect;

export class WithdrawError extends Error {
  constructor(message: string, public status: 400 | 401 | 404 | 409 | 502 | 503 = 400) {
    super(message);
  }
}

const CODE_MINUTES = 10;
const MAX_CODE_ATTEMPTS = 5;
const GAS_MICRO = 50_000n; // 0.05 USDC kept for the network fee (the treasury pays gas in USDC)
const DECIMALS: Record<Token, number> = { USDC: 6, EURC: 6, cirBTC: 8 };
const FAILED_STATES = ["FAILED", "DENIED", "CANCELLED"];
// Orders whose payment sits in the treasury and may still be refunded
const OWED_STATUSES = ["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING", "FLAGGED"] as const;
const TOKEN_CONTRACTS = [
  "0x3600000000000000000000000000000000000000",
  "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1",
  "0x171a4217b86a807a64eb94757db6849fb4bdbaa0",
];

const isToken = (v: unknown): v is Token => typeof v === "string" && (SWAP_TOKENS as readonly string[]).includes(v);
const codeHash = (id: string, code: string) => createHmac("sha256", env.BETTER_AUTH_SECRET).update(`withdraw-code:${id}:${code}`).digest("hex");
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

function units(token: Token, amount: string): bigint {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) return 0n;
  const d = DECIMALS[token];
  return BigInt(m[1]!) * 10n ** BigInt(d) + BigInt((m[2] ?? "").padEnd(d, "0").slice(0, d) || "0");
}

function text(token: Token, u: bigint): string {
  if (u < 0n) u = 0n;
  const d = BigInt(DECIMALS[token]);
  const whole = u / 10n ** d;
  const frac = (u % 10n ** d).toString().padStart(Number(d), "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : String(whole);
}

// The payout address, or null with the reason it is not usable
export function payout(): { address: string | null; problem: string | null } {
  const a = env.TREASURY_PAYOUT_ADDRESS;
  if (!a) return { address: null, problem: "Withdrawals are off: TREASURY_PAYOUT_ADDRESS is not set on Render." };
  if (!/^0x[0-9a-f]{40}$/.test(a) || /^0x0{40}$/.test(a)) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS on Render is not a valid wallet address." };
  if (a === env.TREASURY_ADDRESS.toLowerCase()) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS is the treasury itself. Set your own wallet." };
  if (TOKEN_CONTRACTS.includes(a)) return { address: null, problem: "TREASURY_PAYOUT_ADDRESS is a token contract, not a wallet." };
  return { address: a, problem: null };
}

// Treasury balances with Circle's token ids (needed to send)
async function holdings(): Promise<Record<Token, { tokenId: string | null; units: bigint }>> {
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const list = res.data?.tokenBalances ?? [];
  const pick = (t: Token) => {
    const b = list.find((x) => (x.token?.symbol ?? "").toUpperCase().startsWith(t.toUpperCase()));
    return { tokenId: b?.token?.id ?? null, units: units(t, b?.amount ?? "0") };
  };
  return { USDC: pick("USDC"), EURC: pick("EURC"), cirBTC: pick("cirBTC") };
}

// USDC that must stay: the reserve plus open orders that may need a refund,
// including failed orders that were paid and whose refund has not gone out yet
async function heldBackMicro(): Promise<{ reserve: bigint; owed: bigint }> {
  const [open] = await db
    .select({ micro: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number) })
    .from(orders)
    .where(inArray(orders.status, [...OWED_STATUSES]));
  const [failed] = await db
    .select({ micro: sql<number>`coalesce(sum(${orders.usdcAmountMicro}), 0)`.mapWith(Number) })
    .from(orders)
    .where(
      and(
        eq(orders.status, "FAILED"),
        // Written out in full so each column clearly belongs to its own table
        sql`exists (select 1 from "payments" "p" where "p"."order_id" = "orders"."id" and "p"."status" = 'CONFIRMED')`,
        sql`not exists (select 1 from "refunds" "r" where "r"."order_id" = "orders"."id" and "r"."status" = 'CONFIRMED')`,
      ),
    );
  return {
    reserve: units("USDC", env.TREASURY_RESERVE_USDC.toFixed(6)),
    owed: BigInt(open?.micro ?? 0) + BigInt(failed?.micro ?? 0),
  };
}

async function available() {
  const [have, held] = await Promise.all([holdings(), heldBackMicro()]);
  const usdcFree = have.USDC.units - held.reserve - held.owed - GAS_MICRO;
  const canPayGas = have.USDC.units >= GAS_MICRO;
  return {
    have,
    held,
    free: {
      USDC: usdcFree > 0n ? usdcFree : 0n,
      EURC: canPayGas ? have.EURC.units : 0n,
      cirBTC: canPayGas ? have.cirBTC.units : 0n,
    } as Record<Token, bigint>,
  };
}

async function audit(action: string, w: Pick<Withdrawal, "id" | "adminId">, details: Record<string, unknown>) {
  await db.insert(auditLogs).values({ actorType: "admin", actorId: w.adminId, action, targetType: "withdrawal", targetId: w.id, details });
}

async function emailAdmin(subject: string, lines: string[], extra: { code?: string; footer?: string; button?: { label: string; url: string } } = {}) {
  if (!env.ADMIN_EMAIL) throw new WithdrawError("ADMIN_EMAIL is not set on the server.", 503);
  await sendEmail({ to: env.ADMIN_EMAIL, ...noticeEmail({ subject, lines, ...extra }) });
}

function view(w: Withdrawal) {
  return {
    id: w.id,
    status: w.status,
    token: w.token,
    amount: w.amount,
    toAddress: w.toAddress,
    txUrl: w.txHash ? `${env.EXPLORER_TX_URL}${w.txHash}` : null,
    error: w.error,
    codeExpiresAt: w.status === "AWAITING_CODE" ? (w.codeExpiresAt?.toISOString() ?? null) : null,
    createdAt: w.createdAt.toISOString(),
  };
}

// ---------------------------------------------------------------------------
// The Treasury page
// ---------------------------------------------------------------------------
export async function treasuryView() {
  const p = payout();
  const recent = await db.select().from(treasuryWithdrawals).orderBy(desc(treasuryWithdrawals.createdAt)).limit(20);
  let balances: Record<Token, string> | null = null;
  let free: Record<Token, string> | null = null;
  let held: { reserve: string; owed: string } | null = null;
  let balanceError: string | null = null;
  try {
    const a = await available();
    balances = { USDC: text("USDC", a.have.USDC.units), EURC: text("EURC", a.have.EURC.units), cirBTC: text("cirBTC", a.have.cirBTC.units) };
    free = { USDC: text("USDC", a.free.USDC), EURC: text("EURC", a.free.EURC), cirBTC: text("cirBTC", a.free.cirBTC) };
    held = { reserve: text("USDC", a.held.reserve), owed: text("USDC", a.held.owed) };
  } catch (err) {
    balanceError = `Could not read the treasury from Circle: ${err instanceof Error ? err.message : String(err)}`.slice(0, 300);
  }
  return {
    treasuryAddress: env.TREASURY_ADDRESS,
    payoutAddress: p.address,
    payoutProblem: p.problem,
    payoutUrl: p.address ? `${env.EXPLORER_TX_URL.replace(/\/tx\/?$/, "/address/")}${p.address}` : null,
    reserveUsdc: env.TREASURY_RESERVE_USDC,
    balances,
    available: free,
    heldBack: held,
    balanceError,
    withdrawals: recent.map(view),
  };
}

// ---------------------------------------------------------------------------
// Step 1: checks the amount and emails the code to the admin
// ---------------------------------------------------------------------------
export async function startWithdraw(adminId: string | null, body: { token?: unknown; amount?: unknown }) {
  const p = payout();
  if (!p.address) throw new WithdrawError(p.problem ?? "Withdrawals are off.", 503);
  if (!isToken(body.token)) throw new WithdrawError("Choose USDC, EURC or cirBTC.");
  const token = body.token;
  const raw = String(body.amount ?? "").trim();
  const d = DECIMALS[token];
  if (!new RegExp(`^\\d+(\\.\\d{1,${d}})?$`).test(raw)) throw new WithdrawError(`Enter an amount of ${token}, with at most ${d} decimals.`);
  const want = units(token, raw);
  if (want <= 0n) throw new WithdrawError("Enter an amount above zero.");
  const amount = text(token, want);

  const a = await available();
  if (want > a.free[token]) {
    throw new WithdrawError(
      token === "USDC"
        ? `You can withdraw up to ${text("USDC", a.free.USDC)} USDC. The rest stays for refunds (reserve ${text("USDC", a.held.reserve)} plus ${text("USDC", a.held.owed)} for open orders) and gas.`
        : `You can withdraw up to ${text(token, a.free[token])} ${token}.${a.have.USDC.units < GAS_MICRO ? " The treasury needs at least 0.05 USDC to pay the network fee." : ""}`,
      409,
    );
  }

  // A new request replaces one still waiting for its code
  await db
    .update(treasuryWithdrawals)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "replaced by a new request" })
    .where(eq(treasuryWithdrawals.status, "AWAITING_CODE"));

  const id = randomUUID();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  try {
    await db.insert(treasuryWithdrawals).values({
      id,
      adminId,
      token,
      amount,
      toAddress: p.address,
      status: "AWAITING_CODE",
      codeHash: codeHash(id, code),
      codeExpiresAt: new Date(Date.now() + CODE_MINUTES * 60_000),
      openKey: "treasury",
    });
  } catch {
    throw new WithdrawError("A withdrawal is already in progress. Wait for it to finish.", 409);
  }
  try {
    await emailAdmin(
      `Your code to withdraw ${amount} ${token} from the treasury`,
      [`You asked to withdraw ${amount} ${token} from the dataonchain treasury to ${p.address} on Arc.`, "Enter this code on the Treasury page to confirm:"],
      { code, footer: `The code expires in ${CODE_MINUTES} minutes. If you did not ask for this, do not enter it and change your admin password now.` },
    );
  } catch (err) {
    console.error("[withdraw] could not email the code:", err instanceof Error ? err.message : err);
    await db.update(treasuryWithdrawals).set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code email failed" }).where(eq(treasuryWithdrawals.id, id));
    throw new WithdrawError("Could not email the code. Please try again in a moment.", 502);
  }
  await audit("treasury.withdraw_started", { id, adminId }, { token, amount, toAddress: p.address });
  const [row] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, id)).limit(1);
  return view(row!);
}

// ---------------------------------------------------------------------------
// Step 2: the code. Sends through Circle, then waits a few seconds for the result.
// ---------------------------------------------------------------------------
export async function confirmWithdraw(id: string, codeInput: unknown) {
  const [w] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, id)).limit(1);
  if (!w) throw new WithdrawError("Withdrawal not found.", 404);
  const cancel = (error: string) =>
    db
      .update(treasuryWithdrawals)
      .set({ status: "CANCELLED", codeHash: null, openKey: null, error })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE")));
  if (w.status !== "AWAITING_CODE" || !w.codeHash) throw new WithdrawError("This withdrawal is no longer waiting for a code. Start a new one.", 409);
  if (!w.codeExpiresAt || w.codeExpiresAt.getTime() < Date.now()) {
    await cancel("code expired");
    throw new WithdrawError("The code expired. Nothing was sent. Please start again.", 409);
  }
  // Every try is counted first, in one step, so a burst of guesses cannot get past 5
  const [tried] = await db
    .update(treasuryWithdrawals)
    .set({ codeAttempts: sql`${treasuryWithdrawals.codeAttempts} + 1` })
    .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE"), lt(treasuryWithdrawals.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning();
  if (!tried) {
    await cancel("too many wrong codes");
    throw new WithdrawError("Too many wrong codes. Nothing was sent. Please start again.", 401);
  }
  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(w.id, code), w.codeHash)) {
    if (tried.codeAttempts >= MAX_CODE_ATTEMPTS) {
      await cancel("too many wrong codes");
      await audit("treasury.withdraw_code_failed", w, { attempts: tried.codeAttempts });
      throw new WithdrawError("Too many wrong codes. Nothing was sent. Please start again.", 401);
    }
    throw new WithdrawError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.codeAttempts} tries left.`, 401);
  }

  // The payout address must still be the one on Render, and the money still free
  const p = payout();
  if (!p.address || p.address !== w.toAddress) {
    await cancel("payout address changed");
    throw new WithdrawError("The payout address changed since you started. Nothing was sent. Please start again.", 409);
  }
  const a = await available();
  const tokenId = a.have[w.token].tokenId;
  if (!tokenId || units(w.token, w.amount) > a.free[w.token]) {
    await cancel("not enough free balance at confirmation");
    throw new WithdrawError(`Only ${text(w.token, a.free[w.token])} ${w.token} can be withdrawn now. Nothing was sent.`, 409);
  }
  const [claimed] = await db
    .update(treasuryWithdrawals)
    .set({ status: "SENDING", codeHash: null })
    .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "AWAITING_CODE")))
    .returning();
  if (!claimed) throw new WithdrawError("This withdrawal is already being processed.", 409);
  await audit("treasury.withdraw_confirmed", w, { token: w.token, amount: w.amount, toAddress: w.toAddress });

  await submit(claimed, tokenId);
  for (let i = 0; i < 6; i++) {
    const [now] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, w.id)).limit(1);
    if (!now || now.status !== "SENT") break;
    await new Promise((r) => setTimeout(r, 2_000));
    await check(now);
  }
  const [done] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, w.id)).limit(1);
  return view(done!);
}

// Asks Circle to send. The same idempotency key every time, so it happens once.
async function submit(w: Withdrawal, tokenId: string) {
  const input = {
    walletId: env.TREASURY_WALLET_ID,
    tokenId,
    destinationAddress: w.toAddress,
    amount: [w.amount],
    amounts: [w.amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`treasury-withdraw:${w.id}`),
    refId: `withdraw-${w.id}`,
  };
  try {
    const res = await circle.createTransaction(input as unknown as Parameters<typeof circle.createTransaction>[0]);
    const txId = res.data?.id;
    if (!txId) throw new Error("Circle did not return a transaction id");
    await db
      .update(treasuryWithdrawals)
      .set({ status: "SENT", circleTransactionId: txId })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENDING")));
  } catch (err) {
    const status = (err as { response?: { status?: number } }).response?.status;
    const detail = JSON.stringify((err as { response?: { data?: unknown } }).response?.data ?? "").slice(0, 300);
    const message = `${err instanceof Error ? err.message : String(err)} ${detail}`.trim().slice(0, 500);
    if (status && status >= 400 && status < 500) {
      await db
        .update(treasuryWithdrawals)
        .set({ status: "FAILED", openKey: null, error: message })
        .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENDING")));
      await audit("treasury.withdraw_failed", w, { error: message });
      console.error(`[withdraw] ${w.id} refused by Circle: ${message}`);
      return;
    }
    // Unclear (network): stays SENDING, the worker asks again with the same key
    console.error(`[withdraw] ${w.id} will retry: ${message}`);
  }
}

async function check(w: Withdrawal) {
  if (!w.circleTransactionId) return;
  const res = await circle.getTransaction({ id: w.circleTransactionId });
  const tx = res.data?.transaction as unknown as { state?: string; txHash?: string; errorReason?: string } | undefined;
  if (tx?.state === "COMPLETE") {
    const [done] = await db
      .update(treasuryWithdrawals)
      .set({ status: "COMPLETE", txHash: tx.txHash ?? null, openKey: null })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENT")))
      .returning();
    if (done) await finished(done);
  } else if (tx?.state && FAILED_STATES.includes(tx.state)) {
    const reason = `${tx.state}${tx.errorReason ? `: ${tx.errorReason}` : ""}`.slice(0, 500);
    const [failed] = await db
      .update(treasuryWithdrawals)
      .set({ status: "FAILED", openKey: null, error: reason, txHash: tx.txHash ?? null })
      .where(and(eq(treasuryWithdrawals.id, w.id), eq(treasuryWithdrawals.status, "SENT")))
      .returning();
    if (failed) {
      await audit("treasury.withdraw_failed", w, { error: reason });
      console.error(`[withdraw] ${w.id} FAILED: ${reason}`);
    }
  }
}

async function finished(w: Withdrawal) {
  if (w.token === "USDC") {
    const micro = Number(units("USDC", w.amount));
    const journalId = randomUUID();
    await db.insert(ledgerEntries).values([
      { journalId, account: "owner:withdrawals", currency: "USDC", debit: micro, memo: `Treasury withdrawal ${w.id}` },
      { journalId, account: "treasury:usdc", currency: "USDC", credit: micro, memo: `Treasury withdrawal ${w.id} tx ${w.txHash ?? ""}` },
    ]);
  }
  await audit("treasury.withdraw_complete", w, { token: w.token, amount: w.amount, toAddress: w.toAddress, txHash: w.txHash });
  try {
    await emailAdmin(
      `Treasury withdrawal sent: ${w.amount} ${w.token}`,
      [`${w.amount} ${w.token} left the dataonchain treasury on ${lagos(new Date())}.`, `To: ${w.toAddress} (Arc)`],
      {
        button: w.txHash ? { label: "View the transaction", url: `${env.EXPLORER_TX_URL}${w.txHash}` } : undefined,
        footer: "If this was not you, change your admin password now and remove TREASURY_PAYOUT_ADDRESS on Render.",
      },
    );
  } catch (err) {
    console.error(`[withdraw] ${w.id} receipt email failed:`, err instanceof Error ? err.message : err);
  }
}

// For the worker: expired codes, withdrawals waiting for Circle, and retries
export async function advanceWithdrawals(): Promise<void> {
  await db
    .update(treasuryWithdrawals)
    .set({ status: "CANCELLED", codeHash: null, openKey: null, error: "code expired" })
    .where(and(eq(treasuryWithdrawals.status, "AWAITING_CODE"), lt(treasuryWithdrawals.codeExpiresAt, new Date())));
  const open = await db.select().from(treasuryWithdrawals).where(inArray(treasuryWithdrawals.status, ["SENDING", "SENT"])).limit(5);
  for (const w of open) {
    try {
      if (w.status === "SENT") {
        await check(w);
      } else if (Date.now() - w.updatedAt.getTime() > 60_000) {
        const have = await holdings();
        const tokenId = have[w.token].tokenId;
        if (tokenId) await submit(w, tokenId);
      }
    } catch (err) {
      console.error(`[withdraw] ${w.id}:`, err instanceof Error ? err.message : err);
    }
  }
}
