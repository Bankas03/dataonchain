"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { STATUS_LABELS, describe, naira, toneClass, usdc, type OrderView } from "@/lib/orders";

type History = { total: number; page: number; pageSize: number; orders: OrderView[] };

const FILTERS = [
  { value: "", label: "All" },
  { value: "delivered", label: "Delivered" },
  { value: "refunded", label: "Refunded" },
  { value: "failed", label: "Failed" },
  { value: "open", label: "In progress" },
];

export default function HistoryPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<History | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    let stop = false;
    api<History>(`/history?page=${page}&status=${status}`)
      .then((r) => {
        if (!stop) {
          setData(r);
          setError(null);
        }
      })
      .catch((e: unknown) => !stop && setError(e instanceof Error ? e.message : "Could not load your orders."));
    return () => {
      stop = true;
    };
  }, [session, page, status]);

  const pages = data ? Math.max(1, Math.ceil(data.total / data.pageSize)) : 1;

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-2xl">
        <header className="flex items-center justify-between">
          <Link href="/dashboard" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/dashboard" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Back to dashboard
          </Link>
        </header>

        <div className="mt-8 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Order history</h1>
            {data ? <p className="mt-1 text-sm text-zinc-500">{data.total.toLocaleString("en-US")} order(s)</p> : null}
          </div>
          <a
            href="/api/history.csv"
            download
            className="rounded-lg border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Download CSV
          </a>
        </div>

        <div className="mt-4 flex flex-wrap gap-2">
          {FILTERS.map((f) => (
            <button
              key={f.value}
              onClick={() => {
                setStatus(f.value);
                setPage(1);
              }}
              className={`rounded-full border px-3 py-1 text-sm ${
                status === f.value
                  ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
                  : "border-zinc-300 text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
          {error ? <p className="m-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
          {!data && !error ? <p className="p-4 text-sm text-zinc-500">Loading...</p> : null}
          {data && data.orders.length === 0 ? <p className="p-4 text-sm text-zinc-500">No orders here yet.</p> : null}
          {data && data.orders.length > 0 ? (
            <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {data.orders.map((o) => {
                const label = STATUS_LABELS[o.status] ?? { text: o.status, tone: "wait" as const };
                return (
                  <li key={o.reference}>
                    <Link href={`/orders/${o.reference}`} className="flex items-center justify-between gap-3 px-4 py-3 hover:opacity-80">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">{describe(o)}</p>
                        <p className="text-xs text-zinc-500">
                          {o.phone} · {naira(o.ngnAmount)} · {usdc(o.usdcAmount)} USDC · {new Date(o.createdAt).toLocaleString("en-NG")}
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

        {data && pages > 1 ? (
          <div className="mt-4 flex items-center justify-between text-sm text-zinc-500">
            <span>
              Page {data.page} of {pages}
            </span>
            <div className="flex gap-2">
              <button
                disabled={page <= 1}
                onClick={() => setPage((p) => p - 1)}
                className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300"
              >
                Previous
              </button>
              <button
                disabled={page >= pages}
                onClick={() => setPage((p) => p + 1)}
                className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300"
              >
                Next
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </main>
  );
}
