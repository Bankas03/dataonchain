// Creates a wallet for a temporary test user on Circle (testnet),
// checks it is reused on the second call, reads the balance, then removes
// the test user from the database. The empty testnet wallet stays on Circle.
// Run with: npx tsx scripts/wallet-smoke.ts
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { users, wallets } from "../src/db/schema";
import { ensureUserWallet, getUsdcBalance } from "../src/wallets/service";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  const userId = randomUUID();
  await db.insert(users).values({
    id: userId,
    name: "Wallet Smoke Test",
    email: `walletsmoke+${Date.now()}@example.com`,
    emailVerified: true,
    phone: "+2348012345678",
  });

  try {
    const first = await ensureUserWallet(userId);
    check(/^0x[0-9a-fA-F]{40}$/.test(first.address), "a wallet with a valid address was created", first);

    const second = await ensureUserWallet(userId);
    check(second.id === first.id && second.address === first.address, "the same wallet is reused, never a second one");

    const balance = await getUsdcBalance(first.circleWalletId);
    check(!Number.isNaN(Number(balance)), `the USDC balance can be read (${balance})`);
  } finally {
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
