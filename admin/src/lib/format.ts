// Display helpers. Times are shown in Lagos time.
export const naira = (n: number | null | undefined) =>
  n === null || n === undefined ? "—" : `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;

export const usdc = (s: string | number | null | undefined, digits = 2) =>
  s === null || s === undefined
    ? "—"
    : Number(s).toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: 6 });

export const token = (s: string | number | null | undefined) =>
  s === null || s === undefined ? "—" : Number(s).toLocaleString("en-US", { maximumFractionDigits: 8 });

export const count = (n: number | null | undefined) => (n ?? 0).toLocaleString("en-US");

export function when(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });
}

export function ago(iso: string | null | undefined): string {
  if (!iso) return "—";
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

export const short = (a: string | null | undefined, n = 6) => (a ? (a.length > n * 2 + 3 ? `${a.slice(0, n)}...${a.slice(-4)}` : a) : "—");

export type Tone = "good" | "bad" | "warn" | "wait" | "plain";

const GOOD = ["FULFILLED", "REFUNDED", "COMPLETE", "CONFIRMED", "DELIVERED", "active", "MINTED"];
const BAD = ["FAILED", "MISMATCH", "suspended", "DENIED"];
const WARN = ["FLAGGED", "REFUND_PENDING", "UNKNOWN"];
const PLAIN = ["QUOTED", "EXPIRED", "CANCELLED"];

export function toneOf(status: string): Tone {
  if (GOOD.includes(status)) return "good";
  if (BAD.includes(status)) return "bad";
  if (WARN.includes(status)) return "warn";
  if (PLAIN.includes(status)) return "plain";
  return "wait";
}

export const TONE_CLASS: Record<Tone, string> = {
  good: "bg-emerald-50 text-emerald-800 ring-emerald-600/20 dark:bg-emerald-950 dark:text-emerald-300",
  bad: "bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-950 dark:text-red-300",
  warn: "bg-amber-50 text-amber-900 ring-amber-600/20 dark:bg-amber-950 dark:text-amber-200",
  wait: "bg-sky-50 text-sky-800 ring-sky-600/20 dark:bg-sky-950 dark:text-sky-300",
  plain: "bg-zinc-100 text-zinc-700 ring-zinc-500/20 dark:bg-zinc-800 dark:text-zinc-300",
};

export const label = (s: string) => s.replace(/_/g, " ").toLowerCase().replace(/^\w/, (c) => c.toUpperCase());
