#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 04: split the project into frontend and backend
#
# Before:  one Next.js app at the root, database code inside it
# After:
#   dataonchain/
#   ├── frontend/   Next.js website       (.env.local: public settings only)
#   ├── backend/    Hono API + database   (.env: all secrets)
#   ├── setup/      our .sh scripts
#   ├── render.yaml how Render builds and runs the backend
#   └── README.md
#
# What this does:
#   1. Moves the Next.js app into frontend/ (git history is kept)
#   2. Moves the schema, migrations and db scripts into backend/
#   3. Creates the Hono API server with a /health endpoint
#   4. Moves your Turso secrets from the root .env.local into backend/.env
#   5. Creates frontend/.env.local pointing at the local backend
#   6. Installs packages in both folders, checks everything builds and runs
#   7. Commits and pushes to GitHub
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/04_split_frontend_backend.sh
#
# IMPORTANT, do this first on vercel.com (takes 30 seconds):
#   Your project > Settings > Build and Deployment > Root Directory > frontend > Save
# =============================================================================
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }

# --- 0. Checks -----------------------------------------------------------------
step "Checking the project"
[[ -f package.json && -d src/app ]] || fail "Run this from ~/dataonchain (the folder with package.json and src/)"
grep -q '"name": "dataonchain"' package.json || fail "This does not look like the dataonchain project"
[[ ! -e frontend && ! -e backend ]] || fail "frontend/ or backend/ already exists. Has this script already run?"
[[ -f src/db/schema.ts && -d drizzle ]] || fail "Database files missing. Script 02 must have run first"
[[ -f .env.local ]] || fail ".env.local not found (it holds your Turso secrets)"
grep -q '^TURSO_DATABASE_URL=libsql://' .env.local || fail "TURSO_DATABASE_URL missing in .env.local"
grep -q '^TURSO_AUTH_TOKEN=.' .env.local || fail "TURSO_AUTH_TOKEN missing in .env.local"
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  fail "You have uncommitted changes (listed above). Commit them first, or tell Claude."
fi
green "OK"

read -r -p "Have you set Root Directory to 'frontend' on Vercel? (y/n) " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || yellow "No problem. Do it before the push at the end, or that one Vercel deploy will fail (harmless)."

# --- 1. Move the Next.js app into frontend/ -------------------------------------
step "Moving the Next.js app into frontend/"
mkdir -p frontend
for f in src public next.config.ts postcss.config.mjs eslint.config.mjs tsconfig.json \
         package.json package-lock.json AGENTS.md CLAUDE.md; do
  if [[ -e "$f" ]]; then git mv "$f" frontend/; fi
done
rm -rf node_modules .next next-env.d.ts
green "OK"

# --- 2. Move database code into backend/ -----------------------------------------
step "Moving database code into backend/"
mkdir -p backend/src
git mv frontend/src/db backend/src/db
git mv drizzle backend/drizzle
git mv drizzle.config.ts backend/drizzle.config.ts
git mv scripts backend/scripts
# The backend is plain Node, so take randomUUID from node:crypto
sed -i 's/crypto\.randomUUID()/randomUUID()/' backend/src/db/schema.ts
sed -i '0,/^import {$/s//import { randomUUID } from "node:crypto";\nimport {/' backend/src/db/schema.ts
grep -q 'from "node:crypto"' backend/src/db/schema.ts || fail "Could not update schema.ts imports"
green "OK"

# --- 3. Secrets: root .env.local -> backend/.env --------------------------------
step "Moving secrets into backend/.env"
{
  echo "# Backend settings. Never commit this file."
  echo "NODE_ENV=development"
  echo "PORT=4000"
  echo "# Comma separated list of websites allowed to call the API"
  echo "FRONTEND_URL=http://localhost:3000"
  echo
  echo "# Turso (development database)"
  grep -E '^(TURSO_DATABASE_URL|TURSO_AUTH_TOKEN)=' .env.local
} > backend/.env
chmod 600 backend/.env
rm -f .env.local .env.local.bak
git rm -q --ignore-unmatch .env.example   # replaced by backend/ and frontend/ examples
green "OK: backend/.env created, old root .env.local removed"

# --- 4. Root files ------------------------------------------------------------------
step "Writing root files"

cat > .gitignore <<'EOF'
# dependencies (any folder)
node_modules/
.pnp
.pnp.*

# builds
.next/
out/
build/
dist/
*.tsbuildinfo
next-env.d.ts

# env files hold secrets. Only the examples are shared.
.env*
!.env.example

# tools
.vercel
.DS_Store
*.pem
coverage/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.pnpm-debug.log*
EOF
green "WROTE: .gitignore"

cat > render.yaml <<'EOF'
# Render Blueprint: how Render builds and runs the backend.
# Secrets marked "sync: false" are typed into the Render dashboard once,
# when the Blueprint is first created. They never live in this repo.
services:
  - type: web
    name: dataonchain-api
    runtime: node
    plan: free            # change to a paid plan before launch (free sleeps after 15 min)
    region: frankfurt     # closest Render region to Nigeria
    rootDir: backend
    buildCommand: npm ci --include=dev && npm run build
    startCommand: npm start
    healthCheckPath: /health
    autoDeployTrigger: commit
    envVars:
      - key: NODE_VERSION
        value: "22"
      - key: NODE_ENV
        value: production
      - key: TURSO_DATABASE_URL
        sync: false
      - key: TURSO_AUTH_TOKEN
        sync: false
      - key: FRONTEND_URL
        sync: false
EOF
green "WROTE: render.yaml"

cat > README.md <<'EOF'
# dataonchain

Buy Nigerian airtime and data with USDC on Arc.

| Folder | What it is | Runs on | Hosted on |
| --- | --- | --- | --- |
| `frontend/` | Next.js website | http://localhost:3000 | Vercel |
| `backend/` | Hono API, Turso database, Circle, VTpass | http://localhost:4000 | Render |
| `setup/` | Setup and deploy scripts | | |

## Run locally

```bash
bash setup/dev.sh
```

Starts the backend and frontend together. Press Ctrl+C to stop both.

## Settings

- `backend/.env` holds every secret (database, Circle, VTpass). See `backend/.env.example`.
- `frontend/.env.local` holds public settings only, such as the API address. See `frontend/.env.example`.
- Never commit a real `.env` file.

## Database

```bash
cd backend
npm run db:generate   # after changing src/db/schema.ts
npm run db:migrate    # apply changes to the development database
npm run db:check      # confirm every table exists
npm run db:studio     # browse the data
```
EOF
green "WROTE: README.md"

cat > setup/dev.sh <<'EOF'
#!/usr/bin/env bash
# Runs backend (port 4000) and frontend (port 3000) together. Ctrl+C stops both.
set -euo pipefail
cd "$(dirname "$0")/.."
trap 'kill 0' EXIT
(cd backend && npm run dev) &
(cd frontend && npm run dev) &
wait
EOF
chmod +x setup/dev.sh
green "WROTE: setup/dev.sh"

# Scripts 01 to 03 were for the old single folder layout. Their work is done.
git rm -q --ignore-unmatch setup/01_turso_setup.sh setup/02_database_schema.sh setup/03_deploy_vercel.sh
green "Removed old scripts 01 to 03 (still in git history)"

# --- 5. Backend files ---------------------------------------------------------------
step "Writing backend files"

cat > backend/package.json <<'EOF'
{
  "name": "dataonchain-backend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "esbuild src/index.ts --bundle --platform=node --format=esm --target=node20 --packages=external --outfile=dist/index.js",
    "start": "node dist/index.js",
    "typecheck": "tsc --noEmit",
    "db:generate": "drizzle-kit generate",
    "db:migrate": "drizzle-kit migrate",
    "db:studio": "drizzle-kit studio",
    "db:check": "tsx scripts/db-check.ts"
  }
}
EOF

cat > backend/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "types": ["node"],
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src", "scripts", "drizzle.config.ts"]
}
EOF

cat > backend/.env.example <<'EOF'
# Copy to backend/.env and fill in real values. Never commit backend/.env.
NODE_ENV=development
PORT=4000
# Comma separated list of websites allowed to call the API
FRONTEND_URL=http://localhost:3000

# Turso
TURSO_DATABASE_URL=libsql://your-database-url.turso.io
TURSO_AUTH_TOKEN=your-turso-token
EOF

cat > backend/drizzle.config.ts <<'EOF'
import { config } from "dotenv";
import { defineConfig } from "drizzle-kit";

// Loads backend/.env. Values already set in the shell win, which is how
// the deploy script points migrations at the production database.
config({ path: ".env", quiet: true });

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  throw new Error("TURSO_DATABASE_URL is not set in backend/.env");
}

export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "turso",
  dbCredentials: {
    url,
    authToken: process.env.TURSO_AUTH_TOKEN,
  },
  strict: true,
  verbose: true,
});
EOF

cat > backend/scripts/db-check.ts <<'EOF'
// Checks the database is reachable and every expected table exists.
// Run with: npm run db:check
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const EXPECTED_TABLES = [
  "accounts",
  "audit_logs",
  "data_plans",
  "exchange_rates",
  "ledger_entries",
  "orders",
  "payments",
  "sessions",
  "treasury_movements",
  "users",
  "verifications",
  "vtu_transactions",
  "wallets",
  "webhook_events",
];

async function main() {
  const url = process.env.TURSO_DATABASE_URL;
  if (!url) throw new Error("TURSO_DATABASE_URL is not set");

  const client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
  const result = await client.execute(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  );
  const found = new Set(result.rows.map((row) => String(row.name)));
  client.close();

  const missing = EXPECTED_TABLES.filter((t) => !found.has(t));
  console.log(`Database: ${new URL(url.replace("libsql://", "https://")).host}`);
  console.log(`Tables found: ${EXPECTED_TABLES.length - missing.length} of ${EXPECTED_TABLES.length}`);

  if (missing.length > 0) {
    console.error(`MISSING: ${missing.join(", ")}`);
    process.exit(1);
  }
  console.log("All tables present.");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
EOF

cat > backend/src/env.ts <<'EOF'
// Reads and checks backend settings once, at startup.
// Locally they come from backend/.env; on Render from the dashboard.
import { config } from "dotenv";

config({ path: ".env", quiet: true });

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set. Check backend/.env`);
  return value;
}

export const env = {
  NODE_ENV: process.env.NODE_ENV ?? "development",
  PORT: Number(process.env.PORT ?? 4000),
  FRONTEND_URLS: (process.env.FRONTEND_URL ?? "http://localhost:3000")
    .split(",")
    .map((url) => url.trim().replace(/\/$/, ""))
    .filter(Boolean),
  TURSO_DATABASE_URL: required("TURSO_DATABASE_URL"),
  TURSO_AUTH_TOKEN: process.env.TURSO_AUTH_TOKEN,
};
EOF

cat > backend/src/db/index.ts <<'EOF'
// Database client. Only backend code can reach the database.
import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";
import { env } from "../env";

export const client = createClient({
  url: env.TURSO_DATABASE_URL,
  authToken: env.TURSO_AUTH_TOKEN,
});

export const db = drizzle({ client });
export * as schema from "./schema";
EOF

cat > backend/src/app.ts <<'EOF'
// The API: routes, CORS and error handling.
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { client } from "./db";
import { env } from "./env";

export const app = new Hono();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: env.FRONTEND_URLS,
    credentials: true,
  }),
);

app.get("/", (c) => c.json({ name: "dataonchain api", status: "ok" }));

// Render calls this to check the server is healthy before sending traffic.
app.get("/health", async (c) => {
  try {
    await client.execute("SELECT 1");
    return c.json({ status: "ok", database: "ok", time: new Date().toISOString() });
  } catch (err) {
    console.error("Health check failed:", err);
    return c.json({ status: "error", database: "unreachable" }, 503);
  }
});

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
EOF

cat > backend/src/index.ts <<'EOF'
// Starts the API server.
import { serve } from "@hono/node-server";
import { app } from "./app";
import { env } from "./env";

serve({ fetch: app.fetch, port: env.PORT }, (info) => {
  console.log(`dataonchain api running on http://localhost:${info.port} (${env.NODE_ENV})`);
});
EOF
green "OK: backend files written"

# --- 6. Frontend files -------------------------------------------------------------
step "Writing frontend files"

cat > frontend/.env.local <<'EOF'
# Frontend settings. Anything starting NEXT_PUBLIC_ is visible in the browser,
# so never put secrets here. Secrets belong in backend/.env.
NEXT_PUBLIC_API_URL=http://localhost:4000
EOF

cat > frontend/.env.example <<'EOF'
# Copy to frontend/.env.local. Public settings only, no secrets.
NEXT_PUBLIC_API_URL=http://localhost:4000
EOF

mkdir -p frontend/src/lib
cat > frontend/src/lib/api.ts <<'EOF'
// Calls the backend API. Every request to the backend goes through here.
export const API_URL = (process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000").replace(/\/$/, "");

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API_URL}${path}`, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  if (!res.ok) {
    throw new Error(`API error ${res.status} on ${path}`);
  }
  return (await res.json()) as T;
}
EOF
green "OK: frontend files written"

# --- 7. Packages ----------------------------------------------------------------------
step "Installing backend packages"
(
  cd backend
  npm install hono @hono/node-server drizzle-orm @libsql/client dotenv
  npm install -D typescript tsx esbuild drizzle-kit @types/node
)
green "OK"

step "Cleaning frontend packages (database tools now live in the backend)"
(
  cd frontend
  npm uninstall drizzle-orm @libsql/client server-only drizzle-kit dotenv tsx
  npm pkg delete scripts.db:generate scripts.db:migrate scripts.db:studio scripts.db:check
  npm install
)
green "OK"

# --- 8. Checks -----------------------------------------------------------------------
step "Backend: type check"
(cd backend && npm run typecheck)
green "OK"

step "Backend: database check"
(cd backend && npm run db:check)

step "Backend: build"
(cd backend && npm run build)
green "OK"

step "Backend: start the server and call /health"
(cd backend && PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
HEALTH=""
for _ in $(seq 1 20); do
  sleep 1
  HEALTH="$(curl -s http://localhost:4099/health || true)"
  [[ "$HEALTH" == *'"status":"ok"'* ]] && break
done
kill "$API_PID" 2>/dev/null || true
if [[ "$HEALTH" == *'"status":"ok"'* ]]; then
  green "OK: $HEALTH"
else
  cat /tmp/dataonchain-api.log
  fail "The API did not answer /health (log above)"
fi

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 9. Commit and push ------------------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
git commit -q -m "Split project into frontend (Next.js) and backend (Hono API)"
git push
green "OK: pushed to GitHub"

echo
green "Script 04 complete. New structure:"
echo "  frontend/  Next.js website   settings in frontend/.env.local"
echo "  backend/   Hono API          secrets in backend/.env"
echo
echo "Try it locally:   bash setup/dev.sh"
echo "  Website:  http://localhost:3000"
echo "  API:      http://localhost:4000/health"
