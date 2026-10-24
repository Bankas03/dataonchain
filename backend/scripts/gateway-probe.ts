// Live check of the Circle Gateway bridge on testnet (development database):
//   1. fee estimates from Arc to every supported chain
//   2. safety rules: unapproved addresses and same chain transfers are refused
//   3. one real transfer: 0.5 USDC from an Arc Testnet smart wallet, through
//      Gateway with forwarding, to an approved smart wallet on Base Sepolia,
//      recorded step by step from the deposit to the mint
// The two probe wallets are kept (saved in backend/.env) and reused next time,
// so leftover test USDC is not wasted. The treasury tops them up when needed.
// Exit code 3 means the treasury needs more test USDC.
// Run with: npx tsx scripts/gateway-probe.ts
import { appendFileSync } from "node:fs";
import { asc, eq } from "drizzle-orm";
import { bridgeChains, chainByKey, feeCapMicro, homeChain } from "../src/bridge/chains";
import { buildSpec, estimate, gatewayBalanceMicro, newSalt } from "../src/bridge/gateway";
import { BridgeError, advanceTransfer, createTransfer } from "../src/bridge/service";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { approvedDestinations, bridgeEvents } from "../src/db/schema";
import { env } from "../src/env";
import { uuidFrom } from "../src/wallets/service";

const AMOUNT_MICRO = 500_000; // 0.5 USDC
const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function usdcOf(walletId: string) {
  const res = await circle.getWalletTokenBalance({ id: walletId });
  const b = (res.data?.tokenBalances ?? []).find((t) => t.token?.symbol?.toUpperCase().startsWith("USDC"));
  return { tokenId: b?.token?.id, micro: b ? Math.round(Number(b.amount) * 1_000_000) : 0 };
}

// A probe wallet kept in backend/.env, created once
async function probeWallet(name: string, blockchain: string) {
  const idKey = `GATEWAY_PROBE_${name}_WALLET_ID`;
  const addrKey = `GATEWAY_PROBE_${name}_ADDRESS`;
  if (process.env[idKey] && process.env[addrKey]) return { id: process.env[idKey]!, address: process.env[addrKey]! };
  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [blockchain as "ARC-TESTNET"],
    count: 1,
    accountType: "SCA",
    idempotencyKey: uuidFrom(`gateway-probe:${name}:${blockchain}:${env.CIRCLE_WALLET_SET_ID}`),
  });
  const w = res.data?.wallets?.[0];
  if (!w?.id || !w.address) throw new Error(`Circle did not create the ${name} probe wallet`);
  appendFileSync(".env", `\n# Gateway probe wallet (${name.toLowerCase()}, ${blockchain}): test only\n${idKey}=${w.id}\n${addrKey}=${w.address}\n`);
  process.env[idKey] = w.id;
  process.env[addrKey] = w.address;
  return { id: w.id, address: w.address };
}

async function sendFromTreasury(to: string, micro: number, tokenId: string) {
  const amount = show(micro);
  const res = await circle.createTransaction({
    walletId: env.TREASURY_WALLET_ID,
    tokenId,
    destinationAddress: to,
    amount: [amount],
    amounts: [amount],
    fee: { type: "level", config: { feeLevel: "MEDIUM" } },
    idempotencyKey: uuidFrom(`gateway-probe:fund:${to}:${Date.now()}`),
  } as unknown as Parameters<typeof circle.createTransaction>[0]);
  const id = res.data?.id;
  if (!id) throw new Error("Circle did not accept the funding transfer");
  for (let i = 0; i < 60; i++) {
    await sleep(3_000);
    const t = await circle.getTransaction({ id });
    const state = (t.data?.transaction as unknown as { state?: string } | undefined)?.state;
    if (state === "COMPLETE") return;
    if (state && ["FAILED", "DENIED", "CANCELLED"].includes(state)) throw new Error(`funding transfer ${state}`);
  }
  throw new Error("funding transfer did not complete");
}

async function main() {
  const arc = homeChain();
  const base = chainByKey("base");

  // 1. Fee estimates to every chain (no money moves)
  console.log(`Gateway API: ${env.GATEWAY_API_URL}`);
  const depositor = await probeWallet("DEPOSITOR", arc.circleBlockchain);
  const recipient = await probeWallet("RECIPIENT", base.circleBlockchain);
  console.log(`Probe depositor (Arc Testnet SCA): ${depositor.address}`);
  console.log(`Probe recipient (Base Sepolia SCA): ${recipient.address}`);
  console.log("\nFees from Arc Testnet for 0.5 USDC, with Circle forwarding:");
  for (const dest of bridgeChains().filter((c) => c.key !== arc.key)) {
    const spec = buildSpec({ source: arc, destination: dest, depositor: depositor.address, recipient: recipient.address, amountMicro: AMOUNT_MICRO, salt: newSalt() });
    const est = await estimate(spec, true);
    const cap = feeCapMicro(dest);
    const note = est.maxFeeMicro > cap ? `  ABOVE the ${show(cap)} cap: transfers there are refused until it drops` : `  (cap ${show(cap)})`;
    console.log(`  to ${dest.label.padEnd(18)} max fee ${show(est.maxFeeMicro)} USDC${est.forwardingFeeMicro !== null ? `, forwarding ${show(est.forwardingFeeMicro)}` : ""}${note}`);
    check(est.maxFeeMicro > 0, `Gateway quotes a fee to ${dest.label}`);
  }

  // 2. Safety rules
  await db
    .insert(approvedDestinations)
    .values({ label: "Gateway probe recipient (testnet)", chain: base.key, address: recipient.address.toLowerCase(), note: "created by scripts/gateway-probe.ts" })
    .onConflictDoNothing();
  try {
    await createTransfer({ direction: "OUT", depositorWalletId: depositor.id, depositorAddress: depositor.address, sourceChain: "arc", destinationChain: "base", recipientAddress: "0x000000000000000000000000000000000000dEaD", amountMicro: AMOUNT_MICRO });
    check(false, "an address that is not approved is refused");
  } catch (err) {
    check(err instanceof BridgeError && /approved/.test(err.message), "an address that is not approved is refused");
  }
  try {
    await createTransfer({ direction: "OUT", depositorWalletId: depositor.id, depositorAddress: depositor.address, sourceChain: "arc", destinationChain: "arc", recipientAddress: recipient.address, amountMicro: AMOUNT_MICRO });
    check(false, "a same chain transfer is refused");
  } catch (err) {
    check(err instanceof BridgeError, "a same chain transfer is refused");
  }

  // 3. Make sure the depositor can cover amount + the largest fee we allow
  const cap = feeCapMicro(base);
  const inGateway = await gatewayBalanceMicro(depositor.address, arc.domain);
  const inWallet = (await usdcOf(depositor.id)).micro;
  const want = AMOUNT_MICRO + cap;
  console.log(`\nProbe depositor: ${show(inWallet)} USDC in wallet, ${show(inGateway)} USDC in Gateway`);
  if (inGateway + inWallet < want) {
    const treasury = await usdcOf(env.TREASURY_WALLET_ID);
    const top = want - inGateway - inWallet + 20_000;
    if (!treasury.tokenId || treasury.micro < top + 50_000) {
      console.log(`NEEDS_FUNDING: treasury has ${show(treasury.micro)} USDC, needs ${show(top + 50_000)}`);
      process.exit(3);
    }
    console.log(`Topping up the probe depositor with ${show(top)} USDC from the treasury...`);
    await sendFromTreasury(depositor.address, top, treasury.tokenId);
  }

  // 4. The real transfer
  const recipientBefore = (await usdcOf(recipient.id)).micro;
  const transfer = await createTransfer({
    direction: "OUT",
    depositorWalletId: depositor.id,
    depositorAddress: depositor.address,
    sourceChain: "arc",
    destinationChain: "base",
    recipientAddress: recipient.address,
    amountMicro: AMOUNT_MICRO,
  });
  console.log(`\nBridge transfer ${transfer.id}: 0.5 USDC Arc Testnet -> Base Sepolia, max fee ${show(transfer.maxFeeMicro ?? 0)} USDC`);
  let t = transfer;
  let last = "";
  const started = Date.now();
  while (!["COMPLETE", "FAILED"].includes(t.status) && Date.now() - started < 15 * 60_000) {
    if (t.status !== last) {
      console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${t.status}`);
      last = t.status;
    }
    t = await advanceTransfer(t.id);
    if (t.status === last) await sleep(4_000);
  }
  console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${t.status}${t.failureReason ? `: ${t.failureReason}` : ""}`);
  check(t.status === "COMPLETE", `transfer complete (${Math.round((Date.now() - started) / 1000)} seconds)`);
  check(Boolean(t.mintTxHash), `mint on Base Sepolia recorded: ${base.explorerTx}${t.mintTxHash}`);

  let recipientAfter = recipientBefore;
  for (let i = 0; i < 30 && recipientAfter < recipientBefore + AMOUNT_MICRO; i++) {
    await sleep(3_000);
    recipientAfter = (await usdcOf(recipient.id)).micro;
  }
  check(recipientAfter - recipientBefore === AMOUNT_MICRO, `the recipient received exactly 0.5 USDC on Base Sepolia (${show(recipientBefore)} -> ${show(recipientAfter)})`);

  const steps = await db.select().from(bridgeEvents).where(eq(bridgeEvents.transferId, t.id)).orderBy(asc(bridgeEvents.createdAt));
  console.log("\nRecorded steps:");
  for (const s of steps) {
    console.log(`  ${s.createdAt.toLocaleTimeString("en-GB")}  ${s.step.padEnd(16)} ${s.chain ?? ""} ${s.txHash ?? ""}`);
  }
  const names = steps.map((s) => s.step);
  check(names.includes("finalized") && names.includes("signed") && names.includes("submitted") && names.includes("minted") && names.includes("complete"),
    "every step from Gateway balance to final mint is recorded");
  const leftover = await gatewayBalanceMicro(depositor.address, arc.domain);
  console.log(`\nProbe depositor keeps ${show(leftover)} USDC in Gateway for the next run.`);
}

main()
  .then(() => {
    console.log("All Gateway checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
