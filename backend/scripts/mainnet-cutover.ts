// Moving the live database from Arc Testnet to Arc mainnet.
//   pause: closes buying, bridge and swaps (users see "coming soon")
//   clear: removes the test network activity (orders, payments, transfers,
//          swaps, test wallets, test provider addresses). Accounts, logins,
//          data plans, exchange rates and admin settings stay.
// Only runs against the production database (dataonchainprod), and "clear"
// needs --yes-clear-testnet-data. Make the archive copy first (setup/28 does).
// Run with: TURSO_DATABASE_URL=... TURSO_AUTH_TOKEN=... npx tsx scripts/mainnet-cutover.ts pause|clear [--yes-clear-testnet-data]
import { createClient } from "@libsql/client";

const url = process.env.TURSO_DATABASE_URL ?? "";
const mode = process.argv[2];

const TESTNET_CHAINS = ["ARC-TESTNET", "BASE-SEPOLIA", "ARB-SEPOLIA", "ETH-SEPOLIA", "AVAX-FUJI", "OP-SEPOLIA", "MATIC-AMOY", "UNI-SEPOLIA"];

// Children before parents, so links between tables never break
const CLEAR: { table: string; where?: string }[] = [
  { table: "bridge_events" },
  { table: "bridge_transfers" },
  { table: "refunds" },
  { table: "vtu_transactions" },
  { table: "ledger_entries" },
  { table: "payments" },
  { table: "orders" },
  { table: "swaps" },
  { table: "wallet_sweeps" },
  { table: "webhook_events" },
  { table: "treasury_movements" },
  { table: "approved_destinations" },
  { table: "audit_logs", where: "actor_type <> 'admin'" },
  { table: "wallets", where: `blockchain IN (${TESTNET_CHAINS.map((c) => `'${c}'`).join(", ")})` },
];

async function main() {
  if (!/dataonchainprod/.test(url)) throw new Error("This only runs against the production database (dataonchainprod).");
  const db = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
  try {
    if (mode === "pause") {
      for (const key of ["purchasesPaused", "bridgePaused", "swapPaused"]) {
        await db.execute({
          sql: "INSERT INTO app_settings (key, value, updated_at) VALUES (?, 'true', ?) ON CONFLICT(key) DO UPDATE SET value = 'true', updated_at = excluded.updated_at",
          args: [key, Date.now()],
        });
      }
      console.log("Buying, bridge and swaps are paused (users see 'coming soon').");
      return;
    }
    if (mode !== "clear") throw new Error("Choose pause or clear");
    if (!process.argv.includes("--yes-clear-testnet-data")) throw new Error("Add --yes-clear-testnet-data to confirm");

    const before: Record<string, number> = {};
    for (const c of CLEAR) {
      const r = await db.execute(`SELECT count(*) AS n FROM ${c.table}${c.where ? ` WHERE ${c.where}` : ""}`);
      before[c.table] = Number(r.rows[0]?.n ?? 0);
    }
    // One batch: all of it is removed, or nothing is
    await db.batch(
      CLEAR.map((c) => `DELETE FROM ${c.table}${c.where ? ` WHERE ${c.where}` : ""}`),
      "write",
    );
    for (const c of CLEAR) console.log(`  ${c.table}: removed ${before[c.table]}`);
    const users = await db.execute("SELECT count(*) AS n FROM users");
    console.log(`Test network activity removed. ${users.rows[0]?.n} user account(s) kept; each gets a new mainnet wallet on next login.`);
  } finally {
    db.close();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
