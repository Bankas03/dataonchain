// Emails customers get when an order finishes: a receipt when airtime or data
// is delivered, and a notice when a refund reaches their wallet.
// Never blocks the order: any email problem is only logged.
import { eq } from "drizzle-orm";
import { db } from "../db";
import { dataPlans, orders, users } from "../db/schema";
import { env } from "../env";
import { sendEmail } from "./index";
import { receiptEmail } from "./templates";

type Order = typeof orders.$inferSelect;

const NETWORKS: Record<string, string> = { mtn: "MTN", airtel: "Airtel", glo: "Glo", "9mobile": "9mobile" };
const usdc = (micro: number) => `${Math.floor(micro / 1_000_000)}.${String(micro % 1_000_000).padStart(6, "0")}`;
const naira = (kobo: number) => `₦${(kobo / 100).toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
const localPhone = (phone: string) => (phone.startsWith("+234") ? `0${phone.slice(4)}` : phone);
const lagos = (d: Date) => d.toLocaleString("en-GB", { timeZone: "Africa/Lagos", dateStyle: "medium", timeStyle: "short" });

async function send(order: Order, kind: "delivered" | "refunded", txHash?: string | null) {
  const [user] = await db.select({ name: users.name, email: users.email }).from(users).where(eq(users.id, order.userId)).limit(1);
  // Test accounts (example.com, .local) never get real emails
  if (!user || /@(example\.com|[^@]*\.local)$/i.test(user.email)) return;
  const [plan] = order.planId ? await db.select({ name: dataPlans.name }).from(dataPlans).where(eq(dataPlans.id, order.planId)).limit(1) : [];
  const what = order.serviceType === "data" ? `${NETWORKS[order.network] ?? order.network} data${plan ? `, ${plan.name}` : ""}` : `${NETWORKS[order.network] ?? order.network} airtime`;
  // BETTER_AUTH_URL is the website address users open
  const url = `${env.BETTER_AUTH_URL}/orders/${order.reference}`;
  const rows: [string, string][] = [
    ["Order", order.reference],
    ["What", what],
    ["Phone", localPhone(order.phone)],
    ["Value", naira(order.ngnAmountKobo)],
    [kind === "delivered" ? "Paid" : "Refunded", `${usdc(order.usdcAmountMicro)} USDC`],
    ["Date", lagos(new Date())],
  ];
  if (txHash) rows.push(["Transaction", txHash]);
  const message =
    kind === "delivered"
      ? receiptEmail({
          name: user.name,
          subject: `Receipt: ${what} for ${localPhone(order.phone)} (${order.reference})`,
          heading: `Your ${order.serviceType} was delivered.`,
          rows,
          note: "Keep this email as your receipt. If anything looks wrong, reply on WhatsApp with the order number.",
          url,
        })
      : receiptEmail({
          name: user.name,
          subject: `Refund sent: ${usdc(order.usdcAmountMicro)} USDC (${order.reference})`,
          heading: `We could not deliver this order, so your USDC is back in your dataonchain wallet.`,
          rows,
          note: "The refund is a transaction on Arc; you can open it from the order page.",
          url,
        });
  await sendEmail({ to: user.email, ...message });
}

export function sendOrderEmail(order: Order, kind: "delivered" | "refunded", txHash?: string | null): void {
  void send(order, kind, txHash).catch((err) => {
    console.error(`[email] ${kind} email for ${order.reference} failed:`, err instanceof Error ? err.message : err);
  });
}
