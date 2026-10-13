// One time Circle setup. Safe to run again: it only does what is missing.
//   1. Entity secret: create, register with Circle, save the recovery file
//   2. Wallet set: the container that holds every user wallet
// Writes CIRCLE_ENTITY_SECRET and CIRCLE_WALLET_SET_ID into backend/.env.
// Run with: npx tsx scripts/circle-setup.ts /path/to/recovery/folder
import { randomBytes } from "node:crypto";
import { appendFileSync, mkdirSync, readdirSync } from "node:fs";
import { config } from "dotenv";
import {
  initiateDeveloperControlledWalletsClient,
  registerEntitySecretCiphertext,
} from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

const apiKey = process.env.CIRCLE_API_KEY;
const recoveryDir = process.argv[2];

function save(key: string, value: string) {
  appendFileSync(".env", `${key}=${value}\n`);
  process.env[key] = value;
}

async function main() {
  if (!apiKey) throw new Error("CIRCLE_API_KEY is not set in backend/.env");
  if (!recoveryDir) throw new Error("Give the folder for the recovery file");

  if (!process.env.CIRCLE_ENTITY_SECRET) {
    mkdirSync(recoveryDir, { recursive: true, mode: 0o700 });
    const entitySecret = randomBytes(32).toString("hex");
    await registerEntitySecretCiphertext({
      apiKey,
      entitySecret,
      recoveryFileDownloadPath: recoveryDir,
    });
    save("CIRCLE_ENTITY_SECRET", entitySecret);
    console.log("Entity secret created and registered with Circle.");
    console.log(`Recovery file saved in ${recoveryDir}: ${readdirSync(recoveryDir).join(", ")}`);
  } else {
    console.log("Entity secret already set. Skipping.");
  }

  if (!process.env.CIRCLE_WALLET_SET_ID) {
    const client = initiateDeveloperControlledWalletsClient({
      apiKey,
      entitySecret: process.env.CIRCLE_ENTITY_SECRET!,
    });
    const res = await client.createWalletSet({ name: "dataonchain users" });
    const id = res.data?.walletSet?.id;
    if (!id) throw new Error("Circle did not return a wallet set id");
    save("CIRCLE_WALLET_SET_ID", id);
    console.log(`Wallet set created: ${id}`);
  } else {
    console.log("Wallet set already set. Skipping.");
  }
}

main().catch((err) => {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
  process.exit(1);
});
