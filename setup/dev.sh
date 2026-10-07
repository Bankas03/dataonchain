#!/usr/bin/env bash
# Runs backend (port 4000) and frontend (port 3000) together. Ctrl+C stops both.
set -euo pipefail
cd "$(dirname "$0")/.."
trap 'kill 0' EXIT
(cd backend && npm run dev) &
(cd frontend && npm run dev) &
wait
