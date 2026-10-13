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
