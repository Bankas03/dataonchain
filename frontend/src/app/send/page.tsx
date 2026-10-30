"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKEN_LIST: Token[] = ["USDC", "EURC", "cirBTC"];
type Chain = "arc" | "base";
type Info = {
  chain?: Chain;
  network: string;
  baseOpen?: boolean;
  tokens?: Token[];
  balances: Record<Token, string>;
  limits: Record<Token, { decimals: number; min: number; max: number; daily: number }>;
  usedToday: Record<Token, string>;
  sendsLeftToday: number;
  paused: string | null;
};
type SendView = {
  id: string;
  status: string;
  token: Token;
  amount: string;
  toAddress: string;
  toShort: string;
  network: string;
  codeSentTo: string | null;
  codeExpiresAt: string | null;
  failure: string | null;
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

const STATUS_TEXT: Record<string, string> = {
  SENDING: "Sending",
  SENT: "Sending",
  COMPLETE: "Sent",
  FAILED: "Not sent",
};

export default function SendPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [info, setInfo] = useState<Info | null>(null);
  const [chain, setChain] = useState<Chain>("arc");
  const [baseOpen, setBaseOpen] = useState(false);
  const [token, setToken] = useState<Token>("USDC");
  const [amount, setAmount] = useState("");
  const [toAddress, setToAddress] = useState("");
  const [confirmNetwork, setConfirmNetwork] = useState(false);
  const [pending, setPending] = useState<SendView | null>(null);
  const [code, setCode] = useState("");
  const [result, setResult] = useState<SendView | null>(null);
  const [recent, setRecent] = useState<SendView[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // The network on screen now: an answer for the other network that arrives late is ignored
  const current = useRef<Chain>("arc");
  current.current = chain;

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  const load = useCallback(async () => {
    try {
      const i = await api<Info>(`/send/info?chain=${chain}`);
      if (current.current !== chain) return;
      setInfo(i);
      if (i.baseOpen !== undefined) setBaseOpen(i.baseOpen);
      const r = await api<{ sends: SendView[] }>("/sends");
      setRecent(r.sends);
    } catch (e) {
      if (current.current === chain) setError(e instanceof Error ? e.message : "Could not load your balances.");
    }
  }, [chain]);

  useEffect(() => {
    if (session) void load();
  }, [session, load]);

  // A send still on its way: check again every few seconds
  useEffect(() => {
    if (!result || !["SENDING", "SENT"].includes(result.status)) return;
    const timer = setTimeout(async () => {
      try {
        const r = await api<{ send: SendView }>(`/sends/${result.id}`);
        setResult(r.send);
        if (!["SENDING", "SENT"].includes(r.send.status)) void load();
      } catch {
        // tried again on the next tick
      }
    }, 4_000);
    return () => clearTimeout(timer);
  }, [result, load]);

  async function start(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      const r = await api<{ send: SendView }>("/send", {
        method: "POST",
        body: JSON.stringify({ chain, token, amount, toAddress: toAddress.trim(), confirmNetwork }),
      });
      setPending(r.send);
      setCode("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start the send.");
    } finally {
      setBusy(false);
    }
  }

  async function confirm(e: FormEvent) {
    e.preventDefault();
    if (!pending) return;
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ send: SendView }>(`/send/${pending.id}/confirm`, { method: "POST", body: JSON.stringify({ code }) });
      setResult(r.send);
      setPending(null);
      setAmount("");
      setToAddress("");
      setConfirmNetwork(false);
      await load();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Could not confirm.";
      setError(message);
      // A cancelled send (expired or too many wrong codes) needs a fresh start
      if (/start again|start a new one|Nothing was sent/i.test(message)) setPending(null);
    } finally {
      setBusy(false);
    }
  }

  const limit = info?.limits[token];
  const network = info?.network ?? (chain === "base" ? "Base" : "Arc");
  const tokens: Token[] = info?.tokens ?? (chain === "base" ? ["USDC"] : TOKEN_LIST);

  function pickChain(next: Chain) {
    if (next === chain) return;
    setChain(next);
    setInfo(null);
    setToken("USDC");
    setAmount("");
    setConfirmNetwork(false);
    setError(null);
    setResult(null);
  }

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Send to another wallet</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          {chain === "base"
            ? "Send USDC from your own Base wallet to any wallet or exchange address on Base. "
            : `Send USDC, EURC or cirBTC from your wallet to any wallet on ${network}. `}
          No gas to pay. You confirm every send with a code we email you.
        </p>

        {info ? (
          <p className="mt-4 text-sm text-zinc-600 dark:text-zinc-400">
            You have on {network}: {tokens.map((t) => `${fmt(info.balances[t], t)} ${t}`).join(", ")}
          </p>
        ) : null}

        {info?.paused ? (
          <p className="mt-4 rounded-lg bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">{info.paused}</p>
        ) : null}

        <section className="mt-4 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          {!pending ? (
            <form onSubmit={start} className="space-y-5">
              {baseOpen ? (
                <div>
                  <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Network</p>
                  <div className="mt-2 flex gap-2">
                    <button type="button" onClick={() => pickChain("arc")} className={choiceClass(chain === "arc")}>
                      Arc
                    </button>
                    <button type="button" onClick={() => pickChain("base")} className={choiceClass(chain === "base")}>
                      Base
                    </button>
                  </div>
                  {chain === "base" ? (
                    <p className="mt-2 text-xs text-zinc-500">
                      Sends from your Base wallet. To send from your Arc balance, first use To Base on the dashboard.
                    </p>
                  ) : null}
                </div>
              ) : null}
              <div>
                <p className="text-sm font-medium text-zinc-700 dark:text-zinc-300">Token</p>
                <div className="mt-2 flex gap-2">
                  {tokens.map((t) => (
                    <button
                      type="button"
                      key={t}
                      onClick={() => {
                        setToken(t);
                        setAmount("");
                      }}
                      className={choiceClass(token === t)}
                    >
                      {t}
                    </button>
                  ))}
                </div>
              </div>

              <div>
                <div className="flex items-center justify-between">
                  <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                    Amount of {token}
                  </label>
                  {info ? (
                    <button
                      type="button"
                      onClick={() => setAmount(info.balances[token])}
                      className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400"
                    >
                      Use all ({fmt(info.balances[token], token)})
                    </button>
                  ) : null}
                </div>
                <input
                  id="amount"
                  inputMode="decimal"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder={limit ? `${limit.min} to ${limit.max}` : ""}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                {limit && info ? (
                  <p className="mt-1 text-xs text-zinc-500">
                    Up to {limit.max} {token} per send and {limit.daily} {token} per day ({fmt(info.usedToday[token], token)} used
                    today). {info.sendsLeftToday} send{info.sendsLeftToday === 1 ? "" : "s"} left today.
                  </p>
                ) : null}
              </div>

              <div>
                <label htmlFor="to" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Wallet address on {network}
                </label>
                <input
                  id="to"
                  value={toAddress}
                  onChange={(e) => setToAddress(e.target.value)}
                  placeholder="0x..."
                  autoComplete="off"
                  spellCheck={false}
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 font-mono text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
              </div>

              <label className="flex items-start gap-2 rounded-lg bg-amber-50 px-3 py-2.5 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <input type="checkbox" checked={confirmNetwork} onChange={(e) => setConfirmNetwork(e.target.checked)} className="mt-0.5" />
                <span>
                  This address can receive {token} on <strong>{network}</strong>. I understand that sends cannot be reversed,
                  and funds sent to a wrong address or to an exchange that does not support {network} are lost.
                </span>
              </label>

              <button
                type="submit"
                disabled={busy || !amount || !toAddress || !confirmNetwork || Boolean(info?.paused)}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Checking..." : "Continue"}
              </button>
            </form>
          ) : (
            <form onSubmit={confirm} className="space-y-5">
              <dl className="grid grid-cols-[7rem_1fr] gap-2 text-sm">
                <dt className="text-zinc-500">You send</dt>
                <dd className="font-medium text-zinc-900 dark:text-zinc-100">
                  {fmt(pending.amount, pending.token)} {pending.token}
                </dd>
                <dt className="text-zinc-500">To</dt>
                <dd className="break-all font-mono text-xs text-zinc-900 dark:text-zinc-100">{pending.toAddress}</dd>
                <dt className="text-zinc-500">Network</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">{pending.network}</dd>
                <dt className="text-zinc-500">Fee</dt>
                <dd className="text-zinc-900 dark:text-zinc-100">None. We pay the gas.</dd>
              </dl>
              <div>
                <label htmlFor="code" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Code from your email
                </label>
                <input
                  id="code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  maxLength={7}
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  placeholder="6 digits"
                  className="mt-2 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-lg tracking-widest text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
                />
                <p className="mt-1 text-xs text-zinc-500">
                  We sent it to {pending.codeSentTo}. It expires in 10 minutes. Check the address above once more before you confirm.
                </p>
              </div>
              <div className="flex gap-3">
                <button
                  type="submit"
                  disabled={busy || code.replace(/\s/g, "").length !== 6}
                  className="flex-1 rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
                >
                  {busy ? "Sending..." : `Confirm and send ${fmt(pending.amount, pending.token)} ${pending.token}`}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setPending(null);
                    setError(null);
                  }}
                  disabled={busy}
                  className="rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Cancel
                </button>
              </div>
            </form>
          )}

          {result ? (
            <div
              className={`rounded-lg px-3 py-2 text-sm ${
                result.status === "COMPLETE"
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : result.status === "FAILED"
                    ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
                    : "bg-sky-50 text-sky-900 dark:bg-sky-950 dark:text-sky-200"
              }`}
            >
              {result.status === "COMPLETE"
                ? `Sent. ${fmt(result.amount, result.token)} ${result.token} went to ${result.toShort}.`
                : result.status === "FAILED"
                  ? result.failure
                  : `Sending ${fmt(result.amount, result.token)} ${result.token} to ${result.toShort}. This usually takes a few seconds.`}
              {result.explorerUrl ? (
                <a href={result.explorerUrl} target="_blank" rel="noreferrer" className="ml-1 font-medium underline">
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
            <h2 className="text-sm font-medium text-zinc-500">Recent sends</h2>
            <ul className="mt-3 divide-y divide-zinc-100 text-sm dark:divide-zinc-800">
              {recent.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
                  <span className="min-w-0">
                    <span className="block text-zinc-900 dark:text-zinc-100">
                      {fmt(s.amount, s.token)} {s.token} to <span className="font-mono">{s.toShort}</span>
                      {s.network ? <span className="text-zinc-500"> on {s.network}</span> : null}
                    </span>
                    <span className="block text-xs text-zinc-500">{new Date(s.createdAt).toLocaleString("en-NG")}</span>
                  </span>
                  <span className="flex items-center gap-2 text-xs text-zinc-500">
                    {STATUS_TEXT[s.status] ?? s.status}
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
