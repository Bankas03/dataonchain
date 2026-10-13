// Shared order types and labels for the website.
export type OrderView = {
  reference: string;
  status: string;
  serviceType: "airtime" | "data";
  network: "mtn" | "airtel" | "glo" | "9mobile";
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  createdAt: string;
  expiresAt?: string;
  failureReason?: string | null;
  payment?: { status: string; txHash: string | null; explorerUrl: string | null } | null;
};

export const NETWORK_LABELS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };

export const STATUS_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Not paid", tone: "wait" },
  EXPIRED: { text: "Price expired", tone: "bad" },
  PAYMENT_PENDING: { text: "Payment in progress", tone: "wait" },
  PAYMENT_CONFIRMED: { text: "Paid, waiting for delivery", tone: "good" },
  FULFILMENT_PENDING: { text: "Delivering", tone: "wait" },
  FULFILLED: { text: "Delivered", tone: "good" },
  FAILED: { text: "Failed", tone: "bad" },
  FLAGGED: { text: "Under review", tone: "bad" },
  REFUNDED: { text: "Refunded", tone: "good" },
};

export function toneClass(tone: "wait" | "good" | "bad") {
  return tone === "good"
    ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "bad"
      ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
      : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200";
}

export const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
export const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

export function describe(o: OrderView) {
  const net = NETWORK_LABELS[o.network] ?? o.network;
  return o.serviceType === "data" ? `${net} ${o.planName ?? "data"}` : `${net} airtime ${naira(o.ngnAmount)}`;
}
