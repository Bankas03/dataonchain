#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 06 (Phase 4): signup and login
#
# What this adds:
#   Backend  (Hono on Render)
#     - Better Auth: email + password signup and login, using the users,
#       sessions, accounts and verifications tables we already have
#     - Nigerian phone number required at signup, saved as +234XXXXXXXXXX
#     - role and status fields users cannot set themselves
#     - GET /api/me: returns the signed in user (template for future routes)
#   Frontend (Next.js on Vercel)
#     - Pages: / (home), /signup, /login, /dashboard (signed in only)
#     - Every /api/... call is passed through the website to Render, so the
#       browser only ever talks to your website and login cookies just work
#
# What it does, in order:
#   1. Adds auth secrets to backend/.env, updates frontend/.env.local
#   2. Installs packages and writes the code
#   3. Tests locally: signs up a test user, checks the session and /api/me,
#      checks a bad phone number is refused, signs out, deletes the test user
#   4. Guides you to add 2 settings on Render (secret on your clipboard)
#   5. Points Vercel at the API, commits, pushes, waits for both to go live
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/06_auth.sh
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
FE_ENV="frontend/.env.local"
env_get() { grep -E "^$1=" "$2" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() { # key value file
  if grep -qE "^$1=" "$3"; then
    sed -i "s#^$1=.*#$1=$2#" "$3"
  else
    printf '%s=%s\n' "$1" "$2" >> "$3"
  fi
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
[[ -d frontend && -d backend && -f backend/src/app.ts ]] || fail "Run this from ~/dataonchain"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE not found"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL "$ENV_FILE")"
PROD_API="$(env_get PRODUCTION_API_URL "$ENV_FILE")"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "PRODUCTION_FRONTEND_URL or PRODUCTION_API_URL missing in $ENV_FILE. Run setup/05_deploy.sh first"
command -v openssl >/dev/null || fail "openssl not found. Run: sudo apt install -y openssl"
command -v vercel  >/dev/null || fail "Vercel CLI not found. Run setup/05_deploy.sh first"
if [[ -n "$(git status --porcelain | grep -v 'setup/06_auth.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK: website $PROD_FRONTEND, API $PROD_API"

# --- 1. Settings ----------------------------------------------------------------
step "Adding auth settings"
if [[ -z "$(env_get BETTER_AUTH_SECRET "$ENV_FILE")" ]]; then
  printf '\n# Auth (Better Auth)\n' >> "$ENV_FILE"
  env_set BETTER_AUTH_SECRET "$(openssl rand -base64 32)" "$ENV_FILE"
  env_set BETTER_AUTH_URL "http://localhost:3000" "$ENV_FILE"
  green "OK: development auth secret created in $ENV_FILE"
else
  green "OK: auth secret already in $ENV_FILE"
fi

# The website now proxies /api to the backend, so it needs a private API_URL
# (read on the server) instead of the public NEXT_PUBLIC_API_URL.
touch "$FE_ENV"
sed -i '/^NEXT_PUBLIC_API_URL=/d' "$FE_ENV"
env_set API_URL "http://localhost:4000" "$FE_ENV"
green "OK: $FE_ENV uses API_URL"

# --- 2. Packages ----------------------------------------------------------------
step "Installing packages"
(cd backend && npm install better-auth @better-auth/drizzle-adapter)
(cd frontend && npm install better-auth)
green "OK"

# --- 3. Backend code ------------------------------------------------------------
step "Writing backend files"

cat > backend/.env.example <<'EOF'
# Copy to backend/.env and fill in real values. Never commit backend/.env.
NODE_ENV=development
PORT=4000
# Comma separated list of websites allowed to call the API
FRONTEND_URL=http://localhost:3000

# Turso
TURSO_DATABASE_URL=libsql://your-database-url.turso.io
TURSO_AUTH_TOKEN=your-turso-token

# Auth (Better Auth). Create a secret with: openssl rand -base64 32
BETTER_AUTH_SECRET=change-me
# The address users open in the browser (the website, not the API)
BETTER_AUTH_URL=http://localhost:3000
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
  BETTER_AUTH_SECRET: required("BETTER_AUTH_SECRET"),
  BETTER_AUTH_URL: required("BETTER_AUTH_URL").replace(/\/$/, ""),
};
EOF

mkdir -p backend/src/auth
cat > backend/src/auth/phone.ts <<'EOF'
// Nigerian mobile numbers: 070, 080, 081, 090, 091 (and the same after +234).
// Accepts 08012345678, +2348012345678, 2348012345678, with spaces or dashes.
// Returns the standard form +2348012345678, or null if it is not valid.
export function normalizeNigerianPhone(input: string): string | null {
  const compact = input.replace(/[\s()-]/g, "");
  const match = compact.match(/^(?:\+?234|0)([789][01]\d{8})$/);
  return match ? `+234${match[1]}` : null;
}
EOF

cat > backend/src/auth/index.ts <<'EOF'
// Better Auth: signup, login, sessions.
// All routes live under /api/auth/* (see app.ts).
import { randomUUID } from "node:crypto";
import { betterAuth } from "better-auth";
import { APIError } from "better-auth/api";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import { db } from "../db";
import { accounts, sessions, users, verifications } from "../db/schema";
import { env } from "../env";
import { normalizeNigerianPhone } from "./phone";

export const auth = betterAuth({
  appName: "dataonchain",
  // The address users see. The website passes /api/* through to this server.
  baseURL: env.BETTER_AUTH_URL,
  secret: env.BETTER_AUTH_SECRET,
  trustedOrigins: env.FRONTEND_URLS,

  database: drizzleAdapter(db, {
    provider: "sqlite",
    usePlural: true,
    schema: { users, sessions, accounts, verifications },
  }),

  emailAndPassword: {
    enabled: true,
    minPasswordLength: 8,
    autoSignIn: true,
  },

  user: {
    additionalFields: {
      phone: { type: "string", required: true },
      // Users can never set these themselves.
      role: { type: "string", required: false, defaultValue: "user", input: false },
      status: { type: "string", required: false, defaultValue: "active", input: false },
    },
  },

  databaseHooks: {
    user: {
      create: {
        before: async (user) => {
          const raw = String((user as { phone?: unknown }).phone ?? "");
          const phone = normalizeNigerianPhone(raw);
          if (!phone) {
            throw new APIError("BAD_REQUEST", {
              message: "Enter a valid Nigerian phone number, for example 08012345678",
            });
          }
          return { data: { ...user, phone } };
        },
      },
    },
  },

  advanced: {
    database: { generateId: () => randomUUID() },
  },
});

export type AuthSession = typeof auth.$Infer.Session;
EOF

cat > backend/src/auth/middleware.ts <<'EOF'
// Protects a route: only signed in users get through.
// Usage: app.get("/api/something", requireAuth, (c) => { const { user } = c.get("auth"); ... })
import { createMiddleware } from "hono/factory";
import { auth, type AuthSession } from "./index";

export const requireAuth = createMiddleware<{ Variables: { auth: AuthSession } }>(
  async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers });
    if (!session) {
      return c.json({ error: "Please log in" }, 401);
    }
    c.set("auth", session);
    await next();
  },
);
EOF

cat > backend/src/app.ts <<'EOF'
// The API: routes, CORS and error handling.
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { auth } from "./auth";
import { requireAuth } from "./auth/middleware";
import { client } from "./db";
import { env } from "./env";

export const app = new Hono();

app.use("*", logger());
app.use(
  "*",
  cors({
    origin: env.FRONTEND_URLS,
    credentials: true,
    allowHeaders: ["Content-Type", "Authorization"],
    allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
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

// Quick check that the API (and the website's /api pass through) is up.
app.get("/api/status", (c) => c.json({ ok: true, auth: true }));

// Signup, login, logout, sessions (Better Auth)
app.all("/api/auth/*", (c) => auth.handler(c.req.raw));

// The signed in user's own profile
app.get("/api/me", requireAuth, (c) => {
  const { user } = c.get("auth");
  const extra = user as { phone?: string; role?: string; status?: string };
  return c.json({
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      emailVerified: user.emailVerified,
      phone: extra.phone ?? null,
      role: extra.role ?? "user",
      status: extra.status ?? "active",
    },
  });
});

app.notFound((c) => c.json({ error: "Not found" }, 404));

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "Internal server error" }, 500);
});
EOF

cat > backend/scripts/auth-smoke.ts <<'EOF'
// End to end auth test against a running backend, then cleans up.
// Run with: npx tsx scripts/auth-smoke.ts http://localhost:4000
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const base = (process.argv[2] ?? "http://localhost:4000").replace(/\/$/, "");
const origin = (process.env.BETTER_AUTH_URL ?? "http://localhost:3000").replace(/\/$/, "");
const email = `smoketest+${Date.now()}@example.com`;
const password = "Sm0ke-test-password";

type Result = { status: number; body: unknown; cookies: string[] };

async function call(path: string, method: string, body?: unknown, cookie?: string): Promise<Result> {
  const res = await fetch(base + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      Origin: origin,
      ...(cookie ? { Cookie: cookie } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // not JSON
  }
  return { status: res.status, body: parsed, cookies: res.headers.getSetCookie() };
}

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function cleanup() {
  const db = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });
  const where = "user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com')";
  await db.execute(`DELETE FROM sessions WHERE ${where}`);
  await db.execute(`DELETE FROM accounts WHERE ${where}`);
  await db.execute("DELETE FROM users WHERE email LIKE 'smoketest+%@example.com'");
  db.close();
  console.log("Cleaned up test users");
}

async function main() {
  const bad = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test",
    email: `bad-${email}`,
    password,
    phone: "12345",
  });
  check(bad.status >= 400 && bad.status < 500, "invalid phone number is refused", bad.body);

  const signUp = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test",
    email,
    password,
    phone: "0801 234 5678",
  });
  check(signUp.status === 200, "sign up", signUp.body);
  const cookie = signUp.cookies.map((c) => c.split(";")[0]).join("; ");
  check(cookie.length > 0, "sign up sets a login cookie");

  const session = await call("/api/auth/get-session", "GET", undefined, cookie);
  const sessionUser = (session.body as { user?: { email?: string } } | null)?.user;
  check(sessionUser?.email === email, "session belongs to the new user", session.body);

  const me = await call("/api/me", "GET", undefined, cookie);
  const meUser = (me.body as { user?: { phone?: string; role?: string } }).user;
  check(meUser?.phone === "+2348012345678", "phone saved as +2348012345678", me.body);
  check(meUser?.role === "user", "new users get the 'user' role", me.body);

  const anon = await call("/api/me", "GET");
  check(anon.status === 401, "/api/me refuses visitors who are not logged in", anon.body);

  const signOut = await call("/api/auth/sign-out", "POST", {}, cookie);
  check(signOut.status === 200, "sign out", signOut.body);

  const login = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(login.status === 200, "log in with the same password", login.body);

  const wrong = await call("/api/auth/sign-in/email", "POST", { email, password: "wrong-password" });
  check(wrong.status === 401 || wrong.status === 400, "wrong password is refused", wrong.body);
}

main()
  .then(cleanup)
  .then(() => console.log("All auth checks passed."))
  .catch(async (err) => {
    await cleanup().catch(() => undefined);
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
EOF
(cd backend && npm pkg set scripts.test:auth="tsx scripts/auth-smoke.ts")
green "OK: backend files written"

# --- 4. Frontend code -----------------------------------------------------------
step "Writing frontend files"

cat > frontend/.env.example <<'EOF'
# Copy to frontend/.env.local. No secrets here.
# Where the website forwards /api requests (read on the server, not in the browser)
API_URL=http://localhost:4000
EOF

cat > frontend/next.config.ts <<'EOF'
import type { NextConfig } from "next";

// Every /api/... request to the website is passed through to the backend.
// The browser only talks to the website, so login cookies stay first party.
const API_URL = (process.env.API_URL ?? "http://localhost:4000").replace(/\/$/, "");

const nextConfig: NextConfig = {
  async rewrites() {
    return [{ source: "/api/:path*", destination: `${API_URL}/api/:path*` }];
  },
};

export default nextConfig;
EOF

cat > frontend/src/lib/api.ts <<'EOF'
// Calls the backend through the website's /api pass through.
export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`/api${path}`, {
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

cat > frontend/src/lib/auth-client.ts <<'EOF'
// Login, signup and session helpers for the browser.
import { createAuthClient } from "better-auth/react";
import { inferAdditionalFields } from "better-auth/client/plugins";

export const authClient = createAuthClient({
  baseURL:
    typeof window !== "undefined" ? window.location.origin : "http://localhost:3000",
  plugins: [
    inferAdditionalFields({
      user: {
        phone: { type: "string", required: true },
        role: { type: "string", required: false, input: false },
        status: { type: "string", required: false, input: false },
      },
    }),
  ],
});
EOF

mkdir -p frontend/src/components
cat > frontend/src/components/AuthShell.tsx <<'EOF'
import Link from "next/link";
import type { InputHTMLAttributes, ReactNode } from "react";

// Shared frame for the login and signup pages.
export function AuthShell({
  title,
  subtitle,
  children,
  footer,
}: {
  title: string;
  subtitle: string;
  children: ReactNode;
  footer: ReactNode;
}) {
  return (
    <main className="min-h-screen flex items-center justify-center bg-zinc-50 px-4 py-12 dark:bg-zinc-950">
      <div className="w-full max-w-sm">
        <Link href="/" className="block text-center text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
          dataonchain
        </Link>
        <div className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <h1 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">{title}</h1>
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{subtitle}</p>
          <div className="mt-6">{children}</div>
        </div>
        <p className="mt-4 text-center text-sm text-zinc-600 dark:text-zinc-400">{footer}</p>
      </div>
    </main>
  );
}

export function Field({
  label,
  hint,
  ...input
}: { label: string; hint?: string } & InputHTMLAttributes<HTMLInputElement>) {
  return (
    <label className="block">
      <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">{label}</span>
      <input
        {...input}
        className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 outline-none focus:border-emerald-600 focus:ring-2 focus:ring-emerald-600/20 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
      />
      {hint ? <span className="mt-1 block text-xs text-zinc-500">{hint}</span> : null}
    </label>
  );
}

export function SubmitButton({ busy, children }: { busy: boolean; children: ReactNode }) {
  return (
    <button
      type="submit"
      disabled={busy}
      className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white transition hover:bg-emerald-800 disabled:opacity-60"
    >
      {busy ? "Please wait..." : children}
    </button>
  );
}

export function FormError({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
      {message}
    </p>
  );
}
EOF

cat > frontend/src/app/page.tsx <<'EOF'
import Link from "next/link";

export default function Home() {
  return (
    <main className="min-h-screen bg-zinc-50 px-4 dark:bg-zinc-950">
      <div className="mx-auto flex min-h-screen max-w-2xl flex-col justify-center py-16">
        <p className="text-sm font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">dataonchain</p>
        <h1 className="mt-4 text-4xl font-semibold tracking-tight text-zinc-900 sm:text-5xl dark:text-zinc-50">
          Buy airtime and data with USDC.
        </h1>
        <p className="mt-4 max-w-xl text-lg text-zinc-600 dark:text-zinc-400">
          Top up any MTN, Airtel, Glo or 9mobile line in seconds. Paid in USDC on Arc, delivered to the phone.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <Link href="/signup" className="rounded-lg bg-emerald-700 px-5 py-3 font-medium text-white hover:bg-emerald-800">
            Create an account
          </Link>
          <Link href="/login" className="rounded-lg border border-zinc-300 px-5 py-3 font-medium text-zinc-900 hover:bg-white dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-900">
            Log in
          </Link>
        </div>
      </div>
    </main>
  );
}
EOF

mkdir -p frontend/src/app/signup frontend/src/app/login frontend/src/app/dashboard
cat > frontend/src/app/signup/page.tsx <<'EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function SignupPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    setBusy(true);
    const { error } = await authClient.signUp.email({
      name: String(form.get("name")).trim(),
      email: String(form.get("email")).trim(),
      phone: String(form.get("phone")).trim(),
      password,
    });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not create your account. Please try again.");
      return;
    }
    router.push("/dashboard");
  }

  return (
    <AuthShell
      title="Create your account"
      subtitle="It takes a minute. No crypto knowledge needed."
      footer={
        <>
          Already have an account?{" "}
          <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Log in
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Full name" name="name" autoComplete="name" required />
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field
          label="Phone number"
          name="phone"
          type="tel"
          autoComplete="tel"
          placeholder="08012345678"
          hint="Nigerian mobile number"
          required
        />
        <Field label="Password" name="password" type="password" autoComplete="new-password" minLength={8} hint="At least 8 characters" required />
        <Field label="Confirm password" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
        <FormError message={error} />
        <SubmitButton busy={busy}>Create account</SubmitButton>
      </form>
    </AuthShell>
  );
}
EOF

cat > frontend/src/app/login/page.tsx <<'EOF'
"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function LoginPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(event.currentTarget);
    const { error } = await authClient.signIn.email({
      email: String(form.get("email")).trim(),
      password: String(form.get("password")),
    });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not log you in. Check your email and password.");
      return;
    }
    router.push("/dashboard");
  }

  return (
    <AuthShell
      title="Welcome back"
      subtitle="Log in to buy airtime and data."
      footer={
        <>
          New here?{" "}
          <Link href="/signup" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Create an account
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field label="Password" name="password" type="password" autoComplete="current-password" required />
        <FormError message={error} />
        <SubmitButton busy={busy}>Log in</SubmitButton>
      </form>
    </AuthShell>
  );
}
EOF

cat > frontend/src/app/dashboard/page.tsx <<'EOF'
"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";
import { authClient } from "@/lib/auth-client";

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();

  useEffect(() => {
    if (!isPending && !data) router.replace("/login");
  }, [isPending, data, router]);

  if (isPending || !data) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const { user } = data;

  async function logOut() {
    await authClient.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-2xl">
        <header className="flex items-center justify-between">
          <span className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">dataonchain</span>
          <button
            onClick={logOut}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Log out
          </button>
        </header>

        <h1 className="mt-10 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          Hello, {user.name.split(" ")[0]}
        </h1>

        <section className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="text-sm font-medium text-zinc-500">Your account</h2>
          <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-[8rem_1fr]">
            <dt className="text-zinc-500">Name</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.name}</dd>
            <dt className="text-zinc-500">Email</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.email}</dd>
            <dt className="text-zinc-500">Phone</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.phone}</dd>
          </dl>
        </section>

        <section className="mt-4 rounded-2xl border border-dashed border-zinc-300 p-6 text-sm text-zinc-500 dark:border-zinc-700">
          Your USDC wallet and purchases will appear here soon.
        </section>
      </div>
    </main>
  );
}
EOF

sed -i 's/title: "Create Next App"/title: "dataonchain"/; s/description: "Generated by create next app"/description: "Buy Nigerian airtime and data with USDC on Arc"/' frontend/src/app/layout.tsx

# Script 05 now sets API_URL on Vercel instead of NEXT_PUBLIC_API_URL
sed -i 's/NEXT_PUBLIC_API_URL/API_URL/g' setup/05_deploy.sh
green "OK: frontend files written"

# --- 5. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Backend: full signup and login test against your development database"
(cd backend && PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
if ! (cd backend && npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  kill "$API_PID" 2>/dev/null || true
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  fail "Auth test failed (details above). Nothing was committed."
fi
kill "$API_PID" 2>/dev/null || true

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 6. Render settings -----------------------------------------------------------
step "Adding 2 settings on Render"
read -r -p "Have you already added BETTER_AUTH_SECRET and BETTER_AUTH_URL on Render? (y/n) " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  PROD_SECRET="$(openssl rand -base64 32)"
  echo
  bold "In your browser:"
  echo "  1. Open https://dashboard.render.com and click your API service"
  echo "  2. Go to Environment, then add these 2 variables:"
  echo
  echo "     BETTER_AUTH_URL      $PROD_FRONTEND"
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$PROD_SECRET" | clip.exe
    echo "     BETTER_AUTH_SECRET   (already on your clipboard: paste with Ctrl+V)"
  else
    yellow "     BETTER_AUTH_SECRET   $PROD_SECRET"
    yellow "     (keep this private and clear your screen afterwards)"
  fi
  unset PROD_SECRET
  echo
  echo "  3. Click 'Save, rebuild, and deploy' (or 'Save Changes')"
  echo
  pause "When both are saved,"
  command -v clip.exe >/dev/null 2>&1 && printf ' ' | clip.exe
fi
green "OK"

# --- 7. Vercel setting -------------------------------------------------------------
step "Pointing the website at the API"
printf '%s' "$PROD_API" | vercel env add API_URL production --force --no-sensitive >/dev/null
vercel env rm NEXT_PUBLIC_API_URL production --yes >/dev/null 2>&1 || true
green "OK: API_URL = $PROD_API"

# --- 8. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
git commit -q -m "Phase 4: signup and login with Better Auth"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"ok":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab of your service on Render."
wait_for "the website on Vercel" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 4 complete. Signup and login are live."
echo "  Sign up:    $PROD_FRONTEND/signup"
echo "  Log in:     $PROD_FRONTEND/login"
echo "  Dashboard:  $PROD_FRONTEND/dashboard"
echo
echo "Try it locally too:  bash setup/dev.sh  then open http://localhost:3000/signup"
