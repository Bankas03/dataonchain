"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean; gasFree?: boolean; previousAddress?: string | null };
  balance: { usdc: string | null };
  bridgeBalance?: string | null;
  tokens?: { EURC: string; cirBTC: string } | null;
};

function formatUsdc(amount: string | null): string {
  if (amount === null) return "unavailable";
  const n = Number(amount);
  if (Number.isNaN(n)) return amount;
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

export function WalletCard() {
  const [data, setData] = useState<WalletResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await api<WalletResponse>("/wallet"));
    } catch {
      setError("We could not load your wallet. Please try again.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function copy() {
    if (!data) return;
    await navigator.clipboard.writeText(data.wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium text-zinc-500">Your USDC wallet</h2>
        {data ? (
          <span className="rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">
            {data.wallet.network}
          </span>
        ) : null}
      </div>

      {loading && !data ? (
        <p className="mt-4 text-sm text-zinc-500">Setting up your wallet...</p>
      ) : null}

      {error ? (
        <div className="mt-4 space-y-3">
          <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          <button onClick={load} className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Try again
          </button>
        </div>
      ) : null}

      {data ? (
        <div className="mt-4 space-y-5">
          <div>
            <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
              {formatUsdc(data.balance.usdc)} <span className="text-lg font-medium text-zinc-500">USDC</span>
            </p>
            {data.tokens && (Number(data.tokens.EURC) > 0 || Number(data.tokens.cirBTC) > 0) ? (
              <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                Also:{" "}
                {[
                  Number(data.tokens.EURC) > 0 ? `${Number(data.tokens.EURC).toLocaleString("en-US", { maximumFractionDigits: 6 })} EURC` : null,
                  Number(data.tokens.cirBTC) > 0 ? `${Number(data.tokens.cirBTC).toLocaleString("en-US", { maximumFractionDigits: 8 })} cirBTC` : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            ) : null}
            {data.bridgeBalance && Number(data.bridgeBalance) > 0 ? (
              <p className="mt-1 text-sm text-zinc-500">
                Plus {formatUsdc(data.bridgeBalance)} USDC in your bridge balance (used first for your next transfer)
              </p>
            ) : null}
            <button
              onClick={load}
              disabled={loading}
              className="mt-1 text-sm font-medium text-emerald-700 hover:underline disabled:opacity-60 dark:text-emerald-400"
            >
              {loading ? "Refreshing..." : "Refresh balance"}
            </button>
          </div>

          <Link
            href="/add-usdc"
            className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center font-medium text-white hover:bg-emerald-800"
          >
            Add USDC (address and QR code)
          </Link>

          <div>
            <p className="text-sm text-zinc-500">Wallet address (to receive USDC on {data.wallet.network} only)</p>
            <div className="mt-1 flex items-center gap-2">
              <code className="min-w-0 flex-1 truncate rounded-lg bg-zinc-100 px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100">
                {data.wallet.address}
              </code>
              <button
                onClick={copy}
                className="shrink-0 rounded-lg border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
              >
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          </div>

          {data.wallet.gasFree ? (
            <p className="text-sm text-emerald-800 dark:text-emerald-300">No network fees: Arc gas is covered for you.</p>
          ) : null}

          {data.wallet.previousAddress ? (
            <p className="rounded-lg bg-zinc-100 px-3 py-2 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
              Your wallet was upgraded. Please use the address above from now on. Any USDC in or sent to your old address (
              <span className="font-mono">{data.wallet.previousAddress.slice(0, 6)}...{data.wallet.previousAddress.slice(-4)}</span>) is moved
              here automatically within a few minutes, minus a tiny network fee.
            </p>
          ) : null}

          {data.wallet.testnet ? (
            <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
              Test network: this USDC has no real value. Get free test USDC at{" "}
              <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                faucet.circle.com
              </a>{" "}
              (choose Arc Testnet and paste your address).
            </p>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
