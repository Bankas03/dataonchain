"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { BRIDGE_DONE, BRIDGE_LABELS, STEP_LABELS, type BridgeView } from "@/lib/bridge";
import { toneClass } from "@/lib/orders";

const MILESTONES = [
  { key: "deposit", text: "Moved into Circle Gateway", done: ["DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED"] },
  { key: "finalized", text: "Gateway balance confirmed", done: ["FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED"] },
  { key: "submitted", text: "Signed and sent to Circle", done: ["SUBMITTED", "MINTED", "COMPLETE"] },
  { key: "minted", text: "Arrived at the destination", done: ["MINTED", "COMPLETE"] },
];

export default function BridgeTransferPage() {
  const router = useRouter();
  const { id } = useParams<{ id: string }>();
  const { data: session, isPending } = authClient.useSession();
  const [t, setT] = useState<BridgeView | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session || !id) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async () => {
      try {
        const r = await api<{ transfer: BridgeView }>(`/bridge/transfers/${id}`);
        if (stop) return;
        setT(r.transfer);
        setError(null);
        if (!BRIDGE_DONE.includes(r.transfer.status)) timer = setTimeout(load, 3000);
      } catch (e) {
        if (stop) return;
        setError(e instanceof Error ? e.message : "Could not load this transfer.");
        timer = setTimeout(load, 5000);
      }
    };
    void load();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [session, id]);

  const label = t ? (BRIDGE_LABELS[t.status] ?? { text: t.status, tone: "wait" as const }) : null;

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Transfer</h1>
        {error && !t ? (
          <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
        ) : null}
        {!t && !error ? <p className="mt-6 text-zinc-500">Loading...</p> : null}

        {t && label ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="flex items-center justify-between gap-3">
              <p className="text-lg font-medium text-zinc-900 dark:text-zinc-50">
                {t.amount} USDC to {t.destinationLabel} on {t.destinationChainLabel}
              </p>
              <span className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-medium ${toneClass(label.tone)}`}>{label.text}</span>
            </div>

            <ol className="space-y-3">
              {MILESTONES.map((m) => {
                const done = m.done.includes(t.status);
                return (
                  <li key={m.key} className="flex items-center gap-3 text-sm">
                    <span
                      className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                        done ? "bg-emerald-700 text-white" : "border border-zinc-300 text-zinc-400 dark:border-zinc-700"
                      }`}
                    >
                      {done ? "✓" : ""}
                    </span>
                    <span className={done ? "text-zinc-900 dark:text-zinc-100" : "text-zinc-500"}>
                      {m.key === "minted" ? `Arrived on ${t.destinationChainLabel}` : m.text}
                    </span>
                  </li>
                );
              })}
            </ol>

            {t.slowFinality && ["DEPOSITING", "DEPOSITED"].includes(t.status) ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                Waiting for {t.sourceLabel} to confirm the deposit. On this network Circle waits for full finality, which
                can take up to 20 minutes. You can close this page; it keeps going.
              </p>
            ) : null}
            {t.status === "COMPLETE" ? (
              <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                Done. {t.amount} USDC arrived at {t.destinationLabel} on {t.destinationChainLabel}.
              </p>
            ) : null}
            {t.status === "FAILED" ? (
              <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
                This transfer stopped: {t.failureReason ?? "unknown reason"}. Any USDC already moved stays in your bridge
                balance and is used for your next transfer.
              </p>
            ) : null}

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">From</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">Your wallet ({t.sourceLabel})</dd>
              <dt className="text-zinc-500">To</dt>
              <dd className="min-w-0 text-zinc-900 dark:text-zinc-100">
                {t.destinationLabel} ({t.destinationChainLabel})
                <span className="block truncate font-mono text-xs text-zinc-500">{t.recipientAddress}</span>
              </dd>
              <dt className="text-zinc-500">Amount</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{t.amount} USDC</dd>
              {t.maxFee ? (
                <>
                  <dt className="text-zinc-500">Circle fee (max)</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">{t.maxFee} USDC</dd>
                </>
              ) : null}
              {t.mintUrl ? (
                <>
                  <dt className="text-zinc-500">Mint</dt>
                  <dd className="min-w-0">
                    <a href={t.mintUrl} target="_blank" rel="noreferrer" className="block truncate font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                      {t.mintTxHash}
                    </a>
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Started</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{new Date(t.createdAt).toLocaleString("en-NG")}</dd>
            </dl>

            <div>
              <h2 className="text-sm font-medium text-zinc-500">Every step</h2>
              <ul className="mt-2 space-y-1.5 text-xs">
                {t.steps.map((s, i) => (
                  <li key={`${s.step}-${i}`} className="flex flex-wrap items-baseline gap-x-2">
                    <span className="text-zinc-500">{new Date(s.at).toLocaleTimeString("en-NG")}</span>
                    <span className="text-zinc-900 dark:text-zinc-100">{STEP_LABELS[s.step] ?? s.step}</span>
                    {s.chainLabel ? <span className="text-zinc-500">({s.chainLabel})</span> : null}
                    {s.url ? (
                      <a href={s.url} target="_blank" rel="noreferrer" className="font-mono text-emerald-700 hover:underline dark:text-emerald-400">
                        {s.txHash?.slice(0, 10)}...
                      </a>
                    ) : null}
                  </li>
                ))}
              </ul>
            </div>

            <Link
              href="/bridge"
              className="block w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-center text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
            >
              Send another
            </Link>
          </section>
        ) : null}
      </div>
    </main>
  );
}
