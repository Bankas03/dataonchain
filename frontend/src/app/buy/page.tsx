"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Network = "mtn" | "airtel" | "glo" | "9mobile";
type Service = "data" | "airtime";
type Plan = { id: string; name: string; ngnAmount: number; validity: string | null };
type Quote = {
  reference: string;
  status: string;
  serviceType: Service;
  network: Network;
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  expiresAt: string;
  rate?: number;
  marginPercent?: number;
};

const NETWORKS: { id: Network; label: string }[] = [
  { id: "mtn", label: "MTN" },
  { id: "airtel", label: "Airtel" },
  { id: "glo", label: "Glo" },
  { id: "9mobile", label: "9mobile" },
];
const QUICK_AMOUNTS = [100, 200, 500, 1000, 2000];

const naira = (n: number) => `₦${n.toLocaleString("en-NG", { maximumFractionDigits: 2 })}`;
const usdc = (s: string) =>
  Number(s).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
const localPhone = (p?: string | null) => (p ? (p.startsWith("+234") ? `0${p.slice(4)}` : p) : "");
const networkLabel = (id: Network) => NETWORKS.find((n) => n.id === id)?.label ?? id;

function choiceClass(active: boolean) {
  return `rounded-lg border px-3 py-2 text-sm font-medium transition ${
    active
      ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
  }`;
}

export default function BuyPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [service, setService] = useState<Service>("data");
  const [network, setNetwork] = useState<Network>("mtn");
  const [plans, setPlans] = useState<Plan[]>([]);
  const [plansLoading, setPlansLoading] = useState(false);
  const [planId, setPlanId] = useState("");
  const [amount, setAmount] = useState("");
  const [phone, setPhone] = useState("");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [balance, setBalance] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [recent, setRecent] = useState<{ phone: string; network: Network }[]>([]);
  // "Buy again" links open this page with the details filled in (?service=&network=&phone=&plan=&amount=)
  const pendingPlan = useRef<string | null>(null);

  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    const s = q.get("service");
    const n = q.get("network");
    if (s === "data" || s === "airtime") setService(s);
    if (n && NETWORKS.some((x) => x.id === n)) setNetwork(n as Network);
    if (q.get("phone")) setPhone(q.get("phone") ?? "");
    if (q.get("amount")) setAmount(q.get("amount") ?? "");
    pendingPlan.current = q.get("plan");
  }, []);

  // Numbers bought for before, newest first, to fill in with one tap
  useEffect(() => {
    if (!session) return;
    api<{ orders: { phone: string; network: Network }[] }>("/orders")
      .then((r) => {
        const seen = new Set<string>();
        const list: { phone: string; network: Network }[] = [];
        for (const o of r.orders) {
          if (seen.has(o.phone)) continue;
          seen.add(o.phone);
          list.push({ phone: o.phone, network: o.network });
          if (list.length === 4) break;
        }
        setRecent(list);
      })
      .catch(() => setRecent([]));
  }, [session]);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  // Start with the user's own number; they can change it.
  useEffect(() => {
    if (session) setPhone((p) => p || localPhone((session.user as { phone?: string }).phone));
  }, [session]);

  useEffect(() => {
    if (!session) return;
    api<{ balance: { usdc: string | null } }>("/wallet")
      .then((r) => setBalance(r.balance.usdc))
      .catch(() => setBalance(null));
  }, [session]);

  useEffect(() => {
    if (!session || service !== "data") return;
    let cancelled = false;
    setPlansLoading(true);
    setPlanId("");
    setError(null);
    api<{ plans: Plan[] }>(`/plans?network=${network}`)
      .then((r) => {
        if (cancelled) return;
        setPlans(r.plans);
        const wanted = pendingPlan.current;
        if (wanted && r.plans.some((p) => p.id === wanted)) setPlanId(wanted);
        pendingPlan.current = null;
      })
      .catch((e: Error) => !cancelled && setError(e.message))
      .finally(() => !cancelled && setPlansLoading(false));
    return () => {
      cancelled = true;
    };
  }, [session, service, network]);

  useEffect(() => {
    if (!quote) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [quote]);

  async function pay() {
    if (!quote) return;
    setError(null);
    setBusy(true);
    try {
      await api(`/orders/${quote.reference}/pay`, { method: "POST" });
      router.push(`/orders/${quote.reference}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Payment could not start. Please try again.");
      setBusy(false);
    }
  }

  async function getPrice(event?: FormEvent<HTMLFormElement>) {
    event?.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const body =
        service === "data"
          ? { serviceType: "data", network, planId, phone }
          : { serviceType: "airtime", network, amountNgn: Number(amount), phone };
      const r = await api<{ quote: Quote }>("/quotes", { method: "POST", body: JSON.stringify(body) });
      setQuote(r.quote);
      setNow(Date.now());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not get a price. Please try again.");
    } finally {
      setBusy(false);
    }
  }

  if (isPending || !session) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const secondsLeft = quote ? Math.max(0, Math.floor((new Date(quote.expiresAt).getTime() - now) / 1000)) : 0;
  const expired = quote !== null && secondsLeft === 0;
  const notEnough = quote !== null && balance !== null && Number(balance) < Number(quote.usdcAmount);

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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Buy airtime or data</h1>
        {balance !== null ? (
          <p className="mt-1 text-sm text-zinc-500">Your balance: {usdc(balance)} USDC</p>
        ) : null}

        {!quote ? (
          <form onSubmit={getPrice} className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">What do you want?</legend>
              <div className="mt-2 grid grid-cols-2 gap-2">
                <button type="button" onClick={() => setService("data")} className={choiceClass(service === "data")}>Data</button>
                <button type="button" onClick={() => setService("airtime")} className={choiceClass(service === "airtime")}>Airtime</button>
              </div>
            </fieldset>

            <fieldset>
              <legend className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Network</legend>
              <div className="mt-2 grid grid-cols-4 gap-2">
                {NETWORKS.map((n) => (
                  <button key={n.id} type="button" onClick={() => setNetwork(n.id)} className={choiceClass(network === n.id)}>
                    {n.label}
                  </button>
                ))}
              </div>
            </fieldset>

            {service === "data" ? (
              <label className="block">
                <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Data plan</span>
                <select
                  value={planId}
                  onChange={(e) => setPlanId(e.target.value)}
                  required
                  disabled={plansLoading}
                  className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                >
                  <option value="">{plansLoading ? "Loading plans..." : "Choose a plan"}</option>
                  {plans.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} ({naira(p.ngnAmount)})
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <div>
                <label className="block">
                  <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Amount in naira</span>
                  <input
                    type="number"
                    inputMode="numeric"
                    min={50}
                    max={50000}
                    step={1}
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="500"
                    required
                    className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
                  />
                </label>
                <div className="mt-2 flex flex-wrap gap-2">
                  {QUICK_AMOUNTS.map((a) => (
                    <button key={a} type="button" onClick={() => setAmount(String(a))} className={choiceClass(amount === String(a))}>
                      {naira(a)}
                    </button>
                  ))}
                </div>
              </div>
            )}

            <label className="block">
              <span className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Phone number to top up</span>
              <input
                type="tel"
                value={phone}
                onChange={(e) => setPhone(e.target.value)}
                placeholder="08012345678"
                required
                className="mt-1 block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-zinc-900 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-50"
              />
              <span className="mt-1 block text-xs text-zinc-500">
                Make sure this number is on {networkLabel(network)}.
              </span>
            </label>
            {recent.length > 0 ? (
              <div className="-mt-3 flex flex-wrap gap-2">
                {recent.map((r) => (
                  <button
                    key={r.phone}
                    type="button"
                    onClick={() => {
                      setPhone(r.phone);
                      setNetwork(r.network);
                    }}
                    className={choiceClass(phone === r.phone)}
                  >
                    {r.phone} <span className="text-xs text-zinc-500">{networkLabel(r.network)}</span>
                  </button>
                ))}
              </div>
            ) : null}

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            <button
              type="submit"
              disabled={busy || (service === "data" && !planId)}
              className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white transition hover:bg-emerald-800 disabled:opacity-60"
            >
              {busy ? "Getting your price..." : "Get price in USDC"}
            </button>
          </form>
        ) : (
          <section className="mt-6 space-y-5 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div>
              <p className="text-sm text-zinc-500">You pay</p>
              <p className="text-3xl font-semibold text-zinc-900 dark:text-zinc-50">
                {usdc(quote.usdcAmount)} <span className="text-lg font-medium text-zinc-500">USDC</span>
              </p>
            </div>

            <dl className="grid grid-cols-[8rem_1fr] gap-2 text-sm">
              <dt className="text-zinc-500">For</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {networkLabel(quote.network)} {quote.serviceType === "data" ? quote.planName : `airtime ${naira(quote.ngnAmount)}`}
              </dd>
              <dt className="text-zinc-500">Value</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{naira(quote.ngnAmount)}</dd>
              <dt className="text-zinc-500">Phone</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">{quote.phone}</dd>
              {quote.rate ? (
                <>
                  <dt className="text-zinc-500">Rate</dt>
                  <dd className="text-zinc-900 dark:text-zinc-100">
                    1 USDC = {naira(quote.rate)}
                    {quote.marginPercent ? ` (includes ${quote.marginPercent}% service fee)` : ""}
                  </dd>
                </>
              ) : null}
              <dt className="text-zinc-500">Reference</dt>
              <dd className="font-mono text-zinc-900 dark:text-zinc-100">{quote.reference}</dd>
            </dl>

            <p className="text-xs text-zinc-500">
              No network fee: the Arc gas for your payment is covered by dataonchain.
            </p>

            {expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                This price has expired. Get a new one to continue.
              </p>
            ) : (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Price held for {Math.floor(secondsLeft / 60)}:{String(secondsLeft % 60).padStart(2, "0")}
              </p>
            )}

            {notEnough && !expired ? (
              <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                Your balance is not enough for this purchase. Add USDC to your wallet first.
              </p>
            ) : null}

            {error ? (
              <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p>
            ) : null}

            {expired ? (
              <button
                onClick={() => void getPrice()}
                disabled={busy}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Getting a new price..." : "Get a new price"}
              </button>
            ) : (
              <button
                onClick={() => void pay()}
                disabled={busy || notEnough}
                className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
              >
                {busy ? "Sending payment..." : `Pay ${usdc(quote.usdcAmount)} USDC`}
              </button>
            )}

            <button
              onClick={() => {
                setQuote(null);
                setError(null);
              }}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
            >
              Change details
            </button>
          </section>
        )}
      </div>
    </main>
  );
}
