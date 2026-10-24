#!/usr/bin/env bash
# =============================================================================
# dataonchain | Manage approved bridge destinations (VTU provider addresses)
# Users can only send USDC to addresses on this list.
#
#   bash setup/destinations.sh prod list
#   bash setup/destinations.sh prod add base 0xProviderAddress Acme VTU
#   bash setup/destinations.sh prod disable 0xProviderAddress
#   bash setup/destinations.sh prod enable 0xProviderAddress
#
# Use "dev" instead of "prod" for the development database.
# Chains: base, arbitrum, ethereum, avalanche, optimism, polygon, unichain
# =============================================================================
set -euo pipefail
[[ -f backend/.env ]] || { echo "Run this from ~/dataonchain"; exit 1; }
target="${1:-}"; shift || true
case "$target" in
  dev)
    (cd backend && npx tsx scripts/destinations.ts "$@")
    ;;
  prod)
    url="$(turso db show dataonchainprod --url 2>/dev/null | tr -d '[:space:]')"
    [[ "$url" == libsql://* ]] || { echo "Turso is not logged in. Run: turso auth login --headless"; exit 1; }
    token="$(turso db tokens create dataonchainprod --expiration 1d | tr -d '[:space:]')"
    (cd backend && TURSO_DATABASE_URL="$url" TURSO_AUTH_TOKEN="$token" npx tsx scripts/destinations.ts "$@")
    ;;
  *)
    echo "Usage: bash setup/destinations.sh prod|dev list|add|disable|enable ..."
    exit 1
    ;;
esac
