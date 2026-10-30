// Admin login for the dashboard.
//
// One admin only: the email in ADMIN_EMAIL. Logging in takes two steps:
//   1. email + password  -> a 6 digit code is emailed to ADMIN_EMAIL
//   2. the code          -> an admin session (8 hours, ends after 60 minutes idle)
//
// Safety:
//   - passwords are stored as scrypt hashes; session tokens, codes and reset
//     tokens only as hashes, so a copy of the database cannot be used to log in
//   - 5 wrong passwords lock the login for 15 minutes (and email the admin);
//     "Forgot password" unlocks it
//   - 5 wrong codes end that login attempt
//   - changing ADMIN_EMAIL on Render ends every session at once; the new
//     address sets its own password with "Forgot password"
//   - every login, lock and password change is emailed and written to the audit log
import { createHash, createHmac, randomBytes, randomInt, scrypt, timingSafeEqual } from "node:crypto";
import { and, eq, gte, isNull, lt, ne, or, sql } from "drizzle-orm";
import { db } from "../db";
import { adminAccounts, adminResetTokens, adminSessions, auditLogs } from "../db/schema";
import { sendEmail } from "../email";
import { noticeEmail } from "../email/templates";
import { env } from "../env";

export type AdminAccount = typeof adminAccounts.$inferSelect;
export type AdminSession = typeof adminSessions.$inferSelect;
export type Meta = { ip: string; userAgent: string };

export const CODE_MINUTES = 10;
export const SESSION_HOURS = 8;
export const IDLE_MINUTES = 60;
const MAX_CODE_ATTEMPTS = 5;
const MAX_FAILED_PASSWORDS = 5;
const LOCK_MINUTES = 15;
const RESET_MINUTES = 30;
const RESETS_PER_HOUR = 3;
export const MIN_PASSWORD = 12;
const MAX_PASSWORD = 128;

export class AdminAuthError extends Error {
  constructor(message: string, public status: 400 | 401 | 423 | 429 | 502 | 503 = 400) {
    super(message);
  }
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------
const SCRYPT_N = 32768;

function scryptKey(password: string, salt: Buffer, n: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, 64, { N: n, r: 8, p: 1, maxmem: 128 * 1024 * 1024 }, (err, key) => (err ? reject(err) : resolve(key)));
  });
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scryptKey(password, salt, SCRYPT_N);
  return `scrypt$${SCRYPT_N}$${salt.toString("base64")}$${key.toString("base64")}`;
}

let dummyHash: string | null = null;

// Always does the same amount of work, so the answer time reveals nothing.
export async function verifyPassword(password: string, stored: string | null): Promise<boolean> {
  if (!stored) {
    dummyHash ??= await hashPassword("not-a-real-password-just-for-timing");
    await verifyPassword(password, dummyHash);
    return false;
  }
  const [kind, n, salt, key] = stored.split("$");
  if (kind !== "scrypt" || !n || !salt || !key) return false;
  const expected = Buffer.from(key, "base64");
  const actual = await scryptKey(password, Buffer.from(salt, "base64"), Number(n));
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");
const newToken = () => randomBytes(32).toString("base64url");
const codeHash = (sessionId: string, code: string) =>
  createHmac("sha256", env.BETTER_AUTH_SECRET).update(`admin-code:${sessionId}:${code}`).digest("hex");

function sameHex(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

export function checkNewPassword(password: unknown, email: string): string {
  if (typeof password !== "string" || password.length < MIN_PASSWORD) {
    throw new AdminAuthError(`Use at least ${MIN_PASSWORD} characters for the password.`);
  }
  if (password.length > MAX_PASSWORD) throw new AdminAuthError(`Use at most ${MAX_PASSWORD} characters.`);
  if (password.toLowerCase().includes(email.split("@")[0]!.toLowerCase())) {
    throw new AdminAuthError("The password must not contain your email name.");
  }
  if (new Set(password).size < 5) throw new AdminAuthError("That password is too simple. Mix more different characters.");
  return password;
}

// ---------------------------------------------------------------------------
// The account
// ---------------------------------------------------------------------------
const lagosTime = (d: Date) =>
  d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

function requireConfigured(): string {
  if (!env.ADMIN_EMAIL) throw new AdminAuthError("The admin login is not set up yet (ADMIN_EMAIL is missing on the server).", 503);
  return env.ADMIN_EMAIL;
}

async function currentAccount(): Promise<AdminAccount> {
  const email = requireConfigured();
  await db.insert(adminAccounts).values({ email }).onConflictDoNothing();
  const [account] = await db.select().from(adminAccounts).where(eq(adminAccounts.email, email)).limit(1);
  if (!account) throw new AdminAuthError("Could not load the admin account.", 503);
  return account;
}

export async function adminAudit(action: string, details: Record<string, unknown>, accountId: string | null, target?: { type: string; id: string | null }) {
  await db.insert(auditLogs).values({
    actorType: "admin",
    actorId: accountId,
    action,
    targetType: target?.type ?? "admin",
    targetId: target?.id ?? null,
    details,
  });
}

type NoticeExtra = Omit<Parameters<typeof noticeEmail>[0], "subject" | "lines">;

async function notify(subject: string, lines: string[], extra: NoticeExtra = {}): Promise<void> {
  if (!env.ADMIN_EMAIL) return;
  await sendEmail({ to: env.ADMIN_EMAIL, ...noticeEmail({ subject, lines, ...extra }) });
}

function notifyQuietly(subject: string, lines: string[]) {
  void notify(subject, lines).catch((err) => console.error("[admin] notice email failed:", err instanceof Error ? err.message : err));
}

// ---------------------------------------------------------------------------
// Step 1: email and password
// ---------------------------------------------------------------------------
export async function startLogin(emailInput: unknown, passwordInput: unknown, meta: Meta): Promise<string> {
  const account = await currentAccount();
  const email = typeof emailInput === "string" ? emailInput.trim().toLowerCase() : "";
  const password = typeof passwordInput === "string" ? passwordInput.slice(0, MAX_PASSWORD) : "";
  const emailOk = email === account.email;

  if (account.lockedUntil && account.lockedUntil.getTime() > Date.now()) {
    await verifyPassword(password, null);
    throw new AdminAuthError(
      `Too many wrong passwords. The admin login is locked until ${lagosTime(account.lockedUntil)} (Lagos time). Use "Forgot password" to unlock it now.`,
      423,
    );
  }

  const passwordOk = await verifyPassword(password, emailOk ? account.passwordHash : null);
  if (!emailOk || !passwordOk) {
    if (emailOk) {
      // Counted in the database itself, so many wrong passwords sent at the same
      // moment all count
      const [row] = await db
        .update(adminAccounts)
        .set({ failedAttempts: sql`${adminAccounts.failedAttempts} + 1` })
        .where(eq(adminAccounts.id, account.id))
        .returning({ failed: adminAccounts.failedAttempts });
      const failed = row?.failed ?? MAX_FAILED_PASSWORDS;
      if (failed >= MAX_FAILED_PASSWORDS) {
        const until = new Date(Date.now() + LOCK_MINUTES * 60_000);
        await db.update(adminAccounts).set({ failedAttempts: 0, lockedUntil: until }).where(eq(adminAccounts.id, account.id));
        await adminAudit("admin.locked", { ip: meta.ip, until: until.toISOString() }, account.id);
        notifyQuietly("dataonchain admin login locked", [
          `Someone entered the wrong admin password ${MAX_FAILED_PASSWORDS} times. The login is locked until ${lagosTime(until)} (Lagos time).`,
          `Last attempt from IP ${meta.ip}.`,
          'If this was not you, use "Forgot password" to set a new password. That also unlocks the login.',
        ]);
      }
    }
    throw new AdminAuthError(
      account.passwordHash || !emailOk ? "Wrong email or password." : 'No password is set yet. Use "Forgot password" to set one.',
      401,
    );
  }

  await db.update(adminAccounts).set({ failedAttempts: 0 }).where(eq(adminAccounts.id, account.id));
  // Housekeeping: finished and unfinished logins that expired
  await db.delete(adminSessions).where(or(lt(adminSessions.expiresAt, new Date()), and(eq(adminSessions.accountId, account.id), eq(adminSessions.stage, "code"))));

  const token = newToken();
  const now = new Date();
  const [session] = await db
    .insert(adminSessions)
    .values({
      accountId: account.id,
      tokenHash: sha256(token),
      stage: "code",
      ipAddress: meta.ip,
      userAgent: meta.userAgent.slice(0, 300),
      expiresAt: new Date(now.getTime() + CODE_MINUTES * 60_000),
      lastSeenAt: now,
    })
    .returning();
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  await db.update(adminSessions).set({ codeHash: codeHash(session!.id, code) }).where(eq(adminSessions.id, session!.id));
  try {
    await notify(
      "Your dataonchain admin login code",
      ["Enter this code on the admin dashboard to finish logging in:"],
      { code, footer: `The code expires in ${CODE_MINUTES} minutes. Login attempt from IP ${meta.ip}. If this was not you, change your password now.` },
    );
  } catch (err) {
    console.error("[admin] could not email the login code:", err instanceof Error ? err.message : err);
    await db.delete(adminSessions).where(eq(adminSessions.id, session!.id));
    throw new AdminAuthError("Could not send the login code email. Please try again.", 502);
  }
  return token;
}

// ---------------------------------------------------------------------------
// Step 2: the emailed code. Returns a fresh token for the real session.
// ---------------------------------------------------------------------------
export async function finishLogin(pendingToken: string | undefined, codeInput: unknown, meta: Meta): Promise<string> {
  const account = await currentAccount();
  const expired = new AdminAuthError("This login has expired. Please log in again.", 401);
  if (!pendingToken) throw expired;
  const [pending] = await db
    .select()
    .from(adminSessions)
    .where(and(eq(adminSessions.tokenHash, sha256(pendingToken)), eq(adminSessions.stage, "code")))
    .limit(1);
  if (!pending || pending.accountId !== account.id || pending.expiresAt.getTime() < Date.now() || !pending.codeHash) throw expired;

  // Every try is counted in the database before the code is checked, so many
  // guesses sent at the same moment cannot get past the limit
  const [tried] = await db
    .update(adminSessions)
    .set({ codeAttempts: sql`${adminSessions.codeAttempts} + 1` })
    .where(and(eq(adminSessions.id, pending.id), lt(adminSessions.codeAttempts, MAX_CODE_ATTEMPTS)))
    .returning({ attempts: adminSessions.codeAttempts });
  if (!tried) {
    await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
    throw new AdminAuthError("Too many wrong codes. Please log in again.", 401);
  }

  const code = typeof codeInput === "string" ? codeInput.replace(/\s/g, "") : "";
  if (!/^\d{6}$/.test(code) || !sameHex(codeHash(pending.id, code), pending.codeHash)) {
    if (tried.attempts >= MAX_CODE_ATTEMPTS) {
      await db.delete(adminSessions).where(eq(adminSessions.id, pending.id));
      await adminAudit("admin.code_failed", { ip: meta.ip }, account.id);
      throw new AdminAuthError("Too many wrong codes. Please log in again.", 401);
    }
    throw new AdminAuthError(`Wrong code. ${MAX_CODE_ATTEMPTS - tried.attempts} tries left.`, 401);
  }

  // The pending login is used up (only once, even if the code is sent twice);
  // the real session gets a brand new token
  const used = await db.delete(adminSessions).where(eq(adminSessions.id, pending.id)).returning({ id: adminSessions.id });
  if (!used.length) throw expired;
  const token = newToken();
  const now = new Date();
  await db.insert(adminSessions).values({
    accountId: account.id,
    tokenHash: sha256(token),
    stage: "active",
    ipAddress: meta.ip,
    userAgent: meta.userAgent.slice(0, 300),
    expiresAt: new Date(now.getTime() + SESSION_HOURS * 60 * 60_000),
    lastSeenAt: now,
  });
  await db.update(adminAccounts).set({ lastLoginAt: now }).where(eq(adminAccounts.id, account.id));
  await adminAudit("admin.login", { ip: meta.ip, userAgent: meta.userAgent.slice(0, 200) }, account.id);
  notifyQuietly("New login to the dataonchain admin dashboard", [
    `You logged in to the admin dashboard on ${lagosTime(now)} (Lagos time).`,
    `IP: ${meta.ip}`,
    `Browser: ${meta.userAgent.slice(0, 160) || "unknown"}`,
    'If this was not you, change your password now. Changing it signs out every session.',
  ]);
  return token;
}

// ---------------------------------------------------------------------------
// Checking a session on every admin request
// ---------------------------------------------------------------------------
export async function readSession(token: string | undefined): Promise<{ account: AdminAccount; session: AdminSession } | null> {
  if (!token || !env.ADMIN_EMAIL) return null;
  const [row] = await db
    .select({ session: adminSessions, account: adminAccounts })
    .from(adminSessions)
    .innerJoin(adminAccounts, eq(adminSessions.accountId, adminAccounts.id))
    .where(and(eq(adminSessions.tokenHash, sha256(token)), eq(adminSessions.stage, "active")))
    .limit(1);
  if (!row) return null;
  const now = Date.now();
  const idle = now - row.session.lastSeenAt.getTime() > IDLE_MINUTES * 60_000;
  // A different ADMIN_EMAIL on the server ends old sessions
  if (row.account.email !== env.ADMIN_EMAIL || row.session.expiresAt.getTime() < now || idle) {
    await db.delete(adminSessions).where(eq(adminSessions.id, row.session.id));
    return null;
  }
  if (now - row.session.lastSeenAt.getTime() > 60_000) {
    await db.update(adminSessions).set({ lastSeenAt: new Date(now) }).where(eq(adminSessions.id, row.session.id));
  }
  return row;
}

export async function endSession(token: string | undefined): Promise<void> {
  if (!token) return;
  await db.delete(adminSessions).where(eq(adminSessions.tokenHash, sha256(token)));
}

export async function listSessions(accountId: string, currentId: string) {
  const rows = await db
    .select()
    .from(adminSessions)
    .where(and(eq(adminSessions.accountId, accountId), eq(adminSessions.stage, "active"), gte(adminSessions.expiresAt, new Date())));
  return rows.map((s) => ({
    id: s.id,
    current: s.id === currentId,
    ip: s.ipAddress,
    userAgent: s.userAgent,
    createdAt: s.createdAt.toISOString(),
    lastSeenAt: s.lastSeenAt.toISOString(),
  }));
}

export async function endOtherSessions(accountId: string, currentId: string): Promise<number> {
  const rows = await db
    .delete(adminSessions)
    .where(and(eq(adminSessions.accountId, accountId), ne(adminSessions.id, currentId)))
    .returning({ id: adminSessions.id });
  await adminAudit("admin.sessions_ended", { count: rows.length }, accountId);
  return rows.length;
}

// ---------------------------------------------------------------------------
// Forgot password: a link to ADMIN_EMAIL, valid 30 minutes, used once.
// Always answers the same way, whatever email was typed.
// ---------------------------------------------------------------------------
export async function requestReset(emailInput: unknown, meta: Meta): Promise<void> {
  const account = await currentAccount();
  const email = typeof emailInput === "string" ? emailInput.trim().toLowerCase() : "";
  if (email !== account.email) return;
  const recent = await db
    .select({ id: adminResetTokens.id })
    .from(adminResetTokens)
    .where(and(eq(adminResetTokens.accountId, account.id), gte(adminResetTokens.createdAt, new Date(Date.now() - 60 * 60_000))));
  if (recent.length >= RESETS_PER_HOUR) return;

  const token = newToken();
  await db.insert(adminResetTokens).values({
    accountId: account.id,
    tokenHash: sha256(token),
    expiresAt: new Date(Date.now() + RESET_MINUTES * 60_000),
    ipAddress: meta.ip,
  });
  await adminAudit("admin.reset_requested", { ip: meta.ip }, account.id);
  // The token is after "#", so it never reaches any server log
  const url = `${env.ADMIN_URL}/reset#token=${token}`;
  try {
    await notify(
      account.passwordHash ? "Reset your dataonchain admin password" : "Set your dataonchain admin password",
      [account.passwordHash ? "Someone asked to reset the admin dashboard password." : "Set the password for the admin dashboard."],
      {
        button: { label: account.passwordHash ? "Choose a new password" : "Set my password", url },
        footer: `The link works once and expires in ${RESET_MINUTES} minutes. Requested from IP ${meta.ip}. If this was not you, ignore this email: your password stays the same.`,
      },
    );
  } catch (err) {
    console.error("[admin] could not email the reset link:", err instanceof Error ? err.message : err);
  }
}

export async function resetPassword(tokenInput: unknown, passwordInput: unknown, meta: Meta): Promise<void> {
  const account = await currentAccount();
  const invalid = new AdminAuthError('This link is not valid any more. Use "Forgot password" to get a new one.', 400);
  if (typeof tokenInput !== "string" || tokenInput.length < 20) throw invalid;
  const password = checkNewPassword(passwordInput, account.email);
  const [row] = await db
    .select()
    .from(adminResetTokens)
    .where(and(eq(adminResetTokens.tokenHash, sha256(tokenInput)), isNull(adminResetTokens.usedAt)))
    .limit(1);
  if (!row || row.accountId !== account.id || row.expiresAt.getTime() < Date.now()) throw invalid;
  // Use the link up first, so it can never be used twice
  const [claimed] = await db
    .update(adminResetTokens)
    .set({ usedAt: new Date() })
    .where(and(eq(adminResetTokens.id, row.id), isNull(adminResetTokens.usedAt)))
    .returning();
  if (!claimed) throw invalid;

  await db
    .update(adminAccounts)
    .set({ passwordHash: await hashPassword(password), failedAttempts: 0, lockedUntil: null, passwordChangedAt: new Date() })
    .where(eq(adminAccounts.id, account.id));
  // Every other link and every session ends
  await db.update(adminResetTokens).set({ usedAt: new Date() }).where(and(eq(adminResetTokens.accountId, account.id), isNull(adminResetTokens.usedAt)));
  await db.delete(adminSessions).where(eq(adminSessions.accountId, account.id));
  await adminAudit("admin.password_reset", { ip: meta.ip }, account.id);
  notifyQuietly("Your dataonchain admin password was changed", [
    `The admin dashboard password was set on ${lagosTime(new Date())} (Lagos time), from IP ${meta.ip}.`,
    "Every admin session was signed out.",
    'If this was not you, use "Forgot password" right away and check who can read this mailbox.',
  ]);
}

export async function changePassword(account: AdminAccount, sessionId: string, currentInput: unknown, nextInput: unknown, meta: Meta): Promise<void> {
  const current = typeof currentInput === "string" ? currentInput.slice(0, MAX_PASSWORD) : "";
  if (!(await verifyPassword(current, account.passwordHash))) throw new AdminAuthError("Your current password is not right.", 401);
  const next = checkNewPassword(nextInput, account.email);
  if (next === current) throw new AdminAuthError("Choose a password different from the current one.");
  await db
    .update(adminAccounts)
    .set({ passwordHash: await hashPassword(next), passwordChangedAt: new Date() })
    .where(eq(adminAccounts.id, account.id));
  await db.delete(adminSessions).where(and(eq(adminSessions.accountId, account.id), ne(adminSessions.id, sessionId)));
  await adminAudit("admin.password_changed", { ip: meta.ip }, account.id);
  notifyQuietly("Your dataonchain admin password was changed", [
    `The admin dashboard password was changed on ${lagosTime(new Date())} (Lagos time), from IP ${meta.ip}.`,
    "Every other admin session was signed out.",
    'If this was not you, use "Forgot password" right away.',
  ]);
}
