"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { ActivityFeed } from "@/components/ActivityFeed";
import { SupportLink } from "@/components/SupportLink";
import { authClient } from "@/lib/auth-client";

// Onchain history: every send, swap and transfer (and later, purchases), newest first
export default function ActivityPage() {
  const router = useRouter();
  const { data: session, isPending } = authClient.useSession();
  const [flags, setFlags] = useState<{ bridge: boolean; swap: boolean } | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  useEffect(() => {
    fetch("/api/status")
      .then((r) => r.json())
      .then((s: { bridge?: boolean; swap?: boolean }) => setFlags({ bridge: Boolean(s.bridge), swap: Boolean(s.swap) }))
      .catch(() => setFlags({ bridge: false, swap: false }));
  }, []);

  return (
    <main className="min-h-screen bg-paper pb-16 dark:bg-[#07120e]">
      <div className="mx-auto max-w-2xl px-4">
        <header className="flex items-center justify-between py-5">
          <Link href="/dashboard" className="font-display text-xl font-bold tracking-tight text-note dark:text-mint">
            dataonchain
          </Link>
          <Link href="/dashboard" className="rounded-full px-3 py-2 text-sm font-semibold text-ink hover:bg-white dark:text-zinc-200 dark:hover:bg-white/10">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-4 font-display text-3xl font-semibold tracking-tight text-ink sm:text-4xl dark:text-white">Onchain history</h1>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
          Your sends, swaps and transfers on Arc and Base, newest first. Tap one to see its details and transaction.
        </p>

        <div className="mt-6">
          {session && flags ? <ActivityFeed bridgeOn={flags.bridge} swapOn={flags.swap} full /> : null}
        </div>

        <p className="mt-10 text-center text-sm text-zinc-500">
          Something look wrong? <SupportLink />
        </p>
      </div>
    </main>
  );
}
