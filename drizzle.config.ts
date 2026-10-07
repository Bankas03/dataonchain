import { config } from "dotenv";
import { defineConfig } from "drizzle-kit";

// Loads local settings. Values already set in the shell win, which is how
// setup/03_deploy_vercel.sh points migrations at the production database.
config({ path: ".env.local", quiet: true });

const url = process.env.TURSO_DATABASE_URL;
if (!url) {
  throw new Error("TURSO_DATABASE_URL is not set. Run setup/01_turso_setup.sh");
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
