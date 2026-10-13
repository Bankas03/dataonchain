// Nigerian mobile numbers: 070, 080, 081, 090, 091 (and the same after +234).
// Accepts 08012345678, +2348012345678, 2348012345678, with spaces or dashes.
// Returns the standard form +2348012345678, or null if it is not valid.
export function normalizeNigerianPhone(input: string): string | null {
  const compact = input.replace(/[\s()-]/g, "");
  const match = compact.match(/^(?:\+?234|0)([789][01]\d{8})$/);
  return match ? `+234${match[1]}` : null;
}
