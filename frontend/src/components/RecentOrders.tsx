"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { STATUS_LABELS, describe, toneClass, usdc, type OrderView } from "@/lib/orders";

export function RecentOrders() {
  const [orders, setOrders] = useState<OrderView[] | null>(null);

  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ orders: OrderView[] }>("/orders");
        if (stop) return;
        setOrders(r.orders);
        // Keep the list live while any order is still changing
        const recent = Date.now() - 15 * 60_000;
        const moving = r.orders.some(
          (o) =>
            ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "REFUND_PENDING"].includes(o.status) ||
            (o.status === "FAILED" && new Date(o.createdAt).getTime() > recent),
        );
        if (moving) timer = setTimeout(load, 5000);
      } catch {
        if (!stop) setOrders((prev) => prev ?? []);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, []);

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium text-zinc-500">Recent orders</h2>
        <Link href="/history" className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          See all and download
        </Link>
      </div>
      {orders === null ? <p className="mt-4 text-sm text-zinc-500">Loading...</p> : null}
      {orders && orders.length === 0 ? <p className="mt-4 text-sm text-zinc-500">No orders yet.</p> : null}
      {orders && orders.length > 0 ? (
        <ul className="mt-3 divide-y divide-zinc-100 dark:divide-zinc-800">
          {orders.map((o) => {
            const label = STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" as const };
            return (
              <li key={o.reference}>
                <Link href={`/orders/${o.reference}`} className="flex items-center justify-between gap-3 py-3 hover:opacity-80">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{describe(o)}</p>
                    <p className="text-xs text-zinc-500">
                      {o.phone} · {usdc(o.usdcAmount)} USDC · {new Date(o.createdAt).toLocaleString("en-NG")}
                    </p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
