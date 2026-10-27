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

export function resetPasswordEmail(name: string, url: string) {
  const first = name.trim().split(/\s+/)[0] || "there";
  const subject = "Reset your dataonchain password";

  const text = [
    `Hi ${first},`,
    "",
    "Someone asked to reset the password of your dataonchain account. Choose a new password here:",
    url,
    "",
    "This link works once and expires after one hour. If you did not ask for it, ignore this email: your password stays the same.",
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
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">Someone asked to reset the password of your dataonchain account.</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${safeUrl}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">Choose a new password</a>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">
            This link works once and expires after one hour. If the button does not work, copy this address into your browser:<br>
            <span style="word-break:break-all;">${safeUrl}</span>
          </td></tr>
          <tr><td style="padding-top:24px;font-size:13px;color:#71717a;">If you did not ask for this, ignore this email: your password stays the same.</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;

  return { subject, text, html };
}

// A short email with optional big code or button. Used by the admin dashboard.
export function noticeEmail(p: { subject: string; lines: string[]; code?: string; button?: { label: string; url: string }; footer?: string }) {
  const text = [
    ...p.lines,
    ...(p.code ? ["", p.code] : []),
    ...(p.button ? ["", `${p.button.label}: ${p.button.url}`] : []),
    ...(p.footer ? ["", p.footer] : []),
    "",
    "dataonchain",
  ].join("\n");
  const paragraphs = p.lines
    .map((l) => `<tr><td style="padding-top:12px;font-size:15px;line-height:1.5;">${escapeHtml(l)}</td></tr>`)
    .join("");
  const code = p.code
    ? `<tr><td style="padding-top:20px;font-size:32px;font-weight:bold;letter-spacing:8px;font-family:monospace;">${escapeHtml(p.code)}</td></tr>`
    : "";
  const button = p.button
    ? `<tr><td style="padding-top:24px;"><a href="${escapeHtml(p.button.url)}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">${escapeHtml(p.button.label)}</a></td></tr>
<tr><td style="padding-top:16px;font-size:13px;line-height:1.5;color:#71717a;">If the button does not work, copy this address into your browser:<br><span style="word-break:break-all;">${escapeHtml(p.button.url)}</span></td></tr>`
    : "";
  const footer = p.footer ? `<tr><td style="padding-top:24px;font-size:13px;line-height:1.5;color:#71717a;">${escapeHtml(p.footer)}</td></tr>` : "";
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain admin</td></tr>
          ${paragraphs}${code}${button}${footer}
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
  return { subject: p.subject, text, html };
}

// Receipts for customers: a short summary table and a link to the order.
export function receiptEmail(p: { name: string; subject: string; heading: string; rows: [string, string][]; note: string; url: string }) {
  const first = p.name.trim().split(/\s+/)[0] || "there";
  const text = [
    `Hi ${first},`,
    "",
    p.heading,
    "",
    ...p.rows.map(([k, v]) => `${k}: ${v}`),
    "",
    p.note,
    "",
    `View your order: ${p.url}`,
    "",
    "dataonchain",
  ].join("\n");
  const rows = p.rows
    .map(
      ([k, v]) =>
        `<tr><td style="padding:6px 12px 6px 0;color:#71717a;font-size:14px;white-space:nowrap;vertical-align:top;">${escapeHtml(k)}</td><td style="padding:6px 0;font-size:14px;word-break:break-all;">${escapeHtml(v)}</td></tr>`,
    )
    .join("");
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:32px;">
          <tr><td style="font-size:18px;font-weight:bold;color:#047857;">dataonchain</td></tr>
          <tr><td style="padding-top:24px;font-size:16px;">Hi ${escapeHtml(first)},</td></tr>
          <tr><td style="padding-top:12px;font-size:16px;line-height:1.5;">${escapeHtml(p.heading)}</td></tr>
          <tr><td style="padding-top:16px;"><table role="presentation" cellpadding="0" cellspacing="0">${rows}</table></td></tr>
          <tr><td style="padding-top:16px;font-size:14px;line-height:1.5;color:#3f3f46;">${escapeHtml(p.note)}</td></tr>
          <tr><td style="padding-top:24px;">
            <a href="${escapeHtml(p.url)}" style="display:inline-block;background:#047857;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 20px;border-radius:8px;">View your order</a>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
  return { subject: p.subject, text, html };
}
