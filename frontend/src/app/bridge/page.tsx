"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";
import { shortAddress, type BridgeQuote, type BridgeView, type Destination } from "@/lib/bridge";

type Limits = { min: number; max: number; daily: number };

export default function BridgePage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [destinations, setDestinations] = useState<Destination[] | null>(null);
  const [limits, setLimits] = useState<Limits | null>(null);
  const [destinationId, setDestinationId] = useState("");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<BridgeQuote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<{ destinations: Destination[]; limits: Limits }>("/bridge/destinations")
      .then((r) => {
        setDestinations(r.destinations);
        setLimits(r.limits);
        if (r.destinations[0]) setDestinationId(r.destinations[0].id);
      })
      .catch((e) => {
        setDestinations([]);
        setError(e instanceof Error ? e.message : "Could not load destinations.");
      });
  }, [session]);

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    try {
      const r = await api<{ quote: BridgeQuote }>("/bridge/quote", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function send() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ transfer: BridgeView }>("/bridge/transfers", {
        method: "POST",
        body: JSON.stringify({ destinationId, amount }),
      });
      router.push(`/bridge/${r.transfer.id}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the transfer.");
      setBusy(false);
    }
  }

  const enough = quote ? Number(quote.available) >= Number(quote.total) : false;

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Send to a provider</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Send USDC from your Arc wallet to an approved provider on another network, through Circle Gateway. You pay no
          gas on any network; Circle&apos;s fee is shown before you confirm.
        </p>

        <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {destinations === null ? <p className="text-sm text-zinc-500">Loading...</p> : null}
          {destinations && destinations.length === 0 && !error ? (
            <p className="text-sm text-zinc-500">No providers are available yet.</p>
          ) : null}

          {destinations && destinations.length > 0 ? (
            <form onSubmit={getQuote} className="space-y-5">
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Provider</p>
                <div className="mt-2 space-y-2">
                  {destinations.map((d) => (
                    <label
                      key={d.id}
                      className={`flex cursor-pointer items-center justify-between gap-3 rounded-lg border px-3 py-2.5 text-sm ${
                        destinationId === d.id
                          ? "border-emerald-700 bg-emerald-50 dark:border-emerald-500 dark:bg-emerald-950"
                          : "border-zinc-300 dark:border-zinc-700"
                      }`}
                    >
                      <span className="flex items-center gap-2">
                        <input
                          type="radio"
                          name="destination"
                          value={d.id}
                          checked={destinationId === d.id}
                          onChange={() => {
                            setDestinationId(d.id);
                            setQuote(null);
                          }}
                        />
                        <span className="font-medium text-zinc-900 dark:text-zinc-100">{d.label}</span>
                      </span>
                      <span className="text-xs text-zinc-500">
                        {d.chainLabel} · <span className="font-mono">{shortAddress(d.address)}</span>
                      </span>
                    </label>
                  ))}
                </div>
              </div>

              <div>
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount (USDC)
                </label>
                <input
                  id="amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => {
                    setAmount(e.target.value);
                    setQuote(null);
                  }}
                  placeholder={limits ? `${limits.min} to ${limits.max}` : "5"}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                {limits ? (
                  <p className="mt-1 text-xs text-zinc-500">
                    Minimum {limits.min} USDC, maximum {limits.max} USDC per transfer, {limits.daily} USDC per day.
                  </p>
                ) : null}
              </div>

              {!quote ? (
                <button
                  type="submit"
                  disabled={busy || !amount || !destinationId}
                  className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Checking the fee..." : "See the fee"}
                </button>
              ) : null}
            </form>
          ) : null}

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[9rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">To</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {quote.destination.label} ({quote.destination.chainLabel})
                </dd>
                <dt className="text-zinc-500">Address</dt>
                <dd className="truncate font-mono text-zinc-900 dark:text-zinc-100">{quote.destination.address}</dd>
                <dt className="text-zinc-500">They receive</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.receives} USDC</dd>
                <dt className="text-zinc-500">Circle fee (max)</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.fee} USDC</dd>
                <dt className="text-zinc-500">From your wallet</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{quote.total} USDC</dd>
                <dt className="text-zinc-500">You have</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.available} USDC</dd>
              </dl>
              <p className="text-xs text-zinc-500">{quote.note}</p>
              {!quote.allowed ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Circle&apos;s fee to this network is unusually high right now. Please try again later.
                </p>
              ) : null}
              {!enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough USDC for this amount plus the fee.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={send}
                  disabled={busy || !enough || !quote.allowed}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Starting..." : `Send ${quote.amount} USDC`}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
            </div>
          ) : null}

          {error ? (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          ) : null}
        </section>
      </div>
    </main>
  );
}
