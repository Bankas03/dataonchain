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

  // Account page: phone number changes are checked like at sign up
  const acct = cookieOf(login);
  const badPhone = await call("/api/auth/update-user", "POST", { phone: "12345" }, acct);
  check(badPhone.status >= 400 && badPhone.status < 500, "an invalid phone number is refused on the account page", badPhone.body);
  const goodPhone = await call("/api/auth/update-user", "POST", { phone: "0803 111 2222", name: "Smoke Tester" }, acct);
  check(goodPhone.status === 200, "name and phone can be updated", goodPhone.body);
  const me2 = await call("/api/me", "GET", undefined, acct);
  const me2User = (me2.body as { user?: { phone?: string; name?: string } }).user;
  check(me2User?.phone === "+2348031112222" && me2User?.name === "Smoke Tester", "the new phone is saved as +2348031112222", me2.body);
  const roleTry = await call("/api/auth/update-user", "POST", { role: "admin" }, acct);
  const me3 = await call("/api/me", "GET", undefined, acct);
  check((me3.body as { user?: { role?: string } }).user?.role === "user", "users cannot make themselves admin", roleTry.body);

  // Order history and CSV download
  const history = await call("/api/history?page=1", "GET", undefined, acct);
  check(history.status === 200 && typeof (history.body as { total?: unknown }).total === "number", "order history loads", history.body);
  const csv = await call("/api/history.csv", "GET", undefined, acct);
  check(csv.status === 200 && typeof csv.body === "string" && (csv.body as string).startsWith('"Date (Lagos)"'), "order history downloads as CSV", csv.body);
  const anonCsv = await call("/api/history.csv", "GET");
  check(anonCsv.status === 401, "the CSV needs a login", anonCsv.status);

  // Forgot password
  const loggedIn = cookieOf(login);
  const ask = await call("/api/auth/request-password-reset", "POST", { email, redirectTo: "/reset-password" });
  check(ask.status === 200, "forgot password answers", ask.body);
  const nobody = await call("/api/auth/request-password-reset", "POST", { email: `nobody-${email}`, redirectTo: "/reset-password" });
  check(nobody.status === 200, "forgot password answers the same for an unknown email", nobody.body);
  let resetMail: { subject: string; text: string } | null = null;
  for (let i = 0; i < 20 && !resetMail; i++) {
    const m = await latestEmailTo(email);
    if (m && /reset/i.test(m.subject)) resetMail = m;
    else await new Promise((r) => setTimeout(r, 250));
  }
  check(resetMail !== null, "a password reset email was sent");
  const resetLink = resetMail!.text.match(/https?:\/\/\S+/)?.[0];
  check(Boolean(resetLink && resetLink.includes("reset-password")), "the email contains a reset link", resetMail);
  const resetUrl = new URL(resetLink!);
  const opened = await call(base + resetUrl.pathname + resetUrl.search, "GET");
  const token = /[?&]token=([^&]+)/.exec(opened.location ?? "")?.[1];
  check(opened.status >= 300 && opened.status < 400 && Boolean(token), "the reset link opens the reset page with a token", opened.location);
  const newPassword = "N3w-smoke-password";
  const reset = await call("/api/auth/reset-password", "POST", { newPassword, token });
  check(reset.status === 200, "a new password can be set", reset.body);
  const reuse = await call("/api/auth/reset-password", "POST", { newPassword: "Another-pass-123", token });
  check(reuse.status >= 400, "the same reset link cannot be used twice", reuse.body);
  const oldPass = await call("/api/auth/sign-in/email", "POST", { email, password });
  check(oldPass.status === 401 || oldPass.status === 400, "the old password no longer works", oldPass.body);
  const newPass = await call("/api/auth/sign-in/email", "POST", { email, password: newPassword });
  check(newPass.status === 200, "the new password works", newPass.body);
  const stale = await call("/api/auth/get-session", "GET", undefined, loggedIn);
  check(!(stale.body as { user?: unknown } | null)?.user, "sessions from before the reset were signed out", stale.body);
}

main()
  .then(cleanup)
  .then(() => console.log("All auth checks passed."))
  .catch(async (err) => {
    await cleanup().catch(() => undefined);
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
