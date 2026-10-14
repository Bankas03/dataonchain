// A real testnet payment, end to end, from a dedicated test wallet.
// Exit code 3 means the test wallet needs USDC; its address is written to argv[2].
// Run with: npx tsx scripts/pay-smoke.ts /tmp/payer-address.txt
import { writeFileSync } from "node:fs";
import { eq } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { ledgerEntries, orders, payments, users, vtuTransactions } from "../src/db/schema";
import { createQuote } from "../src/pricing/quote";
import { PaymentError, checkTransfer, getOrderView, payOrder, usdcToMicro } from "../src/payments/service";
import { ensureUserWallet } from "../src/wallets/service";

const PAYER_EMAIL = "payer+smoketest@dataonchain.local";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  // Pure checks first: the verifier must catch every kind of bad transfer.
  const expected = { destination: "0xAbC0000000000000000000000000000000000001", amountMicro: 75_189, tokenId: "tok", blockchain: "ARC-TESTNET" };
  const good = { state: "COMPLETE", destinationAddress: "0xabc0000000000000000000000000000000000001", amounts: ["0.075189"], tokenId: "tok", blockchain: "ARC-TESTNET", txHash: "0x1" };
  check(checkTransfer(good, expected).length === 0, "a correct transfer passes verification");
  check(checkTransfer({ ...good, destinationAddress: "0x0000000000000000000000000000000000000002" }, expected).length > 0, "a transfer to the wrong address is caught");
  check(checkTransfer({ ...good, amounts: ["0.07"] }, expected).length > 0, "a wrong amount is caught");
  check(checkTransfer({ ...good, tokenId: "other" }, expected).length > 0, "a wrong token is caught");
  check(checkTransfer({ ...good, txHash: undefined }, expected).length > 0, "a missing transaction hash is caught");
  check(checkTransfer({ ...good, state: "SENT" }, expected).length > 0, "an unfinished transfer is not counted");
  check(usdcToMicro("1.5") === 1_500_000 && usdcToMicro("0.0000001") === null, "USDC amounts are read exactly");

  // The test payer: one user in the development database, kept between runs.
  let [payer] = await db.select().from(users).where(eq(users.email, PAYER_EMAIL)).limit(1);
  if (!payer) {
    [payer] = await db
      .insert(users)
      .values({ name: "Payment Test", email: PAYER_EMAIL, emailVerified: true, phone: "+2348011111111" })
      .returning();
  }
  if (!payer) throw new Error("Could not create the test payer");
  const wallet = await ensureUserWallet(payer.id);

  const res = await circle.getWalletTokenBalance({ id: wallet.circleWalletId });
  const usdc = (res.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const balance = Number(usdc?.amount ?? 0);
  console.log(`Test wallet ${wallet.address} holds ${balance} USDC`);
  if (balance < 0.5) {
    if (process.argv[2]) writeFileSync(process.argv[2], wallet.address);
    console.log("NEEDS_FUNDING");
    process.exit(3);
  }

  const quote = await createQuote(payer.id, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "08011111111" });
  console.log(`Quote ${quote.reference}: ${quote.usdcAmount} USDC`);
  let orderId: string | undefined;

  try {
    const started = await payOrder(payer.id, quote.reference);
    check(["PAYMENT_PENDING", ...["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"]].includes(started?.status ?? ""), "payment started");
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    orderId = row?.id;

    const again = await payOrder(payer.id, quote.reference);
    check(again?.reference === quote.reference, "paying the same order twice does not start a second transfer");
    const all = orderId ? await db.select().from(payments).where(eq(payments.orderId, orderId)) : [];
    check(all.length === 1, "exactly one payment exists for the order");

    let view = started;
    for (let i = 0; i < 60 && view?.status === "PAYMENT_PENDING"; i++) {
      await new Promise((r) => setTimeout(r, 3_000));
      view = await getOrderView(payer.id, quote.reference);
      process.stdout.write(".");
    }
    console.log("");
    check(["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"].includes(view?.status ?? ""), `payment confirmed on Arc (status ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""})`);
    check(Boolean(view?.payment?.txHash), `transaction hash recorded (${view?.payment?.txHash})`);
    if (view?.payment?.explorerUrl) console.log(`See it on the explorer: ${view.payment.explorerUrl}`);

    const lines = (orderId ? await db.select().from(ledgerEntries).where(eq(ledgerEntries.orderId, orderId)) : [])
      .filter((l) => (l.memo ?? "").startsWith("Payment"));
    const debit = lines.reduce((s, l) => s + l.debit, 0);
    const credit = lines.reduce((s, l) => s + l.credit, 0);
    check(lines.length === 2 && debit === credit, "ledger entries written and balanced");

    try {
      await payOrder(payer.id, "ARC00000000");
      check(false, "paying an unknown order is refused");
    } catch (err) {
      check(err instanceof PaymentError && err.status === 404, "paying an unknown order is refused");
    }
  } finally {
    // Remove the test order so Phase 9 never tries to deliver it. The USDC stays in the treasury.
    const [row] = await db.select().from(orders).where(eq(orders.reference, quote.reference)).limit(1);
    if (row) {
      // Let the automatic delivery finish (VTpass sandbox) before removing the order.
      for (let i = 0; i < 30; i++) {
        const [now] = await db.select().from(orders).where(eq(orders.id, row.id)).limit(1);
        if (!now || !['PAYMENT_CONFIRMED', 'FULFILMENT_PENDING'].includes(now.status)) break;
        await new Promise((r) => setTimeout(r, 2_000));
      }
      await db.delete(vtuTransactions).where(eq(vtuTransactions.orderId, row.id));
      await db.delete(ledgerEntries).where(eq(ledgerEntries.orderId, row.id));
      await db.delete(payments).where(eq(payments.orderId, row.id));
      await db.delete(orders).where(eq(orders.id, row.id));
      console.log("Cleaned up the test order");
    }
  }
}

main()
  .then(() => {
    console.log("All payment checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
