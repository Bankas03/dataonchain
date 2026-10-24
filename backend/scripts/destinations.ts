// Manage the approved bridge destinations (the only addresses USDC may be sent to).
// Run through setup/destinations.sh, which points it at the right database:
//   list
//   add <chain> <address> <label...>
//   disable <address>
//   enable <address>
import { and, eq } from "drizzle-orm";
import { bridgeChains, chainByKey, isEvmAddress } from "../src/bridge/chains";
import { db } from "../src/db";
import { approvedDestinations, auditLogs } from "../src/db/schema";

async function list() {
  const rows = await db.select().from(approvedDestinations);
  if (rows.length === 0) {
    console.log("No approved destinations yet.");
    return;
  }
  for (const r of rows) {
    console.log(`${r.active ? "ACTIVE  " : "disabled"}  ${chainByKey(r.chain).label.padEnd(18)} ${r.address}  ${r.label}`);
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === "list" || !command) return list();

  if (command === "add") {
    const [chain, address, ...labelParts] = args;
    const label = labelParts.join(" ").trim();
    const keys = bridgeChains().map((c) => c.key).filter((k) => k !== "arc");
    if (!chain || !keys.includes(chain)) throw new Error(`Chain must be one of: ${keys.join(", ")}`);
    if (!address || !isEvmAddress(address)) throw new Error("Address must look like 0x followed by 40 letters and numbers");
    if (!label) throw new Error("Give a label, for example: Acme VTU");
    await db
      .insert(approvedDestinations)
      .values({ label, chain, address: address.toLowerCase(), note: "added with setup/destinations.sh" })
      .onConflictDoUpdate({ target: [approvedDestinations.chain, approvedDestinations.address], set: { label, active: true } });
    await db.insert(auditLogs).values({ actorType: "admin", action: "bridge.destination_added", targetType: "address", targetId: address.toLowerCase(), details: { chain, label } });
    console.log(`Approved: ${label} on ${chainByKey(chain).label} (${address})`);
    return list();
  }

  if (command === "disable" || command === "enable") {
    const [address] = args;
    if (!address || !isEvmAddress(address)) throw new Error("Give the address to " + command);
    const rows = await db
      .update(approvedDestinations)
      .set({ active: command === "enable" })
      .where(and(eq(approvedDestinations.address, address.toLowerCase())))
      .returning();
    if (rows.length === 0) throw new Error("That address is not in the list");
    await db.insert(auditLogs).values({ actorType: "admin", action: `bridge.destination_${command}d`, targetType: "address", targetId: address.toLowerCase(), details: null });
    console.log(`${command === "enable" ? "Enabled" : "Disabled"}: ${address}`);
    return list();
  }

  throw new Error(`Unknown command "${command}". Use list, add, disable or enable.`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
