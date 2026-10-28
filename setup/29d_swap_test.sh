#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 29d: swap test, step 2 (run on YOUR computer)
#   1. Shows how much USDC your Arc wallet allows Circle's swap contract to use
#   2. Tries the 1 USDC -> EURC swap again and prints Arc's exact answer
#   3. If the allowance is missing: approves exactly 1 USDC for Circle's swap
#      contract (gas is sponsored), then tries the 1 USDC -> EURC swap again
# Moves at most 1 USDC (into EURC, in your own wallet). Changes no project files.
# Run:  cd ~/dataonchain && bash setup/29d_swap_test.sh
# =============================================================================
set -uo pipefail
red() { printf '\033[31m%s\033[0m\n' "$*"; }
fail() { red "ERROR: $*"; exit 1; }
export PATH="$HOME/.turso:$PATH"
[[ -f backend/.env.mainnet ]] || fail "Run from ~/dataonchain (backend/.env.mainnet not found)"
ADMIN="$(grep -E '^ADMIN_EMAIL=' backend/.env | tail -n1 | cut -d= -f2- | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ -n "$ADMIN" ]] || fail "ADMIN_EMAIL not found in backend/.env"
PROD_URL="$(turso db show dataonchainprod --url 2>/dev/null | tr -d '[:space:]')"
[[ "$PROD_URL" == libsql://* ]] || fail "Could not find the live database (turso auth login --headless, then run again)"
PROD_TOKEN="$(turso db tokens create dataonchainprod --expiration 1d | tr -d '[:space:]')"
[[ "$PROD_TOKEN" == eyJ* ]] || fail "Could not create a database token"

echo "Wallet of: $ADMIN. This may approve 1 USDC for Circle's swap contract and swap 1 USDC to EURC."
read -r -p "Type SWAP to go ahead (anything else stops): " ans
[[ "$ans" == "SWAP" ]] || { echo "Stopped. Nothing happened."; exit 0; }

cd backend
cat > ./swap-test-tmp.mjs <<'JS'
import { readFileSync } from "node:fs";
import { createClient } from "@libsql/client";
import { AppKit } from "@circle-fin/app-kit";
import { createCircleWalletsAdapter } from "@circle-fin/adapter-circle-wallets";
import { initiateDeveloperControlledWalletsClient } from "@circle-fin/developer-controlled-wallets";

const env = Object.fromEntries(readFileSync(".env.mainnet", "utf8").split("\n").filter((l) => /^[A-Z0-9_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]));
const hide = (t) => { let s = String(t); for (const v of [env.CIRCLE_API_KEY, env.CIRCLE_ENTITY_SECRET]) if (v) s = s.split(v).join("***"); return s.replace(/0x[0-9a-fA-F]{200,}/g, (m) => `${m.slice(0, 20)}...(${m.length} chars)`); };
const db = createClient({ url: process.env.PROD_URL, authToken: process.env.PROD_TOKEN });
const r = await db.execute({
  sql: "SELECT w.address, w.circle_wallet_id FROM wallets w JOIN users u ON u.id = w.user_id WHERE lower(u.email) = ? AND w.blockchain = 'ARC' AND w.account_type = 'SCA' AND w.retired_at IS NULL LIMIT 1",
  args: [process.env.ADMIN],
});
const address = r.rows[0]?.address, walletId = r.rows[0]?.circle_wallet_id;
if (!address) { console.log("No Arc mainnet wallet found"); process.exit(1); }
console.log("Wallet:", address);

const USDC = "0x3600000000000000000000000000000000000000";
const SWAP_CONTRACT = "0x7FB8c7260b63934d8da38aF902f87ae6e284a845"; // App Kit's adapter contract on Arc
const rpc = async (method, params) => (await fetch("https://rpc.mainnet.arc.io", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) })).json();
const pad = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const allowance = async () => {
  const res = await rpc("eth_call", [{ to: USDC, data: "0xdd62ed3e" + pad(address) + pad(SWAP_CONTRACT) }, "latest"]);
  return res.result ? Number(BigInt(res.result)) / 1e6 : `error ${JSON.stringify(res.error)}`;
};
const balance = async () => {
  const res = await rpc("eth_call", [{ to: USDC, data: "0x70a08231" + pad(address) }, "latest"]);
  return res.result ? Number(BigInt(res.result)) / 1e6 : "?";
};
console.log("USDC balance (Arc):", await balance());
let allowed = await allowance();
console.log("USDC allowed for the swap contract:", allowed);

const params = (fresh) => ({
  from: { adapter: fresh, chain: "Arc", address },
  tokenIn: "USDC", tokenOut: "EURC", amountIn: "1",
  config: { apiKey: env.CIRCLE_API_KEY, slippageBps: 100, allowanceStrategy: "approve",
    customFee: { percentageBps: 50, recipientAddress: env.TREASURY_ADDRESS } },
});
const describe = (err) => {
  const lines = [`${err?.name ?? "Error"}: ${err?.message}`];
  let e = err?.cause?.trace?.rawError ?? err?.cause;
  for (let i = 0; e && i < 6; i++, e = e.cause) {
    lines.push(`  -> ${e.name ?? ""} code=${e.code ?? ""} ${e.shortMessage ?? e.message ?? ""}`.slice(0, 600));
    if (e.details) lines.push(`     details: ${e.details}`.slice(0, 600));
    if (e.metaMessages) lines.push(`     ${e.metaMessages.join(" | ")}`.slice(0, 600));
  }
  return hide(lines.join("\n"));
};
const kit = new AppKit();
const adapter = createCircleWalletsAdapter({ apiKey: env.CIRCLE_API_KEY, entitySecret: env.CIRCLE_ENTITY_SECRET });

const est = await kit.estimateSwap(params(adapter));
console.log("Estimate OK: about", est.estimatedOutput?.amount, "EURC, at least", est.stopLimit?.amount);
try {
  await kit.swap(params(adapter));
  console.log("\nSWAP OK on the first try (nothing else needed).");
  console.log("EURC now: see your wallet on the dashboard.");
  process.exit(0);
} catch (err) {
  console.log("\nSwap failed as before:\n" + describe(err));
}

if (typeof allowed === "number" && allowed < 1) {
  console.log("\nApproving exactly 1 USDC for the swap contract (gas sponsored)...");
  const circle = initiateDeveloperControlledWalletsClient({ apiKey: env.CIRCLE_API_KEY, entitySecret: env.CIRCLE_ENTITY_SECRET });
  const tx = await circle.createContractExecutionTransaction({
    walletId, contractAddress: USDC, abiFunctionSignature: "approve(address,uint256)",
    abiParameters: [SWAP_CONTRACT, "1000000"], fee: { type: "level", config: { feeLevel: "MEDIUM" } },
  });
  const id = tx.data?.id;
  for (let i = 0; i < 60; i++) {
    await new Promise((s) => setTimeout(s, 3000));
    const t = (await circle.getTransaction({ id })).data?.transaction;
    if (t?.state === "COMPLETE") { console.log("Approved:", `https://explorer.arc.io/tx/${t.txHash}`); break; }
    if (["FAILED", "DENIED", "CANCELLED"].includes(t?.state)) { console.log("Approve", t.state, t.errorReason ?? ""); process.exit(1); }
  }
  console.log("USDC allowed now:", await allowance());
  try {
    const res = await kit.swap(params(createCircleWalletsAdapter({ apiKey: env.CIRCLE_API_KEY, entitySecret: env.CIRCLE_ENTITY_SECRET })));
    console.log("\nSWAP OK after the approval:", res.txHash ? `https://explorer.arc.io/tx/${res.txHash}` : hide(JSON.stringify(res).slice(0, 800)));
  } catch (err) {
    console.log("\nSwap still failed after the approval:\n" + describe(err));
  }
} else {
  console.log("\nThe allowance was already there, so it is not the cause. Not approving anything.");
}
console.log("USDC balance now:", await balance());
JS
PROD_URL="$PROD_URL" PROD_TOKEN="$PROD_TOKEN" ADMIN="$ADMIN" node ./swap-test-tmp.mjs
code=$?
rm -f ./swap-test-tmp.mjs
echo
echo "Done (exit $code). Paste everything above to Claude."
