"use client";

import QRCode from "qrcode";
import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";

type WalletResponse = {
  wallet: { address: string; blockchain: string; network: string; testnet: boolean; gasFree?: boolean; previousAddress?: string | null };
  balance: { usdc: string | null };
  bridgeBalance?: string | null;
  tokens?: { EURC: string; cirBTC: string } | null;
  ngnPerUsdc?: number | null;
};

// The fine wavy lines printed on banknotes, drawn once as a background
const WAVES = (() => {
  const lines: string[] = [];
  for (let i = 0; i < 16; i++) {
    const y0 = 40 + i * 16;
    const amp = 18 + (i % 4) * 6;
    const phase = i * 0.55;
    let d = "";
    for (let x = 0; x <= 640; x += 8) {
      const y = y0 + Math.sin(x / 46 + phase) * amp * Math.sin(x / 210 + i * 0.3);
      d += `${x === 0 ? "M" : "L"}${x} ${y.toFixed(1)} `;
    }
    lines.push(d.trim());
  }
  return lines;
})();

function split(amount: string | null): { whole: string; cents: string } | null {
  if (amount === null) return null;
  const n = Number(amount);
  if (Number.isNaN(n)) return null;
  const text = n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
  const [whole, cents = "00"] = text.split(".");
  return { whole: whole ?? "0", cents };
}

const tokenText = (v: string, max: number) => Number(v).toLocaleString("en-US", { maximumFractionDigits: max });

// The balance card at the top of the dashboard: USDC balance, its naira value,
// other tokens, and the wallet address to copy.
export function WalletCard() {
  const [data, setData] = useState<WalletResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState(false);
  const [qr, setQr] = useState<string | null>(null);
  const [showQr, setShowQr] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await api<WalletResponse>("/wallet"));
    } catch (e) {
      setError(e instanceof Error ? e.message : "We could not load your wallet. Please try again.");
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

  async function toggleQr() {
    if (!data) return;
    if (!qr) setQr(await QRCode.toDataURL(data.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" }));
    setShowQr((v) => !v);
  }

  const amount = split(data?.balance.usdc ?? null);
  const naira =
    data?.ngnPerUsdc && data.balance.usdc !== null
      ? Math.floor(Number(data.balance.usdc) * data.ngnPerUsdc).toLocaleString("en-NG")
      : null;
  const extras = data?.tokens
    ? [
        Number(data.tokens.EURC) > 0 ? { label: "EURC", value: tokenText(data.tokens.EURC, 6) } : null,
        Number(data.tokens.cirBTC) > 0 ? { label: "cirBTC", value: tokenText(data.tokens.cirBTC, 8) } : null,
      ].filter((t): t is { label: string; value: string } => t !== null)
    : [];

  return (
    <>
      <section className="relative overflow-hidden rounded-[28px] bg-note text-white shadow-[0_28px_60px_-32px_rgba(6,42,32,0.85)] dark:bg-note-deep dark:ring-1 dark:ring-white/10">
        <svg
          aria-hidden="true"
          viewBox="0 0 640 320"
          preserveAspectRatio="none"
          className="pointer-events-none absolute inset-0 h-full w-full text-mint opacity-[0.13]"
        >
          {WAVES.map((d, i) => (
            <path key={i} d={d} fill="none" stroke="currentColor" strokeWidth="1" />
          ))}
        </svg>
        <div className="pointer-events-none absolute -right-16 -top-20 h-64 w-64 rounded-full border-[28px] border-white/[0.04]" aria-hidden="true" />

        <div className="relative p-6 sm:p-8">
          <div className="flex items-center justify-between gap-3">
            <p className="text-sm font-medium text-white/70">USDC balance</p>
            {data ? (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1 text-xs font-semibold text-white/90">
                <span className="h-1.5 w-1.5 rounded-full bg-mint" aria-hidden="true" />
                {data.wallet.network}
              </span>
            ) : null}
          </div>

          {loading && !data ? (
            <div className="mt-4 space-y-3" aria-live="polite">
              <div className="h-14 w-48 animate-pulse rounded-xl bg-white/10" />
              <p className="text-sm text-white/60">Setting up your wallet...</p>
            </div>
          ) : null}

          {error && !data ? (
            <div className="mt-4 space-y-3">
              <p className="text-sm text-white/80">{error}</p>
              <button onClick={load} className="rounded-full bg-white px-4 py-2 text-sm font-semibold text-note hover:bg-white/90">
                Try again
              </button>
            </div>
          ) : null}

          {data ? (
            <>
              <p className="balance-in mt-3 font-display text-[3.25rem] font-semibold leading-none tracking-tight tabular-nums sm:text-7xl">
                {amount ? (
                  <>
                    <span className="mr-1 align-top text-2xl font-medium text-white/55 sm:text-3xl">$</span>
                    {amount.whole}
                    <span className="text-white/45">.{amount.cents}</span>
                  </>
                ) : (
                  <span className="text-3xl text-white/70">Balance unavailable</span>
                )}
              </p>

              <div className="mt-4 flex flex-wrap items-center gap-2">
                {naira ? (
                  <span className="rounded-full bg-gold/15 px-3 py-1 text-sm font-semibold text-gold">about ₦{naira}</span>
                ) : null}
                {extras.map((t) => (
                  <span key={t.label} className="rounded-full bg-white/10 px-3 py-1 text-sm font-medium text-white/90">
                    {t.value} {t.label}
                  </span>
                ))}
              </div>
              {data.bridgeBalance && Number(data.bridgeBalance) > 0 ? (
                <p className="mt-3 text-sm text-white/65">
                  Plus {tokenText(data.bridgeBalance, 6)} USDC in your bridge balance, used first for your next transfer.
                </p>
              ) : null}

              <div className="mt-6 flex flex-wrap items-center gap-2 border-t border-white/10 pt-4">
                <code className="min-w-0 flex-1 basis-full truncate font-mono text-sm text-white/75 sm:basis-0" title={data.wallet.address}>
                  {data.wallet.address}
                </code>
                <button
                  onClick={toggleQr}
                  aria-expanded={showQr}
                  className="shrink-0 rounded-full bg-white/10 px-3.5 py-1.5 text-sm font-semibold text-white hover:bg-white/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  {showQr ? "Hide QR code" : "Generate QR code"}
                </button>
                <button
                  onClick={copy}
                  className="shrink-0 rounded-full bg-white/10 px-3.5 py-1.5 text-sm font-semibold text-white hover:bg-white/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  {copied ? "Copied" : "Copy address"}
                </button>
                <button
                  onClick={load}
                  disabled={loading}
                  aria-label="Refresh balance"
                  title="Refresh balance"
                  className="shrink-0 rounded-full bg-white/10 p-2 text-white hover:bg-white/20 disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mint"
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={loading ? "animate-spin" : ""}>
                    <path d="M21 12a9 9 0 1 1-2.64-6.36" />
                    <path d="M21 3v6h-6" />
                  </svg>
                </button>
              </div>

              {showQr && qr ? (
                <div className="mt-4 flex flex-col items-center gap-3 rounded-2xl bg-white p-5 text-center text-ink sm:flex-row sm:text-left">
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={qr} alt="QR code of your wallet address" width={180} height={180} className="h-44 w-44 shrink-0" />
                  <div className="space-y-2 text-sm">
                    <p className="font-display text-base font-semibold">Scan to send USDC to this wallet</p>
                    <p className="text-zinc-600">
                      Send only USDC on the <b>{data.wallet.network}</b> network. USDC sent on any other network may be lost.
                    </p>
                    <p className="break-all font-mono text-xs text-zinc-500">{data.wallet.address}</p>
                  </div>
                </div>
              ) : null}
            </>
          ) : null}
        </div>
      </section>

      {data?.wallet.previousAddress ? (
        <p className="mt-3 rounded-2xl bg-white px-4 py-3 text-sm text-zinc-600 ring-1 ring-ink/10 dark:bg-white/5 dark:text-zinc-300 dark:ring-white/10">
          Your wallet was upgraded. Use the address above from now on. Any USDC in or sent to your old address (
          <span className="font-mono">{data.wallet.previousAddress.slice(0, 6)}...{data.wallet.previousAddress.slice(-4)}</span>) moves here
          automatically within a few minutes, minus a tiny network fee.
        </p>
      ) : null}

      {data?.wallet.testnet ? (
        <p className="mt-3 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
          Test network: this USDC has no real value. Get free test USDC at{" "}
          <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
            faucet.circle.com
          </a>{" "}
          (choose Arc Testnet and paste your address).
        </p>
      ) : null}
    </>
  );
}
