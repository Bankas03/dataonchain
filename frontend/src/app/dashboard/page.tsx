"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { ActivityFeed } from "@/components/ActivityFeed";
import { ChainWallets } from "@/components/ChainWallets";
import { SupportLink } from "@/components/SupportLink";
import { WalletCard } from "@/components/WalletCard";
import { authClient } from "@/lib/auth-client";

type Status = {
  bridge?: boolean;
  swap?: boolean;
  network?: string;
  notices?: string[];
  paused?: { purchasesPaused?: boolean; bridgePaused?: boolean; swapPaused?: boolean; sendPaused?: boolean };
};

function greeting() {
  const h = Number(new Date().toLocaleString("en-GB", { hour: "numeric", hour12: false, timeZone: "Africa/Lagos" }));
  return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening";
}

const icon = (path: ReactNode) => (
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {path}
  </svg>
);

const ICONS = {
  add: icon(<path d="M12 5v14M5 12h14" />),
  send: icon(<path d="M7 17 17 7M9 7h8v8" />),
  swap: icon(<path d="M7 4 3 8l4 4M3 8h14M17 20l4-4-4-4M21 16H7" />),
  bridge: icon(<path d="M4 12a8 8 0 0 1 16 0M12 4v16M4 12h16" />),
  airtime: icon(<path d="M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2" />),
};

type Action = { href: string; label: string; icon: ReactNode; soon?: boolean; primary?: boolean };

function ActionTile({ a }: { a: Action }) {
  const circle = a.primary
    ? "bg-note text-white group-hover:bg-note-deep dark:bg-mint dark:text-note-deep dark:group-hover:bg-mint/90"
    : "bg-white text-ink ring-1 ring-ink/10 group-hover:bg-paper dark:bg-white/[0.06] dark:text-white dark:ring-white/10 dark:group-hover:bg-white/10";
  const inner = (
    <>
      <span className={`relative flex h-14 w-14 items-center justify-center rounded-2xl transition-colors ${circle} ${a.soon ? "opacity-50" : ""}`}>
        {a.icon}
        {a.soon ? (
          <span className="absolute -right-2 -top-2 rounded-full bg-gold px-1.5 py-0.5 text-[10px] font-bold text-note-deep">Soon</span>
        ) : null}
      </span>
      <span className={`text-center text-xs font-semibold leading-tight sm:text-sm ${a.soon ? "text-zinc-500" : "text-ink dark:text-white"}`}>{a.label}</span>
    </>
  );
  if (a.soon) {
    return (
      <span className="flex flex-col items-center gap-2" aria-disabled="true" title="Coming soon">
        {inner}
      </span>
    );
  }
  return (
    <Link href={a.href} className="group flex flex-col items-center gap-2 rounded-2xl focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-emerald-600">
      {inner}
    </Link>
  );
}

export default function DashboardPage() {
  const router = useRouter();
  const { data, isPending } = authClient.useSession();
  const [status, setStatus] = useState<Status | null>(null);

  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: Status) => setStatus(s))
      .catch(() => setStatus({}));
  }, []);

  useEffect(() => {
    if (isPending || data) return;
    // A failed confirmation link lands here with ?error=...
    const failedLink = new URLSearchParams(window.location.search).has("error");
    router.replace(failedLink ? "/login?error=link" : "/login");
  }, [isPending, data, router]);

  if (isPending || !data) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-paper text-zinc-500 dark:bg-[#07120e]">
        <span className="h-8 w-8 animate-spin rounded-full border-2 border-note/20 border-t-note dark:border-white/10 dark:border-t-mint" aria-label="Loading" />
      </main>
    );
  }

  const { user } = data;
  const mainnet = status?.network === "mainnet";
  const bridgeOn = Boolean(status?.bridge);
  const swapOn = Boolean(status?.swap);
  const buyPaused = Boolean(status?.paused?.purchasesPaused);
  const first = user.name.split(" ")[0];

  // Testnet maintenance notice (on mainnet the notices say what opens soon)
  const paused: string[] = [];
  if (status?.paused?.purchasesPaused) paused.push("buying airtime and data");
  if (status?.paused?.bridgePaused && bridgeOn) paused.push("sending to other networks");
  if (status?.paused?.swapPaused && swapOn) paused.push("swaps");
  if (status?.paused?.sendPaused) paused.push("sending to other wallets");
  // On mainnet, buying airtime and data shows as "Soon" on its button instead
  const notices = (status?.notices ?? []).filter((n) => !(mainnet && /airtime and data/i.test(n)));

  const actions: Action[] = [
    { href: "/add-usdc", label: "Add USDC", icon: ICONS.add, primary: true },
    { href: "/send", label: "Send", icon: ICONS.send },
    ...(swapOn ? [{ href: "/swap", label: "Swap", icon: ICONS.swap }] : []),
    ...(bridgeOn ? [{ href: "/bridge", label: "To Base", icon: ICONS.bridge }] : []),
    { href: "/buy", label: "Airtime and data", icon: ICONS.airtime, soon: mainnet && buyPaused },
  ];

  async function logOut() {
    await authClient.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-2xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <nav className="flex items-center gap-1">
            <Link
              href="/account"
              className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10"
            >
              Account
            </Link>
            <button
              onClick={logOut}
              className="rounded-full px-3 py-2 text-sm font-semibold text-zinc-600 hover:bg-white dark:text-zinc-400 dark:hover:bg-white/10"
            >
              Log out
            </button>
          </nav>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink sm:text-4xl dark:text-white">
          {greeting()}, {first}
        </h1>

        {user.status === "suspended" ? (
          <p className="mt-4 rounded-2xl bg-red-50 px-4 py-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
            Your account is suspended. Please contact support. Orders already in progress still complete, and refunds still go out.
          </p>
        ) : null}
        {!user.emailVerified ? (
          <p className="mt-4 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Confirm your email to use your wallet: open the link we sent to {user.email}.
          </p>
        ) : null}

        <div className="mt-6">
          <WalletCard />
        </div>

        <nav aria-label="Actions" className={`mt-6 grid gap-2 ${actions.length >= 5 ? "grid-cols-5" : "grid-cols-4"}`}>
          {actions.map((a) => (
            <ActionTile key={a.label} a={a} />
          ))}
        </nav>

        {mainnet && notices.length > 0 ? (
          <div className="mt-6 space-y-1 rounded-2xl bg-sky-50 px-4 py-3 text-sm text-sky-900 dark:bg-sky-950 dark:text-sky-200">
            {notices.map((n) => (
              <p key={n}>{n}</p>
            ))}
          </div>
        ) : null}
        {mainnet && buyPaused ? (
          <p className="mt-6 rounded-2xl bg-white px-4 py-3 text-sm text-zinc-600 ring-1 ring-ink/10 dark:bg-white/[0.04] dark:text-zinc-300 dark:ring-white/10">
            Buying airtime and data with USDC is coming soon. Until then you can add, send, swap and move your USDC.
          </p>
        ) : null}
        {!mainnet && status && paused.length > 0 ? (
          <p className="mt-6 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            Short maintenance: {paused.join(", ")} {paused.length > 1 ? "are" : "is"} paused for now. Your balance is safe.
          </p>
        ) : null}

        <div className="mt-6">
          <ActivityFeed bridgeOn={bridgeOn} swapOn={swapOn} />
        </div>

        {bridgeOn ? <ChainWallets /> : null}

        <p className="mt-10 text-center text-sm text-zinc-500">
          Need help? <SupportLink />
        </p>
      </div>
    </main>
  );
}
