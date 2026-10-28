// Own wallets on other networks, on testnet and the development database:
//   1. a test user sends 0.2 USDC from Arc to their OWN new wallet on Base Sepolia
//   2. the dashboard balance for Base Sepolia shows it, and our transfer fee
//      (BRIDGE_NETWORK_FEE_USDC) went from their Arc wallet to the treasury
//   also: only the networks in BRIDGE_CHAINS are offered, and the admin can
//   still use the bridge while it is paused (nobody else can)
//   3. (optional, about 20 minutes) "Move to Arc" brings it back to their Arc wallet
// Exit code 3 means the treasury needs more test USDC.
// Run with: BRIDGE_ENABLED=true BRIDGE_MIN_USDC=0.1 BRIDGE_CHAINS=arc,base PAUSE_BYPASS_EMAILS=tester@example.com \
//   npx tsx scripts/bridge-own-smoke.ts [--with-return]
import { randomUUID } from "node:crypto";
import { eq, inArray } from "drizzle-orm";
import { circle } from "../src/circle/client";
import { db } from "../src/db";
import { appSettings, auditLogs, bridgeEvents, bridgeTransfers, ledgerEntries, users, walletSweeps, wallets } from "../src/db/schema";
import { env } from "../src/env";
import { BridgeUserError, chainBalances, driving, getBridgeView, listDestinations, returnToArc, startBridge } from "../src/bridge/user";
import { usdcMicroOf } from "../src/bridge/wallets";
import { advanceNetworkFee, networkFeeMicro } from "../src/bridge/fees";
import { getPauses, pausedMessage, setPause } from "../src/settings";
import { ensureUserWallet, uuidFrom } from "../src/wallets/service";

const show = (micro: number) => (micro / 1_000_000).toFixed(6);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FUND_MICRO = 400_000;
const withReturn = process.argv.includes("--with-return");

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function waitDone(userId: string, id: string, minutes: number) {
  let view = await getBridgeView(userId, id);
  let last = "";
  const t0 = Date.now();
  while (view && !["COMPLETE", "FAILED"].includes(view.status) && Date.now() - t0 < minutes * 60_000) {
    if (view.status !== last) {
      console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view.status}`);
      last = view.status;
    }
    await sleep(5_000);
    view = await getBridgeView(userId, id);
  }
  console.log(`  ${new Date().toLocaleTimeString("en-GB")}  ${view?.status}${view?.failureReason ? `: ${view.failureReason}` : ""}`);
  return { view, seconds: Math.round((Date.now() - t0) / 1000) };
}

async function main() {
  if (!env.BRIDGE_ENABLED) throw new Error("Run with BRIDGE_ENABLED=true");
  const treasuryRes = await circle.getWalletTokenBalance({ id: env.TREASURY_WALLET_ID });
  const t = (treasuryRes.data?.tokenBalances ?? []).find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  const treasuryMicro = t ? Math.round(Number(t.amount) * 1e6) : 0;
  if (!t?.token?.id || treasuryMicro < FUND_MICRO + 100_000) {
    console.log(`NEEDS_FUNDING: treasury has ${show(treasuryMicro)} USDC`);
    process.exit(3);
  }

  const userId = randomUUID();
  await db.insert(users).values({ id: userId, name: "Own Wallet Smoke Test", email: `ownsmoke+${Date.now()}@example.com`, emailVerified: true, phone: "+2348011111111" });
  const ids: string[] = [];
  try {
    const dests = await listDestinations();
    check(dests.some((d) => d.id === "own:base" && d.own), "users can choose their own wallet on Base Sepolia");
    if (env.BRIDGE_CHAINS.join(",") === "arc,base") {
      check(dests.every((d) => d.chain === "base"), "only Base is offered when BRIDGE_CHAINS=arc,base", dests.map((d) => d.chain));
      try {
        await returnToArc(userId, { chain: "polygon" });
        check(false, "a network that is not open is refused");
      } catch (err) {
        check(err instanceof BridgeUserError && err.status === 404, "a network that is not open is refused");
      }
    }

    // The admin (PAUSE_BYPASS_EMAILS) can still use a paused bridge for live checks
    if (env.PAUSE_BYPASS_EMAILS.includes("tester@example.com")) {
      const was = (await getPauses()).bridgePaused;
      try {
        await setPause("bridgePaused", true);
        check((await pausedMessage("bridgePaused", "Tester@Example.com")) === null, "the admin can use the bridge while it is paused");
        check((await pausedMessage("bridgePaused", "someone@example.com")) !== null, "everyone else sees the paused message");
        check((await pausedMessage("purchasesPaused", "tester@example.com")) === (await pausedMessage("purchasesPaused", "someone@example.com")),
          "the bypass never opens buying airtime and data");
      } finally {
        await setPause("bridgePaused", was);
        if (!was) await db.delete(appSettings).where(eq(appSettings.key, "bridgePaused"));
      }
    }

    const arc = await ensureUserWallet(userId);
    console.log(`Funding the test user's Arc wallet with ${show(FUND_MICRO)} USDC from the treasury...`);
    const res = await circle.createTransaction({
      walletId: env.TREASURY_WALLET_ID,
      tokenId: t.token.id,
      destinationAddress: arc.address,
      amount: [show(FUND_MICRO)],
      amounts: [show(FUND_MICRO)],
      fee: { type: "level", config: { feeLevel: "MEDIUM" } },
      idempotencyKey: uuidFrom(`own-smoke:fund:${userId}`),
    } as unknown as Parameters<typeof circle.createTransaction>[0]);
    for (let i = 0; i < 60; i++) {
      await sleep(3_000);
      const tx = await circle.getTransaction({ id: res.data?.id ?? "" });
      if ((tx.data?.transaction as unknown as { state?: string })?.state === "COMPLETE") break;
    }
    check((await usdcMicroOf(arc.circleWalletId)) >= FUND_MICRO, "test Arc wallet funded");

    // 1. Arc -> own wallet on Base Sepolia
    const out = await startBridge(userId, { destinationId: "own:base", amount: "0.2" });
    check(Boolean(out?.id) && out?.destinationLabel === "Your wallet", "transfer to their own Base Sepolia wallet started");
    ids.push(out!.id);
    const sent = await waitDone(userId, out!.id, 15);
    check(sent.view?.status === "COMPLETE", `arrived on Base Sepolia in ${sent.seconds} seconds (${sent.view?.mintUrl})`);

    // 2. The dashboard shows it
    let base = (await chainBalances(userId)).find((w) => w.chain === "base");
    for (let i = 0; i < 20 && Number(base?.balance ?? 0) < 0.2; i++) {
      await sleep(3_000);
      base = (await chainBalances(userId)).find((w) => w.chain === "base");
    }
    check(base?.balance === "0.200000", `the dashboard shows 0.2 USDC on Base Sepolia (${base?.address})`);

    // Our transfer fee: from the test user's Arc wallet to the treasury
    const fee = networkFeeMicro();
    if (fee > 0) {
      let row = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      for (let i = 0; i < 40 && row?.networkFeeStatus !== "COMPLETE" && row?.networkFeeStatus !== "FAILED"; i++) {
        await advanceNetworkFee(out!.id);
        await sleep(3_000);
        row = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      }
      check(row?.networkFeeStatus === "COMPLETE" && Boolean(row.networkFeeTxHash) && row.networkFeeMicro === fee,
        `our transfer fee of ${show(fee)} USDC went to the treasury (${env.EXPLORER_TX_URL}${row?.networkFeeTxHash ?? ""})`,
        { status: row?.networkFeeStatus, micro: row?.networkFeeMicro });
      await advanceNetworkFee(out!.id);
      const again = (await db.select().from(bridgeTransfers).where(eq(bridgeTransfers.id, out!.id)))[0];
      check(again?.networkFeeTxId === row?.networkFeeTxId, "the fee is never taken twice");
    }

    // 3. Move it back to Arc (Base Sepolia deposits wait for full finality: about 20 minutes)
    if (withReturn) {
      const arcBefore = await usdcMicroOf(arc.circleWalletId);
      const back = await returnToArc(userId, { chain: "base" });
      check(Boolean(back?.id) && back?.direction === "IN", `"Move to Arc" started: ${back?.amount} USDC after Circle's fee`);
      ids.push(back!.id);
      console.log("Waiting for Base Sepolia finality (up to about 20 minutes)...");
      const home = await waitDone(userId, back!.id, 40);
      check(home.view?.status === "COMPLETE", `back on Arc in ${Math.round(home.seconds / 60)} minutes (${home.view?.mintUrl})`);
      let arcAfter = arcBefore;
      const expected = Math.round(Number(back!.amount) * 1e6);
      for (let i = 0; i < 20 && arcAfter < arcBefore + expected; i++) {
        await sleep(3_000);
        arcAfter = await usdcMicroOf(arc.circleWalletId);
      }
      check(arcAfter - arcBefore === expected, `the Arc wallet received exactly ${back!.amount} USDC`);
    } else {
      console.log("Skipped the 20 minute Move to Arc test.");
    }

    try {
      await returnToArc(userId, { chain: "polygon" });
      check(false, "moving from a network with no USDC is refused");
    } catch (err) {
      check(err instanceof BridgeUserError, "moving from a network with no USDC is refused");
    }
  } finally {
    for (const id of ids) while (driving.has(id)) await sleep(1_000);
    const ts = (await db.select({ id: bridgeTransfers.id }).from(bridgeTransfers).where(eq(bridgeTransfers.userId, userId))).map((r) => r.id);
    if (ts.length) {
      await db.delete(bridgeEvents).where(inArray(bridgeEvents.transferId, ts));
      await db.delete(auditLogs).where(inArray(auditLogs.targetId, ts));
      await db.delete(bridgeTransfers).where(inArray(bridgeTransfers.id, ts));
    }
    const journals = (await db.select({ j: ledgerEntries.journalId }).from(ledgerEntries).where(eq(ledgerEntries.account, `customer:${userId}`))).map((r) => r.j);
    if (journals.length) await db.delete(ledgerEntries).where(inArray(ledgerEntries.journalId, journals));
    const ws = (await db.select({ id: wallets.id }).from(wallets).where(eq(wallets.userId, userId))).map((w) => w.id);
    if (ws.length) await db.delete(walletSweeps).where(inArray(walletSweeps.fromWalletId, ws));
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All own wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
