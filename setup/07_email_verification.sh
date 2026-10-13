#!/usr/bin/env bash
# =============================================================================
# dataonchain | Script 07 (Phase 5): email verification with Resend
#
# What this adds:
#   - New users must confirm their email before they can log in
#   - Confirmation email sent from your own domain through Resend
#   - Clicking the link confirms the email AND logs the user in
#   - "Check your inbox" screen after signup, with a resend button
#   - Logging in with an unconfirmed email sends a fresh link automatically
#
# Before running, on resend.com:
#   1. Domains > Add domain > use a subdomain like mail.yourdomain.com
#      Add the DNS records Resend shows you, then click Verify
#   2. API Keys > Create API key (Sending access) > copy it (starts with re_)
#
# Run from the project folder:
#   cd ~/dataonchain
#   bash setup/07_email_verification.sh
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
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    # use a separator that cannot appear in keys, emails or URLs
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}

# --- 0. Checks ------------------------------------------------------------------
step "Checking the project"
[[ -d frontend && -d backend && -f backend/src/auth/index.ts ]] || fail "Run this from ~/dataonchain after Phase 4 (script 06)"
PROD_FRONTEND="$(env_get PRODUCTION_FRONTEND_URL)"
PROD_API="$(env_get PRODUCTION_API_URL)"
[[ -n "$PROD_FRONTEND" && -n "$PROD_API" ]] || fail "Production addresses missing in $ENV_FILE"
if [[ -n "$(git status --porcelain | grep -v 'setup/07_email_verification.sh' || true)" ]]; then
  git status --short
  yellow "There are uncommitted changes (listed above)."
  yellow "That is expected if this script stopped halfway before. Otherwise answer n."
  read -r -p "Continue? (y/n) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || fail "Stopped. Commit or undo those changes first."
fi
green "OK"

# --- 1. Resend settings ------------------------------------------------------------
step "Resend settings"
EMAIL_FROM="$(env_get EMAIL_FROM)"
if [[ -z "$EMAIL_FROM" ]]; then
  echo "Which domain did you verify on Resend? (the exact one shown under Domains)"
  read -r -p "Sending domain, for example mail.yourdomain.com: " SEND_DOMAIN
  SEND_DOMAIN="${SEND_DOMAIN#http://}"; SEND_DOMAIN="${SEND_DOMAIN#https://}"; SEND_DOMAIN="${SEND_DOMAIN%/}"
  [[ "$SEND_DOMAIN" == *.* && "$SEND_DOMAIN" != *" "* ]] || fail "That does not look like a domain"
  EMAIL_FROM="dataonchain <no-reply@$SEND_DOMAIN>"
  printf '\n# Email (Resend)\n' >> "$ENV_FILE"
  env_set EMAIL_FROM "$EMAIL_FROM"
fi
green "OK: emails come from $EMAIL_FROM"

if [[ -z "$(env_get RESEND_API_KEY)" ]]; then
  echo "Paste your Resend API key (it starts with re_). It will not show on screen."
  read -r -s -p "Resend API key: " RESEND_KEY; echo
  [[ "$RESEND_KEY" == re_* ]] || fail "That does not look like a Resend API key (it should start with re_)"
  env_set RESEND_API_KEY "$RESEND_KEY"
  unset RESEND_KEY
fi
green "OK: Resend API key saved in $ENV_FILE"

# --- 2. Packages ----------------------------------------------------------------
step "Installing packages"
(cd backend && npm install resend)
green "OK"

# --- 3. Backend code ------------------------------------------------------------
step "Writing backend files"

cat >> backend/.env.example <<'EOF'

# Email (Resend). Without a key, emails are printed in the terminal instead.
RESEND_API_KEY=re_your_key
EMAIL_FROM=dataonchain <no-reply@mail.yourdomain.com>
EOF
# keep the example file tidy if this script runs twice
awk '!(/^# Email \(Resend\)/ && seen++) && !(/^RESEND_API_KEY=/ && s2++) && !(/^EMAIL_FROM=/ && s3++)' backend/.env.example > backend/.env.example.tmp
mv backend/.env.example.tmp backend/.env.example

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
};
EOF

mkdir -p backend/src/email
cat > backend/src/email/index.ts <<'EOF'
// Sends emails through Resend.
// Without RESEND_API_KEY (local only) the email is printed in the terminal.
// Tests set EMAIL_OUTBOX_FILE so emails are written to a file instead.
import { appendFile } from "node:fs/promises";
import { Resend } from "resend";
import { env } from "../env";

export type Email = { to: string; subject: string; html: string; text: string };

const resend = env.RESEND_API_KEY ? new Resend(env.RESEND_API_KEY) : null;

export async function sendEmail(email: Email): Promise<void> {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (outbox) {
    await appendFile(outbox, `${JSON.stringify(email)}\n`);
    return;
  }
  if (!resend) {
    console.warn(`[email] RESEND_API_KEY not set. Email to ${email.to}: ${email.subject}\n${email.text}`);
    return;
  }
  const { error } = await resend.emails.send({
    from: env.EMAIL_FROM,
    to: email.to,
    subject: email.subject,
    html: email.html,
    text: email.text,
  });
  if (error) {
    throw new Error(`Resend refused the email: ${error.name}: ${error.message}`);
  }
}
EOF

cat > backend/src/email/templates.ts <<'EOF'
// Email wording. Plain text and HTML versions of every email.
function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === '"' ? "&quot;" : "&#39;",
  );
}

export function verificationEmail(name: string, url: string) {
  const first = name.trim().split(/\s+/)[0] || "there";
  const subject = "Confirm your email for dataonchain";

  const text = [
    `Hi ${first},`,
    "",
    "Confirm your email to finish setting up your dataonchain account:",
    url,
    "",
    "This link expires after one hour. If you did not create an account, you can ignore this email.",
    "",
    "dataonchain",
  ].join("\n");

  const safeUrl = escapeHtml(url);
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain</td></tr>
          <tr><td style="padding-top:24px;font-size:16px;">Hi ${escapeHtml(first)},</td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">Confirm your email to finish setting up your account.</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${safeUrl}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">Confirm my email</a>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">
            This link expires after one hour. If the button does not work, copy this address into your browser:<br>
            <span style="word-break:break-all;">${safeUrl}</span>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;color:#71717a;">If you did not create an account, you can ignore this email.</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  return { subject, text, html };
}
EOF

cat > backend/src/auth/index.ts <<'EOF'
// Better Auth: signup, login, sessions, email verification.
// All routes live under /api/auth/* (see app.ts).
import { randomUUID } from "node:crypto";
import { betterAuth } from "better-auth";
import { APIError } from "better-auth/api";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import { db } from "../db";
import { accounts, sessions, users, verifications } from "../db/schema";
import { sendEmail } from "../email";
import { verificationEmail } from "../email/templates";
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
    // No login until the email is confirmed.
    requireEmailVerification: true,
    autoSignIn: false,
  },

  emailVerification: {
    sendOnSignUp: true,
    // Logging in with an unconfirmed email sends a fresh link.
    sendOnSignIn: true,
    // Clicking the link also logs the user in.
    autoSignInAfterVerification: true,
    sendVerificationEmail: async ({ user, url }) => {
      const message = verificationEmail(user.name, url);
      // Not awaited on purpose: the response time must not reveal anything.
      void sendEmail({ to: user.email, ...message }).catch((err) => {
        console.error("[email] verification email failed:", err);
      });
    },
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

# status endpoint now reports email too (the deploy wait looks for it)
sed -i 's/c.json({ ok: true, auth: true })/c.json({ ok: true, auth: true, email: true })/' backend/src/app.ts
grep -q 'email: true' backend/src/app.ts || fail "Could not update /api/status in backend/src/app.ts"

cat > backend/scripts/send-test-email.ts <<'EOF'
// Sends one real email through Resend to check the domain and key work.
// Run with: npx tsx scripts/send-test-email.ts you@example.com
import { config } from "dotenv";
import { Resend } from "resend";

config({ path: ".env", quiet: true });

async function main() {
  const to = process.argv[2];
  const key = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM;
  if (!to) throw new Error("Give an email address to send to");
  if (!key || !from) throw new Error("RESEND_API_KEY and EMAIL_FROM must be set in backend/.env");

  const { data, error } = await new Resend(key).emails.send({
    from,
    to,
    subject: "dataonchain test email",
    text: "If you can read this, dataonchain can send emails from your domain.",
  });
  if (error) throw new Error(`${error.name}: ${error.message}`);
  console.log(`Sent. Resend id: ${data?.id}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
EOF

cat > backend/scripts/auth-smoke.ts <<'EOF'
// End to end auth test against a running backend, then cleans up.
// The backend must run with EMAIL_OUTBOX_FILE set, so emails land in that file.
// Run with: EMAIL_OUTBOX_FILE=/tmp/outbox.jsonl npx tsx scripts/auth-smoke.ts http://localhost:4000
import { readFile } from "node:fs/promises";
import { config } from "dotenv";
import { createClient } from "@libsql/client";

config({ path: ".env", quiet: true });

const base = (process.argv[2] ?? "http://localhost:4000").replace(/\/$/, "");
const origin = (process.env.BETTER_AUTH_URL ?? "http://localhost:3000").replace(/\/$/, "");
const outbox = process.env.EMAIL_OUTBOX_FILE;
const email = `smoketest+${Date.now()}@example.com`;
const password = "Sm0ke-test-password";

type Result = { status: number; body: unknown; cookies: string[]; location: string | null };

async function call(path: string, method: string, body?: unknown, cookie?: string): Promise<Result> {
  const res = await fetch(path.startsWith("http") ? path : base + path, {
    method,
    redirect: "manual",
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
  return {
    status: res.status,
    body: parsed,
    cookies: res.headers.getSetCookie(),
    location: res.headers.get("location"),
  };
}

const cookieOf = (r: Result) => r.cookies.map((c) => c.split(";")[0]).join("; ");

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

async function latestEmailTo(to: string): Promise<{ subject: string; text: string } | null> {
  if (!outbox) throw new Error("EMAIL_OUTBOX_FILE is not set");
  for (let i = 0; i < 20; i++) {
    const lines = (await readFile(outbox, "utf8").catch(() => "")).trim().split("\n").filter(Boolean);
    const found = lines.map((l) => JSON.parse(l) as { to: string; subject: string; text: string }).filter((m) => m.to === to);
    if (found.length > 0) return found[found.length - 1]!;
    await new Promise((r) => setTimeout(r, 250));
  }
  return null;
}

async function cleanup() {
  const db = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });
  const where = "user_id IN (SELECT id FROM users WHERE email LIKE 'smoketest+%@example.com')";
  await db.execute(`DELETE FROM sessions WHERE ${where}`);
  await db.execute(`DELETE FROM accounts WHERE ${where}`);
  await db.execute("DELETE FROM verifications WHERE identifier LIKE '%smoketest+%'");
  await db.execute("DELETE FROM users WHERE email LIKE 'smoketest+%@example.com'");
  db.close();
  console.log("Cleaned up test users");
}

async function main() {
  const bad = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test", email: `bad-${email}`, password, phone: "12345",
  });
  check(bad.status >= 400 && bad.status < 500, "invalid phone number is refused", bad.body);

  const signUp = await call("/api/auth/sign-up/email", "POST", {
    name: "Smoke Test", email, password, phone: "0801 234 5678", callbackURL: "/dashboard",
  });
  check(signUp.status === 200, "sign up", signUp.body);

  const early = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(early.status === 403, "log in is blocked until the email is confirmed", early.body);

  const message = await latestEmailTo(email);
  check(message !== null, "a confirmation email was sent");
  const link = message!.text.match(/https?:\/\/\S+/)?.[0];
  check(Boolean(link && link.includes("verify-email")), "the email contains a confirmation link", message);

  // The link points at the website; in this test we open it on the backend directly.
  const url = new URL(link!);
  const verify = await call(base + url.pathname + url.search, "GET");
  check(verify.status >= 300 && verify.status < 400, "the confirmation link works", verify.body);
  const cookie = cookieOf(verify);
  check(cookie.length > 0, "confirming the email logs the user in");

  const session = await call("/api/auth/get-session", "GET", undefined, cookie);
  const user = (session.body as { user?: { email?: string; emailVerified?: boolean } } | null)?.user;
  check(user?.email === email && user.emailVerified === true, "the email is now marked as confirmed", session.body);

  const me = await call("/api/me", "GET", undefined, cookie);
  const meUser = (me.body as { user?: { phone?: string; role?: string } }).user;
  check(meUser?.phone === "+2348012345678", "phone saved as +2348012345678", me.body);
  check(meUser?.role === "user", "new users get the 'user' role", me.body);

  const anon = await call("/api/me", "GET");
  check(anon.status === 401, "/api/me refuses visitors who are not logged in", anon.body);

  const signOut = await call("/api/auth/sign-out", "POST", {}, cookie);
  check(signOut.status === 200, "sign out", signOut.body);

  const login = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(login.status === 200, "log in after confirming", login.body);

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
green "OK: backend files written"

# --- 4. Frontend code -----------------------------------------------------------
step "Writing frontend files"

cat > frontend/src/app/signup/page.tsx <<'EOF'
"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function SignupPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    const email = String(form.get("email")).trim();
    setBusy(true);
    const { error } = await authClient.signUp.email({
      name: String(form.get("name")).trim(),
      email,
      phone: String(form.get("phone")).trim(),
      password,
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not create your account. Please try again.");
      return;
    }
    setSentTo(email);
  }

  async function resend() {
    if (!sentTo) return;
    setBusy(true);
    await authClient.sendVerificationEmail({ email: sentTo, callbackURL: "/dashboard" });
    setBusy(false);
    setResent(true);
  }

  if (sentTo) {
    return (
      <AuthShell
        title="Check your inbox"
        subtitle="One last step to finish setting up your account."
        footer={
          <>
            Already confirmed?{" "}
            <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
              Log in
            </Link>
          </>
        }
      >
        <div className="space-y-4 text-sm text-zinc-700 dark:text-zinc-300">
          <p>
            We sent a confirmation link to <strong className="text-zinc-900 dark:text-zinc-50">{sentTo}</strong>.
            Click it to confirm your email and you will be logged in.
          </p>
          <p className="text-zinc-500">Not there after a minute? Check your spam folder.</p>
          {resent ? (
            <p className="rounded-lg bg-emerald-50 px-3 py-2 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
              We sent a new link.
            </p>
          ) : (
            <button
              type="button"
              onClick={resend}
              disabled={busy}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 font-medium text-zinc-900 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-800"
            >
              {busy ? "Please wait..." : "Send the link again"}
            </button>
          )}
        </div>
      </AuthShell>
    );
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
import { useEffect, useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function LoginPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Arriving from an expired or used confirmation link
  useEffect(() => {
    if (new URLSearchParams(window.location.search).get("error") === "link") {
      setNotice("That confirmation link has expired or was already used. Log in and we will send you a new one.");
    }
  }, []);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setNotice(null);
    setBusy(true);
    const form = new FormData(event.currentTarget);
    const email = String(form.get("email")).trim();
    const { error } = await authClient.signIn.email({
      email,
      password: String(form.get("password")),
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      if (error.status === 403) {
        setNotice(`Please confirm your email first. We just sent a new link to ${email}.`);
        return;
      }
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
        {notice ? (
          <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">{notice}</p>
        ) : null}
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
    if (isPending || data) return;
    // A failed confirmation link lands here with ?error=...
    const failedLink = new URLSearchParams(window.location.search).has("error");
    router.replace(failedLink ? "/login?error=link" : "/login");
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
            <dd className="flex items-center gap-2 text-zinc-900 dark:text-zinc-100">
              {user.email}
              {user.emailVerified ? (
                <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                  Confirmed
                </span>
              ) : null}
            </dd>
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
green "OK: frontend files written"

# --- 5. Local checks ------------------------------------------------------------
step "Backend: type check and build"
(cd backend && npm run typecheck && npm run build)
green "OK"

step "Backend: full signup, email confirmation and login test (development database)"
OUTBOX="$(mktemp)"
(cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" PORT=4099 exec node dist/index.js > /tmp/dataonchain-api.log 2>&1) &
API_PID=$!
for _ in $(seq 1 20); do
  sleep 1
  curl -s http://localhost:4099/health | grep -q '"status":"ok"' && break
done
if ! (cd backend && EMAIL_OUTBOX_FILE="$OUTBOX" npx tsx scripts/auth-smoke.ts http://localhost:4099); then
  kill "$API_PID" 2>/dev/null || true
  rm -f "$OUTBOX"
  echo "--- server log ---"; tail -40 /tmp/dataonchain-api.log
  fail "Auth test failed (details above). Nothing was committed."
fi
kill "$API_PID" 2>/dev/null || true
rm -f "$OUTBOX"

step "Frontend: build"
(cd frontend && npm run build)
green "OK"

# --- 6. Real email test -------------------------------------------------------------
step "Sending a real test email through Resend"
read -r -p "Your email address (to receive the test): " TEST_TO
if ! (cd backend && npx tsx scripts/send-test-email.ts "$TEST_TO"); then
  echo
  yellow "Resend refused the email. Most common reasons:"
  yellow "  - the domain is not verified yet (resend.com > Domains should say Verified)"
  yellow "  - EMAIL_FROM in $ENV_FILE does not use that exact domain"
  yellow "  - the API key was copied wrongly (fix RESEND_API_KEY in $ENV_FILE)"
  fail "Fix it and run this script again. Nothing was committed."
fi
pause "Check that inbox (and spam) for 'dataonchain test email'. When it has arrived,"

# --- 7. Render settings -------------------------------------------------------------
step "Adding 2 settings on Render"
read -r -p "Have you already added RESEND_API_KEY and EMAIL_FROM on Render? (y/n) " ans
if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
  echo
  bold "In your browser:"
  echo "  1. Open https://dashboard.render.com and click your API service"
  echo "  2. Go to Environment, then add these 2 variables:"
  echo
  echo "     EMAIL_FROM       $EMAIL_FROM"
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$(env_get RESEND_API_KEY)" | clip.exe
    echo "     RESEND_API_KEY   (already on your clipboard: paste with Ctrl+V)"
  else
    yellow "     RESEND_API_KEY   copy it from $ENV_FILE"
  fi
  echo
  echo "  3. Click 'Save, rebuild, and deploy' (or 'Save Changes')"
  echo
  pause "When both are saved,"
  command -v clip.exe >/dev/null 2>&1 && printf ' ' | clip.exe
fi
green "OK"

# --- 8. Commit, push, wait -----------------------------------------------------------
step "Committing to GitHub"
git add -A
if git diff --cached --name-only | grep -E '(^|/)\.env($|\.local|\.production|\.development|\.local\.bak)$'; then
  git reset -q
  fail "A real .env file was staged. Nothing was committed. Tell Claude."
fi
git commit -q -m "Phase 5: email verification with Resend"
git push
green "OK: pushed. Render and Vercel are now deploying."

wait_for() { # label url
  local label="$1" url="$2" body=""
  printf 'Waiting for %s ' "$label"
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 20 "$url" || true)"
    if [[ "$body" == *'"email":true'* ]]; then echo; green "OK: $label is live"; return 0; fi
    printf '.'
    sleep 10
  done
  echo
  return 1
}

step "Waiting for the new versions (usually 3 to 6 minutes)"
wait_for "the API on Render" "$PROD_API/api/status" \
  || fail "The API did not come up. Check the Logs tab on Render (a missing RESEND_API_KEY or EMAIL_FROM stops it starting)."
wait_for "the website on Vercel" "$PROD_FRONTEND/api/status" \
  || fail "The website is not passing /api to Render yet. Check the latest deployment on vercel.com."

echo
green "Phase 5 complete. Email confirmation is live."
echo "  Try it: $PROD_FRONTEND/signup  (use a real email you can open)"
echo
echo "Note: accounts created before today are not confirmed yet."
echo "When they log in, they get a confirmation link by email automatically."
