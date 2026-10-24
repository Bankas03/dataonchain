#!/usr/bin/env bash
# =============================================================================
# dataonchain | Bridge report (read only, changes nothing)
#   bash setup/bridge-report.sh prod     the live site
#   bash setup/bridge-report.sh dev      your development database
# =============================================================================
set -euo pipefail
[[ -f backend/.env ]] || { echo "Run this from ~/dataonchain"; exit 1; }
case "${1:-prod}" in
  dev)
    (cd backend && npx tsx scripts/bridge-report.ts)
    ;;
  prod)
    url="$(turso db show dataonchainprod --url 2>/dev/null | tr -d '[:space:]')"
    [[ "$url" == libsql://* ]] || { echo "Turso is not logged in. Run: turso auth login --headless"; exit 1; }
    token="$(turso db tokens create dataonchainprod --expiration 1d | tr -d '[:space:]')"
    (cd backend && TURSO_DATABASE_URL="$url" TURSO_AUTH_TOKEN="$token" npx tsx scripts/bridge-report.ts)
    ;;
  *)
    echo "Usage: bash setup/bridge-report.sh prod|dev"; exit 1 ;;
esac
