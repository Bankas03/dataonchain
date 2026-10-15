// Delivery end to end against the VTpass sandbox and the development database.
// Uses VTpass sandbox test numbers:
//   08011111111 -> delivered, 201000000000 -> pending, any other number -> failed
// Run with: npx tsx scripts/delivery-smoke.ts
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { listDataPlans } from "../src/catalog/plans";
import { db } from "../src/db";
import { auditLogs, ledgerEntries, orders, users, vtuTransactions } from "../src/db/schema";
import { fulfilOrder, getDeliveryView } from "../src/fulfilment/service";
import { getCurrentRate } from "../src/pricing/rates";
import { classify } from "../src/vtpass/client";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  // How VTpass answers are read
  check(classify({ code: "000", content: { transactions: { status: "delivered", transactionId: 1 } } }).result === "DELIVERED", "000 + delivered counts as delivered");
  check(classify({ code: "000", content: { transactions: { status: "pending" } } }).result === "PENDING", "000 + pending is asked about again, not resent");
  check(classify({ code: "099" }).result === "PENDING", "099 (processing) is asked about again");
  check(classify({ code: "016" }).result === "FAILED", "016 counts as failed");
  check(classify({ code: "040" }).result === "FAILED", "040 (reversed) counts as failed");
  check(classify({ code: "028" }).result === "FAILED", "028 (product not whitelisted) counts as failed");
  check(classify({ code: "018" }).result === "FAILED", "018 (VTpass wallet too low) counts as failed, so the customer is refunded");
  check(classify({ code: "015" }).result === "PENDING", "015 (no record yet) is asked about again before giving up");
  check(classify(null).result === "PENDING", "no answer at all is asked about again, never resent");

  const rate = await getCurrentRate();
  const [plan] = await listDataPlans("mtn");
  if (!plan) throw new Error("No MTN plans");

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId, name: "Delivery Smoke Test", email: `deliverysmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111",
  });

  const ids: string[] = [];
  async function paidOrder(over: Partial<typeof orders.$inferInsert>) {
    const [o] = await db.insert(orders).values({
      reference: `TEST${Date.now()}${ids.length}`,
      userId,
      serviceType: "airtime",
      network: "mtn",
      phone: "+2348011111111",
      ngnAmountKobo: 10_000,
      marginKobo: 200,
      usdcAmountMicro: 80_000,
      exchangeRateId: rate.id,
      status: "PAYMENT_CONFIRMED",
      quoteExpiresAt: new Date(Date.now() + 600_000),
      ...over,
    }).returning();
    if (!o) throw new Error("could not create test order");
    ids.push(o.id);
    return o;
  }
  const statusOf = async (id: string) => (await db.select().from(orders).where(eq(orders.id, id)).limit(1))[0];

  try {
    const data = await paidOrder({ serviceType: "data", planId: plan.id, ngnAmountKobo: plan.priceKobo });
    await fulfilOrder(data.id);
    const view = await getDeliveryView(data.id);
    check((await statusOf(data.id))?.status === "FULFILLED", `MTN data (${plan.name}) delivered by the VTpass sandbox`, view);
    check(view?.status === "DELIVERED" && Boolean(view.providerReference), `VTpass reference saved (${view?.providerReference})`);

    await fulfilOrder(data.id);
    const sent = await db.select().from(vtuTransactions).where(eq(vtuTransactions.orderId, data.id));
    check(sent.length === 1, "a delivered order is never sent to VTpass a second time");
    const lines = await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, data.id));
    const bal = (cur: string) => lines.filter((l) => l.currency === cur).reduce((s, l) => s + l.debit - l.credit, 0);
    check(lines.length === 4 && bal("USDC") === 0 && bal("NGN") === 0, "delivery ledger entries written and balanced");

    const airtime = await paidOrder({ serviceType: "airtime", network: "glo", ngnAmountKobo: 10_000 });
    await fulfilOrder(airtime.id);
    check((await statusOf(airtime.id))?.status === "FULFILLED", "Glo ₦100 airtime delivered by the VTpass sandbox", await getDeliveryView(airtime.id));

    const bad = await paidOrder({ phone: "+2348022222222" });
    await fulfilOrder(bad.id);
    const badOrder = await statusOf(bad.id);
    check(badOrder?.status === "FAILED" && /refunded/.test(badOrder.failureReason ?? ""), "a failed delivery marks the order Failed, waiting for a refund", await getDeliveryView(bad.id));

    const slow = await paidOrder({ phone: "201000000000" });
    await fulfilOrder(slow.id);
    const slowOrder = await statusOf(slow.id);
    check(slowOrder?.status === "FULFILMENT_PENDING", "a pending delivery waits (it is asked about again, not resent)", await getDeliveryView(slow.id));
  } finally {
    if (ids.length) {
      await db.delete(ledgerEntries).where(inArray(ledgerEntries.orderId, ids));
      await db.delete(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(orders).where(inArray(orders.id, ids));
    }
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test orders");
  }
}

main()
  .then(() => {
    console.log("All delivery checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
