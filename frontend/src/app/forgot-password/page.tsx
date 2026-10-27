"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function ForgotPasswordPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const email = String(new FormData(event.currentTarget).get("email")).trim();
    setBusy(true);
    const { error } = await authClient.requestPasswordReset({ email, redirectTo: "/reset-password" });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not send the link. Please try again.");
      return;
    }
    setSentTo(email);
  }

  return (
    <AuthShell
      title="Forgot your password?"
      subtitle="Enter your email and we will send you a link to choose a new password."
      footer={
        <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Back to log in
        </Link>
      }
    >
      {sentTo ? (
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          If {sentTo} has a dataonchain account, a link is on its way. It works once and expires after one hour. Check
          your spam folder too.
        </p>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="Email" name="email" type="email" autoComplete="email" required autoFocus />
          <FormError message={error} />
          <SubmitButton busy={busy}>Email me a link</SubmitButton>
        </form>
      )}
    </AuthShell>
  );
}
