// Admin API, mounted at /api/admin. Used only by the admin dashboard website,
// which passes /api/* through to this server, so the cookies belong to the
// dashboard's own address.
//
//   - session cookie: HttpOnly, Secure (in production), SameSite=Strict
//   - every change (POST) must carry the header X-Admin-Request: 1, which a
//     form on another website cannot send
//   - answers are never cached
//   - too many login, code or reset requests from one IP are refused for a while
import { Hono, type Context } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { createMiddleware } from "hono/factory";
import { env } from "../env";
import { isPauseKey } from "../settings";
import { AdminActionError, failAndRefund, recheckOrder, retryRefund, setPauseSwitch, setProviderActive, setUserStatus } from "./actions";
import {
  AdminAuthError,
  CODE_MINUTES,
  IDLE_MINUTES,
  MIN_PASSWORD,
  SESSION_HOURS,
  changePassword,
  endOtherSessions,
  endSession,
  finishLogin,
  listSessions,
  readSession,
  requestReset,
  resetPassword,
  startLogin,
  type AdminAccount,
  type AdminSession,
  type Meta,
} from "./auth";
import {
  getBridge,
  getOrder,
  getUser,
  listActivity,
  listBridge,
  listOrders,
  listProviders,
  listRefunds,
  listSendsAdmin,
  listSwapsAdmin,
  listUsers,
  overview,
  pageOf,
  settingsView,
} from "./data";

type Vars = { Variables: { admin: { account: AdminAccount; session: AdminSession } } };

const SESSION_COOKIE = "doc_admin";
const PENDING_COOKIE = "doc_admin_pending";
const secure = env.NODE_ENV === "production";

export const adminApp = new Hono<Vars>();

function meta(c: Context): Meta {
  const forwarded = c.req.header("x-forwarded-for")?.split(",")[0]?.trim();
  return { ip: forwarded || c.req.header("x-real-ip") || "unknown", userAgent: c.req.header("user-agent") ?? "" };
}

function setSessionCookie(c: Context, name: string, value: string, maxAgeSeconds: number) {
  setCookie(c, name, value, { path: "/", httpOnly: true, secure, sameSite: "Strict", maxAge: maxAgeSeconds });
}

function clearCookies(c: Context) {
  deleteCookie(c, SESSION_COOKIE, { path: "/", secure });
  deleteCookie(c, PENDING_COOKIE, { path: "/", secure });
}

// Simple per IP limit for the login, code and reset routes (kept in memory)
const hits = new Map<string, { count: number; resetAt: number }>();
function tooMany(c: Context, bucket: string, limit: number, windowMinutes: number): boolean {
  const key = `${bucket}:${meta(c).ip}`;
  const now = Date.now();
  const entry = hits.get(key);
  if (!entry || entry.resetAt < now) {
    hits.set(key, { count: 1, resetAt: now + windowMinutes * 60_000 });
    if (hits.size > 5_000) for (const [k, v] of hits) if (v.resetAt < now) hits.delete(k);
    return false;
  }
  entry.count += 1;
  return entry.count > limit;
}

function fail(c: Context, err: unknown) {
  if (err instanceof AdminAuthError || err instanceof AdminActionError) return c.json({ error: err.message }, err.status);
  throw err;
}

async function body(c: Context): Promise<Record<string, unknown>> {
  const b = await c.req.json().catch(() => null);
  return b && typeof b === "object" ? (b as Record<string, unknown>) : {};
}

adminApp.use("*", async (c, next) => {
  if (c.req.method !== "GET" && c.req.header("x-admin-request") !== "1") {
    return c.json({ error: "Bad request" }, 400);
  }
  await next();
  c.header("Cache-Control", "no-store");
  c.header("X-Robots-Tag", "noindex, nofollow");
});

const requireAdmin = createMiddleware<Vars>(async (c, next) => {
  const found = await readSession(getCookie(c, SESSION_COOKIE));
  if (!found) {
    deleteCookie(c, SESSION_COOKIE, { path: "/", secure });
    return c.json({ error: "Please log in" }, 401);
  }
  c.set("admin", found);
  await next();
});

// ---------------------------------------------------------------------------
// Logging in and out, passwords
// ---------------------------------------------------------------------------
adminApp.get("/config", (c) =>
  c.json({ configured: Boolean(env.ADMIN_EMAIL), minPassword: MIN_PASSWORD, codeMinutes: CODE_MINUTES, idleMinutes: IDLE_MINUTES, sessionHours: SESSION_HOURS }),
);

adminApp.post("/login", async (c) => {
  if (tooMany(c, "login", 20, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    const token = await startLogin(b.email, b.password, meta(c));
    setSessionCookie(c, PENDING_COOKIE, token, CODE_MINUTES * 60);
    return c.json({ step: "code" });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/login/code", async (c) => {
  if (tooMany(c, "code", 30, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    const token = await finishLogin(getCookie(c, PENDING_COOKIE), b.code, meta(c));
    deleteCookie(c, PENDING_COOKIE, { path: "/", secure });
    setSessionCookie(c, SESSION_COOKIE, token, SESSION_HOURS * 60 * 60);
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/logout", async (c) => {
  await endSession(getCookie(c, SESSION_COOKIE));
  clearCookies(c);
  return c.json({ ok: true });
});

adminApp.post("/forgot", async (c) => {
  if (tooMany(c, "forgot", 5, 60)) return c.json({ error: "Too many requests. Please wait an hour." }, 429);
  const b = await body(c);
  try {
    await requestReset(b.email, meta(c));
  } catch (err) {
    return fail(c, err);
  }
  return c.json({ ok: true, message: "If that is the admin email, a link is on its way. It expires in 30 minutes." });
});

adminApp.post("/reset", async (c) => {
  if (tooMany(c, "reset", 10, 15)) return c.json({ error: "Too many attempts. Please wait 15 minutes." }, 429);
  const b = await body(c);
  try {
    await resetPassword(b.token, b.password, meta(c));
    clearCookies(c);
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.get("/me", requireAdmin, (c) => {
  const { account, session } = c.get("admin");
  return c.json({
    email: account.email,
    lastLoginAt: account.lastLoginAt?.toISOString() ?? null,
    passwordChangedAt: account.passwordChangedAt?.toISOString() ?? null,
    sessionExpiresAt: session.expiresAt.toISOString(),
    idleMinutes: IDLE_MINUTES,
  });
});

adminApp.post("/password", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  const b = await body(c);
  try {
    await changePassword(account, session.id, b.current, b.next, meta(c));
    return c.json({ ok: true });
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.get("/sessions", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  return c.json({ sessions: await listSessions(account.id, session.id) });
});

adminApp.post("/sessions/end-others", requireAdmin, async (c) => {
  const { account, session } = c.get("admin");
  return c.json({ ended: await endOtherSessions(account.id, session.id) });
});

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------
adminApp.get("/overview", requireAdmin, async (c) => c.json(await overview()));

adminApp.get("/users", requireAdmin, async (c) =>
  c.json(await listUsers(c.req.query("q"), c.req.query("status"), pageOf(c.req.query("page")))),
);

adminApp.get("/users/:id", requireAdmin, async (c) => {
  const user = await getUser(c.req.param("id"));
  if (!user) return c.json({ error: "User not found" }, 404);
  return c.json(user);
});

adminApp.get("/orders", requireAdmin, async (c) =>
  c.json(await listOrders(c.req.query("status"), c.req.query("q"), pageOf(c.req.query("page")))),
);

adminApp.get("/orders/:key", requireAdmin, async (c) => {
  const order = await getOrder(c.req.param("key"));
  if (!order) return c.json({ error: "Order not found" }, 404);
  return c.json(order);
});

adminApp.get("/refunds", requireAdmin, async (c) => c.json(await listRefunds(c.req.query("status"), pageOf(c.req.query("page")))));

adminApp.get("/bridge", requireAdmin, async (c) =>
  c.json(await listBridge(c.req.query("status"), c.req.query("q"), pageOf(c.req.query("page")))),
);

adminApp.get("/bridge/:id", requireAdmin, async (c) => {
  const transfer = await getBridge(c.req.param("id"));
  if (!transfer) return c.json({ error: "Transfer not found" }, 404);
  return c.json(transfer);
});

adminApp.get("/swaps", requireAdmin, async (c) => c.json(await listSwapsAdmin(c.req.query("status"), pageOf(c.req.query("page")))));

adminApp.get("/sends", requireAdmin, async (c) => c.json(await listSendsAdmin(c.req.query("status"), pageOf(c.req.query("page")))));

adminApp.get("/providers", requireAdmin, async (c) => c.json({ providers: await listProviders() }));

adminApp.get("/activity", requireAdmin, async (c) => c.json(await listActivity(c.req.query("actor"), pageOf(c.req.query("page")))));

adminApp.get("/settings", requireAdmin, async (c) => c.json(await settingsView()));

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
adminApp.post("/orders/:key/recheck", requireAdmin, async (c) => {
  try {
    return c.json(await recheckOrder(c.get("admin").account.id, c.req.param("key")));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/orders/:key/refund", requireAdmin, async (c) => {
  try {
    return c.json(await retryRefund(c.get("admin").account.id, c.req.param("key")));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/orders/:key/fail-refund", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await failAndRefund(c.get("admin").account.id, c.req.param("key"), b.reason));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/users/:id/status", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await setUserStatus(c.get("admin").account.id, c.req.param("id"), b.status, b.reason));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/providers/:id", requireAdmin, async (c) => {
  const b = await body(c);
  try {
    return c.json(await setProviderActive(c.get("admin").account.id, c.req.param("id"), b.active));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.post("/settings/pause", requireAdmin, async (c) => {
  const b = await body(c);
  if (!isPauseKey(b.key)) return c.json({ error: "Unknown switch" }, 400);
  try {
    return c.json(await setPauseSwitch(c.get("admin").account.id, b.key, b.paused));
  } catch (err) {
    return fail(c, err);
  }
});

adminApp.notFound((c) => c.json({ error: "Not found" }, 404));
