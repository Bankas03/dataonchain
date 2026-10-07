// Database client for server code only (API routes, server actions, jobs).
// "server-only" makes the build fail if a browser component imports this.
import "server-only";
import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  throw new Error("TURSO_DATABASE_URL is not set");
}

const client = createClient({
  url,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

export const db = drizzle({ client });
export * as schema from "./schema";
