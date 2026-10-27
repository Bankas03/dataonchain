"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, type FormEvent } from "react";
import { AuthCard, Input, Submit } from "@/components/AuthCard";
import { Notice } from "@/components/ui";
import { post } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [step, setStep] = useState<"password" | "code">("password");
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function sendPassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    const typed = String(form.get("email")).trim();
    try {
      await post("/login", { email: typed, password: String(form.get("password")) });
      setEmail(typed);
      setStep("code");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not log you in.");
    } finally {
      setBusy(false);
    }
  }

  async function sendCode(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    try {
      await post("/login/code", { code: String(form.get("code")).trim() });
      router.replace("/");
    } catch (err) {
      setError(err instanceof Error ? err.message : "That code did not work.");
      if (err instanceof Error && /log in again|expired/i.test(err.message)) setStep("password");
      setBusy(false);
    }
  }

  if (step === "code") {
    return (
      <AuthCard title="Check your email" subtitle={`We sent a 6 digit code to ${email}. It expires in 10 minutes.`}>
        <form onSubmit={sendCode} className="space-y-4">
          <Input label="Code" name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9 ]{6,7}" maxLength={7} required autoFocus />
          {error ? <Notice>{error}</Notice> : null}
          <Submit busy={busy}>Log in</Submit>
          <button type="button" onClick={() => setStep("password")} className="w-full text-sm text-zinc-500 hover:underline">
            Start again
          </button>
        </form>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      title="Admin login"
      subtitle="Only the dataonchain admin can log in here."
      footer={
        <Link href="/forgot" className="font-medium text-emerald-700 hover:underline dark:text-emerald-400">
          Forgot password? (or set it for the first time)
        </Link>
      }
    >
      <form onSubmit={sendPassword} className="space-y-4">
        <Input label="Email" name="email" type="email" autoComplete="username" required autoFocus />
        <Input label="Password" name="password" type="password" autoComplete="current-password" required />
        {error ? <Notice>{error}</Notice> : null}
        <Submit busy={busy}>Continue</Submit>
      </form>
    </AuthCard>
  );
}
