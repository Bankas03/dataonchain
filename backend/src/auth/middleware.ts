// Protects a route: only signed in users get through (and not suspended ones).
// Usage: app.get("/api/something", requireAuth, (c) => { const { user } = c.get("auth"); ... })
import { createMiddleware } from "hono/factory";
import { auth, type AuthSession } from "./index";

export const requireAuth = createMiddleware<{ Variables: { auth: AuthSession } }>(
  async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers });
    if (!session) {
      return c.json({ error: "Please log in" }, 401);
    }
    // Suspended by the admin: nothing new until restored
    if ((session.user as { status?: string }).status === "suspended") {
      return c.json({ error: "Your account is suspended. Please contact support." }, 403);
    }
    c.set("auth", session);
    await next();
  },
);
