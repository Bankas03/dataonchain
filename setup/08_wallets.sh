#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 08 (Phase 6): a Circle USDC wallet for every user
#
# What this adds:
#   - Every confirmed user gets their own developer controlled Circle wallet
#     on Arc Testnet, created automatically the first time they open the
#     dashboard (users who signed up earlier get one too)
#   - GET /api/wallet: the signed in user's wallet address and USDC balance
#   - Dashboard: wallet address with a copy button, USDC balance, refresh,
#     and a link to get free test USDC
#
# One time Circle setup (done by this script):
#   - creates your entity secret (the master key for all user wallets),
#     registers it with Circle and saves the RECOVERY FILE outside the project
#   - creates the wallet set that holds every user wallet
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/08_wallets.sh
# =============================================================================
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail()   { red "ERROR: $*"; exit 1; }
pause()  { read -r -p "$* Press Enter to continue... " _; }

ENV_FILE="backend/.env"
RECOVERY_DIR="$HOME/dataonchain-circle-recovery"
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
to_clipboard() { command -v clip.exe >/dev/null 2>&1 && printf '%s' "$1" | clip.exe; }

# Refuses to commit if any secret value from backend/.env appears in the commit,
# whatever file it is in.
secret_scan() {
  local key val found=""
  while IFS='=' read -r key val; do
    [[ "$key" =~ (SECRET|TOKEN|KEY)$ ]] || continue
    [[ ${#val} -ge 12 ]] || continue
    if git diff --cached -- . ':(exclude)*package-lock.json' | grep -qF -- "$val"; then
      found="$found $key"
    fi
  done < <(grep -E '^[A-Z0-9_]+=' "$ENV_FILE")
  if [[ -n "$found" ]]; then
    git diff --cached --name-only
    git reset -q
    fail "The value of$found is inside one of the files above. Nothing was committed. Delete that file or remove the secret, then run again."
  fi
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
command -v python3 >/dev/null || fail "python3 not found. Run: sudo apt install -y python3"
[[ -d frontend && -d backend && -f backend/src/email/index.ts ]] || fail "Run this from ~/dataonchain after Phase 5 (script 07)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/08_wallets.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Circle API key -------------------------------------------------------------
step "Circle API key"
if [[ -z "$(env_get CIRCLE_API_KEY)" ]]; then
  echo "Paste your Circle testnet API key. It will not show on screen."
  read -r -s -p "Circle API key: " CIRCLE_KEY; echo
  CIRCLE_KEY="$(printf '%s' "$CIRCLE_KEY" | tr -d '[:space:]')"
  [[ ${#CIRCLE_KEY} -gt 20 ]] || fail "That key looks too short"
  if [[ "$CIRCLE_KEY" == LIVE_* ]]; then
    fail "That is a LIVE (mainnet) key. For now we use a testnet key (it starts with TEST_API_KEY:)."
  fi
  [[ "$CIRCLE_KEY" == TEST_* ]] || yellow "Note: testnet keys usually start with TEST_API_KEY:. Continuing anyway."
  printf '\n# Circle wallets (Arc Testnet)\n' >> "$ENV_FILE"
  env_set CIRCLE_API_KEY "$CIRCLE_KEY"
  env_set CIRCLE_BLOCKCHAIN "ARC-TESTNET"
  unset CIRCLE_KEY
fi
green "OK: Circle API key saved in $ENV_FILE"

# --- 2. Packages ----------------------------------------------------------------
step "Installing packages"
(cd backend && npm install @circle-fin/developer-controlled-wallets)
green "OK"

# --- 3. Circle one time setup ---------------------------------------------------------
step "Writing the Circle setup helper"
mkdir -p backend/scripts
cat > backend/scripts/circle-setup.ts <<'EOF'
// One time Circle setup. Safe to run again: it only does what is missing.
//   1. Entity secret: create, register with Circle, save the recovery file
//   2. Wallet set: the container that holds every user wallet
// Writes CIRCLE_ENTITY_SECRET and CIRCLE_WALLET_SET_ID into backend/.env.
// Run with: npx tsx scripts/circle-setup.ts /path/to/recovery/folder
import { randomBytes } from "node:crypto";
import { appendFileSync, mkdirSync, readdirSync } from "node:fs";
import { config } from "dotenv";
import {
  initiateDeveloperControlledWalletsClient,
  registerEntitySecretCiphertext,
} from "@circle-fin/developer-controlled-wallets";

config({ path: ".env", quiet: true });

const apiKey = process.env.CIRCLE_API_KEY;
const recoveryDir = process.argv[2];

function save(key: string, value: string) {
  appendFileSync(".env", `${key}=${value}\n`);
  process.env[key] = value;
}

async function main() {
  if (!apiKey) throw new Error("CIRCLE_API_KEY is not set in backend/.env");
  if (!recoveryDir) throw new Error("Give the folder for the recovery file");

  if (!process.env.CIRCLE_ENTITY_SECRET) {
    mkdirSync(recoveryDir, { recursive: true, mode: 0o700 });
    const entitySecret = randomBytes(32).toString("hex");
    await registerEntitySecretCiphertext({
      apiKey,
      entitySecret,
      recoveryFileDownloadPath: recoveryDir,
    });
    save("CIRCLE_ENTITY_SECRET", entitySecret);
    console.log("Entity secret created and registered with Circle.");
    console.log(`Recovery file saved in ${recoveryDir}: ${readdirSync(recoveryDir).join(", ")}`);
  } else {
    console.log("Entity secret already set. Skipping.");
  }

  if (!process.env.CIRCLE_WALLET_SET_ID) {
    const client = initiateDeveloperControlledWalletsClient({
      apiKey,
      entitySecret: process.env.CIRCLE_ENTITY_SECRET!,
    });
    const res = await client.createWalletSet({ name: "dataonchain users" });
    const id = res.data?.walletSet?.id;
    if (!id) throw new Error("Circle did not return a wallet set id");
    save("CIRCLE_WALLET_SET_ID", id);
    console.log(`Wallet set created: ${id}`);
  } else {
    console.log("Wallet set already set. Skipping.");
  }
}

main().catch((err) => {
  const detail = (err as { response?: { data?: unknown } }).response?.data;
  console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
  process.exit(1);
});
EOF
green "OK"

step "Circle one time setup (entity secret and wallet set)"
if [[ -z "$(env_get CIRCLE_ENTITY_SECRET)" ]]; then
  echo "An entity secret is the master key Circle uses to protect every user wallet."
  read -r -p "Have you EVER registered an entity secret on this Circle account before? (y/n) " ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    echo "Paste that entity secret (64 characters). It will not show on screen."
    read -r -s -p "Entity secret: " ES; echo
    ES="$(printf '%s' "$ES" | tr -d '[:space:]')"
    [[ "$ES" =~ ^[0-9a-fA-F]{64}$ ]] || fail "An entity secret is 64 characters of 0 to 9 and a to f. If you lost it, reset it in the Circle console using your recovery file."
    env_set CIRCLE_ENTITY_SECRET "$ES"
    unset ES
  fi
fi
(cd backend && npx tsx scripts/circle-setup.ts "$RECOVERY_DIR")
[[ -n "$(env_get CIRCLE_ENTITY_SECRET)" && -n "$(env_get CIRCLE_WALLET_SET_ID)" ]] || fail "Circle setup did not finish"
green "OK: Circle is ready"

if [[ -d "$RECOVERY_DIR" ]] && [[ -n "$(ls -A "$RECOVERY_DIR" 2>/dev/null)" ]]; then
  chmod -R go-rwx "$RECOVERY_DIR"
  echo
  bold "IMPORTANT: back up your Circle recovery file now."
  echo "  It is in: $RECOVERY_DIR"
  echo "  Without it (and if backend/.env is lost), you can never reset access to user wallets."
  echo "  It is NOT inside the project, so it will never go to GitHub."
  echo "  Copy it to a password manager or a safe place outside this computer."
  echo "  To open the folder in Windows:  explorer.exe \"\$(wslpath -w $RECOVERY_DIR)\""
  pause "When you have backed it up,"
fi

# --- 4. Backend code ------------------------------------------------------------
step "Writing backend files"

cat >> backend/.env.example <<'EOF'

# Circle developer controlled wallets (run setup/08_wallets.sh to fill these)
CIRCLE_API_KEY=TEST_API_KEY:your-key
CIRCLE_ENTITY_SECRET=64-hex-characters
CIRCLE_WALLET_SET_ID=wallet-set-id
CIRCLE_BLOCKCHAIN=ARC-TESTNET
EOF
awk '!(/^# Circle developer controlled wallets/ && a++) && !(/^CIRCLE_API_KEY=/ && b++) && !(/^CIRCLE_ENTITY_SECRET=/ && c++) && !(/^CIRCLE_WALLET_SET_ID=/ && d++) && !(/^CIRCLE_BLOCKCHAIN=/ && e++)' \
  backend/.env.example > backend/.env.example.tmp && mv backend/.env.example.tmp backend/.env.example

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

const NODE_ENV = process.env.NODE_ENV ?? "development";

export const env = {
  NODE_ENV,
  PORT: Number(process.env.PORT ?? 4000),
  FRONTEND_URLS: (process.env.FRONTEND_URL ?? "http://localhost:3000")
    .split(",")
    .map((url) => url.trim().replace(/\/$/, ""))
    .filter(Boolean),
  TURSO_DATABASE_URL: required("TURSO_DATABASE_URL"),
  TURSO_AUTH_TOKEN: process.env.TURSO_AUTH_TOKEN,
  BETTER_AUTH_SECRET: required("BETTER_AUTH_SECRET"),
  BETTER_AUTH_URL: required("BETTER_AUTH_URL").replace(/\/$/, ""),
  // Email: required in production, optional locally (emails print to the terminal)
  RESEND_API_KEY: NODE_ENV === "production" ? required("RESEND_API_KEY") : process.env.RESEND_API_KEY,
  EMAIL_FROM: NODE_ENV === "production"
    ? required("EMAIL_FROM")
    : (process.env.EMAIL_FROM ?? "dataonchain <onboarding@resend.dev>"),
  // Circle developer controlled wallets
  CIRCLE_API_KEY: required("CIRCLE_API_KEY"),
  CIRCLE_ENTITY_SECRET: required("CIRCLE_ENTITY_SECRET"),
  CIRCLE_WALLET_SET_ID: required("CIRCLE_WALLET_SET_ID"),
  CIRCLE_BLOCKCHAIN: process.env.CIRCLE_BLOCKCHAIN ?? "ARC-TESTNET",
};
EOF

mkdir -p backend/src/circle backend/src/wallets
cat > backend/src/circle/client.ts <<'EOF'
// Circle developer controlled wallets client (server only).
import { initiateDeveloperControlledWalletsClient } from "@circle-fin/developer-controlled-wallets";
import { env } from "../env";

export const circle = initiateDeveloperControlledWalletsClient({
  apiKey: env.CIRCLE_API_KEY,
  entitySecret: env.CIRCLE_ENTITY_SECRET,
});
EOF

cat > backend/src/wallets/service.ts <<'EOF'
// User wallets: one Circle wallet per user per blockchain.
import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { circle } from "../circle/client";
import { db } from "../db";
import { wallets } from "../db/schema";
import { env } from "../env";

export type UserWallet = typeof wallets.$inferSelect;

export const NETWORK_NAMES: Record<string, string> = {
  "ARC-TESTNET": "Arc Testnet",
  ARC: "Arc",
};

// The same user always gets the same key, so a retry can never create a
// second wallet on Circle.
function idempotencyKeyFor(userId: string, blockchain: string): string {
  const h = createHash("sha256").update(`wallet:${userId}:${blockchain}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

async function findWallet(userId: string): Promise<UserWallet | undefined> {
  const rows = await db
    .select()
    .from(wallets)
    .where(and(eq(wallets.userId, userId), eq(wallets.blockchain, env.CIRCLE_BLOCKCHAIN)))
    .limit(1);
  return rows[0];
}

export async function ensureUserWallet(userId: string): Promise<UserWallet> {
  const existing = await findWallet(userId);
  if (existing) return existing;

  const res = await circle.createWallets({
    walletSetId: env.CIRCLE_WALLET_SET_ID,
    blockchains: [env.CIRCLE_BLOCKCHAIN as "ARC-TESTNET"],
    count: 1,
    accountType: "EOA",
    idempotencyKey: idempotencyKeyFor(userId, env.CIRCLE_BLOCKCHAIN),
  });
  const created = res.data?.wallets?.[0];
  if (!created?.id || !created.address) {
    throw new Error("Circle did not return a wallet");
  }

  await db
    .insert(wallets)
    .values({
      userId,
      purpose: "user",
      circleWalletId: created.id,
      circleWalletSetId: env.CIRCLE_WALLET_SET_ID,
      custodyType: "DEVELOPER",
      blockchain: env.CIRCLE_BLOCKCHAIN,
      address: created.address,
    })
    .onConflictDoNothing();

  const saved = await findWallet(userId);
  if (!saved) throw new Error("Wallet was created on Circle but could not be saved");
  return saved;
}

// USDC balance as a decimal string, for example "12.5". "0" when empty.
export async function getUsdcBalance(circleWalletId: string): Promise<string> {
  const res = await circle.getWalletTokenBalance({ id: circleWalletId });
  const balances = res.data?.tokenBalances ?? [];
  const usdc = balances.find((b) => b.token?.symbol?.toUpperCase().startsWith("USDC"));
  return usdc?.amount ?? "0";
}
EOF

cat > backend/scripts/wallet-smoke.ts <<'EOF'
// Creates a wallet for a temporary test user on Circle (testnet),
// checks it is reused on the second call, reads the balance, then removes
// the test user from the database. The empty testnet wallet stays on Circle.
// Run with: npx tsx scripts/wallet-smoke.ts
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { users, wallets } from "../src/db/schema";
import { ensureUserWallet, getUsdcBalance } from "../src/wallets/service";

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function main() {
  const userId = randomUUID();
  await db.insert(users).values({
    id: userId,
    name: "Wallet Smoke Test",
    email: `walletsmoke+${Date.now()}@example.com`,
    emailVerified: true,
    phone: "+2348012345678",
  });

  try {
    const first = await ensureUserWallet(userId);
    check(/^0x[0-9a-fA-F]{40}$/.test(first.address), "a wallet with a valid address was created", first);

    const second = await ensureUserWallet(userId);
    check(second.id === first.id && second.address === first.address, "the same wallet is reused, never a second one");

    const balance = await getUsdcBalance(first.circleWalletId);
    check(!Number.isNaN(Number(balance)), `the USDC balance can be read (${balance})`);
  } finally {
    await db.delete(wallets).where(eq(wallets.userId, userId));
    await db.delete(users).where(eq(users.id, userId));
    console.log("Cleaned up the test user");
  }
}

main()
  .then(() => {
    console.log("All wallet checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    const detail = (err as { response?: { data?: unknown } }).response?.data;
    console.error(err instanceof Error ? err.message : err, detail ? JSON.stringify(detail) : "");
    process.exit(1);
  });
EOF

# API routes: insert the wallet route after /api/me and mark the status
python3 - <<'PY'
import re, sys
p = "backend/src/app.ts"
s = open(p).read()
if "ensureUserWallet" not in s:
    s = s.replace(
        'import { env } from "./env";',
        'import { env } from "./env";\nimport { NETWORK_NAMES, ensureUserWallet, getUsdcBalance } from "./wallets/service";',
        1,
    )
    route = '''
// The signed in user's wallet. Created on first visit, then reused.
app.get("/api/wallet", requireAuth, async (c) => {
  const { user } = c.get("auth");
  if (!user.emailVerified) {
    return c.json({ error: "Please confirm your email first" }, 403);
  }
  const wallet = await ensureUserWallet(user.id);
  let usdc: string | null = null;
  try {
    usdc = await getUsdcBalance(wallet.circleWalletId);
  } catch (err) {
    console.error("[wallet] balance lookup failed:", err);
  }
  return c.json({
    wallet: {
      address: wallet.address,
      blockchain: wallet.blockchain,
      network: NETWORK_NAMES[wallet.blockchain] ?? wallet.blockchain,
      testnet: wallet.blockchain.endsWith("TESTNET"),
    },
    balance: { usdc },
  });
});
'''
    marker = 'app.notFound('
    if marker not in s:
        sys.exit("could not find app.notFound in app.ts")
    s = s.replace(marker, route.lstrip("\n") + "\n" + marker, 1)
s = re.sub(r'c\.json\(\{ ok: true, auth: true(, email: true)?(, wallets: true)? \}\)',
           'c.json({ ok: true, auth: true, email: true, wallets: true })', s)
open(p, "w").write(s)
PY
grep -q 'wallets: true' backend/src/app.ts || fail "Could not update /api/status in backend/src/app.ts"
grep -q '"/api/wallet"' backend/src/app.ts || fail "Could not add /api/wallet to backend/src/app.ts"
green "OK: backend files written"

# --- 5. Frontend code -----------------------------------------------------------
step "Writing frontend files"
mkdir -p frontend/src/components
cat > frontend/src/components/WalletCard.tsx <<'EOF'
"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean };
  balance: { usdc: string | null };
};

function formatUsdc(amount: string | null): string {
  if (amount === null) return "unavailable";
  const n = Number(amount);
  if (Number.isNaN(n)) return amount;
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

export function WalletCard() {
  const [data, setData] = useState<WalletResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await api<WalletResponse>("/wallet"));
    } catch {
      setError("We could not load your wallet. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function copy() {
    if (!data) return;
    await navigator.clipboard.writeText(data.wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium text-zinc-500">Your USDC wallet</h2>
        {data ? (
          <span className="rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
            {data.wallet.network}
          </span>
        ) : null}
      </div>

      {loading && !data ? (
        <p className="mt-4 text-sm text-zinc-500">Setting up your wallet...</p>
      ) : null}

      {error ? (
        <div className="mt-4 space-y-3">
          <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          <button onClick={load} className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Try again
          </button>
        </div>
      ) : null}

      {data ? (
        <div className="mt-4 space-y-5">
          <div>
            <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
              {formatUsdc(data.balance.usdc)} <span className="text-lg font-medium text-zinc-500">USDC</span>
            </p>
            <button
              onClick={load}
              disabled={loading}
              className="mt-1 text-sm font-medium text-emerald-700 hover:underline disabled:opacity-60 dark:text-emerald-400"
            >
              {loading ? "Refreshing..." : "Refresh balance"}
            </button>
          </div>

          <div>
            <p className="text-sm text-zinc-500">Wallet address (to receive USDC on {data.wallet.network} only)</p>
            <div className="mt-1 flex items-center gap-2">
              <code className="min-w-0 flex-1 truncate rounded-lg bg-zinc-100 px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100">
                {data.wallet.address}
              </code>
              <button
                onClick={copy}
                className="shrink-0 rounded-lg border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          </div>

          {data.wallet.testnet ? (
            <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
              Test network: this USDC has no real value. Get free test USDC at{" "}
              <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                faucet.circle.com
              </a>{" "}
              (choose Arc Testnet and paste your address).
            </p>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
EOF

python3 - <<'PY'
import sys
p = "frontend/src/app/dashboard/page.tsx"
s = open(p).read()
if "WalletCard" not in s:
    s = s.replace('import { authClient } from "@/lib/auth-client";',
                  'import { WalletCard } from "@/components/WalletCard";\nimport { authClient } from "@/lib/auth-client";', 1)
    old_start = '<section className="mt-4 rounded-2xl border border-dashed'
    i = s.find(old_start)
    if i < 0:
        sys.exit("could not find the placeholder section in dashboard/page.tsx")
    j = s.find("</section>", i) + len("</section>")
    s = s[:i] + "<WalletCard />" + s[j:]
open(p, "w").write(s)
PY
grep -q '<WalletCard />' frontend/src/app/dashboard/page.tsx || fail "Could not add the wallet card to the dashboard"
green "OK: frontend files written"

# --- 6. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Wallets: real test on Circle (Arc Testnet) with a temporary user"
(cd backend && npx tsx scripts/wallet-smoke.ts) || fail "Wallet test failed (details above). Nothing was committed."

step "Auth: make sure signup and login still work"
OUTBOX="$(mktemp)"
(cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  fail "Auth test failed (details above). Nothing was committed."
fi
kill "$API_PID" 2>/dev/null || true; rm -f "$OUTBOX"

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 7. Render settings -------------------------------------------------------------
step "Adding 4 settings on Render"
read -r -p "Have you already added the 4 CIRCLE_ settings on Render? (y/n) " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  echo
  bold "In your browser: Render > your API service > Environment > add these 4:"
  echo
  echo "     CIRCLE_BLOCKCHAIN      ARC-TESTNET"
  echo "     CIRCLE_WALLET_SET_ID   $(env_get CIRCLE_WALLET_SET_ID)"
  if command -v clip.exe >/dev/null 2>&1; then
    echo "     CIRCLE_API_KEY         (copied to your clipboard in the next step)"
    echo "     CIRCLE_ENTITY_SECRET   (copied to your clipboard after that)"
    echo
    to_clipboard "$(env_get CIRCLE_API_KEY)"
    pause "CIRCLE_API_KEY is on your clipboard. Paste it on Render, then"
    to_clipboard "$(env_get CIRCLE_ENTITY_SECRET)"
    pause "CIRCLE_ENTITY_SECRET is on your clipboard. Paste it on Render, then"
    to_clipboard " "
  else
    yellow "     CIRCLE_API_KEY and CIRCLE_ENTITY_SECRET: copy them from $ENV_FILE"
  fi
  echo
  echo "  Then click 'Save, rebuild, and deploy' (or 'Save Changes')."
  pause "When all 4 are saved,"
fi
green "OK"

# --- 8. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
secret_scan
git commit -q -m "Phase 6: Circle USDC wallet for every user (Arc Testnet)"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"wallets":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render (a missing CIRCLE_ setting stops it starting)."
wait_for "the website" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 6 complete. Every user now gets a USDC wallet on Arc Testnet."
echo "  Open $PROD_FRONTEND/dashboard and log in: your wallet appears in a few seconds."
echo "  Get free test USDC at https://faucet.circle.com (choose Arc Testnet, paste your address),"
echo "  then click 'Refresh balance'."
