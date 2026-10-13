// Checks pricing end to end against the development database and the
// VTpass sandbox, using a temporary user. Cleans up after itself.
// Run with: npx tsx scripts/pricing-smoke.ts
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { listDataPlans } from "../src/catalog/plans";
import { db } from "../src/db";
import { orders, users } from "../src/db/schema";
import { getCurrentRate } from "../src/pricing/rates";
import { QuoteError, createQuote, getQuote, priceInUsdc } from "../src/pricing/quote";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function rejects(fn: () => Promise<unknown>, label: string) {
  try {
    await fn();
  } catch (err) {
    check(err instanceof QuoteError, label, err instanceof Error ? err.message : err);
    return;
  }
  check(false, label, "it was accepted");
}

async function main() {
  // Pure maths: the price always covers cost plus margin, never a micro USDC more than needed.
  const { marginKobo, usdcMicro } = priceInUsdc(100_000, 133_017, 200);
  check(marginKobo === 2_000, "2% margin on ₦1,000 is ₦20");
  check(usdcMicro * 133_017 >= 102_000 * 1_000_000 && (usdcMicro - 1) * 133_017 < 102_000 * 1_000_000,
    "USDC price is rounded up, by less than 0.000001 USDC");

  const rate = await getCurrentRate();
  check(rate.koboPerUsdc > 50_000 && rate.koboPerUsdc < 5_000_000,
    `exchange rate looks sensible (₦${(rate.koboPerUsdc / 100).toLocaleString("en-NG")} per USDC, from ${rate.source})`);

  const plans = await listDataPlans("mtn");
  check(plans.length > 0, `VTpass sandbox MTN data plans loaded (${plans.length} plans)`);
  check(plans.every((p) => p.priceKobo > 0), "every plan has a price");

  const userId = randomUUID();
  await db.insert(users).values({
    id: userId,
    name: "Pricing Smoke Test",
    email: `pricingsmoke+${Date.now()}@example.com`,
    emailVerified: true,
    phone: "+2348012345678",
  });

  try {
    const plan = plans[0]!;
    const dataQuote = await createQuote(userId, {
      serviceType: "data", network: "mtn", planId: plan.id, phone: "08011111111",
    });
    check(dataQuote.status === "QUOTED" && /^ARC\d{8}$/.test(dataQuote.reference), `data quote created (${dataQuote.reference})`);
    check(dataQuote.ngnAmount === plan.priceKobo / 100, "data quote uses the plan price");
    check(Number(dataQuote.usdcAmount) > 0, `data quote has a USDC price (${dataQuote.usdcAmount} USDC)`);
    check(new Date(dataQuote.expiresAt).getTime() > Date.now(), "the price is held for a while");

    const airtime = await createQuote(userId, {
      serviceType: "airtime", network: "glo", amountNgn: 500, phone: "+234 801 111 1111",
    });
    check(airtime.ngnAmount === 500 && airtime.phone === "08011111111", "airtime quote created and phone saved in one format");

    const again = await getQuote(userId, dataQuote.reference);
    check(again?.reference === dataQuote.reference, "a quote can be read back");
    const stranger = await getQuote(randomUUID(), dataQuote.reference);
    check(stranger === null, "nobody else can read your quote");

    await rejects(() => createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 10, phone: "08011111111" }),
      "airtime below ₦50 is refused");
    await rejects(() => createQuote(userId, { serviceType: "airtime", network: "mtn", amountNgn: 100, phone: "12345" }),
      "an invalid phone number is refused");
    await rejects(() => createQuote(userId, { serviceType: "data", network: "mtn", planId: "no-such-plan", phone: "08011111111" }),
      "an unknown data plan is refused");
    await rejects(() => createQuote(userId, { serviceType: "data", network: "starcomms", planId: plan.id, phone: "08011111111" }),
      "an unknown network is refused");
  } finally {
    await db.delete(orders).where(eq(orders.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user and quotes");
  }
}

main()
  .then(() => {
    console.log("All pricing checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
