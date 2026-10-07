#!/usr/bin/env bash
# =============================================================================
# dataonchain | Phase 3, script 1 of 3: Turso setup (development database)
#
# What this does:
#   1. Installs the Turso CLI if it is missing
#   2. Logs you in to Turso (opens a link you approve in your browser)
#   3. Creates the development database (reuses it if it already exists)
#   4. Writes TURSO_DATABASE_URL and TURSO_AUTH_TOKEN into .env.local
#
# Your token is written straight to .env.local. It is never printed on screen
# and never committed to GitHub (.env.local is ignored by git).
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/01_turso_setup.sh
#
# Optional: use a different database name
#   bash setup/01_turso_setup.sh mydbname
# =============================================================================
set -euo pipefail

DB_NAME="${1:-dataonchain}"
ENV_FILE=".env.local"

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

# --- 0. Make sure we are in the right folder ---------------------------------
step "Checking project folder"
[[ -f package.json ]] || fail "No package.json here. Run this from ~/dataonchain"
grep -q '"name": "dataonchain"' package.json || fail "This does not look like the dataonchain project"
green "OK: $(pwd)"

# --- 1. Turso CLI -------------------------------------------------------------
step "Checking Turso CLI"
export PATH="$HOME/.turso:$PATH"
if ! command -v turso >/dev/null 2>&1; then
  yellow "Turso CLI not found. Installing..."
  curl -sSfL https://get.tur.so/install.sh | bash
  export PATH="$HOME/.turso:$PATH"
fi
command -v turso >/dev/null 2>&1 || fail "Turso CLI install failed. Open a new terminal and run this script again."
green "OK: $(turso --version 2>/dev/null | head -n1)"

# --- 2. Login -----------------------------------------------------------------
step "Checking Turso login"
if ! turso_logged_in; then
  yellow "You are not logged in. A login link will appear below."
  yellow "Open it in your Windows browser and approve the login."
  turso auth login --headless || true
  # Headless login sometimes shows a command in the browser to finish login.
  until turso_logged_in; do
    echo
    yellow "Still not logged in."
    yellow "If the browser page showed a command (it starts with: turso config set token),"
    yellow "open a SECOND Ubuntu terminal, paste and run that command there."
    read -r -p "Then press Enter here to check again (or Ctrl+C to stop)... " _
  done
fi
green "OK: logged in to Turso"

# --- 3. Database --------------------------------------------------------------
step "Preparing database: $DB_NAME"
if [[ -n "$(turso_db_url "$DB_NAME")" ]]; then
  green "Database '$DB_NAME' already exists. Reusing it."
else
  turso db create "$DB_NAME"
  green "Created database '$DB_NAME'"
fi

DB_URL="$(turso_db_url "$DB_NAME")"
[[ "$DB_URL" == libsql://* ]] || fail "Unexpected database URL: $DB_URL"

DB_TOKEN="$(turso db tokens create "$DB_NAME" | tr -d '[:space:]')"
[[ ${#DB_TOKEN} -gt 40 && "$DB_TOKEN" != *login* ]] || fail "Could not create a database token"
green "OK: URL and token ready"

# --- 4. Write .env.local ------------------------------------------------------
step "Writing $ENV_FILE"
touch "$ENV_FILE"
cp "$ENV_FILE" "$ENV_FILE.bak"
# Keep every other line, replace only the Turso lines.
grep -v -E '^(TURSO_DATABASE_URL|TURSO_AUTH_TOKEN)=' "$ENV_FILE.bak" > "$ENV_FILE" || true
{
  echo "TURSO_DATABASE_URL=$DB_URL"
  echo "TURSO_AUTH_TOKEN=$DB_TOKEN"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE" "$ENV_FILE.bak"
unset DB_TOKEN
green "OK: $ENV_FILE updated (backup saved as $ENV_FILE.bak)"

# --- 5. Safety check: env files must not be tracked by git --------------------
step "Checking git will not upload your secrets"
if git check-ignore -q "$ENV_FILE" && git check-ignore -q "$ENV_FILE.bak"; then
  green "OK: $ENV_FILE and its backup are ignored by git"
else
  fail "$ENV_FILE is NOT ignored by git. Do not commit. Tell Claude."
fi

echo
green "Script 1 complete. Database: $DB_NAME ($DB_URL)"
echo "Next: bash setup/02_database_schema.sh"
