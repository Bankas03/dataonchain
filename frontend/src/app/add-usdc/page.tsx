"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import QRCode from "qrcode";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type Wallet = { address: string; network: string; testnet?: boolean };
type Way = "arc" | "base";

// Add USDC: straight to the Arc wallet, or (for exchanges that do not support
// Arc yet) to the user's own Base wallet, then Move to Arc.
export default function AddUsdcPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [way, setWay] = useState<Way>("arc");
  const [arc, setArc] = useState<Wallet | null>(null);
  const [base, setBase] = useState<Wallet | null>(null);
  const [baseOn, setBaseOn] = useState(false);
  const [qr, setQr] = useState<Record<Way, string | null>>({ arc: null, base: null });
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadingBase, setLoadingBase] = useState(false);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<{ wallet: Wallet }>("/wallet")
      .then(async (r) => {
        setArc(r.wallet);
        const code = await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" });
        setQr((q) => ({ ...q, arc: code }));
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Could not load your wallet."));
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; network?: string }) => setBaseOn(Boolean(s.bridge)))
      .catch(() => setBaseOn(false));
  }, [session]);

  async function choose(next: Way) {
    setWay(next);
    setCopied(false);
    setError(null);
    if (next !== "base" || base) return;
    setLoadingBase(true);
    try {
      const r = await api<{ wallet: Wallet }>("/wallet/base");
      setBase(r.wallet);
      const code = await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" });
      setQr((q) => ({ ...q, base: code }));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load your Base wallet.");
    } finally {
      setLoadingBase(false);
    }
  }

  const wallet = way === "arc" ? arc : base;

  async function copy() {
    if (!wallet) return;
    await navigator.clipboard.writeText(wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  const tab = (active: boolean) =>
    `flex-1 rounded-full px-4 py-2 text-sm font-semibold transition-colors ${
      active ? "bg-note text-white dark:bg-mint dark:text-note-deep" : "text-ink hover:bg-white dark:text-zinc-300 dark:hover:bg-white/10"
    }`;

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/dashboard" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <Link href="/dashboard" className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink dark:text-white">Add USDC</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Send USDC from an exchange or another wallet to your address below. Choose the network your exchange supports.
        </p>

        {baseOn ? (
          <div role="tablist" aria-label="Network" className="mt-6 flex gap-1 rounded-full bg-white/70 p-1 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:ring-white/10">
            <button role="tab" aria-selected={way === "arc"} onClick={() => choose("arc")} className={tab(way === "arc")}>
              Arc (fastest)
            </button>
            <button role="tab" aria-selected={way === "base"} onClick={() => choose("base")} className={tab(way === "base")}>
              Base
            </button>
          </div>
        ) : null}

        {error ? <p className="mt-6 rounded-2xl bg-red-50 px-4 py-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
        {(!wallet && !error) || loadingBase ? <p className="mt-6 text-sm text-zinc-500">Loading your wallet...</p> : null}

        {wallet && !loadingBase ? (
          <section className="mt-6 space-y-6 rounded-3xl bg-white p-6 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:ring-white/10">
            <div className="rounded-2xl border-2 border-red-300 bg-red-50 p-4 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <p className="font-semibold">Send only USDC on {wallet.network}.</p>
              <p className="mt-1">
                USDC sent on any other network, or any other token, may be lost for good. When you withdraw from an exchange, choose{" "}
                <strong>{wallet.network}</strong> as the network.
              </p>
            </div>

            <div className="flex flex-col items-center gap-4">
              {qr[way] ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={qr[way]!} alt={`QR code of your ${wallet.network} wallet address`} width={240} height={240} className="rounded-2xl border border-zinc-200 bg-white p-2" />
              ) : (
                <div className="h-[240px] w-[240px] animate-pulse rounded-2xl bg-zinc-100 dark:bg-white/5" />
              )}
              <div className="w-full">
                <p className="text-sm text-zinc-500">Your wallet address on {wallet.network}</p>
                <code className="mt-1 block break-all rounded-xl bg-paper px-3 py-2 font-mono text-sm text-ink dark:bg-white/5 dark:text-zinc-100">
                  {wallet.address}
                </code>
                <button onClick={copy} className="mt-3 w-full rounded-full bg-note px-4 py-3 font-semibold text-white hover:bg-note-deep dark:bg-mint dark:text-note-deep">
                  {copied ? "Copied" : "Copy address"}
                </button>
              </div>
            </div>

            {way === "arc" ? (
              <ul className="list-disc space-y-1 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
                <li>It shows in your balance within a minute, and we email you when it arrives.</li>
                <li>Check the first and last characters of the address after you paste it.</li>
                <li>Send a small amount first if you have not used this address before.</li>
                <li>Your exchange does not list Arc? Choose Base above.</li>
              </ul>
            ) : (
              <ol className="list-decimal space-y-2 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
                <li>
                  Withdraw USDC from your exchange to this address, with <b>{wallet.network}</b> as the network. Send at least 1 USDC.
                </li>
                <li>It arrives in your own {wallet.network} wallet within a few minutes, and we email you.</li>
                <li>
                  On your dashboard, under <b>Your USDC on other networks</b>, tap <b>Move to Arc</b>. It reaches your Arc wallet in about 20
                  minutes. Circle&apos;s fee (about 0.03 USDC) and our 0.10 USDC transfer fee come out of the amount.
                </li>
              </ol>
            )}

            {arc?.testnet && way === "arc" ? (
              <div className="rounded-2xl bg-amber-50 p-4 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <p className="font-semibold">Test network: get free test USDC</p>
                <p className="mt-1">
                  Open{" "}
                  <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                    faucet.circle.com
                  </a>
                  , choose USDC and Arc Testnet, paste your address and send. Test USDC has no real value.
                </p>
              </div>
            ) : null}
          </section>
        ) : null}
      </div>
    </main>
  );
}
