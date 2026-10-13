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
