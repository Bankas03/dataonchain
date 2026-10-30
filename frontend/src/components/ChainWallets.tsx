"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { shortAddress, type BridgeView, type ChainWallet } from "@/lib/bridge";

const usdc = (s: string) => Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });

// The user's own wallets on other networks (created the first time they send there)
export function ChainWallets() {
  const router = useRouter();
  const [rows, setRows] = useState<ChainWallet[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fee, setFee] = useState(0);

  useEffect(() => {
    api<{ wallets: ChainWallet[]; networkFee?: number }>("/bridge/wallets")
      .then((r) => {
        setRows(r.wallets);
        setFee(r.networkFee ?? 0);
      })
      .catch(() => setRows([]));
  }, []);

  async function moveToArc(chain: string) {
    setBusy(chain);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/return", { method: "POST", body: JSON.stringify({ chain }) });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not start the transfer.");
      setBusy(null);
    }
  }

  if (!rows || rows.length === 0) return null;

  return (
    <section className="mt-4 rounded-3xl bg-white p-5 ring-1 ring-ink/10 sm:p-6 dark:bg-white/[0.04] dark:ring-white/10">
      <h2 className="font-display text-lg font-semibold text-ink dark:text-white">Your USDC on other networks</h2>
      <ul className="mt-2 divide-y divide-ink/5 dark:divide-white/5">
        {rows.map((w) => (
          <li key={w.chain} className="flex flex-wrap items-center justify-between gap-3 py-3">
            <div className="min-w-0">
              <p className="text-sm font-semibold text-ink dark:text-white">{w.chainLabel}</p>
              <a href={w.explorerUrl} target="_blank" rel="noreferrer" className="font-mono text-xs text-emerald-700 hover:underline dark:text-emerald-400">
                {shortAddress(w.address)}
              </a>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-sm font-semibold tabular-nums text-ink dark:text-white">
                {w.balance === null ? "unavailable" : `${usdc(w.balance)} USDC`}
              </span>
              {w.balance !== null && Number(w.balance) >= 0.1 + fee ? (
                <button
                  onClick={() => moveToArc(w.chain)}
                  disabled={busy !== null}
                  className="rounded-full bg-note px-3.5 py-1.5 text-xs font-semibold text-white hover:bg-note-deep disabled:opacity-60 dark:bg-mint dark:text-note-deep dark:hover:bg-mint/90"
                >
                  {busy === w.chain ? "Starting..." : "Move to Arc"}
                </button>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
      <p className="mt-2 text-xs text-zinc-500">
        Move to Arc sends everything on that network back to your Arc wallet, minus Circle&apos;s fee
        {fee > 0 ? ` and our ${fee.toFixed(2)} USDC transfer fee (taken on Arc when it arrives)` : ""}. No gas needed.
      </p>
      {error ? (
        <p className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
      ) : null}
    </section>
  );
}
