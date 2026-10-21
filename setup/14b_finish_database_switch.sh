#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 14b: finish moving the live site to dataonchainprod
#
# Script 14 saved the new database on Render, but Render never deployed, so
# the live API kept using dataonchain. This script:
#   1. you suspend the live API again (no new changes while copying)
#   2. refreshes dataonchainprod as an exact copy of dataonchain
#   3. you DEPLOY on Render (this is the step that applies the new database)
#   4. checks nothing was written to the old database in between
#   5. checks your login lands in dataonchainprod
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/14b_finish_database_switch.sh
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
turso_db_url() {
  local out
  out="$(turso db show "$1" --url 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$out" == libsql://* ]] && printf '%s' "$out"
  return 0
}
sql_number() { turso db shell "$1" "$2" 2>/dev/null | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tail -n1 | tr -dc '0-9' || true; }
count() { local n; n="$(sql_number "$1" "SELECT count(*) FROM $2;")"; printf '%s' "${n:-error}"; }
TABLES=(users sessions wallets orders payments vtu_transactions refunds wallet_sweeps ledger_entries)
now_ms() { echo "$(($(date +%s) * 1000))"; }

step "Checking"
[[ -f "$ENV_FILE" ]] || fail "Run this from ~/dataonchain"
turso db list >/dev/null 2>&1 || fail "Turso CLI is not logged in. Run: turso auth login --headless"
PROD_API="$(env_get PRODUCTION_API_URL)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_API" && -n "$PROD_FRONTEND" && -n "$PROD_URL" ]] || fail "Missing production settings. Tell Claude."
green "OK"

# --- 1. Suspend --------------------------------------------------------------------
step "Pause the live API"
echo "  Render > dataonchain service > Settings > bottom > 'Suspend Web Service' > confirm"
pause "When it says Suspended,"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_API/health" || true)"
if [[ "$code" == "200" ]]; then
  pause "The API still answers. Wait a minute after suspending, then"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_API/health" || true)"
  [[ "$code" != "200" ]] || fail "Still running. Nothing was changed. Suspend it and run again."
fi
green "OK: paused"

# --- 2. Refresh the copy -----------------------------------------------------------------
step "Refreshing $PROD_DB as an exact copy of $DEV_DB"
yellow "This replaces $PROD_DB. It only holds an older copy from script 14, nothing new."
read -r -p "Type  recopy  to continue: " ans
[[ "$ans" == "recopy" ]] || fail "Stopped. Resume the service on Render; nothing was changed."
turso db destroy "$PROD_DB" --yes
turso db create "$PROD_DB" --from-db "$DEV_DB" --wait
[[ "$(turso_db_url "$PROD_DB")" == "$PROD_URL" ]] || fail "The copy has a different address. Resume the service on Render (it still uses $DEV_DB) and tell Claude."
ok="yes"
for t in "${TABLES[@]}"; do
  a="$(count "$DEV_DB" "$t")"; b="$(count "$PROD_DB" "$t")"
  printf '  %-18s %-8s %s\n' "$t" "$a" "$b"
  [[ "$a" == "$b" && "$a" != "error" ]] || ok="no"
done
[[ "$ok" == "yes" ]] || fail "The copy does not match. Resume the service on Render (it still uses $DEV_DB) and tell Claude."
green "OK: identical"
COPY_MS="$(now_ms)"

# --- 3. Deploy with the new database --------------------------------------------------
step "Deploy on Render (this applies the new database)"
# The copy is a new database, so Render needs a new token for it.
RENDER_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ "$RENDER_TOKEN" == eyJ* ]] || fail "Could not create the database token. Resume the service on Render and tell Claude."
printf '%s' "$RENDER_TOKEN" | clip.exe
unset RENDER_TOKEN
bold "On your dataonchain service:"
echo "  1. Environment: TURSO_DATABASE_URL must be $PROD_URL (it already is)"
echo "     TURSO_AUTH_TOKEN: click edit, select all, paste (Ctrl+V). The new token is in your clipboard."
echo "     Then choose 'Save only' (we deploy in the next step)."
echo "  2. Top right: 'Manual Deploy' > 'Deploy latest commit'"
echo "     If Render says the service is suspended, click 'Resume Web Service' first,"
echo "     then immediately 'Manual Deploy' > 'Deploy latest commit'."
echo "  3. Wait until Events shows a NEW line: 'Deploy live for 9baa6e5' with today's time"
pause "When the new deploy is live,"
printf 'x' | clip.exe   # clear the clipboard

printf 'Checking the API '
for _ in $(seq 1 30); do
  body="$(curl -s --max-time 20 "$PROD_API/api/status" || true)"
  [[ "$body" == *'"sca":true'* ]] && break
  printf '.'; sleep 10
done
echo
[[ "$body" == *'"sca":true'* ]] || fail "The API is not answering. Check Events and Logs on Render."
green "OK: API is up"

# --- 4. Anything written to the old database in between? ------------------------------
step "Checking nothing landed in the old database during the switch"
late_orders="$(sql_number "$DEV_DB" "SELECT count(*) FROM orders WHERE created_at > $COPY_MS OR updated_at > $COPY_MS;")"
late_users="$(sql_number "$DEV_DB" "SELECT count(*) FROM users WHERE created_at > $COPY_MS;")"
echo "  Orders created or changed in $DEV_DB after the copy: ${late_orders:-?}"
echo "  New users in $DEV_DB after the copy: ${late_users:-?}"
if [[ "${late_orders:-0}" != "0" || "${late_users:-0}" != "0" ]]; then
  yellow "Something was written to the old database during the switch (shown above)."
  yellow "Keep going, then tell Claude these two numbers so it can be copied across."
else
  green "OK: nothing was missed"
fi

# --- 5. Prove the live site uses the production database --------------------------------
step "Proving the live site now uses $PROD_DB"
echo "On $PROD_FRONTEND : click Log out, then log in again."
pause "When you see your dashboard,"
prod_new="$(sql_number "$PROD_DB" "SELECT count(*) FROM sessions WHERE created_at > $COPY_MS;")"
dev_new="$(sql_number "$DEV_DB" "SELECT count(*) FROM sessions WHERE created_at > $COPY_MS;")"
echo "  New logins since the copy: $PROD_DB ${prod_new:-0}, $DEV_DB ${dev_new:-0}"
if [[ "${prod_new:-0}" -ge 1 && "${dev_new:-0}" == "0" ]]; then
  green "OK: the live site writes to $PROD_DB"
elif [[ "${dev_new:-0}" -ge 1 ]]; then
  fail "Your login went to $DEV_DB, so Render is still on the old settings. Paste this whole output to Claude."
else
  fail "No new login was recorded anywhere. Make sure you logged OUT first, then run only this check again (ask Claude)."
fi

step "Wallet upgrade progress on the live database"
TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1d | tr -d '[:space:]')"
(cd backend && TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$TOKEN" npx tsx scripts/wallets-report.ts) \
  | tee "$HOME/dataonchain-wallets-report.txt" || yellow "Could not read the report."
unset TOKEN

git add setup/14b_finish_database_switch.sh setup/14_separate_databases.sh 2>/dev/null || true
if ! git diff --cached --quiet; then
  git commit -q -m "Scripts 14 and 14b: live site uses dataonchainprod"
  git push -q
fi

echo
green "Done. Live site: $PROD_DB. Your computer and the tests: $DEV_DB."
