"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, toneClass, usdc, type OrderView } from "@/lib/orders";

const STILL_MOVING = ["PAYMENT_PENDING", "FULFILMENT_PENDING"];

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
        if (STILL_MOVING.includes(r.order.status)) timer = setTimeout(load, 3000);
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
  const paid = order ? ["PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED"].includes(order.status) : false;
  const steps = order
    ? [
        { text: "Payment sent", done: Boolean(order.payment) },
        { text: "Payment confirmed on Arc", done: paid },
        { text: "Airtime or data delivered", done: order.status === "FULFILLED" },
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
                      s.done ? "bg-emerald-700 text-white" : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                    }`}
                  >
                    {s.done ? "✓" : ""}
                  </span>
                  <span className={s.done ? "text-zinc-900 dark:text-zinc-100" : "text-zinc-500"}>{s.text}</span>
                </li>
              ))}
            </ol>

            {order.status === "PAYMENT_PENDING" ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Confirming your payment on Arc. This usually takes a few seconds...</p>
            ) : null}
            {order.status === "PAYMENT_CONFIRMED" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Payment received. Automatic delivery is being switched on in the next update.
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
            </dl>

            <Link href="/buy" className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800">
              Buy something else
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
