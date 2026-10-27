"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, type FormEvent } from "react";
import { Field, FormError, SubmitButton } from "@/components/AuthShell";
import { SupportLink } from "@/components/SupportLink";
import { authClient } from "@/lib/auth-client";

type Note = { tone: "good" | "bad"; text: string } | null;

function Message({ note }: { note: Note }) {
  if (!note) return null;
  if (note.tone === "bad") return <FormError message={note.text} />;
  return <p className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">{note.text}</p>;
}

const localPhone = (p?: string | null) => (p ? (p.startsWith("+234") ? `0${p.slice(4)}` : p) : "");

export default function AccountPage() {
  const router = useRouter();
  const { data: session, isPending, refetch } = authClient.useSession();
  const [profileNote, setProfileNote] = useState<Note>(null);
  const [passwordNote, setPasswordNote] = useState<Note>(null);
  const [busy, setBusy] = useState<"profile" | "password" | "signout" | null>(null);

  useEffect(() => {
    if (!isPending && !session) router.replace("/login");
  }, [isPending, session, router]);

  if (isPending || !session) {
    return <main className="flex min-h-screen items-center justify-center bg-zinc-50 text-zinc-500 dark:bg-zinc-950">Loading...</main>;
  }
  const { user } = session;

  async function saveProfile(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setProfileNote(null);
    const form = new FormData(e.currentTarget);
    setBusy("profile");
    const { error } = await authClient.updateUser({
      name: String(form.get("name")).trim(),
      phone: String(form.get("phone")).trim(),
    });
    setBusy(null);
    if (error) {
      setProfileNote({ tone: "bad", text: error.message ?? "Could not save your details." });
      return;
    }
    await refetch?.();
    setProfileNote({ tone: "good", text: "Saved." });
  }

  async function changePassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setPasswordNote(null);
    const formEl = e.currentTarget;
    const form = new FormData(formEl);
    const newPassword = String(form.get("new"));
    if (newPassword !== String(form.get("confirm"))) {
      setPasswordNote({ tone: "bad", text: "The two new passwords do not match." });
      return;
    }
    setBusy("password");
    const { error } = await authClient.changePassword({
      currentPassword: String(form.get("current")),
      newPassword,
      revokeOtherSessions: true,
    });
    setBusy(null);
    if (error) {
      setPasswordNote({ tone: "bad", text: error.message ?? "Could not change your password." });
      return;
    }
    formEl.reset();
    setPasswordNote({ tone: "good", text: "Password changed. You were signed out on your other devices." });
  }

  async function signOutEverywhere() {
    setBusy("signout");
    await authClient.revokeSessions();
    await authClient.signOut().catch(() => null);
    router.replace("/login");
  }

  const card = "mt-4 rounded-2xl border border-zinc-200 bg-white p-6 dark:border-zinc-800 dark:bg-zinc-900";

  return (
    <main className="min-h-screen bg-zinc-50 px-4 py-10 dark:bg-zinc-950">
      <div className="mx-auto max-w-xl">
        <header className="flex items-center justify-between">
          <Link href="/dashboard" className="text-lg font-semibold tracking-tight text-emerald-700 dark:text-emerald-400">
            dataonchain
          </Link>
          <Link href="/dashboard" className="text-sm font-medium text-zinc-600 hover:underline dark:text-zinc-400">
            Back to dashboard
          </Link>
        </header>

        <h1 className="mt-8 text-2xl font-semibold text-zinc-900 dark:text-zinc-50">Account settings</h1>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Your details</h2>
          <form onSubmit={saveProfile} className="mt-4 space-y-4">
            <div>
              <p className="text-sm font-medium text-zinc-800 dark:text-zinc-200">Email</p>
              <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{user.email} (cannot be changed)</p>
            </div>
            <Field label="Full name" name="name" defaultValue={user.name} autoComplete="name" required />
            <Field label="Phone number" name="phone" type="tel" defaultValue={localPhone(user.phone)} autoComplete="tel" hint="Nigerian mobile number" required />
            <Message note={profileNote} />
            <SubmitButton busy={busy === "profile"}>Save details</SubmitButton>
          </form>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Change password</h2>
          <form onSubmit={changePassword} className="mt-4 space-y-4">
            <Field label="Current password" name="current" type="password" autoComplete="current-password" required />
            <Field label="New password" name="new" type="password" autoComplete="new-password" minLength={8} hint="At least 8 characters" required />
            <Field label="New password again" name="confirm" type="password" autoComplete="new-password" minLength={8} required />
            <Message note={passwordNote} />
            <SubmitButton busy={busy === "password"}>Change password</SubmitButton>
          </form>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Devices</h2>
          <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            Lost a phone, or logged in on someone else&apos;s computer? Sign out everywhere, including here.
          </p>
          <button
            onClick={signOutEverywhere}
            disabled={busy === "signout"}
            className="mt-4 w-full rounded-lg border border-zinc-300 px-4 py-2.5 text-sm font-medium text-zinc-800 hover:bg-zinc-50 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
          >
            {busy === "signout" ? "Signing out..." : "Sign out on all devices"}
          </button>
        </section>

        <section className={card}>
          <h2 className="text-sm font-medium text-zinc-500">Delete your account</h2>
          <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            Move any USDC, EURC or cirBTC out of your wallets first. Then ask us on WhatsApp and we will close your account
            and delete your personal data, except records the law requires us to keep (see the{" "}
            <Link href="/privacy" className="underline">Privacy Policy</Link>).
          </p>
          <div className="mt-4">
            <SupportLink block message={`Hello dataonchain, please delete my account (${user.email}). I have moved my balance out.`}>
              Ask to delete my account
            </SupportLink>
          </div>
        </section>
      </div>
    </main>
  );
}
