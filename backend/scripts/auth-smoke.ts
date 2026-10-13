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
