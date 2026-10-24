"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Limits = Record<Token, { decimals: number; min: number; max: number }>;
type TokensResponse = { balances: Record<Token, string>; limits: Limits; feePercent: number; slippagePercent: number };
type Quote = {
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  feePercent: number;
  slippagePercent: number;
  balance: string;
  enough: boolean;
};
type SwapView = {
  id: string;
  status: string;
  tokenIn: Token;
  tokenOut: Token;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  amountOut: string | null;
  explorerUrl: string | null;
  createdAt: string;
};

const fmt = (v: string | null | undefined, token: Token) =>
  v === null || v === undefined ? "?" : Number(v).toLocaleString("en-US", { maximumFractionDigits: token === "cirBTC" ? 8 : 6 });

function choiceClass(active: boolean) {
  return `rounded-lg border px-3 py-2 text-sm font-medium transition ${
    active
      ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
  }`;
}

export default function SwapPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [info, setInfo] = useState<TokensResponse | null>(null);
  const [tokenIn, setTokenIn] = useState<Token>("USDC");
  const [tokenOut, setTokenOut] = useState<Token>("EURC");
  const [amount, setAmount] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [done, setDone] = useState<SwapView | null>(null);
  const [recent, setRecent] = useState<SwapView[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      setInfo(await api<TokensResponse>("/swap/tokens"));
      const r = await api<{ swaps: SwapView[] }>("/swaps");
      setRecent(r.swaps.filter(Boolean));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, []);

  useEffect(() => {
    if (session) void load();
  }, [session, load]);

  function pick(side: "in" | "out", t: Token) {
    setQuote(null);
    setDone(null);
    if (side === "in") {
      if (t === tokenOut) setTokenOut(tokenIn);
      setTokenIn(t);
    } else {
      if (t === tokenIn) setTokenIn(tokenOut);
      setTokenOut(t);
    }
  }

  async function getQuote(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setQuote(null);
    setDone(null);
    try {
      const r = await api<{ quote: Quote }>("/swap/quote", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount }) });
      setQuote(r.quote);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not get a price.");
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ swap: SwapView }>("/swap", { method: "POST", body: JSON.stringify({ tokenIn, tokenOut, amount }) });
      setDone(r.swap);
      setQuote(null);
      setAmount("");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "The swap could not be completed.");
    } finally {
      setBusy(false);
    }
  }

  const limit = info?.limits[tokenIn];

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Swap</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Swap between USDC, EURC and cirBTC in your Arc wallet. No gas to pay.
          {info ? ` Fee ${info.feePercent}%; if the price moves more than ${info.slippagePercent}% against you, the swap is cancelled.` : ""}
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have: {TOKEN_LIST.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(" · ")}
          </p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <form onSubmit={getQuote} className="space-y-5">
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">From</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("in", t)} className={choiceClass(tokenIn === t)}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">To</p>
              <div className="mt-2 flex gap-2">
                {TOKEN_LIST.map((t) => (
                  <button type="button" key={t} onClick={() => pick("out", t)} disabled={t === tokenIn} className={`${choiceClass(tokenOut === t)} disabled:opacity-40`}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div className="flex items-center justify-between">
                <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Amount of {tokenIn}
                </label>
                {info ? (
                  <button
                    type="button"
                    onClick={() => {
                      setAmount(info.balances[tokenIn]);
                      setQuote(null);
                    }}
                    className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                  >
                    Use all ({fmt(info.balances[tokenIn], tokenIn)})
                  </button>
                ) : null}
              </div>
              <input
                id="amount"
                inputMode="decimal"
                value={amount}
                onChange={(e) => {
                  setAmount(e.target.value);
                  setQuote(null);
                  setDone(null);
                }}
                placeholder={limit ? `${limit.min} to ${limit.max}` : ""}
                className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
              />
            </div>
            {!quote ? (
              <button
                type="submit"
                disabled={busy || !amount}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a price..." : "Get a price"}
              </button>
            ) : null}
          </form>

          {quote ? (
            <div className="space-y-4 border-t border-zinc-100 pt-5 dark:border-zinc-800">
              <dl className="grid grid-cols-[10rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">You swap</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.amountIn, quote.tokenIn)} {quote.tokenIn}</dd>
                <dt className="text-zinc-500">You get about</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">{fmt(quote.estimatedOut, quote.tokenOut)} {quote.tokenOut}</dd>
                <dt className="text-zinc-500">At least</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">
                  {fmt(quote.minOut, quote.tokenOut)} {quote.tokenOut} <span className="text-xs text-zinc-500">(or it is cancelled)</span>
                </dd>
                <dt className="text-zinc-500">Fees</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{quote.feePercent}% dataonchain + 0.02% swap provider, included above</dd>
              </dl>
              {!quote.enough ? (
                <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                  Not enough {quote.tokenIn}. You have {fmt(quote.balance, quote.tokenIn)}.
                </p>
              ) : null}
              <div className="flex gap-3">
                <button
                  onClick={confirm}
                  disabled={busy || !quote.enough}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Swapping..." : "Confirm swap"}
                </button>
                <button
                  onClick={() => setQuote(null)}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Change
                </button>
              </div>
              <p className="text-xs text-zinc-500">Prices on the test network can move a lot. If the swap is cancelled, nothing is taken.</p>
            </div>
          ) : null}

          {done ? (
            <div
              className={`rounded-lg px-3 py-2 text-sm ${
                done.status === "COMPLETE"
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
              }`}
            >
              {done.status === "COMPLETE"
                ? `Done. ${fmt(done.amountIn, done.tokenIn)} ${done.tokenIn} swapped for ${fmt(done.amountOut ?? done.estimatedOut, done.tokenOut)} ${done.tokenOut}.`
                : "The swap was sent but its result is not clear yet. Check your balance in a minute; our team is notified."}
              {done.explorerUrl ? (
                <a href={done.explorerUrl} target="_blank" rel="noreferrer" className="ml-1 font-medium underline">
                  View transaction
                </a>
              ) : null}
            </div>
          ) : null}

          {error ? (
            <p className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
          ) : null}
        </section>

        {recent.length > 0 ? (
          <section className="mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <h2 className="text-sm font-medium text-zinc-500">Recent swaps</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {recent.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <span className="text-zinc-900 dark:text-zinc-100">
                    {fmt(s.amountIn, s.tokenIn)} {s.tokenIn} → {s.amountOut ? `${fmt(s.amountOut, s.tokenOut)} ` : ""}
                    {s.tokenOut}
                  </span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    {s.status === "COMPLETE" ? "Done" : s.status === "FAILED" ? "Cancelled" : s.status === "UNKNOWN" ? "Checking" : "In progress"}
                    {s.explorerUrl ? (
                      <a href={s.explorerUrl} target="_blank" rel="noreferrer" className="text-emerald-700 hover:underline dark:text-emerald-400">
                        tx
                      </a>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </div>
    </main>
  );
}
