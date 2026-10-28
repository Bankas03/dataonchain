"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ChainWallets } from "@/components/ChainWallets";
import { SupportLink } from "@/components/SupportLink";
import { RecentOrders } from "@/components/RecentOrders";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [bridgeOn, setBridgeOn] = useState(false);
  const [swapOn, setSwapOn] = useState(false);
  const [paused, setPaused] = useState<string[]>([]);
  const [mainnet, setMainnet] = useState(false);
  const [notices, setNotices] = useState<string[]>([]);
  const [buyPaused, setBuyPaused] = useState(false);

  // The "Send to a provider" button appears only when bridging is switched on
  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean; network?: string; notices?: string[]; paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean } }) => {
        setBridgeOn(Boolean(s.bridge));
        setSwapOn(Boolean(s.swap));
        setMainnet(s.network === "mainnet");
        setNotices(s.notices ?? []);
        setBuyPaused(Boolean(s.paused?.purchasesPaused));
        const parts: string[] = [];
        if (s.paused?.purchasesPaused) parts.push("buying airtime and data");
        if (s.paused?.bridgePaused && s.bridge) parts.push("sending to other networks");
        if (s.paused?.swapPaused && s.swap) parts.push("swaps");
        setPaused(parts);
      })
      .catch(() => setBridgeOn(false));
  }, []);

  useEffect(() => {
    if (isPending || data) return;
    // A failed confirmation link lands here with ?error=...
    const failedLink = new URLSearchParams(window.location.search).has("error");
    router.replace(failedLink ? "/login?error=link" : "/login");
  }, [isPending, data, router]);

  if (isPending || !data) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">
        Loading...
      </main>
    );
  }

  const { user } = data;

  async function logOut() {
    await authClient.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-2xl">
        <header className="flex items-center justify-between">
          <span className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">dataonchain</span>
          <div className="flex items-center gap-2">
          <Link
            href="/account"
            className="rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:text-zinc-300 dark:hover:bg-zinc-900"
          >
            Account
          </Link>
          <button
            onClick={logOut}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-800 hover:bg-white dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-900"
          >
            Log out
          </button>
          </div>
        </header>

        <h1 className="mt-10 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">
          Hello, {user.name.split(" ")[0]}
        </h1>

        {user.status === "suspended" ? (
          <p className="mt-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
            Your account is suspended. Please contact support. Orders already in progress still complete, and refunds
            still go out.
          </p>
        ) : null}
        {mainnet && notices.length > 0 ? (
          <div className="mt-4 rounded-lg bg-sky-50 px-3 py-2 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">
            {notices.map((n) => (
              <p key={n}>{n}</p>
            ))}
          </div>
        ) : null}
        {!mainnet && paused.length > 0 ? (
          <p className="mt-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Short maintenance: {paused.join(", ")} {paused.length > 1 ? "are" : "is"} paused for now. Your balance is safe.
          </p>
        ) : null}

        <div className="mt-4 flex flex-wrap gap-3">
          {mainnet && buyPaused ? (
            <span className="inline-block cursor-not-allowed rounded-lg bg-zinc-200 px-4 py-2.5 font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400">
              Buy airtime or data · coming soon
            </span>
          ) : (
            <Link
              href="/buy"
              className="inline-block rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800"
            >
              Buy airtime or data
            </Link>
          )}
          {swapOn ? (
            <Link
              href="/swap"
              className="inline-block rounded-lg border border-emerald-700 px-4 py-2.5 font-medium text-emerald-800 hover:bg-emerald-50 dark:border-emerald-500 dark:text-emerald-300 dark:hover:bg-emerald-950"
            >
              Swap
            </Link>
          ) : null}
          {bridgeOn ? (
            <Link
              href="/bridge"
              className="inline-block rounded-lg border border-emerald-700 px-4 py-2.5 font-medium text-emerald-800 hover:bg-emerald-50 dark:border-emerald-500 dark:text-emerald-300 dark:hover:bg-emerald-950"
            >
              Send to another network
            </Link>
          ) : null}
        </div>

        <section className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium text-zinc-500">Your account</h2>
            <Link href="/account" className="text-sm font-medium text-emerald-700 hover:underline dark:text-emerald-400">
              Edit
            </Link>
          </div>
          <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-[8rem_1fr]">
            <dt className="text-zinc-500">Name</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.name}</dd>
            <dt className="text-zinc-500">Email</dt>
            <dd className="flex items-center gap-2 text-zinc-900 dark:text-zinc-100">
              {user.email}
              {user.emailVerified ? (
                <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                  Confirmed
                </span>
              ) : null}
            </dd>
            <dt className="text-zinc-500">Phone</dt>
            <dd className="text-zinc-900 dark:text-zinc-100">{user.phone}</dd>
          </dl>
        </section>

        <WalletCard />
        {bridgeOn ? <ChainWallets /> : null}
        <RecentOrders />

        <p className="mt-8 text-center text-sm text-zinc-500">
          Need help? <SupportLink />
        </p>
      </div>
    </main>
  );
}
