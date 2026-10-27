"use client";

import Link from "next/link";
import { useState, type FormEvent, type ReactNode } from "react";
import { TONE_CLASS, label, toneOf, type Tone } from "@/lib/format";

export function PageTitle({ title, subtitle, right }: { title: string; subtitle?: ReactNode; right?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">{title}</h1>
        {subtitle ? <p className="mt-1 text-sm text-zinc-500">{subtitle}</p> : null}
      </div>
      {right}
    </div>
  );
}

export function Card({ title, right, children, className = "" }: { title?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`rounded-xl border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900 ${className}`}>
      {title || right ? (
        <div className="mb-4 flex items-center justify-between gap-3">
          {title ? <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">{title}</h2> : <span />}
          {right}
        </div>
      ) : null}
      {children}
    </section>
  );
}

export function Stat({ label: name, value, hint, href }: { label: string; value: ReactNode; hint?: ReactNode; href?: string }) {
  const body = (
    <div className="h-full rounded-xl border border-zinc-200 bg-white p-4 transition hover:border-zinc-300 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-zinc-700">
      <p className="text-xs font-medium uppercase tracking-wide text-zinc-500">{name}</p>
      <p className="mt-2 text-2xl font-semibold tabular-nums text-zinc-900 dark:text-zinc-50">{value}</p>
      {hint ? <p className="mt-1 text-xs text-zinc-500">{hint}</p> : null}
    </div>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

export function Badge({ status, tone, children }: { status?: string; tone?: Tone; children?: ReactNode }) {
  const t = tone ?? (status ? toneOf(status) : "plain");
  return (
    <span className={`inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset ${TONE_CLASS[t]}`}>
      {children ?? (status ? label(status) : "")}
    </span>
  );
}

export function Table({ head, children, empty }: { head: ReactNode[]; children: ReactNode; empty?: boolean }) {
  return (
    <div className="-mx-5 overflow-x-auto">
      <table className="w-full min-w-[640px] text-left text-sm">
        <thead>
          <tr className="border-b border-zinc-200 text-xs uppercase tracking-wide text-zinc-500 dark:border-zinc-800">
            {head.map((h, i) => (
              <th key={i} className="whitespace-nowrap px-5 py-2 font-medium">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">{children}</tbody>
      </table>
      {empty ? <p className="px-5 py-8 text-center text-sm text-zinc-500">Nothing here yet.</p> : null}
    </div>
  );
}

export function Td({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <td className={`px-5 py-2.5 align-top text-zinc-800 dark:text-zinc-200 ${className}`}>{children}</td>;
}

export function RowLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <Link href={href} className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      {children}
    </Link>
  );
}

export function ExtLink({ href, children }: { href: string | null | undefined; children: ReactNode }) {
  if (!href) return <span className="text-zinc-400">{children}</span>;
  return (
    <a href={href} target="_blank" rel="noreferrer noopener" className="text-emerald-700 hover:underline dark:text-emerald-400">
      {children}
    </a>
  );
}

export function Pager({ page, pageSize, total, onPage }: { page: number; pageSize: number; total: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  return (
    <div className="mt-4 flex items-center justify-between text-sm text-zinc-500">
      <span>
        {total.toLocaleString("en-US")} in total · page {page} of {pages}
      </span>
      <div className="flex gap-2">
        <button
          disabled={page <= 1}
          onClick={() => onPage(page - 1)}
          className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          Previous
        </button>
        <button
          disabled={page >= pages}
          onClick={() => onPage(page + 1)}
          className="rounded-lg border border-zinc-300 px-3 py-1.5 font-medium text-zinc-700 hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          Next
        </button>
      </div>
    </div>
  );
}

export function Notice({ tone = "bad", children }: { tone?: Tone; children: ReactNode }) {
  return <p className={`rounded-lg px-3 py-2 text-sm ring-1 ring-inset ${TONE_CLASS[tone]}`}>{children}</p>;
}

export function Loading() {
  return <p className="py-10 text-center text-sm text-zinc-500">Loading...</p>;
}

export function Json({ value }: { value: unknown }) {
  if (value === null || value === undefined) return <span className="text-zinc-400">—</span>;
  return (
    <details className="text-xs">
      <summary className="cursor-pointer text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">Show</summary>
      <pre className="mt-2 max-h-80 max-w-xl overflow-auto rounded-lg bg-zinc-50 p-3 text-zinc-700 dark:bg-zinc-950 dark:text-zinc-300">
        {JSON.stringify(value, null, 2)}
      </pre>
    </details>
  );
}

export function Select({ value, onChange, options }: { value: string; onChange: (v: string) => void; options: { value: string; label: string }[] }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-800 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-200"
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

export function SearchBox({ initial, placeholder, onSearch }: { initial: string; placeholder: string; onSearch: (q: string) => void }) {
  const [text, setText] = useState(initial);
  const [seen, setSeen] = useState(initial);
  // Follow the initial value once it is read from the address bar
  if (initial !== seen) {
    setSeen(initial);
    setText(initial);
  }
  function submit(e: FormEvent) {
    e.preventDefault();
    onSearch(text.trim());
  }
  return (
    <form onSubmit={submit} className="flex gap-2">
      <input
        value={text}
        onChange={(e) => setText(e.target.value)}
        placeholder={placeholder}
        className="w-64 max-w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
      />
      <button className="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300">
        Search
      </button>
    </form>
  );
}

// A button that asks "Are you sure?" inline before doing anything.
export function ConfirmButton({
  children,
  confirmText = "Yes, do it",
  onConfirm,
  danger = false,
  disabled = false,
}: {
  children: ReactNode;
  confirmText?: string;
  onConfirm: () => Promise<void>;
  danger?: boolean;
  disabled?: boolean;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const base = "rounded-lg px-3 py-1.5 text-sm font-medium disabled:opacity-50";
  const main = danger
    ? "border border-red-300 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
    : "border border-zinc-300 text-zinc-800 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800";
  if (!asking) {
    return (
      <button disabled={disabled} onClick={() => setAsking(true)} className={`${base} ${main}`}>
        {children}
      </button>
    );
  }
  return (
    <span className="inline-flex gap-2">
      <button
        disabled={busy}
        onClick={async () => {
          setBusy(true);
          try {
            await onConfirm();
          } finally {
            setBusy(false);
            setAsking(false);
          }
        }}
        className={`${base} ${danger ? "bg-red-600 text-white hover:bg-red-700" : "bg-emerald-700 text-white hover:bg-emerald-800"}`}
      >
        {busy ? "Working..." : confirmText}
      </button>
      <button disabled={busy} onClick={() => setAsking(false)} className={`${base} ${main}`}>
        Cancel
      </button>
    </span>
  );
}

export function DefList({ items }: { items: [string, ReactNode][] }) {
  return (
    <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-[11rem_1fr]">
      {items.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-zinc-500">{k}</dt>
          <dd className="min-w-0 break-words text-zinc-900 dark:text-zinc-100">{v}</dd>
        </div>
      ))}
    </dl>
  );
}
