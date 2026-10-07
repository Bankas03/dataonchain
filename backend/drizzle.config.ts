import { config } from "dotenv";
import { defineConfig } from "drizzle-kit";

// Loads backend/.env. Values already set in the shell win, which is how
// the deploy script points migrations at the production database.
config({ path: ".env", quiet: true });

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  throw new Error("TURSO_DATABASE_URL is not set in backend/.env");
}

export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "turso",
  dbCredentials: {
    url,
    authToken: process.env.TURSO_AUTH_TOKEN,
  },
  strict: true,
  verbose: true,
});
