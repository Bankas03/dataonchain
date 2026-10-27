"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function ForgotPage() {
  const [sent, setSent] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    try {
      const r = await post<{ message: string }>("/forgot", { email: String(form.get("email")).trim() });
      setSent(r.message);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not send the link.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <AuthCard
      title="Reset your password"
      subtitle="Enter the admin email. We will email a link to choose a new password. This also unlocks a locked login."
      footer={
        <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Back to login
        </Link>
      }
    >
      {sent ? (
        <Notice tone="good">{sent}</Notice>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <Input label="Email" name="email" type="email" autoComplete="username" required autoFocus />
          {error ? <Notice>{error}</Notice> : null}
          <Submit busy={busy}>Email me a link</Submit>
        </form>
      )}
    </AuthCard>
  );
}
