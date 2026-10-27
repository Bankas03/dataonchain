// End to end test of the admin login and API against a running backend,
// on the development database. Cleans up after itself.
// The backend must run with the same ADMIN_EMAIL and with EMAIL_OUTBOX_FILE set.
// Run with:
//   ADMIN_EMAIL=admin-smoke@example.com EMAIL_OUTBOX_FILE=/tmp/x npx tsx scripts/admin-smoke.ts http://localhost:4099
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { eq, inArray, or } from "drizzle-orm";
import { db } from "../src/db";
import { adminAccounts, adminResetTokens, adminSessions, auditLogs, users } from "../src/db/schema";
import { setPause } from "../src/settings";

const base = `${(process.argv[2] ?? "http://localhost:4099").replace(/\/$/, "")}/api/admin`;
const statusUrl = `${(process.argv[2] ?? "http://localhost:4099").replace(/\/$/, "")}/api/status`;
const outbox = process.env.EMAIL_OUTBOX_FILE;
const adminEmail = (process.env.ADMIN_EMAIL ?? "").toLowerCase();
const PASSWORD = "Admin smoke 2024 password!";
const PASSWORD2 = "Another admin smoke pass 77";

type Result = { status: number; body: Record<string, unknown>; cookies: string[] };
const jar = new Map<string, string>();

async function call(path: string, method = "GET", body?: unknown, opts: { header?: boolean } = {}): Promise<Result> {
  const cookie = [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  const res = await fetch(base + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(method !== "GET" && opts.header !== false ? { "X-Admin-Request": "1" } : {}),
      ...(cookie ? { Cookie: cookie } : {}),
      "User-Agent": "admin-smoke",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const cookies = res.headers.getSetCookie();
  for (const c of cookies) {
    const [pair] = c.split(";");
    const [name, ...rest] = pair!.split("=");
    const value = rest.join("=");
    if (!value || /max-age=0/i.test(c)) jar.delete(name!.trim());
    else jar.set(name!.trim(), value);
  }
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    parsed = { raw: text };
  }
  return { status: res.status, body: parsed, cookies };
}

function check(ok: boolean, label: string, detail?: unknown) {
  if (!ok) {
    console.error(`FAIL: ${label}`, detail === undefined ? "" : JSON.stringify(detail));
    throw new Error(label);
  }
  console.log(`PASS: ${label}`);
}

type Mail = { to: string; subject: string; text: string };
async function mails(): Promise<Mail[]> {
  const lines = (await readFile(outbox!, "utf8").catch(() => "")).trim().split("\n").filter(Boolean);
  return lines.map((l) => JSON.parse(l) as Mail);
}
async function waitForMail(subjectPart: string, after: number): Promise<Mail> {
  for (let i = 0; i < 40; i++) {
    const found = (await mails()).slice(after).filter((m) => m.to === adminEmail && m.subject.includes(subjectPart));
    if (found.length) return found[found.length - 1]!;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`No email with "${subjectPart}" arrived`);
}

async function resetFlow(password: string): Promise<void> {
  const before = (await mails()).length;
  const r = await call("/forgot", "POST", { email: adminEmail.toUpperCase() });
  check(r.status === 200, "forgot password answers");
  const mail = await waitForMail("admin password", before);
  const token = /#token=([A-Za-z0-9_-]+)/.exec(mail.text)?.[1];
  check(Boolean(token), "the reset email has a link with the token after #");
  const done = await call("/reset", "POST", { token, password });
  check(done.status === 200, "a new password can be set with the link", done.body);
  const again = await call("/reset", "POST", { token, password });
  check(again.status === 400, "the same link cannot be used twice");
}

async function login(password: string): Promise<void> {
  const before = (await mails()).length;
  const r = await call("/login", "POST", { email: adminEmail, password });
  check(r.status === 200 && r.body.step === "code", "email and password accepted, code requested", r.body);
  const mail = await waitForMail("login code", before);
  const code = /\b(\d{6})\b/.exec(mail.text)?.[1];
  check(Boolean(code), "the code arrives by email");
  const wrong = await call("/login/code", "POST", { code: code === "000000" ? "111111" : "000000" });
  check(wrong.status === 401, "a wrong code is refused");
  const ok = await call("/login/code", "POST", { code });
  check(ok.status === 200, "the right code logs in", ok.body);
  const cookie = ok.cookies.find((c) => c.startsWith("doc_admin="));
  check(Boolean(cookie && /HttpOnly/i.test(cookie) && /SameSite=Strict/i.test(cookie)), "the session cookie is HttpOnly and SameSite=Strict", cookie);
}

async function main() {
  if (!outbox || !adminEmail) throw new Error("Run with ADMIN_EMAIL and EMAIL_OUTBOX_FILE set");
  const testUserId = randomUUID();
  try {
    // A clean start for the test admin
    const [old] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, adminEmail));
    if (old) {
      await db.delete(adminSessions).where(eq(adminSessions.accountId, old.id));
      await db.delete(adminResetTokens).where(eq(adminResetTokens.accountId, old.id));
      await db.delete(adminAccounts).where(eq(adminAccounts.id, old.id));
    }

    check((await call("/me")).status === 401, "nothing is visible without logging in");
    check((await call("/overview")).status === 401, "the overview needs a login");
    check((await call("/login", "POST", { email: adminEmail, password: "x" }, { header: false })).status === 400, "changes without the dashboard header are refused");

    const before = (await mails()).length;
    await call("/forgot", "POST", { email: "someone-else@example.com" });
    await new Promise((r) => setTimeout(r, 500));
    check((await mails()).slice(before).length === 0, "forgot password for another email sends nothing");

    const noPassword = await call("/login", "POST", { email: adminEmail, password: PASSWORD });
    check(noPassword.status === 401, "no login before a password is set");

    const weakBefore = (await mails()).length;
    await call("/forgot", "POST", { email: adminEmail });
    const weakMail = await waitForMail("admin password", weakBefore);
    const weakToken = /#token=([A-Za-z0-9_-]+)/.exec(weakMail.text)?.[1];
    check((await call("/reset", "POST", { token: weakToken, password: "short" })).status === 400, "a short password is refused");

    await resetFlow(PASSWORD);
    check((await call("/login", "POST", { email: adminEmail, password: "wrong password here" })).status === 401, "a wrong password is refused");
    await login(PASSWORD);

    const me = await call("/me");
    check(me.status === 200 && me.body.email === adminEmail, "logged in as the admin email", me.body);

    // Every page of the dashboard answers
    const overview = await call("/overview");
    check(overview.status === 200 && typeof (overview.body.users as { total?: unknown })?.total === "number", "overview loads", overview.body);
    check(Array.isArray(overview.body.days) && (overview.body.days as unknown[]).length === 14, "overview has 14 days of volume");
    for (const path of ["/users", "/orders", "/orders?status=open", "/refunds", "/bridge", "/swaps", "/providers", "/activity", "/settings", "/sessions"]) {
      const r = await call(path);
      check(r.status === 200, `${path} loads`, r.body);
    }
    check((await call("/orders/NOPE")).status === 404, "an unknown order is a 404");

    // Pausing swaps shows on the public status, then reopens
    const pause = await call("/settings/pause", "POST", { key: "swapPaused", paused: true });
    check(pause.status === 200, "swaps can be paused", pause.body);
    const status = (await (await fetch(statusUrl)).json()) as { paused?: { swapPaused?: boolean } };
    check(status.paused?.swapPaused === true, "the public status shows swaps paused");
    check((await call("/settings/pause", "POST", { key: "swapPaused", paused: false })).status === 200, "swaps can be reopened");
    check((await call("/settings/pause", "POST", { key: "nonsense", paused: true })).status === 400, "unknown switches are refused");

    // Suspending a user
    await db.insert(users).values({ id: testUserId, name: "Admin Smoke User", email: `admin-smoke-user+${Date.now()}@example.com`, emailVerified: true, phone: "+2348000000000" });
    check((await call(`/users/${testUserId}/status`, "POST", { status: "suspended" })).status === 400, "a suspension needs a reason");
    check((await call(`/users/${testUserId}/status`, "POST", { status: "suspended", reason: "smoke test" })).status === 200, "a user can be suspended");
    const u = await call(`/users/${testUserId}`);
    check((u.body.user as { status?: string })?.status === "suspended", "the user shows as suspended");
    check((await call(`/users/${testUserId}/status`, "POST", { status: "active" })).status === 200, "a user can be restored");
    const found = await call(`/users?q=${encodeURIComponent("Admin Smoke User")}`);
    check((found.body.users as unknown[]).length >= 1, "user search finds the user by name");

    // Changing the password signs out other sessions
    check((await call("/password", "POST", { current: "not it at all", next: PASSWORD2 })).status === 401, "changing the password needs the current one");
    check((await call("/password", "POST", { current: PASSWORD, next: PASSWORD2 })).status === 200, "the password can be changed");

    check((await call("/logout", "POST")).status === 200, "log out");
    check((await call("/me")).status === 401, "logged out for real");

    // Five wrong passwords lock the login, even for the right password
    for (let i = 0; i < 5; i++) await call("/login", "POST", { email: adminEmail, password: `wrong ${i} password` });
    const locked = await call("/login", "POST", { email: adminEmail, password: PASSWORD2 });
    check(locked.status === 423, "five wrong passwords lock the login", locked.body);
    await waitForMail("locked", 0);
    check(true, "the admin is emailed about the lock");
    await resetFlow(PASSWORD);
    await login(PASSWORD);
    check((await call("/me")).status === 200, "forgot password unlocks the login");
    await call("/logout", "POST");
  } finally {
    const [acc] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, adminEmail));
    await setPause("swapPaused", false);
    await db.delete(auditLogs).where(or(eq(auditLogs.targetId, testUserId), inArray(auditLogs.actorId, acc ? [acc.id] : ["none"])));
    await db.delete(users).where(eq(users.id, testUserId));
    if (acc) {
      await db.delete(adminSessions).where(eq(adminSessions.accountId, acc.id));
      await db.delete(adminResetTokens).where(eq(adminResetTokens.accountId, acc.id));
      await db.delete(adminAccounts).where(eq(adminAccounts.id, acc.id));
    }
    console.log("Cleaned up the test admin and test user");
  }
}

main()
  .then(() => {
    console.log("All admin checks passed.");
    process.exit(0);
  })
  .catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  });
