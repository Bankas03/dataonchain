import Link from "next/link";
import type { ReactNode } from "react";
import { SupportLink } from "@/components/SupportLink";

const LEGAL = [
  { href: "/terms", label: "Terms of Service" },
  { href: "/privacy", label: "Privacy Policy" },
  { href: "/refund-policy", label: "Refund Policy" },
];

// Shared frame for the Terms, Privacy and Refund pages.
export function LegalPage({ title, updated, intro, children }: { title: string; updated: string; intro: ReactNode; children: ReactNode }) {
  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-3xl">
        <header className="flex items-center justify-between">
          <Link href="/" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Home
          </Link>
        </header>

        <nav className="mt-8 flex flex-wrap gap-2 text-sm">
          {LEGAL.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="rounded-full border border-zinc-300 px-3 py-1 text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
            >
              {l.label}
            </Link>
          ))}
        </nav>

        <article className="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 sm:p-10 dark:border-zinc-800 dark:bg-zinc-900 [&_h2]:mt-10 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-zinc-900 dark:[&_h2]:text-zinc-50 [&_li]:mt-1.5 [&_p]:mt-3 [&_p]:leading-relaxed [&_ul]:mt-3 [&_ul]:list-disc [&_ul]:space-y-1 [&_ul]:pl-5 text-zinc-700 dark:text-zinc-300">
          <h1 className="text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h1>
          <p className="!mt-1 text-sm text-zinc-500">Last updated {updated}</p>
          <div className="mt-6 text-base">{intro}</div>
          {children}
          <h2>Contact us</h2>
          <p>
            Questions about this page, your account or an order: <SupportLink />. Please include your order reference if
            it is about a purchase.
          </p>
        </article>
      </div>
    </main>
  );
}
