// Data plans, copied from VTpass into our database and refreshed every hour,
// so prices stay close to what VTpass charges at delivery.
import { and, asc, eq, lt, max } from "drizzle-orm";
import { db } from "../db";
import { NETWORKS, dataPlans } from "../db/schema";
import { getDataVariations, type Network } from "../vtpass/client";

const REFRESH_AFTER_MS = 60 * 60 * 1000;
const syncing = new Map<Network, Promise<void>>();

export type DataPlan = typeof dataPlans.$inferSelect;

export function isNetwork(value: unknown): value is Network {
  return typeof value === "string" && (NETWORKS as readonly string[]).includes(value);
}

export async function syncDataPlans(network: Network): Promise<number> {
  const startedAt = new Date();
  const variations = await getDataVariations(network);
  let saved = 0;
  for (const v of variations) {
    const priceKobo = Math.round(Number.parseFloat(v.variation_amount) * 100);
    const name = String(v.name ?? "").trim();
    if (!v.variation_code || !name || !Number.isFinite(priceKobo) || priceKobo <= 0) continue;
    await db
      .insert(dataPlans)
      .values({
        provider: "vtpass",
        serviceType: "data",
        network,
        planCode: v.variation_code,
        name,
        priceKobo,
        active: true,
        syncedAt: startedAt,
      })
      .onConflictDoUpdate({
        target: [dataPlans.provider, dataPlans.network, dataPlans.planCode],
        set: { name, priceKobo, active: true, syncedAt: startedAt },
      });
    saved++;
  }
  // Plans VTpass no longer offers are hidden, never deleted (old orders point at them).
  await db
    .update(dataPlans)
    .set({ active: false })
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network), lt(dataPlans.syncedAt, startedAt)));
  return saved;
}

async function refreshIfStale(network: Network): Promise<void> {
  const [row] = await db
    .select({ last: max(dataPlans.syncedAt) })
    .from(dataPlans)
    .where(and(eq(dataPlans.provider, "vtpass"), eq(dataPlans.network, network)));
  const last = row?.last ? new Date(row.last).getTime() : 0;
  if (Date.now() - last < REFRESH_AFTER_MS) return;

  let running = syncing.get(network);
  if (!running) {
    running = syncDataPlans(network)
      .then(() => undefined)
      .finally(() => syncing.delete(network));
    syncing.set(network, running);
  }
  try {
    await running;
  } catch (err) {
    // Keep selling with the plans we already have; only fail if we have none.
    console.error(`[plans] refresh for ${network} failed:`, err);
    if (!last) throw err;
  }
}

export async function listDataPlans(network: Network): Promise<DataPlan[]> {
  await refreshIfStale(network);
  return db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .orderBy(asc(dataPlans.priceKobo));
}

export async function getActivePlan(planId: string, network: Network): Promise<DataPlan | undefined> {
  const [plan] = await db
    .select()
    .from(dataPlans)
    .where(and(eq(dataPlans.id, planId), eq(dataPlans.network, network), eq(dataPlans.active, true)))
    .limit(1);
  return plan;
}
