// Sends one real email through Resend to check the domain and key work.
// Run with: npx tsx scripts/send-test-email.ts you@example.com
import { config } from "dotenv";
import { Resend } from "resend";

config({ path: ".env", quiet: true });

async function main() {
  const to = process.argv[2];
  const key = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM;
  if (!to) throw new Error("Give an email address to send to");
  if (!key || !from) throw new Error("RESEND_API_KEY and EMAIL_FROM must be set in backend/.env");

  const { data, error } = await new Resend(key).emails.send({
    from,
    to,
    subject: "dataonchain test email",
    text: "If you can read this, dataonchain can send emails from your domain.",
  });
  if (error) throw new Error(`${error.name}: ${error.message}`);
  console.log(`Sent. Resend id: ${data?.id}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
