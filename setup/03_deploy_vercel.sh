#!/usr/bin/env bash
# =============================================================================
# dataonchain | Phase 3, script 3 of 3: Production deployment on Vercel
#
# What this does:
#   1. Checks the app builds and everything is pushed to GitHub
#   2. Creates a SEPARATE production Turso database (dataonchainprod)
#      so testing never touches real customer data
#   3. Applies the same migrations to the production database
#   4. Installs the Vercel CLI, logs you in, links this project
#   5. Stores the production database URL and token on Vercel as secrets
#   6. Connects GitHub so every push to main deploys automatically
#   7. Deploys to production and prints your live link
#
# The production token is passed straight from Turso to Vercel.
# It is never printed and never saved in any file on your computer.
#
# Run from the project folder, after scripts 1 and 2:
#   cd ~/dataonchain
#   bash setup/03_deploy_vercel.sh
#
# Safe to run again later: it reuses the database and project, refreshes the
# secrets, applies any new migrations, and deploys the latest code.
# =============================================================================
set -euo pipefail

PROD_DB="${1:-dataonchainprod}"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }

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

export PATH="$HOME/.turso:$PATH"

# --- 0. Checks ------------------------------------------------------------------
step "Checking project folder"
[[ -f package.json ]] || fail "No package.json here. Run this from ~/dataonchain"
grep -q '"name": "dataonchain"' package.json || fail "This does not look like the dataonchain project"
[[ -f drizzle.config.ts && -d drizzle ]] || fail "Database setup missing. Run setup/02_database_schema.sh first"
command -v turso >/dev/null 2>&1 || fail "Turso CLI not found. Run setup/01_turso_setup.sh first"
turso_logged_in || fail "Not logged in to Turso. Run: turso auth login --headless"
green "OK"

# --- 1. Code must be committed, pushed and building ------------------------------
step "Checking git"
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  fail "You have uncommitted changes (listed above). Commit and push them first."
fi
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || fail "Your code is not pushed. Run: git push"
green "OK: clean and pushed"

step "Checking the app builds"
npm run build
green "OK: build passed"

# --- 2. Production database ---------------------------------------------------------
step "Preparing production database: $PROD_DB"
if [[ -n "$(turso_db_url "$PROD_DB")" ]]; then
  green "Database '$PROD_DB' already exists. Reusing it."
else
  turso db create "$PROD_DB"
  green "Created database '$PROD_DB'"
fi
PROD_URL="$(turso_db_url "$PROD_DB")"
[[ "$PROD_URL" == libsql://* ]] || fail "Unexpected database URL: $PROD_URL"
PROD_TOKEN="$(turso db tokens create "$PROD_DB" | tr -d '[:space:]')"
[[ ${#PROD_TOKEN} -gt 40 && "$PROD_TOKEN" != *login* ]] || fail "Could not create a production token"
green "OK: $PROD_URL"

# --- 3. Migrations on production ------------------------------------------------------
step "Applying migrations to the production database"
# Shell values win over .env.local, so this targets production only.
TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npx drizzle-kit migrate
TURSO_DATABASE_URL="$PROD_URL" TURSO_AUTH_TOKEN="$PROD_TOKEN" npm run db:check
green "OK: production database is up to date"

# --- 4. Vercel CLI, login, link ---------------------------------------------------------
step "Checking Vercel CLI"
if ! command -v vercel >/dev/null 2>&1; then
  npm install -g vercel
fi
green "OK: $(vercel --version 2>/dev/null | tail -n1)"

step "Checking Vercel login"
if ! vercel whoami >/dev/null 2>&1; then
  yellow "You are not logged in. Follow the link and code shown below."
  yellow "Tip: choose 'Continue with GitHub' on the Vercel page."
  vercel login
fi
green "OK: logged in as $(vercel whoami 2>/dev/null | tail -n1)"

step "Linking this folder to the Vercel project 'dataonchain'"
vercel link --yes --project dataonchain
green "OK: linked"

# --- 5. Secrets on Vercel ---------------------------------------------------------------------
step "Saving production settings on Vercel"
printf '%s' "$PROD_URL"   | vercel env add TURSO_DATABASE_URL production --force --sensitive >/dev/null
printf '%s' "$PROD_TOKEN" | vercel env add TURSO_AUTH_TOKEN  production --force --sensitive >/dev/null
unset PROD_TOKEN
green "OK: TURSO_DATABASE_URL and TURSO_AUTH_TOKEN saved as secrets"

# --- 6. GitHub auto deploy -------------------------------------------------------------------------
step "Connecting GitHub for automatic deploys"
if vercel git connect; then
  green "OK: every push to main will now deploy automatically"
else
  yellow "Could not connect GitHub automatically."
  yellow "Do it once by hand: Vercel dashboard > dataonchain > Settings > Git > Connect Bankas03/dataonchain"
fi

# --- 7. Deploy ----------------------------------------------------------------------------------------
step "Deploying to production"
DEPLOY_URL="$(vercel deploy --prod --yes | tail -n1)"
green "OK: deployed"

echo
green "Script 3 complete. Your app is live."
echo "Deployment:  $DEPLOY_URL"
echo "Dashboard:   run 'vercel open' to see logs, domains and settings"
