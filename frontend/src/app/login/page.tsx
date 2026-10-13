"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { AuthShell, Field, FormError, SubmitButton } from "@/components/AuthShell";
import { authClient } from "@/lib/auth-client";

export default function LoginPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Arriving from an expired or used confirmation link
  useEffect(() => {
    if (new URLSearchParams(window.location.search).get("error") === "link") {
      setNotice("That confirmation link has expired or was already used. Log in and we will send you a new one.");
    }
  }, []);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setNotice(null);
    setBusy(true);
    const form = new FormData(event.currentTarget);
    const email = String(form.get("email")).trim();
    const { error } = await authClient.signIn.email({
      email,
      password: String(form.get("password")),
      callbackURL: "/dashboard",
    });
    setBusy(false);
    if (error) {
      if (error.status === 403) {
        setNotice(`Please confirm your email first. We just sent a new link to ${email}.`);
        return;
      }
      setError(error.message ?? "Could not log you in. Check your email and password.");
      return;
    }
    router.push("/dashboard");
  }

  return (
    <AuthShell
      title="Welcome back"
      subtitle="Log in to buy airtime and data."
      footer={
        <>
          New here?{" "}
          <Link href="/signup" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
            Create an account
          </Link>
        </>
      }
    >
      <form onSubmit={onSubmit} className="space-y-4">
        <Field label="Email" name="email" type="email" autoComplete="email" required />
        <Field label="Password" name="password" type="password" autoComplete="current-password" required />
        {notice ? (
          <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">{notice}</p>
        ) : null}
        <FormError message={error} />
        <SubmitButton busy={busy}>Log in</SubmitButton>
      </form>
    </AuthShell>
  );
}
