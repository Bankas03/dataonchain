// Watching the bridge:
//   - stuck transfers: anything sitting in one step for too long is reported
//     once (audit log, Render logs, and email to ALERT_EMAIL). The worker keeps
//     retrying them every 30 seconds in the meantime.
//   - daily reconciliation: every completed transfer is checked against Circle
//     Gateway's own record (same mint transaction), and leftover Gateway
//     balances are totalled. The report is emailed to ALERT_EMAIL once a day.
import { and, desc, eq, gte, inArray, lt, notInArray } from "drizzle-orm";
import { db } from "../db";
import { auditLogs, bridgeTransfers } from "../db/schema";
import { sendEmail } from "../email";
import { env } from "../env";
import { bridgeChains, chainByKey } from "./chains";
import { networkFeeSummary } from "./fees";
import { gatewayBalanceMicro, getTransfer } from "./gateway";
import { swapSummary } from "../swap/service";

type Transfer = typeof bridgeTransfers.$inferSelect;

// How long a transfer may stay in one step before it counts as stuck (minutes).
// DEPOSITED waits for source chain finality: about 20 minutes on Ethereum based networks.
export const STUCK_AFTER_MINUTES: Partial<Record<Transfer["status"], number>> = {
  QUOTED: 30,
  DEPOSITING: 30,
  DEPOSITED: 60,
  FINALIZED: 30,
  INTENT_SIGNED: 15,
  SUBMITTED: 20,
  MINTED: 10,
  EXPIRED: 30,
};

const usdc = (micro: number) => (micro / 1_000_000).toFixed(6);
const minutesAgo = (d: Date) => Math.round((Date.now() - d.getTime()) / 60_000);

export async function findStuck(): Promise<Transfer[]> {
  const out: Transfer[] = [];
  for (const [status, minutes] of Object.entries(STUCK_AFTER_MINUTES)) {
    const rows = await db
      .select()
      .from(bridgeTransfers)
      .where(and(eq(bridgeTransfers.status, status as Transfer["status"]), lt(bridgeTransfers.updatedAt, new Date(Date.now() - minutes * 60_000))))
      .limit(50);
    out.push(...rows);
  }
  return out;
}

function describe(t: Transfer): string {
  return `${t.id}  ${usdc(t.amountMicro)} USDC ${chainByKey(t.sourceChain).label} -> ${chainByKey(t.destinationChain).label}, ${t.status} for ${minutesAgo(t.updatedAt)} min`;
}

async function notify(subject: string, lines: string[]) {
  if (!env.ALERT_EMAIL) return;
  const text = lines.join("\n");
  const html = `<pre style="font-family:monospace;font-size:13px">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</pre>`;
  try {
    await sendEmail({ to: env.ALERT_EMAIL, subject, text, html });
  } catch (err) {
    console.error("[bridge] could not email the alert:", err instanceof Error ? err.message : err);
  }
}

// Reports each stuck transfer once per step. Returns how many new alerts were raised.
export async function alertStuck(): Promise<number> {
  const stuck = await findStuck();
  const fresh: Transfer[] = [];
  for (const t of stuck) {
    const previous = await db
      .select({ details: auditLogs.details })
      .from(auditLogs)
      .where(and(eq(auditLogs.action, "bridge.stuck"), eq(auditLogs.targetId, t.id)));
    if (previous.some((p) => (p.details as { status?: string } | null)?.status === t.status)) continue;
    await db.insert(auditLogs).values({
      actorType: "system",
      action: "bridge.stuck",
      targetType: "bridge_transfer",
      targetId: t.id,
      details: { status: t.status, minutes: minutesAgo(t.updatedAt) },
    });
    console.error(`[bridge] STUCK ${describe(t)}`);
    fresh.push(t);
  }
  if (fresh.length) {
    await notify(`dataonchain: ${fresh.length} bridge transfer${fresh.length > 1 ? "s" : ""} stuck`, [
      "These bridge transfers have not moved for a while. The worker keeps retrying them.",
      "Funds are safe: Gateway only burns after the mint, and deposits stay in the user's Gateway balance.",
      "",
      ...fresh.map(describe),
      "",
      "Details: bash setup/bridge-report.sh prod",
    ]);
  }
  return fresh.length;
}

export type Report = { generatedAt: string; issues: string[]; lines: string[] };

export async function reconcile(): Promise<Report> {
  const issues: string[] = [];
  const lines: string[] = [];
  const since = new Date(Date.now() - 24 * 60 * 60_000);

  const open = await db
    .select()
    .from(bridgeTransfers)
    .where(notInArray(bridgeTransfers.status, ["COMPLETE", "FAILED"]));
  const failed = await db
    .select()
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "FAILED"), gte(bridgeTransfers.updatedAt, since)));
  const done = await db
    .select()
    .from(bridgeTransfers)
    .where(and(eq(bridgeTransfers.status, "COMPLETE"), gte(bridgeTransfers.updatedAt, since)))
    .orderBy(desc(bridgeTransfers.updatedAt));

  lines.push(`Last 24 hours: ${done.length} complete (${usdc(done.reduce((s, t) => s + t.amountMicro, 0))} USDC), ${failed.length} failed. Open now: ${open.length}.`);

  // Every completed transfer must match Circle Gateway's own record
  let checked = 0;
  for (const t of done) {
    if (!t.mintTxHash) {
      issues.push(`COMPLETE without a mint transaction: ${t.id}`);
      continue;
    }
    if (!t.gatewayTransferId) {
      issues.push(`COMPLETE without a Gateway transfer id: ${t.id}`);
      continue;
    }
    try {
      const g = await getTransfer(t.gatewayTransferId);
      if (!["confirmed", "finalized"].includes(g.status)) issues.push(`Gateway says ${g.status} for completed transfer ${t.id}`);
      else if ((g.transactionHash ?? "").toLowerCase() !== t.mintTxHash.toLowerCase()) issues.push(`Mint transaction differs from Gateway's for ${t.id}`);
      else checked++;
    } catch (err) {
      issues.push(`Could not check ${t.id} with Gateway: ${err instanceof Error ? err.message : err}`);
    }
  }
  lines.push(`Checked against Circle Gateway: ${checked} of ${done.length} completed transfers match.`);

  for (const t of await findStuck()) issues.push(`Stuck: ${describe(t)}`);
  for (const t of failed) lines.push(`Failed: ${t.id}  ${usdc(t.amountMicro)} USDC to ${chainByKey(t.destinationChain).label}: ${t.failureReason ?? "unknown"}`);

  // Leftovers held in Gateway for users (unused fee margins, unfinished transfers)
  const pairs = await db
    .selectDistinct({ depositor: bridgeTransfers.depositorAddress, chain: bridgeTransfers.sourceChain })
    .from(bridgeTransfers);
  let held = 0;
  const perChain: Record<string, number> = {};
  for (const p of pairs) {
    try {
      const b = await gatewayBalanceMicro(p.depositor, chainByKey(p.chain).domain);
      held += b;
      perChain[p.chain] = (perChain[p.chain] ?? 0) + b;
    } catch {
      issues.push(`Could not read the Gateway balance of ${p.depositor} on ${p.chain}`);
    }
  }
  lines.push(`Held in Circle Gateway for users: ${usdc(held)} USDC across ${pairs.length} wallet(s)` +
    (Object.keys(perChain).length ? ` (${bridgeChains().filter((c) => perChain[c.key]).map((c) => `${c.label} ${usdc(perChain[c.key]!)}`).join(", ")})` : ""));

  // Our transfer fees
  const fees = await networkFeeSummary(since);
  lines.push(`Transfer fees taken, last 24 hours: ${fees.collected} USDC.`);
  for (const id of fees.failed) issues.push(`Transfer fee could not be taken for ${id} (see the audit log)`);

  // Swaps on Arc
  const s = await swapSummary(since);
  lines.push(`Swaps, last 24 hours: ${s.complete} complete, ${s.failed} failed (nothing taken).`);
  for (const u of s.unknown) issues.push(`Swap needs a check (interrupted or unclear): ${u}`);

  return { generatedAt: new Date().toISOString(), issues, lines };
}

export function formatReport(r: Report): string[] {
  return [
    `dataonchain bridge report, ${new Date(r.generatedAt).toLocaleString("en-GB", { timeZone: "Africa/Lagos" })} (Lagos)`,
    "",
    ...r.lines,
    "",
    r.issues.length ? `${r.issues.length} issue(s):` : "No issues found.",
    ...r.issues.map((i) => `  - ${i}`),
  ];
}

// Once a day (checked every worker tick): run the reconciliation and email it.
export async function dailyReconcile(): Promise<boolean> {
  const [last] = await db
    .select({ createdAt: auditLogs.createdAt })
    .from(auditLogs)
    .where(inArray(auditLogs.action, ["bridge.reconcile"]))
    .orderBy(desc(auditLogs.createdAt))
    .limit(1);
  if (last && Date.now() - last.createdAt.getTime() < 24 * 60 * 60_000) return false;
  const r = await reconcile();
  await db.insert(auditLogs).values({ actorType: "system", action: "bridge.reconcile", targetType: "bridge", targetId: null, details: { issues: r.issues, lines: r.lines } });
  for (const line of formatReport(r)) console.log(`[bridge report] ${line}`);
  await notify(r.issues.length ? `dataonchain bridge report: ${r.issues.length} issue(s)` : "dataonchain bridge report: all good", formatReport(r));
  return true;
}
