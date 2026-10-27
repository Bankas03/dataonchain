import type { InputHTMLAttributes, ReactNode } from "react";

export function AuthCard({ title, subtitle, children, footer }: { title: string; subtitle?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="w-full max-w-sm">
        <p className="mb-6 text-center text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
          dataonchain <span className="font-normal text-zinc-500">admin</span>
        </p>
        <div className="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-50">{title}</h1>
          {subtitle ? <p className="mt-1 text-sm text-zinc-500">{subtitle}</p> : null}
          <div className="mt-5">{children}</div>
        </div>
        {footer ? <div className="mt-4 text-center text-sm text-zinc-500">{footer}</div> : null}
      </div>
    </main>
  );
}

export function Input(props: InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  const { label, ...rest } = props;
  return (
    <label className="block">
      <span className="text-sm font-medium text-zinc-700 dark:text-zinc-300">{label}</span>
      <input
        {...rest}
        className="mt-1.5 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2.5 text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100"
      />
    </label>
  );
}

export function Submit({ busy, children }: { busy: boolean; children: ReactNode }) {
  return (
    <button
      type="submit"
      disabled={busy}
      className="w-full rounded-lg bg-emerald-700 px-4 py-2.5 font-medium text-white hover:bg-emerald-800 disabled:opacity-60"
    >
      {busy ? "Please wait..." : children}
    </button>
  );
}
