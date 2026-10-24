// Bridge monitoring checks on the development database (no money moves):
//   - a transfer sitting in one step too long is reported as stuck, once
//   - the alert email goes to ALERT_EMAIL
//   - the report flags a "complete" transfer that has no mint transaction
// Run with: ALERT_EMAIL=alerts@example.com EMAIL_OUTBOX_FILE=/tmp/x npx tsx scripts/monitor-smoke.ts
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { eq, inArray } from "drizzle-orm";
import { db } from "../src/db";
import { auditLogs, bridgeTransfers } from "../src/db/schema";
import { alertStuck, findStuck, reconcile } from "../src/bridge/monitor";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (!outbox || !process.env.ALERT_EMAIL) throw new Error("Run with ALERT_EMAIL and EMAIL_OUTBOX_FILE set");
  const old = new Date(Date.now() - 3 * 60 * 60_000);
  const base = {
    direction: "OUT" as const,
    sourceChain: "arc",
    destinationChain: "base",
    sourceDomain: 26,
    destinationDomain: 6,
    depositorWalletId: "test-wallet",
    depositorAddress: "0x000000000000000000000000000000000000dead",
    recipientAddress: "0x000000000000000000000000000000000000beef",
    amountMicro: 1_000_000,
  };
  const ids: string[] = [];
  try {
    const [stuck] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "INTENT_SIGNED", createdAt: old, updatedAt: old }).returning();
    const [fresh] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "INTENT_SIGNED" }).returning();
    const [broken] = await db.insert(bridgeTransfers).values({ ...base, salt: `0x${randomUUID().replace(/-/g, "")}`, status: "COMPLETE" }).returning();
    ids.push(stuck!.id, fresh!.id, broken!.id);

    const found = (await findStuck()).map((t) => t.id);
    check(found.includes(stuck!.id), "a transfer waiting 3 hours after signing is found as stuck");
    check(!found.includes(fresh!.id), "a transfer that just moved is not stuck");

    const first = await alertStuck();
    check(first >= 1, `stuck transfers were reported (${first})`);
    const emails = readFileSync(outbox, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { to: string; subject: string; text: string });
    check(emails.some((e) => e.to === process.env.ALERT_EMAIL && e.text.includes(stuck!.id)), "the alert email went to ALERT_EMAIL and names the transfer");
    await alertStuck();
    const alerts = await db.select().from(auditLogs).where(eq(auditLogs.targetId, stuck!.id));
    check(alerts.filter((a) => a.action === "bridge.stuck").length === 1, "the same stuck transfer is reported only once");

    const report = await reconcile();
    check(report.issues.some((i) => i.includes(broken!.id) && /without a mint/.test(i)), "the report flags a complete transfer without a mint transaction");
    check(report.issues.some((i) => i.includes(stuck!.id)), "the report lists the stuck transfer");
    console.log("Report preview:");
    for (const line of report.lines) console.log(`  ${line}`);
  } finally {
    if (ids.length) {
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ids));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ids));
    }
    console.log("Cleaned up the test transfers");
  }
}

main()
  .then(() => {
    console.log("All monitoring checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
