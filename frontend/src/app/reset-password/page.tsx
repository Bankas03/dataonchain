"use client";

import Link from "next/link";
import { useEffect, useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function ResetPasswordPage() {
  const [token, setToken] = useState<string | null>(null);
  const [linkError, setLinkError] = useState(false);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  // The email link lands here with ?token=... (or ?error=INVALID_TOKEN if it expired)
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    setToken(params.get("token"));
    setLinkError(params.has("error"));
    setReady(true);
  }, []);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const newPassword = String(form.get("password"));
    if (newPassword !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    if (!token) return;
    setBusy(true);
    const { error } = await authClient.resetPassword({ newPassword, token });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not set the new password. Ask for a new link and try again.");
      return;
    }
    setDone(true);
  }

  const footer = (
    <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      Back to log in
    </Link>
  );

  if (!ready) {
    return (
      <AuthShell title="Choose a new password" subtitle="Loading..." footer={footer}>
        <span />
      </AuthShell>
    );
  }
  if (done) {
    return (
      <AuthShell title="Password changed" subtitle="You can log in with your new password now." footer={footer}>
        <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
          Your password was changed and you were signed out on every device. Your wallet and balance are unchanged.
        </p>
      </AuthShell>
    );
  }
  if (!token || linkError) {
    return (
      <AuthShell title="This link has expired" subtitle="Reset links work once and expire after one hour." footer={footer}>
        <Link
          href="/forgot-password"
          className="block w-full rounded-lg bg-emerald-700 px-4 py-2.5 text-center font-medium text-white hover:bg-emerald-800"
        >
          Send me a new link
        </Link>
      </AuthShell>
    );
  }
  return (
    <AuthShell title="Choose a new password" subtitle="At least 8 characters." footer={footer}>
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="New password" name="password" type="password" autoComplete="new-password" minLength={8} required autoFocus />
        <Field label="New password again" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
        <FormError message={error} />
        <SubmitButton busy={busy}>Save new password</SubmitButton>
      </form>
    </AuthShell>
  );
}
