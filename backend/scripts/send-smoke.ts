// Sends to other wallets, on testnet and the development database:
//   - wrong addresses, amounts and a missing network check are refused
//   - a real 0.2 USDC send to the treasury, confirmed with the emailed code
//     (a wrong code first), arrives with a transaction hash
//   - a new send replaces one still waiting for its code
//   - the admin can still send while sending is paused (nobody else can)
// Exit code 3 means the testnet treasury needs more test USDC.
// Run with: EMAIL_OUTBOX_FILE=/tmp/x PAUSE_BYPASS_EMAILS=tester@example.com npx tsx scripts/send-smoke.ts
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { appSettings, auditLogs, ledgerEntries, sends, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { SendError, advanceSends, confirmSend, getSendView, startSend } from "../src/send/service";
import { getPauses, pausedMessage, setPause } from "../src/settings";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND = "0.5";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function refused(label: string, fn: () => Promise<unknown>) {
  try {
    await fn();
    check(false, label);
  } catch (err) {
    check(err instanceof SendError, label, err instanceof Error ? err.message : err);
  }
}

// The code in the last email to this address (the outbox file the test server writes)
function lastCode(email: string): string {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox) throw new Error("Set EMAIL_OUTBOX_FILE");
  const mails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; text: string });
  const mine = mails.filter((m) => m.to === email);
  const code = /\n(\d{6})\n/.exec(mine[mine.length - 1]?.text ?? "")?.[1];
  if (!code) throw new Error("No code email found");
  return code;
}

async function usdcOf(walletId: string): Promise<number> {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return b ? Number(b.amount) : 0;
}

async function main() {
  const treasury = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (treasury.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  if (!t?.token?.id || Number(t.amount) < Number(FUND) + 0.1) {
    console.log(`NEEDS_FUNDING: treasury has ${t?.amount ?? 0} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  const email = `sendsmoke+${Date.now()}@example.com`;
  const user = { id: userId, email, name: "Send Smoke" };
  await db.insert(users).values({ id: userId, name: user.name, email, emailVerified: true, phone: "+2348011111111" });
  try {
    const wallet = await ensureUserWallet(userId);
    console.log(`Funding the test wallet with ${FUND} USDC from the treasury...`);
    const fund = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: t.token.id,
      destinationAddress: wallet.address,
      amount: [FUND],
      amounts: [FUND],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`send-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: fund.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    for (let i = 0; i < 20 && (await usdcOf(wallet.circleWalletId)) < Number(FUND); i++) await sleep(3_000);
    const before = await usdcOf(wallet.circleWalletId);
    check(before >= Number(FUND), `test wallet funded (${before} USDC)`);

    const ok = { token: "USDC", amount: "0.2", toAddress: env.TREASURY_ADDRESS, confirmNetwork: true };
    await refused("a bad address is refused", () => startSend(user, { ...ok, toAddress: "0x1234" }));
    await refused("their own wallet is refused", () => startSend(user, { ...ok, toAddress: wallet.address }));
    await refused("the USDC token contract is refused", () => startSend(user, { ...ok, toAddress: "0x3600000000000000000000000000000000000000" }));
    await refused("the network must be confirmed", () => startSend(user, { ...ok, confirmNetwork: false }));
    await refused("more than the per send limit is refused", () => startSend(user, { ...ok, amount: String(env.SEND_MAX_STABLE + 1) }));
    await refused("more than the balance is refused", () => startSend(user, { ...ok, amount: "5" }));

    // A new send replaces one still waiting for its code
    const first = await startSend(user, ok);
    const second = await startSend(user, ok);
    const [old] = await db.select().from(sends).where(eq(sends.id, first!.id));
    check(old?.status === "CANCELLED" && second?.status === "AWAITING_CODE", "a new send replaces the one waiting for its code");
    check(second?.codeSentTo?.includes("***") === true, "the page shows where the code went (hidden)", second?.codeSentTo);

    const code = lastCode(email);
    const wrong = code === "000000" ? "111111" : "000000";
    try {
      await confirmSend(userId, second!.id, wrong);
      check(false, "a wrong code is refused");
    } catch (err) {
      check(err instanceof SendError && err.status === 401 && /tries left/.test(err.message), "a wrong code is refused");
    }
    let view = await confirmSend(userId, second!.id, code);
    for (let i = 0; i < 30 && view && ["SENDING", "SENT"].includes(view.status); i++) {
      await sleep(3_000);
      await advanceSends();
      view = await getSendView(userId, second!.id);
    }
    check(view?.status === "COMPLETE" && Boolean(view.explorerUrl), `0.2 USDC sent (${view?.explorerUrl})`, view);
    await refused("the same code cannot be used twice", () => confirmSend(userId, second!.id, code));

    let after = await usdcOf(wallet.circleWalletId);
    for (let i = 0; i < 20 && after > before - 0.2; i++) {
      await sleep(3_000);
      after = await usdcOf(wallet.circleWalletId);
    }
    check(Math.abs(before - 0.2 - after) < 0.000001, `the wallet went down by exactly 0.2 USDC (${before} -> ${after})`);

    // Paused: only the admin (PAUSE_BYPASS_EMAILS) can still send
    if (env.PAUSE_BYPASS_EMAILS.includes("tester@example.com")) {
      const was = (await getPauses()).sendPaused;
      try {
        await setPause("sendPaused", true);
        check((await pausedMessage("sendPaused", "tester@example.com")) === null, "the admin can send while sending is paused");
        check((await pausedMessage("sendPaused", email)) !== null, "everyone else sees the paused message");
      } finally {
        await setPause("sendPaused", was);
        if (!was) await db.delete(appSettings).where(eq(appSettings.key, "sendPaused"));
      }
    }
  } finally {
    const ids = (await db.select({ id: sends.id }).from(sends).where(eq(sends.userId, userId))).map((r) => r.id);
    if (ids.length) await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
    await db.delete(sends).where(eq(sends.userId, userId));
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user (its leftover test USDC stays in a test wallet)");
  }
}

main()
  .then(() => {
    console.log("All send checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
