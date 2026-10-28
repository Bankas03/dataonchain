#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 29c: one real 1 USDC -> EURC swap on Arc mainnet, from
# your admin account's wallet, run on YOUR computer with the full error shown.
#   - If it works here, the problem is only on Render (its connection to Arc).
#   - If it fails, we see Circle App Kit's exact reason.
# Moves at most 1 USDC (into EURC, in your own wallet). Changes no files in the
# project and does not record the swap on the website.
# Run:  cd ~/dataonchain && bash setup/29c_swap_test.sh
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

echo "This swaps 1 USDC to EURC on Arc mainnet from the wallet of: $ADMIN"
read -r -p "Type SWAP to go ahead (anything else stops): " ans
[[ "$ans" == "SWAP" ]] || { echo "Stopped. Nothing happened."; exit 0; }

cd backend
cat > ./swap-test-tmp.mjs <<'JS'
import { readFileSync } from "node:fs";
import { inspect } from "node:util";
import { createClient } from "@libsql/client";
import { AppKit } from "@circle-fin/app-kit";
import { createCircleWalletsAdapter } from "@circle-fin/adapter-circle-wallets";

const env = Object.fromEntries(readFileSync(".env.mainnet", "utf8").split("\n").filter((l) => /^[A-Z0-9_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]));
const db = createClient({ url: process.env.PROD_URL, authToken: process.env.PROD_TOKEN });
const r = await db.execute({
  sql: "SELECT w.address FROM wallets w JOIN users u ON u.id = w.user_id WHERE lower(u.email) = ? AND w.blockchain = 'ARC' AND w.account_type = 'SCA' AND w.retired_at IS NULL LIMIT 1",
  args: [process.env.ADMIN],
});
const address = r.rows[0]?.address;
if (!address) { console.log("No Arc mainnet wallet found for", process.env.ADMIN); process.exit(1); }
console.log("Wallet:", address);

const rpc = async (method, params) => (await fetch("https://rpc.mainnet.arc.io", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) })).json();
const code = await rpc("eth_getCode", [address, "latest"]);
console.log("Smart wallet deployed on Arc:", code.result && code.result !== "0x" ? "yes" : "NO", "");

const kit = new AppKit();
const adapter = createCircleWalletsAdapter({ apiKey: env.CIRCLE_API_KEY, entitySecret: env.CIRCLE_ENTITY_SECRET });
const params = {
  from: { adapter, chain: "Arc", address },
  tokenIn: "USDC", tokenOut: "EURC", amountIn: "1",
  config: { apiKey: env.CIRCLE_API_KEY, slippageBps: 100, allowanceStrategy: "approve",
    customFee: { percentageBps: 50, recipientAddress: env.TREASURY_ADDRESS } },
};
const show = (label, err) => {
  console.log(`\n${label} FAILED:`);
  let text = inspect(err, { depth: 8, breakLength: 120 });
  for (const v of [env.CIRCLE_API_KEY, env.CIRCLE_ENTITY_SECRET]) if (v) text = text.split(v).join("***");
  console.log(text.replace(/(LIVE_API_KEY:)[^\s'"]+/g, "$1***").slice(0, 6000));
};
try {
  const est = await kit.estimateSwap(params);
  console.log("\nEstimate OK:", inspect(est, { depth: 4 }).slice(0, 1500));
} catch (err) { show("Estimate", err); process.exit(1); }
try {
  const res = await kit.swap(params);
  console.log("\nSWAP OK:", inspect(res, { depth: 5 }).slice(0, 3000));
} catch (err) { show("Swap", err); process.exit(1); }
JS
PROD_URL="$PROD_URL" PROD_TOKEN="$PROD_TOKEN" ADMIN="$ADMIN" node ./swap-test-tmp.mjs
code=$?
rm -f ./swap-test-tmp.mjs
echo
echo "Done (exit $code). Paste everything above to Claude (your key is hidden as ***)."
