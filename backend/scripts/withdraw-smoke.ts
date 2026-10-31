// Treasury withdrawals, on testnet and the development database:
//   - wrong tokens and amounts, and more than can be withdrawn, are refused
//   - 6 wrong codes sent at once cancel the withdrawal; the right code then fails
//   - a real 0.1 USDC withdrawal (a wrong code first) completes with a transaction
// Exit code 3 means the testnet treasury needs more test USDC.
// Run with:
//   ADMIN_EMAIL=withdraw-smoke@example.com EMAIL_OUTBOX_FILE=/tmp/x TREASURY_RESERVE_USDC=0.01 \
//   TREASURY_PAYOUT_ADDRESS=0x000000000000000000000000000000000000dEaD npx tsx scripts/withdraw-smoke.ts
import { readFileSync } from "node:fs";
import { eq, inArray, like } from "drizzle-orm";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, treasuryWithdrawals } from "../src/db/schema";
import { env } from "../src/env";
import { WithdrawError, advanceWithdrawals, confirmWithdraw, startWithdraw, treasuryView } from "../src/treasury/withdraw";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
    check(err instanceof WithdrawError, label, err instanceof Error ? err.message : err);
  }
}

function lastCode(): string {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox) throw new Error("Set EMAIL_OUTBOX_FILE");
  const mails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; text: string });
  const mine = mails.filter((m) => m.to === env.ADMIN_EMAIL);
  const code = /\n(\d{6})\n/.exec(mine[mine.length - 1]?.text ?? "")?.[1];
  if (!code) throw new Error("No code email found");
  return code;
}

async function main() {
  if (!env.ADMIN_EMAIL?.endsWith("@example.com") || !env.TREASURY_PAYOUT_ADDRESS) throw new Error("Run with a test ADMIN_EMAIL and TREASURY_PAYOUT_ADDRESS (see the top of this file)");
  if (!env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) throw new Error("This test only runs on testnet");
  const startedAt = new Date();
  const ids: string[] = [];
  try {
    const before = await treasuryView();
    check(before.payoutAddress === env.TREASURY_PAYOUT_ADDRESS, "the payout address comes from the server settings", before.payoutAddress);
    if (!before.available || Number(before.available.USDC) < 0.2) {
      console.log(`NEEDS_FUNDING: treasury can give ${before.available?.USDC ?? 0} USDC`);
      process.exit(3);
    }
    check(Number(before.available.USDC) <= Number(before.balances!.USDC) - 0.05 + 1e-9, "0.05 USDC always stays for gas", before.available);

    await refused("an unknown token is refused", () => startWithdraw(null, { token: "DOGE", amount: "1" }));
    await refused("a bad amount is refused", () => startWithdraw(null, { token: "USDC", amount: "1.1234567" }));
    await refused("zero is refused", () => startWithdraw(null, { token: "USDC", amount: "0" }));
    await refused("more than can be withdrawn is refused", () => startWithdraw(null, { token: "USDC", amount: (Number(before.available!.USDC) + 1).toFixed(6) }));

    // A burst of wrong codes still counts: the withdrawal is cancelled
    const first = await startWithdraw(null, { token: "USDC", amount: "0.1" });
    ids.push(first.id);
    check(first.status === "AWAITING_CODE", "a withdrawal waits for the emailed code");
    const firstCode = lastCode();
    const bad = firstCode === "000000" ? "111111" : "000000";
    await Promise.allSettled(Array.from({ length: 6 }, () => confirmWithdraw(first.id, bad)));
    const [raced] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, first.id));
    check(raced?.status === "CANCELLED", "6 wrong codes at once cancel it (the limit is 5)", raced?.status);
    await refused("the right code no longer works after that", () => confirmWithdraw(first.id, firstCode));

    // The real one
    const second = await startWithdraw(null, { token: "USDC", amount: "0.1" });
    ids.push(second.id);
    const code = lastCode();
    await refused("a wrong code is refused", () => confirmWithdraw(second.id, code === "000000" ? "111111" : "000000"));
    let w = await confirmWithdraw(second.id, code);
    for (let i = 0; i < 20 && ["SENDING", "SENT"].includes(w.status); i++) {
      await sleep(3_000);
      await advanceWithdrawals();
      const [row] = await db.select().from(treasuryWithdrawals).where(eq(treasuryWithdrawals.id, second.id));
      w = { ...w, status: row!.status, txUrl: row!.txHash ? `${env.EXPLORER_TX_URL}${row!.txHash}` : null };
    }
    check(w.status === "COMPLETE" && Boolean(w.txUrl), `0.1 USDC withdrawn (${w.txUrl})`, w);
    await refused("the same code cannot be used twice", () => confirmWithdraw(second.id, code));
    const after = await treasuryView();
    check(after.withdrawals.some((x) => x.id === second.id && x.status === "COMPLETE"), "it shows in the list of withdrawals");
  } finally {
    if (ids.length) {
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      for (const id of ids) await db.delete(ledgerEntries).where(like(ledgerEntries.memo, `%withdrawal ${id}%`));
      await db.delete(treasuryWithdrawals).where(inArray(treasuryWithdrawals.id, ids));
    }
    console.log(`Cleaned up the test withdrawals (started ${startedAt.toISOString()})`);
  }
}

main()
  .then(() => {
    console.log("All treasury withdrawal checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
