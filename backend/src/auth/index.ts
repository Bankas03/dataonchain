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
