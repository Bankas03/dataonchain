// Read only report: how far the upgrade to smart contract wallets has got.
// Changes nothing. Point it at production with TURSO_DATABASE_URL and TURSO_AUTH_TOKEN.
// Run with: npx tsx scripts/wallets-report.ts
import { desc } from "drizzle-orm";
import { db } from "../src/db";
import { walletSweeps, wallets } from "../src/db/schema";

async function main() {
  const all = await db.select().from(wallets);
  const sca = all.filter((w) => w.accountType === "SCA").length;
  const oldActive = all.filter((w) => w.accountType === "EOA" && !w.retiredAt).length;
  const retired = all.filter((w) => w.accountType === "EOA" && w.retiredAt).length;
  console.log(`Smart (SCA) wallets: ${sca}`);
  console.log(`Old wallets still to upgrade: ${oldActive}`);
  console.log(`Old wallets retired (USDC swept to the new wallet): ${retired}`);

  const sweeps = await db.select().from(walletSweeps).orderBy(desc(walletSweeps.createdAt)).limit(20);
  if (sweeps.length === 0) {
    console.log("No USDC moves yet (old wallets with less than 0.02 USDC are not moved).");
    return;
  }
  console.log("\nLatest USDC moves from old wallets:");
  for (const s of sweeps) {
    console.log(`  ${(s.amountMicro / 1_000_000).toFixed(6)} USDC -> ${s.toAddress}  ${s.status}${s.txHash ? `  ${s.txHash}` : ""}${s.lastError ? `  (${s.lastError})` : ""}`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
