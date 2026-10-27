// Checks for the script 22 fixes, on the development database:
//   - an interrupted payment that never reached Circle is closed, so the
//     customer can pay again (and the Circle lookup itself works)
//   - an interrupted payment is left alone when another payment of the same
//     order already holds the Circle transfer
//   - the admin "fail and refund" refuses orders without a confirmed payment,
//     and closes a stuck order and starts its refund (a 0.000001 USDC refund,
//     from the treasury to itself)
//   - the database allows only one open bridge transfer per user
// Run with: npx tsx scripts/fixes-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray, or } from "drizzle-orm";
import { db } from "../src/db";
import { isUniqueViolation } from "../src/db/errors";
import { auditLogs, bridgeTransfers, ledgerEntries, orders, payments, refunds, users, vtuTransactions, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { AdminActionError, failAndRefund } from "../src/admin/actions";
import { recoverInterruptedPayments } from "../src/payments/service";
import { getCurrentRate } from "../src/pricing/rates";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

const ago = (minutes: number) => new Date(Date.now() - minutes * 60_000);
const ref = () => `ARCT${Math.floor(Math.random() * 1e9)}`;

async function main() {
  const userId = randomUUID();
  const orderIds: string[] = [];
  const walletRowId = randomUUID();
  try {
    await db.insert(users).values({ id: userId, name: "Fixes Smoke", email: `fixes-smoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
    // A wallet row so refunds have somewhere to go: the treasury's own address (it pays itself)
    await db.insert(wallets).values({
      id: walletRowId,
      userId,
      purpose: "user",
      circleWalletId: `fixes-smoke-${walletRowId}`,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      blockchain: env.CIRCLE_BLOCKCHAIN,
      address: env.TREASURY_ADDRESS,
      accountType: "SCA",
    });
    const rate = await getCurrentRate();
    const base = {
      userId,
      serviceType: "airtime" as const,
      network: "mtn" as const,
      phone: "+2348011111111",
      ngnAmountKobo: 5_000,
      marginKobo: 0,
      usdcAmountMicro: 1,
      exchangeRateId: rate.id,
      quoteExpiresAt: new Date(Date.now() + 10 * 60_000),
    };

    // 1. Interrupted payment that never reached Circle (a real user wallet is used for the lookup)
    const [realWallet] = await db.select().from(wallets).where(eq(wallets.accountType, "SCA")).limit(1);
    const [o1] = await db.insert(orders).values({ ...base, reference: ref(), status: "PAYMENT_PENDING" }).returning();
    orderIds.push(o1!.id);
    await db.insert(payments).values({
      orderId: o1!.id,
      walletId: realWallet?.id ?? null,
      toAddress: env.TREASURY_ADDRESS,
      token: "test",
      blockchain: env.CIRCLE_BLOCKCHAIN,
      amountMicro: 1,
      status: "INITIATED",
      createdAt: ago(3),
    });

    // 2. Interrupted payment, but another payment of the same order holds the transfer
    const [o2] = await db.insert(orders).values({ ...base, reference: ref(), status: "QUOTED" }).returning();
    orderIds.push(o2!.id);
    await db.insert(payments).values([
      { orderId: o2!.id, walletId: null, toAddress: env.TREASURY_ADDRESS, token: "test", blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "INITIATED", createdAt: ago(3) },
      { orderId: o2!.id, walletId: null, toAddress: env.TREASURY_ADDRESS, token: "test", blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "FAILED", circleTransactionId: `fixes-smoke-${randomUUID()}`, createdAt: ago(3) },
    ]);

    await recoverInterruptedPayments();
    const [p1] = await db.select().from(payments).where(eq(payments.orderId, o1!.id));
    const [after1] = await db.select().from(orders).where(eq(orders.id, o1!.id));
    check(p1?.status === "FAILED" && after1?.status === "QUOTED", "an interrupted payment Circle never got is closed and the order can be paid again", { p: p1?.status, o: after1?.status });
    const p2 = await db.select().from(payments).where(eq(payments.orderId, o2!.id));
    check(p2.every((p) => p.status === "FAILED") && p2.filter((p) => p.circleTransactionId === null).length === 1, "an interrupted payment is left closed when the order's transfer is held elsewhere", p2.map((p) => p.status));

    // 3. Fail and refund: refused without a confirmed payment
    const [o3] = await db.insert(orders).values({ ...base, reference: ref(), status: "FLAGGED" }).returning();
    orderIds.push(o3!.id);
    let refused = false;
    try {
      await failAndRefund("fixes-smoke-admin", o3!.reference, "checked on VTpass");
    } catch (err) {
      refused = err instanceof AdminActionError && err.status === 409;
    }
    check(refused, "fail and refund is refused when there is no confirmed payment");

    // 4. Fail and refund on a stuck, paid order
    const [o4] = await db.insert(orders).values({ ...base, reference: ref(), status: "FLAGGED" }).returning();
    orderIds.push(o4!.id);
    await db.insert(payments).values({
      orderId: o4!.id, walletId: walletRowId, toAddress: env.TREASURY_ADDRESS, token: (await usdcTokenId()) ?? "test",
      blockchain: env.CIRCLE_BLOCKCHAIN, amountMicro: 1, status: "CONFIRMED", txHash: `0xfixes${randomUUID().replace(/-/g, "")}`, confirmedAt: new Date(),
    });
    await db.insert(vtuTransactions).values({ orderId: o4!.id, provider: "vtpass", requestId: `fixes-smoke-${randomUUID()}`, status: "PENDING" });
    let noReason = false;
    try {
      await failAndRefund("fixes-smoke-admin", o4!.reference, "  ");
    } catch (err) {
      noReason = err instanceof AdminActionError;
    }
    check(noReason, "fail and refund needs a note of what was checked");
    const result = await failAndRefund("fixes-smoke-admin", o4!.reference, "smoke test: not on the VTpass dashboard");
    const [vtu] = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, o4!.id));
    check(["REFUND_PENDING", "REFUNDED"].includes(result.after), "the stuck order is closed and its refund starts", result);
    check(vtu?.status === "FAILED", "the unclear delivery is marked failed", vtu?.status);
    let again = false;
    try {
      await failAndRefund("fixes-smoke-admin", o4!.reference, "again");
    } catch (err) {
      again = err instanceof AdminActionError;
    }
    check(again, "it cannot be done twice");

    // 5. One open bridge transfer per user
    const t = {
      userId,
      direction: "OUT" as const,
      sourceChain: "arc",
      destinationChain: "base",
      sourceDomain: 26,
      destinationDomain: 6,
      depositorWalletId: "fixes-smoke",
      depositorAddress: "0x000000000000000000000000000000000000dead",
      recipientAddress: "0x000000000000000000000000000000000000beef",
      amountMicro: 1_000_000,
      status: "QUOTED" as const,
      openKey: userId,
    };
    await db.insert(bridgeTransfers).values({ ...t, salt: `0x${randomUUID().replace(/-/g, "")}` });
    let blocked: unknown = null;
    try {
      await db.insert(bridgeTransfers).values({ ...t, salt: `0x${randomUUID().replace(/-/g, "")}` });
    } catch (err) {
      blocked = err;
    }
    check(isUniqueViolation(blocked, "open_key"), "the database refuses a second open transfer for the same user", String(blocked));
  } finally {
    await db.delete(bridgeTransfers).where(eq(bridgeTransfers.userId, userId));
    if (orderIds.length) {
      await db.delete(refunds).where(inArray(refunds.orderId, orderIds));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, orderIds));
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, orderIds));
      await db.delete(payments).where(inArray(payments.orderId, orderIds));
      await db.delete(auditLogs).where(or(inArray(auditLogs.targetId, orderIds), eq(auditLogs.actorId, "fixes-smoke-admin")));
      await db.delete(orders).where(inArray(orders.id, orderIds));
    }
    await db.delete(wallets).where(eq(wallets.id, walletRowId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test data");
  }
}

// The treasury's USDC token id on Circle, so the tiny refund can really be sent
async function usdcTokenId(): Promise<string | null> {
  const { circle } = await import("../src/circle/client");
  const res = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  return (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"))?.token?.id ?? null;
}

main()
  .then(() => {
    console.log("All fix checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
