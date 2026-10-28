#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 29b: why do swaps fail on Arc mainnet? (read only)
#   Finds which Arc mainnet RPC address Circle App Kit uses, and tests it and
#   Arc's other public RPC addresses. Moves no money, changes no files.
# Run:  cd ~/dataonchain && bash setup/29b_swap_probe.sh
# =============================================================================
set -uo pipefail
cd backend || { echo "Run from ~/dataonchain"; exit 1; }
echo "==> Package versions"
for p in app-kit adapter-circle-wallets; do
  node -e "console.log('@circle-fin/$p', require('./node_modules/@circle-fin/$p/package.json').version)" 2>/dev/null || echo "@circle-fin/$p not found"
done

echo
echo "==> Arc mainnet in App Kit (chain id 5042)"
cat > /tmp/dataonchain-probe.mjs <<'JS'
const mods = ["@circle-fin/app-kit", "@circle-fin/adapter-circle-wallets"];
const seen = new Set();
function walk(obj, path, depth) {
  if (!obj || typeof obj !== "object" || depth > 3 || seen.has(obj)) return;
  seen.add(obj);
  if ((obj.chainId === 5042 || obj.id === 5042) && !String(path).includes("Testnet")) {
    console.log(path, JSON.stringify(obj, (k, v) => (typeof v === "bigint" ? String(v) : typeof v === "function" ? "[fn]" : v), 1).slice(0, 1500));
  }
  for (const k of Object.keys(obj)) {
    try { walk(obj[k], `${path}.${k}`, depth + 1); } catch {}
  }
}
for (const m of mods) {
  try { const mod = await import(m); walk(mod, m, 0); } catch (e) { console.log(m, "could not load:", e.message); }
}
JS
cp /tmp/dataonchain-probe.mjs ./probe-tmp.mjs && node ./probe-tmp.mjs; rm -f ./probe-tmp.mjs

echo
echo "==> Arc RPC addresses written inside the packages"
grep -rhoE 'https://[a-zA-Z0-9./_-]*arc[a-zA-Z0-9./_-]*' node_modules/@circle-fin 2>/dev/null | grep -iv 'testnet\|docs\|explorer\|github' | sort -u | head -20

echo
echo "==> Testing Arc mainnet RPC addresses"
for url in $(grep -rhoE 'https://[a-zA-Z0-9./_-]*arc[a-zA-Z0-9./_-]*' node_modules/@circle-fin 2>/dev/null | grep -i 'rpc' | grep -iv 'testnet' | sort -u) \
           https://rpc.mainnet.arc.io https://rpc.blockdaemon.mainnet.arc.io https://rpc.drpc.mainnet.arc.io https://rpc.quicknode.mainnet.arc.io; do
  out="$(curl -s --max-time 15 -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$url" | head -c 160)"
  blk="$(curl -s --max-time 15 -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["latest",false]}' "$url" | head -c 60)"
  echo "$url"
  echo "    chainId: ${out:-no answer}"
  echo "    latest block: ${blk:-no answer}"
done
echo
echo "Done. Paste everything above to Claude."
