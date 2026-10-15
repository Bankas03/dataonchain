// Read only report of recent paid orders, with what VTpass says right now.
// Changes nothing. Point it at production with TURSO_DATABASE_URL and TURSO_AUTH_TOKEN.
// Run with: npx tsx scripts/orders-report.ts
import { desc, inArray, notInArray } from "drizzle-orm";
import { db } from "../src/db";
import { orders, payments, refunds, vtuTransactions } from "../src/db/schema";
import { requery } from "../src/vtpass/client";

const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "short", timeStyle: "short" });
const usdc = (micro: number) => (micro / 1_000_000).toFixed(6);

async function main() {
  const rows = await db
    .select()
    .from(orders)
    .where(notInArray(orders.status, ["QUOTED", "EXPIRED"]))
    .orderBy(desc(orders.createdAt))
    .limit(30);
  if (rows.length === 0) {
    console.log("No paid orders yet.");
    return;
  }
  const ids = rows.map((o) => o.id);
  const pays = await db.select().from(payments).where(inArray(payments.orderId, ids));
  const txs = await db.select().from(vtuTransactions).where(inArray(vtuTransactions.orderId, ids));
  const refs = await db.select().from(refunds).where(inArray(refunds.orderId, ids));

  const counts: Record<string, number> = {};
  for (const o of rows) counts[o.status] = (counts[o.status] ?? 0) + 1;
  console.log(`Last ${rows.length} orders by status: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ")}\n`);

  for (const o of rows) {
    const pay = pays.filter((p) => p.orderId === o.id).at(-1);
    const tx = txs.filter((t) => t.orderId === o.id).sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0];
    const refund = refs.find((r) => r.orderId === o.id);
    const raw = (tx?.responsePayload ?? {}) as { code?: string; response_description?: string; error?: string };
    console.log(`${o.reference}  ${lagos(o.createdAt)}  ${o.status}  ${o.serviceType} ${o.network} ${o.phone}  ${usdc(o.usdcAmountMicro)} USDC`);
    console.log(`   payment: ${pay?.status ?? "none"}`);
    if (tx) {
      const ageMin = Math.round((Date.now() - tx.createdAt.getTime()) / 60_000);
      console.log(`   vtpass:  ${tx.status}, asked ${tx.attempt} time(s), ${ageMin} min ago, last answer: ${raw.code ?? ""} ${raw.response_description ?? raw.error ?? "(none saved)"}`);
      if (["SENT", "PENDING", "UNKNOWN"].includes(tx.status)) {
        const now = await requery(tx.requestId);
        console.log(`   vtpass now says: ${now.result}${now.notFound ? " (no record of this request)" : ""}, code ${now.code || "none"}, ${now.message}`);
      }
    }
    if (refund) console.log(`   refund:  ${refund.status}${refund.txHash ? ` ${refund.txHash}` : ""}${refund.lastError ? ` (${refund.lastError})` : ""}`);
    if (o.failureReason) console.log(`   note:    ${o.failureReason}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
