// Read only: the latest bridge transfers and swaps on the database you point it
// at (the live one in setup/29), to check the live mainnet tests. Changes nothing.
// Run with: TURSO_DATABASE_URL=... TURSO_AUTH_TOKEN=... npx tsx scripts/live-report.ts
import { desc } from "drizzle-orm";
import { db } from "../src/db";
import { bridgeTransfers, swaps } from "../src/db/schema";
import { chainByKey } from "../src/bridge/chains";
import { getPauses } from "../src/settings";

const usdc = (micro: number | null) => (micro === null ? "-" : (micro / 1_000_000).toFixed(6));
const when = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos" });
const label = (key: string) => {
  try {
    return chainByKey(key).label;
  } catch {
    return key;
  }
};

async function main() {
  const p = await getPauses();
  console.log(`Paused for users: bridge ${p.bridgePaused ? "yes" : "no"}, swaps ${p.swapPaused ? "yes" : "no"}, buying ${p.purchasesPaused ? "yes" : "no"}`);

  const ts = await db.select().from(bridgeTransfers).orderBy(desc(bridgeTransfers.createdAt)).limit(10);
  console.log(`\nLatest transfers (${ts.length}):`);
  for (const t of ts) {
    console.log(`  ${when(t.createdAt)}  ${t.status.padEnd(9)} ${usdc(t.amountMicro)} USDC ${label(t.sourceChain)} -> ${label(t.destinationChain)}`);
    console.log(`      Circle fee (max) ${usdc(t.maxFeeMicro)}, our fee ${usdc(t.networkFeeMicro)} (${t.networkFeeStatus ?? "none"})${t.failureReason ? `, reason: ${t.failureReason}` : ""}`);
    if (t.mintTxHash) console.log(`      mint ${chainByKey(t.destinationChain).explorerTx}${t.mintTxHash}`);
    if (t.networkFeeTxHash) console.log(`      fee  ${chainByKey("arc").explorerTx}${t.networkFeeTxHash}`);
  }

  const ss = await db.select().from(swaps).orderBy(desc(swaps.createdAt)).limit(10);
  console.log(`\nLatest swaps (${ss.length}):`);
  for (const s of ss) {
    console.log(`  ${when(s.createdAt)}  ${s.status.padEnd(9)} ${s.amountIn} ${s.tokenIn} -> ${s.amountOut ?? "?"} ${s.tokenOut}${s.txHash ? `  ${chainByKey("arc").explorerTx}${s.txHash}` : ""}`);
    if (s.error) console.log(`      ${s.error.slice(0, 200)}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
