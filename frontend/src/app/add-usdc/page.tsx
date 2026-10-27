"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import QRCode from "qrcode";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { authClient } from "@/lib/auth-client";

type WalletResponse = { wallet: { address: string; network: string; testnet: boolean } };

export default function AddUsdcPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [wallet, setWallet] = useState<WalletResponse["wallet"] | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    if (!session) return;
    api<WalletResponse>("/wallet")
      .then(async (r) => {
        setWallet(r.wallet);
        setQr(await QRCode.toDataURL(r.wallet.address, { margin: 1, width: 240, errorCorrectionLevel: "M" }));
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Could not load your wallet."));
  }, [session]);

  async function copy() {
    if (!wallet) return;
    await navigator.clipboard.writeText(wallet.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
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

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Add USDC</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Send USDC to your wallet address below. It shows in your balance within a minute.</p>

        {error ? <p className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">{error}</p> : null}
        {!wallet && !error ? <p className="mt-6 text-sm text-zinc-500">Loading your wallet...</p> : null}

        {wallet ? (
          <section className="mt-6 space-y-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="rounded-xl border-2 border-red-300 bg-red-50 p-4 text-sm text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200">
              <p className="font-semibold">Send only USDC on {wallet.network}.</p>
              <p className="mt-1">
                USDC sent on another network (Ethereum, Base, BNB Chain, Tron, Solana or any other), or any other token, may be lost
                for good. When you withdraw from an exchange or wallet, choose <strong>{wallet.network}</strong> as the network.
              </p>
            </div>

            <div className="flex flex-col items-center gap-4">
              {qr ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={qr} alt="QR code of your wallet address" width={240} height={240} className="rounded-lg border border-zinc-200 bg-white p-2 dark:border-zinc-700" />
              ) : (
                <div className="h-[240px] w-[240px] animate-pulse rounded-lg bg-zinc-100 dark:bg-zinc-800" />
              )}
              <div className="w-full">
                <p className="text-sm text-zinc-500">Your wallet address on {wallet.network}</p>
                <code className="mt-1 block break-all rounded-lg bg-zinc-100 px-3 py-2 font-mono text-sm text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100">
                  {wallet.address}
                </code>
                <button
                  onClick={copy}
                  className="mt-3 w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
                >
                  {copied ? "Copied" : "Copy address"}
                </button>
              </div>
            </div>

            <ul className="list-disc space-y-1 pl-5 text-sm text-zinc-600 dark:text-zinc-400">
              <li>Check the first and last characters of the address after you paste it.</li>
              <li>Send a small amount first if you have not used this address before.</li>
              <li>You pay no network fee to receive. The sender pays their own network&apos;s fee.</li>
            </ul>

            {wallet.testnet ? (
              <div className="rounded-lg bg-amber-50 p-4 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
                <p className="font-semibold">Test network: get free test USDC</p>
                <ol className="mt-2 list-decimal space-y-1 pl-5">
                  <li>Copy your address above.</li>
                  <li>
                    Open{" "}
                    <a href="https://faucet.circle.com" target="_blank" rel="noreferrer" className="font-medium underline">
                      faucet.circle.com
                    </a>
                    .
                  </li>
                  <li>Choose USDC and Arc Testnet, paste your address and send.</li>
                </ol>
                <p className="mt-2">Test USDC has no real value.</p>
              </div>
            ) : null}
          </section>
        ) : null}
      </div>
    </main>
  );
}
