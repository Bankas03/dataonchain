"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState, type ReactNode } from "react";
import { api, post } from "@/lib/api";

type Me = { email: string; sessionExpiresAt: string; idleMinutes: number };

const NAV = [
  { href: "/", label: "Overview" },
  { href: "/users", label: "Users" },
  { href: "/orders", label: "Orders" },
  { href: "/refunds", label: "Refunds" },
  { href: "/bridge", label: "Bridge" },
  { href: "/swaps", label: "Swaps" },
  { href: "/sends", label: "Sends" },
  { href: "/deposits", label: "Deposits" },
  { href: "/treasury", label: "Treasury" },
  { href: "/providers", label: "Providers" },
  { href: "/activity", label: "Activity" },
  { href: "/settings", label: "Settings" },
];

// Every dashboard page sits inside this: it checks the login and shows the menu.
export function Shell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const [me, setMe] = useState<Me | null>(null);

  useEffect(() => {
    api<Me>("/me")
      .then(setMe)
      .catch(() => router.replace("/login"));
  }, [router]);

  async function logOut() {
    await post("/logout").catch(() => null);
    router.replace("/login");
  }

  if (!me) {
    return <main className="flex min-h-screen items-center justify-center text-sm text-zinc-500">Checking your login...</main>;
  }

  const active = (href: string) => (href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`));

  return (
    <div className="min-h-screen bg-zinc-50 dark:bg-zinc-950 lg:flex">
      <aside className="border-b border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 lg:sticky lg:top-0 lg:h-screen lg:w-56 lg:shrink-0 lg:border-b-0 lg:border-r">
        <div className="flex items-center justify-between px-4 py-4 lg:block">
          <Link href="/" className="block text-base font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain <span className="font-normal text-zinc-500">admin</span>
          </Link>
          <button onClick={logOut} className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400 lg:hidden">
            Log out
          </button>
        </div>
        <nav className="flex gap-1 overflow-x-auto px-2 pb-3 lg:flex-col lg:overflow-visible lg:pb-0">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={`whitespace-nowrap rounded-lg px-3 py-2 text-sm font-medium ${
                active(n.href)
                  ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                  : "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800"
              }`}
            >
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="hidden px-4 py-6 text-xs text-zinc-500 lg:absolute lg:bottom-0 lg:block lg:w-56">
          <p className="truncate" title={me.email}>
            {me.email}
          </p>
          <button onClick={logOut} className="mt-2 font-medium text-zinc-700 hover:underline dark:text-zinc-300">
            Log out
          </button>
        </div>
      </aside>
      <main className="min-w-0 flex-1 px-4 py-6 sm:px-8 sm:py-8">
        <div className="mx-auto max-w-6xl">{children}</div>
      </main>
    </div>
  );
}
