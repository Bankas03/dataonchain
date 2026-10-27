// Better Auth: signup, login, sessions, email verification.
// All routes live under /api/auth/* (see app.ts).
import { randomUUID } from "node:crypto";
import { betterAuth } from "better-auth";
import { APIError } from "better-auth/api";
import { drizzleAdapter } from "@better-auth/drizzle-adapter";
import { db } from "../db";
import { accounts, sessions, users, verifications } from "../db/schema";
import { sendEmail } from "../email";
import { resetPasswordEmail, verificationEmail } from "../email/templates";
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
    // Forgot password: a link by email, valid one hour, used once.
    // Setting a new password signs the user out everywhere.
    resetPasswordTokenExpiresIn: 60 * 60,
    revokeSessionsOnPasswordReset: true,
    sendResetPassword: async ({ user, url }) => {
      const message = resetPasswordEmail(user.name, url);
      // Not awaited on purpose: the response time must not reveal anything.
      void sendEmail({ to: user.email, ...message }).catch((err) => {
        console.error("[email] password reset email failed:", err);
      });
    },
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
      // Changing the phone number on the Account page: same check as at sign up
      update: {
        before: async (data) => {
          if (!("phone" in data) || (data as { phone?: unknown }).phone === undefined) return { data };
          const phone = normalizeNigerianPhone(String((data as { phone?: unknown }).phone ?? ""));
          if (!phone) {
            throw new APIError("BAD_REQUEST", {
              message: "Enter a valid Nigerian phone number, for example 08012345678",
            });
          }
          return { data: { ...data, phone } };
        },
      },
    },
  },

  advanced: {
    database: { generateId: () => randomUUID() },
  },
});

export type AuthSession = typeof auth.$Infer.Session;
