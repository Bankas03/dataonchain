"use client";

import Link from "next/link";
import { useEffect, useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function ResetPage() {
  const [token, setToken] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // The token is after "#" in the link, so it never reaches a server log.
  // Take it, then remove it from the address bar.
  useEffect(() => {
    const t = new URLSearchParams(window.location.hash.slice(1)).get("token");
    setToken(t);
    setReady(true);
    if (t) window.history.replaceState(null, "", "/reset");
  }, []);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const form = new FormData(e.currentTarget);
    const password = String(form.get("password"));
    if (password !== String(form.get("again"))) {
      setError("The two passwords are not the same.");
      return;
    }
    setBusy(true);
    try {
      await post("/reset", { token, password });
      setDone(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not set the password.");
    } finally {
      setBusy(false);
    }
  }

  const back = (
    <Link href="/login" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
      Go to login
    </Link>
  );

  if (!ready) return <AuthCard title="Choose a new password">Loading...</AuthCard>;
  if (done) {
    return (
      <AuthCard title="Password saved" footer={back}>
        <Notice tone="good">Your new password is set and every old session was signed out. You can log in now.</Notice>
      </AuthCard>
    );
  }
  if (!token) {
    return (
      <AuthCard title="Link not complete" footer={back}>
        <Notice>
          This page needs the link from the email. Open the email again, or ask for a{" "}
          <Link href="/forgot" className="underline">
            new link
          </Link>
          .
        </Notice>
      </AuthCard>
    );
  }
  return (
    <AuthCard title="Choose a new password" subtitle="At least 12 characters. A short sentence is easy to remember and hard to guess." footer={back}>
      <form onSubmit={onSubmit} className="space-y-4">
        <Input label="New password" name="password" type="password" autoComplete="new-password" minLength={12} required autoFocus />
        <Input label="New password again" name="again" type="password" autoComplete="new-password" minLength={12} required />
        {error ? <Notice>{error}</Notice> : null}
        <Submit busy={busy}>Save password</Submit>
      </form>
    </AuthCard>
  );
}
