// Database error helpers.
//
// Drizzle wraps database errors: the message is "Failed query: ..." and the
// real reason ("UNIQUE constraint failed: table.column") is in err.cause.
// So the whole chain of causes is checked, not just the top message.
function reasons(err: unknown): string {
  const parts: string[] = [];
  let e: unknown = err;
  for (let i = 0; i < 5 && e; i++) {
    if (e instanceof Error) {
      parts.push(e.message);
      e = (e as { cause?: unknown }).cause;
    } else {
      parts.push(String(e));
      break;
    }
  }
  return parts.join(" | ");
}

// True when the error is a duplicate value on a unique column (optionally a
// given column, for example "open_key" or "orders.reference").
export function isUniqueViolation(err: unknown, column?: string): boolean {
  const m = /UNIQUE constraint failed: ([^|\n]+)/i.exec(reasons(err));
  if (!m) return false;
  return column ? m[1]!.includes(column) : true;
}
