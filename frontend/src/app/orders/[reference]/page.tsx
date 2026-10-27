"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { SupportLink } from "@/components/SupportLink";
import { STATUS_LABELS, describe, naira, stillMoving, toneClass, usdc, type OrderView } from "@/lib/orders";

export default function OrderPage() {
  const router = useRouter();
  const params = useParams<{ reference: string }>();
  const reference = params.reference;
  const { data: session, isPending } = authClient.useSession();
  const [order, setOrder] = useState<OrderView | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session || !reference) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ order: OrderView }>(`/orders/${reference}`);
        if (stop) return;
        setOrder(r.order);
        setError(null);
        if (stillMoving(r.order)) timer = setTimeout(load, r.order.status === "FLAGGED" ? 15000 : 3000);
      } catch (e) {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this order.");
        timer = setTimeout(load, 5000);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session, reference]);

  const label = order ? (STATUS_LABELS[order.status] ?? { text: order.status, tone: "wait" as const }) : null;
  const paid = order?.payment?.status === "CONFIRMED";
  const refunding = order ? paid && ["FAILED", "REFUND_PENDING", "REFUNDED"].includes(order.status) : false;
  const what = order?.serviceType === "data" ? "Data" : "Airtime";
  const steps: { text: string; state: "done" | "todo" | "failed" }[] = order
    ? [
        { text: "Payment sent", state: order.payment ? "done" : "todo" },
        { text: "Payment confirmed on Arc", state: paid ? "done" : "todo" },
        refunding
          ? { text: `${what} could not be delivered`, state: "failed" }
          : { text: `${what} delivered`, state: order.status === "FULFILLED" ? "done" : "todo" },
        ...(refunding
          ? [{ text: "USDC refunded to your wallet", state: order.status === "REFUNDED" ? ("done" as const) : ("todo" as const) }]
          : []),
      ]
    : [];

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-xl">
        <header className="flex items-center justify-between">
          <Link href="/dashboard" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/dashboard" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Order {reference}</h1>

        {error && !order ? (
          <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
        ) : null}
        {!order && !error ? <p className="mt-6 text-zinc-500">Loading...</p> : null}

        {order && label ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between gap-3">
              <p className="text-lg font-medium text-zinc-900 dark:text-zinc-50">{describe(order)}</p>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
            </div>

            <ol className="space-y-3">
              {steps.map((s) => (
                <li key={s.text} className="flex items-center gap-3 text-sm">
                  <span
                    className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                      s.state === "done"
                        ? "bg-emerald-700 text-white"
                        : s.state === "failed"
                          ? "bg-red-600 text-white"
                          : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                    }`}
                  >
                    {s.state === "done" ? "✓" : s.state === "failed" ? "✕" : ""}
                  </span>
                  <span className={s.state === "todo" ? "text-zinc-500" : "text-zinc-900 dark:text-zinc-100"}>{s.text}</span>
                </li>
              ))}
            </ol>

            {order.status === "PAYMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Confirming your payment on Arc. This usually takes a few seconds...</p>
            ) : null}
            {order.status === "PAYMENT_CONFIRMED" || order.status === "FULFILMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Payment received. Sending your {order.serviceType} to {order.phone}...
                {order.delivery?.message ? <span className="mt-1 block text-xs text-zinc-500">Network status: {order.delivery.message}</span> : null}
              </p>
            ) : null}
            {order.status === "REFUND_PENDING" || (order.status === "FAILED" && paid) ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Sending your USDC back to your wallet. This usually takes under a minute...</p>
            ) : null}
            {order.status === "FULFILLED" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Done. Your {order.serviceType} has been sent to {order.phone}.
              </p>
            ) : null}
            {order.failureReason ? (
              <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{order.failureReason}</p>
            ) : null}

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{order.phone}</dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(order.ngnAmount)}</dd>
              <dt className="text-zinc-500">Paid</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{usdc(order.usdcAmount)} USDC</dd>
              <dt className="text-zinc-500">Date</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{new Date(order.createdAt).toLocaleString("en-NG")}</dd>
              {order.delivery?.providerReference ? (
                <>
                  <dt className="text-zinc-500">VTpass ref</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.providerReference}</dd>
                </>
              ) : null}
              {order.delivery?.token ? (
                <>
                  <dt className="text-zinc-500">Token / PIN</dt>
                  <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.delivery.token}</dd>
                </>
              ) : null}
              {order.refund?.txHash ? (
                <>
                  <dt className="text-zinc-500">Refund</dt>
                  <dd className="min-w-0">
                    {order.refund.explorerUrl ? (
                      <a href={order.refund.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.refund.amount} USDC · {order.refund.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.refund.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              {order.payment?.txHash ? (
                <>
                  <dt className="text-zinc-500">Transaction</dt>
                  <dd className="min-w-0">
                    {order.payment.explorerUrl ? (
                      <a href={order.payment.explorerUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {order.payment.txHash}
                      </a>
                    ) : (
                      <span className="block truncate font-mono">{order.payment.txHash}</span>
                    )}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{order.reference}</dd>
            </dl>

            {order.status === "FULFILLED" ? (
              <button
                onClick={() => window.print()}
                className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                Print or save receipt
              </button>
            ) : null}
            {["FULFILLED", "REFUNDED", "FAILED", "EXPIRED"].includes(order.status) ? (
              <Link
                href={`/buy?${new URLSearchParams({
                  service: order.serviceType,
                  network: order.network,
                  phone: order.phone,
                  ...(order.serviceType === "data" && order.planId ? { plan: order.planId } : {}),
                  ...(order.serviceType === "airtime" ? { amount: String(order.ngnAmount) } : {}),
                }).toString()}`}
                className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center text-sm font-medium text-white hover:bg-emerald-800"
              >
                Buy again
              </Link>
            ) : null}
            <SupportLink block message={`Hello dataonchain, I need help with order ${order.reference} (${label.text}, ${order.phone}).`}>
              Report a problem on WhatsApp
            </SupportLink>
            <Link href="/buy" className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
              Buy something else
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
