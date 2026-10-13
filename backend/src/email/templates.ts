// Email wording. Plain text and HTML versions of every email.
function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (ch) =>
    ch === "&" ? "&amp;" : ch === "<" ? "&lt;" : ch === ">" ? "&gt;" : ch === '"' ? "&quot;" : "&#39;",
  );
}

export function verificationEmail(name: string, url: string) {
  const first = name.trim().split(/\s+/)[0] || "there";
  const subject = "Confirm your email for dataonchain";

  const text = [
    `Hi ${first},`,
    "",
    "Confirm your email to finish setting up your dataonchain account:",
    url,
    "",
    "This link expires after one hour. If you did not create an account, you can ignore this email.",
    "",
    "dataonchain",
  ].join("\n");

  const safeUrl = escapeHtml(url);
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain</td></tr>
          <tr><td style="padding-top:24px;font-size:16px;">Hi ${escapeHtml(first)},</td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">Confirm your email to finish setting up your account.</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${safeUrl}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">Confirm my email</a>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">
            This link expires after one hour. If the button does not work, copy this address into your browser:<br>
            <span style="word-break:break-all;">${safeUrl}</span>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;color:#71717a;">If you did not create an account, you can ignore this email.</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  return { subject, text, html };
}
