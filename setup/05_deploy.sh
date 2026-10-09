#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 05: production deployment
#
#   backend/   -> Render  (API, reads the production database)
#   frontend/  -> Vercel  (website, calls the Render API)
#
# What this does:
#   1. Checks your code is committed and pushed
#   2. Creates a SEPARATE production Turso database (dataonchainprod)
#      and applies all migrations to it
#   3. Guides you through creating the backend on Render (one time, about
#      5 minutes in the browser) and copies the secret token to your clipboard
#   4. Waits until the Render API answers /health
#   5. Tells Vercel where the API lives (NEXT_PUBLIC_API_URL) and deploys
#   6. Checks the website loads and the API accepts calls from it
#
# Your production addresses are read from backend/.env:
#   PRODUCTION_FRONTEND_URL   your Vercel website, e.g. https://dataonchain.vercel.app
#   PRODUCTION_API_URL        your Render API, e.g. https://dataonchain-api.onrender.com
#   VERCEL_PROJECT            your Vercel project name
# Any that are missing are asked once and saved there.
#
# Run from the project folder, after script 04:
#   cd ~/dataonchain
#   bash setup/05_deploy.sh
#
# Safe to run again: it reuses the database and services, applies new
# migrations, and redeploys.
# =============================================================================
set -euo pipefail

PROD_DB="dataonchainprod"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }
pause()  { read -r -p "$* Press Enter to continue... " _; }

# Turso CLI prints "not logged in" without an error code, so check the text too.
turso_logged_in() {
  local out
  out="$(turso db list 2>&1)" || return 1
  ! grep -qi "not logged in\|please login\|auth login" <<<"$out"
}

# Prints the database URL, or nothing if the database does not exist.
turso_db_url() {
  local out
  out="$(turso db show "$1" --url 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$out" == libsql://* ]] && printf '%s' "$out"
  return 0
}

# Asks for a https URL, removes any trailing slash.
ask_url() {
  local prompt="$1" default="${2:-}" url
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " url
      url="${url:-$default}"
    else
      read -r -p "$prompt: " url
    fi
    url="${url%/}"
    [[ "$url" == https://* ]] && { printf '%s' "$url"; return; }
    yellow "Please enter the full address, starting with https://" >&2
  done
}

# Production addresses are kept in backend/.env (never committed).
ENV_FILE="backend/.env"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s#^$1=.*#$1=$2#" "$ENV_FILE"
  else
    grep -q "^# Production (used by setup/05_deploy.sh)" "$ENV_FILE" \
      || printf '\n# Production (used by setup/05_deploy.sh)\n' >> "$ENV_FILE"
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ----------------------------------------------------------------------
step "Checking the project"
[[ -d frontend && -d backend && -f render.yaml ]] || fail "Run this from ~/dataonchain after script 04"
[[ -f backend/.env ]] || fail "backend/.env not found"
command -v turso >/dev/null 2>&1 || fail "Turso CLI not found"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless"
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  fail "You have uncommitted changes (listed above). Commit and push them first."
fi
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "Your code is not pushed. Run: git push"
green "OK: clean and pushed"

step "Reading production settings from $ENV_FILE"
FRONTEND_URL="$(env_get PRODUCTION_FRONTEND_URL)"
if [[ -z "$FRONTEND_URL" ]]; then
  echo "Your Vercel website address is not in $ENV_FILE yet."
  echo "Find it on vercel.com > your project > Domains (for example https://dataonchain.vercel.app)"
  FRONTEND_URL="$(ask_url "Website address" "https://dataonchain.vercel.app")"
  env_set PRODUCTION_FRONTEND_URL "$FRONTEND_URL"
  green "Saved PRODUCTION_FRONTEND_URL in $ENV_FILE"
fi
green "OK: website $FRONTEND_URL"

# --- 1. Production database ------------------------------------------------------------
step "Preparing production database: $PROD_DB"
if [[ -n "$(turso_db_url "$PROD_DB")" ]]; then
  green "Database '$PROD_DB' already exists. Reusing it."
else
  turso db create "$PROD_DB"
  green "Created database '$PROD_DB'"
fi
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ -n "$PROD_URL" ]] || fail "Could not read the production database address"
# A short lived token, only for running migrations from this computer.
MIGRATE_TOKEN="$(turso db tokens create "$PROD_DB" --expiration 1h 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$MIGRATE_TOKEN" == eyJ* ]] \
  || MIGRATE_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ "$MIGRATE_TOKEN" == eyJ* ]] || fail "Could not create a database token"

step "Applying migrations to the production database"
(
  cd backend
  TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$MIGRATE_TOKEN" npx drizzle-kit migrate
  TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$MIGRATE_TOKEN" npm run db:check
)
unset MIGRATE_TOKEN
green "OK: production database is up to date"

# --- 2. Render (backend) -----------------------------------------------------------------
step "Backend on Render"
API_URL="$(env_get PRODUCTION_API_URL)"
RENDER_READY="no"
if [[ -n "$API_URL" ]]; then
  echo "Found PRODUCTION_API_URL in $ENV_FILE: $API_URL"
  RENDER_READY="yes"
else
  read -r -p "Have you already created the backend on Render? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] && RENDER_READY="yes"
fi
if [[ "$RENDER_READY" != "yes" ]]; then
  RENDER_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
  [[ "$RENDER_TOKEN" == eyJ* ]] || fail "Could not create the Render token"

  echo
  bold "Follow these steps in your browser:"
  echo "  1. Open  https://dashboard.render.com/blueprint/new"
  echo "     (sign up with GitHub if you have no Render account)"
  echo "  2. Connect your GitHub repo: Bankas03/dataonchain"
  echo "  3. Give the Blueprint a name: dataonchain"
  echo "  4. Render reads render.yaml and asks for 3 values. Enter them exactly:"
  echo
  echo "     TURSO_DATABASE_URL   $PROD_URL"
  echo "     FRONTEND_URL         $FRONTEND_URL"
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$RENDER_TOKEN" | clip.exe
    echo "     TURSO_AUTH_TOKEN     (already copied to your clipboard: just paste with Ctrl+V)"
  else
    yellow "     TURSO_AUTH_TOKEN     $RENDER_TOKEN"
    yellow "     (keep this private and clear your screen afterwards)"
  fi
  unset RENDER_TOKEN
  echo
  echo "  5. Click 'Deploy Blueprint'. The first build takes about 3 to 5 minutes."
  echo "  6. Open the 'dataonchain-api' service and copy its address at the top"
  echo "     (it looks like https://dataonchain-api.onrender.com)"
  echo
  pause "When the deploy shows 'Live',"
  command -v clip.exe >/dev/null 2>&1 && printf ' ' | clip.exe   # clear the clipboard
fi

if [[ -z "$API_URL" ]]; then
  API_URL="$(ask_url "Render API address" "https://dataonchain-api.onrender.com")"
  env_set PRODUCTION_API_URL "$API_URL"
  green "Saved PRODUCTION_API_URL in $ENV_FILE"
fi

step "Waiting for the API to answer $API_URL/health"
echo "(the free plan can take up to a minute to wake up)"
HEALTH=""
for i in $(seq 1 30); do
  HEALTH="$(curl -s --max-time 20 "$API_URL/health" || true)"
  [[ "$HEALTH" == *'"status":"ok"'* ]] && break
  printf '.'
  sleep 10
done
echo
[[ "$HEALTH" == *'"status":"ok"'* ]] || fail "The API did not answer. Check the Logs tab of dataonchain-api on Render."
green "OK: $HEALTH"

# --- 3. Vercel (frontend) --------------------------------------------------------------------
step "Checking Vercel CLI"
command -v vercel >/dev/null 2>&1 || npm install -g vercel
green "OK: $(vercel --version 2>/dev/null | tail -n1)"

step "Checking Vercel login"
if ! vercel whoami >/dev/null 2>&1; then
  yellow "Follow the link and code below. Choose 'Continue with GitHub'."
  vercel login
fi
green "OK: logged in as $(vercel whoami 2>/dev/null | tail -n1)"

step "Linking to your Vercel project"
VERCEL_PROJECT="$(env_get VERCEL_PROJECT)"
if [[ -z "$VERCEL_PROJECT" ]]; then
  read -r -p "Vercel project name [dataonchain]: " VERCEL_PROJECT
  VERCEL_PROJECT="${VERCEL_PROJECT:-dataonchain}"
  env_set VERCEL_PROJECT "$VERCEL_PROJECT"
fi
vercel link --yes --project "$VERCEL_PROJECT"
green "OK: linked to $VERCEL_PROJECT"
yellow "Reminder: on vercel.com, Settings > Build and Deployment > Root Directory must be 'frontend'."

step "Telling the website where the API lives"
printf '%s' "$API_URL" | vercel env add NEXT_PUBLIC_API_URL production --force --no-sensitive >/dev/null
green "OK: NEXT_PUBLIC_API_URL = $API_URL"

step "Deploying the website"
DEPLOY_URL="$(vercel deploy --prod --yes | tail -n1)"
green "OK: $DEPLOY_URL"

# --- 4. Final checks ----------------------------------------------------------------------------
step "Final checks"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$FRONTEND_URL" || true)"
if [[ "$CODE" == "200" ]]; then green "OK: website loads ($FRONTEND_URL)"; else yellow "Website answered $CODE. Open it in your browser to check."; fi

ALLOW="$(curl -s -D - -o /dev/null --max-time 30 -H "Origin: $FRONTEND_URL" "$API_URL/health" | tr -d '\r' | grep -i '^access-control-allow-origin:' || true)"
if [[ "$ALLOW" == *"$FRONTEND_URL"* ]]; then
  green "OK: the API accepts calls from the website"
else
  yellow "The API does not yet accept calls from $FRONTEND_URL."
  yellow "On Render: dataonchain-api > Environment > FRONTEND_URL must be exactly $FRONTEND_URL"
fi

echo
green "Script 05 complete. Everything is live."
echo "  Website:  $FRONTEND_URL"
echo "  API:      $API_URL/health"
echo
echo "From now on, every git push to main redeploys both automatically."
echo "Run this script again only after a database change (it applies new migrations)."
