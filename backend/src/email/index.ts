// Sends emails through Resend.
// Without RESEND_API_KEY (local only) the email is printed in the terminal.
// Tests set EMAIL_OUTBOX_FILE so emails are written to a file instead.
import { appendFile } from "node:fs/promises";
import { Resend } from "resend";
import { env } from "../env";

export type Email = { to: string; subject: string; html: string; text: string };

const resend = env.RESEND_API_KEY ? new Resend(env.RESEND_API_KEY) : null;

export async function sendEmail(email: Email): Promise<void> {
  const outbox = process.env.EMAIL_OUTBOX_FILE;
  if (outbox) {
    await appendFile(outbox, `${JSON.stringify(email)}\n`);
    return;
  }
  if (!resend) {
    console.warn(`[email] RESEND_API_KEY not set. Email to ${email.to}: ${email.subject}\n${email.text}`);
    return;
  }
  const { error } = await resend.emails.send({
    from: env.EMAIL_FROM,
    to: email.to,
    subject: email.subject,
    html: email.html,
    text: email.text,
  });
  if (error) {
    throw new Error(`Resend refused the email: ${error.name}: ${error.message}`);
  }
}
