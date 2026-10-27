"use client";

import Link from "next/link";
import { useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function SignupPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    const form = new FormData(event.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("confirm"))) {
      setError("The two passwords do not match.");
      return;
    }
    const email = String(form.get("email")).trim();
    setBusy(true);
    const { error } = await authClient.signUp.email({
      name: String(form.get("name")).trim(),
      email,
      phone: String(form.get("phone")).trim(),
      password,
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      setError(error.message ?? "Could not create your account. Please try again.");
      return;
    }
    setSentTo(email);
  }

  async function resend() {
    if (!sentTo) return;
    setBusy(true);
    await authClient.sendVerificationEmail({ email: sentTo, callbackURL: "/dashboard" });
    setBusy(false);
    setResent(true);
  }

  if (sentTo) {
    return (
      <AuthShell
        title="Check your inbox"
        subtitle="One last step to finish setting up your account."
        footer={
          <>
            Already confirmed?{" "}
            <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
              Log in
            </Link>
          </>
        }
      >
        <div className="space-y-4 text-sm text-zinc-700 dark:text-zinc-300">
          <p>
            We sent a confirmation link to <strong className="text-zinc-900 dark:text-zinc-50">{sentTo}</strong>.
            Click it to confirm your email and you will be logged in.
          </p>
          <p className="text-zinc-500">Not there after a minute? Check your spam folder.</p>
          {resent ? (
            <p className="rounded-lg bg-emerald-50 px-3 py-2 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
              We sent a new link.
            </p>
          ) : (
            <button
              type="button"
              onClick={resend}
              disabled={busy}
              className="w-full rounded-lg border border-zinc-300 px-4 py-2.5 font-medium text-zinc-900 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-100 dark:hover:bg-zinc-800"
            >
              {busy ? "Please wait..." : "Send the link again"}
            </button>
          )}
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      title="Create your account"
      subtitle="It takes a minute. No crypto knowledge needed."
      footer={
        <>
          Already have an account?{" "}
          <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Log in
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Full name" name="name" autoComplete="name" required />
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field
          label="Phone number"
          name="phone"
          type="tel"
          autoComplete="tel"
          placeholder="08012345678"
          hint="Nigerian mobile number"
          required
        />
        <Field label="Password" name="password" type="password" autoComplete="new-password" minLength={8} hint="At least 8 characters" required />
        <Field label="Confirm password" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
        <FormError message={error} />
        <p className="text-xs leading-relaxed text-zinc-500">
          By creating an account you agree to our{" "}
          <Link href="/terms" target="_blank" className="underline hover:text-zinc-800 dark:hover:text-zinc-200">Terms of Service</Link> and{" "}
          <Link href="/privacy" target="_blank" className="underline hover:text-zinc-800 dark:hover:text-zinc-200">Privacy Policy</Link>, and
          confirm you are at least 18.
        </p>
        <SubmitButton busy={busy}>Create account</SubmitButton>
      </form>
    </AuthShell>
  );
}
