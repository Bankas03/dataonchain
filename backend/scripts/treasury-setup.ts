// Creates the platform treasury wallet on Circle (once) and saves it in backend/.env.
// Safe to run again: the same idempotency key always returns the same wallet.
// Run with: npx tsx scripts/treasury-setup.ts
import { createHash } from "node:crypto";
import { appendFileSync } from "node:fs";
import { config } from "dotenv";
import { initiateDeveloperControlledWalletsClient } from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function main() {
  if (process.env.TREASURY_WALLET_ID && process.env.TREASURY_ADDRESS) {
    console.log(`Treasury already set: ${process.env.TREASURY_ADDRESS}`);
    return;
  }
  const apiKey = process.env.CIRCLE_API_KEY;
  const entitySecret = process.env.CIRCLE_ENTITY_SECRET;
  const walletSetId = process.env.CIRCLE_WALLET_SET_ID;
  const blockchain = process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET";
  if (!apiKey || !entitySecret || !walletSetId) throw new Error("Circle settings missing in backend/.env");

  const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });
  const res = await client.createWallets({
    walletSetId,
    blockchains: [blockchain as "ARC-TESTNET"],
    count: 1,
    accountType: "EOA",
    idempotencyKey: uuidFrom(`treasury:${walletSetId}:${blockchain}`),
  });
  const wallet = res.data?.wallets?.[0];
  if (!wallet?.id || !wallet.address) throw new Error("Circle did not return the treasury wallet");
  appendFileSync(".env", `\n# Treasury (customer payments arrive here)\nTREASURY_WALLET_ID=${wallet.id}\nTREASURY_ADDRESS=${wallet.address}\n`);
  console.log(`Treasury wallet created: ${wallet.address}`);
}

main().catch((err) => {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
  process.exit(1);
});
