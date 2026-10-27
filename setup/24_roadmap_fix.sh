#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 24: roadmap fix on the home page
#   "Live airtime and data delivery" becomes Planned (it was Next), and moves
#   below "Bridge and swaps on Arc mainnet", which stays Next.
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/24_roadmap_fix.sh
# =============================================================================
set -euo pipefail
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()  { red "ERROR: $*"; exit 1; }
PROD_FRONTEND="$(grep -E '^PRODUCTION_FRONTEND_URL=' backend/.env | tail -n1 | cut -d= -f2-)"

step "Checking the project"
[[ -f frontend/src/app/page.tsx ]] || fail "Run this from ~/dataonchain"
grep -q "Why we are building on Arc" frontend/src/app/page.tsx || fail "Run script 23 (home page) first"
git pull -q || fail "git pull failed"
green "OK"

step "Updating the roadmap"
python3 - <<'PY'
p = "frontend/src/app/page.tsx"
s = open(p).read()
live_old = '  { title: "Live airtime and data delivery", text: "Connecting a live VTU provider once registration is complete.", status: "Next" },\n'
live_new = '  { title: "Live airtime and data delivery", text: "Connecting a live VTU provider once registration is complete.", status: "Planned" },\n'
bridge = '  { title: "Bridge and swaps on Arc mainnet", text: "Moving crosschain transfers and swaps from Arc Testnet to Arc mainnet.", status: "Next" },\n'
if live_new in s:
    print("Already updated")
else:
    assert live_old in s and bridge in s, "The roadmap is not as expected. Tell Claude."
    s = s.replace(live_old + bridge, bridge + live_new)
    assert live_new in s, "Could not reorder the roadmap. Tell Claude."
    open(p, "w").write(s)
    print("Updated")
PY
green "OK"

step "Website: build"
if ! (cd frontend && npm run build); then
  git checkout -- frontend
  fail "The website build failed (details above). The change was undone and nothing was committed."
fi
green "OK"

step "Committing to GitHub"
git add frontend/src/app/page.tsx setup/24_roadmap_fix.sh
git commit -q -m "Roadmap: live airtime and data delivery is planned" || true
git push
green "OK: pushed. Vercel publishes it in about 2 minutes: $PROD_FRONTEND/#roadmap"
