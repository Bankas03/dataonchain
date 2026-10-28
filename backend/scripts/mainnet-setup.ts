// Arc mainnet setup with your LIVE Circle API key. Safe to run again.
//   1. Checks the entity secret works with the live key (registers a new one
//      for mainnet only if Circle refuses the current one)
//   2. Creates (or finds) the mainnet wallet set and treasury wallet on Arc
//   3. Read only checks: Circle Gateway mainnet gives a price for Arc -> Base,
//      and App Kit gives a swap price on Arc. No money moves.
// Everything is saved in backend/.env.mainnet (never committed). backend/.env
// stays on testnet for the tests.
// Run with: MAINNET_CIRCLE_API_KEY=LIVE_API_KEY:... npx tsx scripts/mainnet-setup.ts /path/to/recovery/folder
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { config } from "dotenv";
import {
  initiateDeveloperControlledWalletsClient,
  registerEntitySecretCiphertext,
} from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

const FILE = ".env.mainnet";
const apiKey = process.env.MAINNET_CIRCLE_API_KEY ?? "";
const recoveryDir = process.argv[2];

function uuidFrom(text: string): string {
  const h = createHash("sha256").update(text).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function readSaved(): Record<string, string> {
  if (!existsSync(FILE)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(FILE, "utf8").split("\n")) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]!] = m[2]!;
  }
  return out;
}

function writeSaved(values: Record<string, string>) {
  const lines = [
    "# Arc MAINNET settings for Render (made by setup/28). Never commit this file.",
    ...Object.entries(values).map(([k, v]) => `${k}=${v}`),
    "",
  ];
  writeFileSync(FILE, lines.join("\n"), { mode: 0o600 });
}

const detail = (err: unknown) => {
  const d = (err as { response?: { data?: unknown } }).response?.data;
  return `${err instanceof Error ? err.message : String(err)}${d ? ` ${JSON.stringify(d)}` : ""}`;
};

async function main() {
  if (!/^LIVE_API_KEY:/.test(apiKey)) throw new Error("MAINNET_CIRCLE_API_KEY must be your LIVE key (it starts with LIVE_API_KEY:)");
  if (!recoveryDir) throw new Error("Give the folder for a recovery file");
  const saved = readSaved();
  let entitySecret = saved.CIRCLE_ENTITY_SECRET || process.env.CIRCLE_ENTITY_SECRET || "";
  if (!entitySecret) throw new Error("No entity secret found in backend/.env");

  // 1 + 2. The wallet set proves the entity secret works with the live key
  const makeSet = async (secret: string) => {
    const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret: secret });
    const res = await client.createWalletSet({ name: "dataonchain users (mainnet)", idempotencyKey: uuidFrom("walletset:mainnet:dataonchain") } as Parameters<typeof client.createWalletSet>[0]);
    return res.data?.walletSet?.id;
  };
  let walletSetId: string | undefined = saved.CIRCLE_WALLET_SET_ID || undefined;
  if (!walletSetId) {
    try {
      walletSetId = await makeSet(entitySecret);
      console.log("Your entity secret works with the live key.");
    } catch (err) {
      const why = detail(err);
      if (!/entity ?secret|ciphertext/i.test(why)) throw new Error(`Circle refused the wallet set: ${why}`);
      console.log("Circle needs a separate entity secret for mainnet. Registering a new one...");
      mkdirSync(recoveryDir, { recursive: true, mode: 0o700 });
      entitySecret = randomBytes(32).toString("hex");
      await registerEntitySecretCiphertext({ apiKey, entitySecret, recoveryFileDownloadPath: recoveryDir });
      saved.CIRCLE_ENTITY_SECRET = entitySecret;
      saved.NEW_MAINNET_ENTITY_SECRET = "yes";
      writeSaved(saved);
      console.log(`New mainnet entity secret registered. Recovery file in ${recoveryDir}: ${readdirSync(recoveryDir).join(", ")}`);
      walletSetId = await makeSet(entitySecret);
    }
    if (!walletSetId) throw new Error("Circle did not return a wallet set id");
    saved.CIRCLE_WALLET_SET_ID = walletSetId;
  }
  if (!walletSetId) throw new Error("Circle did not return a wallet set id");
  saved.CIRCLE_ENTITY_SECRET = entitySecret;
  saved.CIRCLE_API_KEY = apiKey;
  saved.CIRCLE_BLOCKCHAIN = "ARC";
  saved.EXPLORER_TX_URL = "https://explorer.arc.io/tx/";
  writeSaved(saved);
  console.log(`Mainnet wallet set: ${walletSetId}`);

  const client = initiateDeveloperControlledWalletsClient({ apiKey, entitySecret });
  if (!saved.TREASURY_WALLET_ID || !saved.TREASURY_ADDRESS) {
    const res = await client.createWallets({
      walletSetId,
      blockchains: ["ARC" as "ARC-TESTNET"],
      count: 1,
      accountType: "EOA",
      idempotencyKey: uuidFrom(`treasury:${walletSetId}:ARC`),
    });
    const w = res.data?.wallets?.[0];
    if (!w?.id || !w.address) throw new Error("Circle did not return the mainnet treasury wallet");
    saved.TREASURY_WALLET_ID = w.id;
    saved.TREASURY_ADDRESS = w.address;
    writeSaved(saved);
  }
  console.log(`Mainnet treasury on Arc: ${saved.TREASURY_ADDRESS}`);

  // 3. Read only checks (no money moves)
  const est = await fetch("https://gateway-api.circle.com/v1/estimate?enableForwarder=true", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify([
      {
        spec: {
          version: 1,
          sourceDomain: 26,
          destinationDomain: 6,
          sourceContract: `0x${"77777777Dcc4d5A8B6E418Fd04D8997ef11000eE".toLowerCase().padStart(64, "0")}`,
          destinationContract: `0x${"2222222d7164433c4C09B0b0D809a9b52C04C205".toLowerCase().padStart(64, "0")}`,
          sourceToken: `0x${"3600000000000000000000000000000000000000".padStart(64, "0")}`,
          destinationToken: `0x${"833589fCD6eDb6E08f4c7C32D4f71b54bdA02913".toLowerCase().padStart(64, "0")}`,
          sourceDepositor: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          destinationRecipient: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          sourceSigner: `0x${saved.TREASURY_ADDRESS!.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`,
          destinationCaller: `0x${"0".repeat(64)}`,
          value: "1000000",
          salt: `0x${randomBytes(32).toString("hex")}`,
          hookData: "0x",
        },
      },
    ]),
    signal: AbortSignal.timeout(30_000),
  });
  const estText = await est.text();
  if (!est.ok) {
    // Not fatal: the bridge stays paused, and this is checked again before it opens
    console.log(`Note: Circle Gateway mainnet gave no price just now (${est.status} ${estText.slice(0, 200)}). The bridge stays paused; checked again before it opens.`);
  } else {
    const fee = Number((JSON.parse(estText) as { body?: { burnIntent?: { maxFee?: string } }[] }).body?.[0]?.burnIntent?.maxFee ?? NaN);
    console.log(`Circle Gateway mainnet works: sending 1 USDC from Arc to Base costs about ${(fee / 1e6).toFixed(4)} USDC.`);
  }

  try {
    const { AppKit } = await import("@circle-fin/app-kit");
    const { createCircleWalletsAdapter } = await import("@circle-fin/adapter-circle-wallets");
    const kit = new AppKit();
    const adapter = createCircleWalletsAdapter({ apiKey, entitySecret });
    const swap = (await kit.estimateSwap({
      from: { adapter, chain: "Arc", address: saved.TREASURY_ADDRESS },
      tokenIn: "USDC",
      tokenOut: "EURC",
      amountIn: "1",
      config: { apiKey, slippageBps: 100 },
    } as never)) as { estimatedOutput?: unknown };
    const out = swap.estimatedOutput as { amount?: string } | string | undefined;
    console.log(`App Kit swaps on Arc mainnet work: 1 USDC is about ${typeof out === "object" ? out?.amount : out} EURC right now.`);
  } catch (err) {
    console.log(`Note: App Kit gave no swap price on Arc mainnet just now (${detail(err).slice(0, 200)}). Swaps stay paused anyway; this is checked again before they open.`);
  }
  console.log("Mainnet setup done. Settings saved in backend/.env.mainnet");
}

main().catch((err) => {
  console.error(detail(err));
  process.exit(1);
});
