#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 14: give the live site its own database
#
# Found: Render (the live API) uses the development database "dataonchain".
# This moves the live site to "dataonchainprod" without losing anything:
#   1. checks dataonchainprod is empty (it only has tables, no users)
#   2. you pause the live API on Render for a few minutes, so nothing changes
#   3. dataonchainprod is recreated as an exact copy of dataonchain
#      (all users, wallets, orders, payments, refunds, sweeps)
#   4. you point Render at dataonchainprod (address + new token) and resume
#   5. checks the live site really writes to dataonchainprod
# After this: dataonchain is for development and tests only.
# No code changes. Downtime: about 5 minutes.
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/14_separate_databases.sh
# =============================================================================
set -euo pipefail

DEV_DB="dataonchain"
PROD_DB="dataonchainprod"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }
pause()  { read -r -p "$* Press Enter to continue... " _; }

ENV_FILE="backend/.env"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

turso_logged_in() {
  local out
  out="$(turso db list 2>&1)" || return 1
  ! grep -qi "not logged in\|please login\|auth login" <<<"$out"
}
turso_db_url() {
  local out
  out="$(turso db show "$1" --url 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$out" == libsql://* ]] && printf '%s' "$out"
  return 0
}
# Prints a single number from a SQL count, or "error"
count() { # db table
  local out
  out="$(turso db shell "$1" "SELECT count(*) FROM $2;" 2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tail -n1 | tr -dc '0-9')" || true
  [[ -n "$out" ]] && printf '%s' "$out" || printf 'error'
}
TABLES=(users wallets orders payments vtu_transactions refunds wallet_sweeps ledger_entries)
show_counts() { # db
  local t
  for t in "${TABLES[@]}"; do printf '  %-18s %s\n' "$t" "$(count "$1" "$t")"; done
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking"
[[ -f "$ENV_FILE" ]] || fail "Run this from ~/dataonchain"
command -v turso >/dev/null || fail "Turso CLI not found"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless   then run this again."
DEV_URL="$(turso_db_url "$DEV_DB")"
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$DEV_URL" ]] || fail "Database $DEV_DB not found"
[[ -n "$PROD_URL" ]] || fail "Database $PROD_DB not found"
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
[[ -n "$PROD_API" && -n "$PROD_FRONTEND" ]] || fail "Production addresses missing in $ENV_FILE"
[[ "$(env_get TURSO_DATABASE_URL)" == "$DEV_URL" ]] || fail "backend/.env does not point at $DEV_DB. Tell Claude."
green "OK"

step "Safety check: $PROD_DB must have no users yet"
PROD_USERS="$(count "$PROD_DB" users)"
[[ "$PROD_USERS" == "0" ]] || fail "$PROD_DB has users ($PROD_USERS) or could not be read. Nothing was changed. Tell Claude."
green "OK: $PROD_DB is empty, safe to replace"

step "What is in $DEV_DB (the live data) right now"
show_counts "$DEV_DB"

# --- 1. Pause the live API ------------------------------------------------------
step "Pause the live API on Render"
bold "In your browser:"
echo "  1. dashboard.render.com > your dataonchain service > Settings"
echo "  2. Scroll to the bottom, click 'Suspend Web Service', confirm"
echo "  (the website shows errors for a few minutes; no data or money is at risk)"
pause "When it says Suspended,"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_API/health" || true)"
if [[ "$code" == "200" ]]; then
  yellow "The API still answers. Give Render a minute after suspending."
  pause "When it is suspended,"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_API/health" || true)"
  [[ "$code" != "200" ]] || fail "The API is still running, so copying now could lose new orders. Nothing was changed. Suspend it, then run again."
fi
green "OK: the live API is paused"
CUTOVER_MS="$(($(date +%s) * 1000))"

# --- 2. Copy -----------------------------------------------------------------------
step "Making $PROD_DB an exact copy of $DEV_DB"
turso db destroy "$PROD_DB" --yes
turso db create "$PROD_DB" --from-db "$DEV_DB" --wait
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "The copy was not created. Resume the Render service (it still uses $DEV_DB, nothing is lost) and tell Claude."

step "Comparing the copy with the original"
ok="yes"
for t in "${TABLES[@]}"; do
  a="$(count "$DEV_DB" "$t")"; b="$(count "$PROD_DB" "$t")"
  printf '  %-18s %-8s %s\n' "$t" "$a" "$b"
  [[ "$a" == "$b" && "$a" != "error" ]] || ok="no"
done
[[ "$ok" == "yes" ]] || fail "The copy does not match. Resume the Render service (it still uses $DEV_DB, nothing is lost) and tell Claude."
green "OK: identical"

# --- 3. Point Render at the production database --------------------------------------
step "Point Render at $PROD_DB"
RENDER_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ "$RENDER_TOKEN" == eyJ* ]] || fail "Could not create the database token"
printf '%s' "$RENDER_TOKEN" | clip.exe
unset RENDER_TOKEN
bold "In your browser, on your dataonchain service > Environment:"
echo "  1. TURSO_DATABASE_URL  -> change it to:"
echo "       $PROD_URL"
echo "  2. TURSO_AUTH_TOKEN    -> click edit, select all, paste (Ctrl+V)"
echo "       The new token is already in your clipboard. Do not paste it anywhere else."
echo "  3. Click 'Save, rebuild, and deploy' (or 'Save changes')"
echo "  4. Go to Settings and click 'Resume Web Service'"
pause "When you have saved both values and resumed the service,"
printf 'x' | clip.exe   # clear the clipboard

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"sca":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}
wait_for "the API on Render" "$PROD_API/api/status" || fail "The API did not come back. Check Events and Logs on Render."
wait_for "the website" "$PROD_FRONTEND/api/status" || fail "The website cannot reach the API. Check vercel.com."

# --- 4. Prove the live site writes to the production database -----------------------
step "Proving the live site now uses $PROD_DB"
echo "Log in once at $PROD_FRONTEND/login (log out first if you are already logged in)."
pause "When you are logged in and see your dashboard,"
sql_number() { turso db shell "$1" "$2" 2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tail -n1 | tr -dc '0-9' || true; }
prod_new="$(sql_number "$PROD_DB" "SELECT count(*) FROM sessions WHERE created_at > $CUTOVER_MS;")"
dev_new="$(sql_number "$DEV_DB" "SELECT count(*) FROM sessions WHERE created_at > $CUTOVER_MS;")"
echo "  New logins since the switch: $PROD_DB ${prod_new:-?}, $DEV_DB ${dev_new:-?}"
if [[ "${prod_new:-0}" -ge 1 && "${dev_new:-0}" == "0" ]]; then
  green "OK: the live site writes to $PROD_DB"
else
  fail "Your login did not show up in $PROD_DB. Check the two values on Render > Environment and that the latest deploy is live, then tell Claude."
fi

step "Wallet upgrade progress on the live database"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')" \
  npx tsx scripts/wallets-report.ts) | tee "$HOME/dataonchain-wallets-report.txt" || yellow "Could not read the report."

# --- 5. Save this script in the repo -------------------------------------------------
if [[ -n "$(git status --porcelain setup/14_separate_databases.sh)" ]]; then
  git add setup/14_separate_databases.sh
  git commit -q -m "Script 14: live site uses its own database (dataonchainprod)"
  git push -q
fi

echo
green "Done. Live site: $PROD_DB. Your computer and the tests: $DEV_DB."
echo "  Report saved: ~/dataonchain-wallets-report.txt"
echo "  Note: $DEV_DB still holds a copy of the live data as of today. Tests keep using it."
