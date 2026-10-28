"use client";

import { useState, type FormEvent } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { ago, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Pauses = { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean; sendPaused: boolean };
type Settings = {
  pauses: Pauses;
  setup: {
    network: string;
    testnet: boolean;
    vtpass: string;
    pricingMarginPercent: number;
    quoteMinutes: number;
    fixedRate: number | null;
    treasuryAddress: string;
    treasuryUrl: string;
    bridgeEnabled: boolean;
    bridgeLimits: { min: number; max: number; daily: number; maxFee: number };
    bridgeChains: string[];
    swapEnabled: boolean;
    swapFeePercent: number;
    swapSlippagePercent: number;
    swapDailyCount: number;
    alertEmail: boolean;
    worker: boolean;
  };
};
type Session = { id: string; current: boolean; ip: string | null; userAgent: string | null; createdAt: string; lastSeenAt: string };
type Me = { email: string; lastLoginAt: string | null; passwordChangedAt: string | null; sessionExpiresAt: string; idleMinutes: number };

const SWITCHES: { key: keyof Pauses; title: string; text: string }[] = [
  { key: "purchasesPaused", title: "Buying airtime and data", text: "New orders and payments. Orders already paid still deliver or refund." },
  { key: "bridgePaused", title: "Sending to other networks", text: "New bridge transfers and Move to Arc. Transfers already started keep going." },
  { key: "swapPaused", title: "Swaps", text: "New swaps on Arc." },
  { key: "sendPaused", title: "Sending to other wallets", text: "New sends of USDC, EURC and cirBTC to other Arc wallets. Sends already confirmed keep going." },
];

export default function SettingsPage() {
  const settings = useLoad<Settings>("/settings");
  const sessions = useLoad<{ sessions: Session[] }>("/sessions");
  const me = useLoad<Me>("/me");
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [pwMessage, setPwMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  async function flip(key: keyof Pauses, paused: boolean) {
    setMessage(null);
    try {
      await post("/settings/pause", { key, paused });
      setMessage({ tone: "good", text: paused ? "Paused. Users see a short maintenance message." : "Open again." });
      settings.reload();
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not change it." });
    }
  }

  async function changePassword(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setPwMessage(null);
    const formEl = e.currentTarget;
    const form = new FormData(formEl);
    const next = String(form.get("next"));
    if (next !== String(form.get("again"))) {
      setPwMessage({ tone: "bad", text: "The two new passwords are not the same." });
      return;
    }
    setBusy(true);
    try {
      await post("/password", { current: String(form.get("current")), next });
      formEl.reset();
      setPwMessage({ tone: "good", text: "Password changed. Every other session was signed out." });
      sessions.reload();
      me.reload();
    } catch (err) {
      setPwMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not change the password." });
    } finally {
      setBusy(false);
    }
  }

  async function endOthers() {
    await post("/sessions/end-others");
    sessions.reload();
  }

  const s = settings.data;
  const input = "mt-1.5 w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950";

  return (
    <>
      <PageTitle title="Settings" subtitle="Switches, your password and sessions, and how the server is set up." />
      {settings.error ? <Notice>{settings.error}</Notice> : null}

      <Card title="Pause switches" className="mb-6">
        {!s ? (
          <Loading />
        ) : (
          <ul className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {SWITCHES.map((sw) => {
              const paused = s.pauses[sw.key];
              return (
                <li key={sw.key} className="flex flex-wrap items-center justify-between gap-3 py-3">
                  <div>
                    <p className="flex items-center gap-2 text-sm font-medium text-zinc-900 dark:text-zinc-100">
                      {sw.title} {paused ? <Badge tone="bad">Paused</Badge> : <Badge tone="good">Open</Badge>}
                    </p>
                    <p className="text-xs text-zinc-500">{sw.text}</p>
                  </div>
                  <ConfirmButton danger={!paused} confirmText={paused ? "Yes, open" : "Yes, pause"} onConfirm={() => flip(sw.key, !paused)}>
                    {paused ? "Open again" : "Pause"}
                  </ConfirmButton>
                </li>
              );
            })}
          </ul>
        )}
        {message ? <div className="mt-3"><Notice tone={message.tone}>{message.text}</Notice></div> : null}
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Your password">
          {me.data ? (
            <p className="mb-4 text-sm text-zinc-500">
              Logged in as {me.data.email}. Password last changed {me.data.passwordChangedAt ? when(me.data.passwordChangedAt) : "never"}. You are logged out after{" "}
              {me.data.idleMinutes} minutes without activity.
            </p>
          ) : null}
          <form onSubmit={changePassword} className="space-y-3">
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">Current password</span>
              <input name="current" type="password" autoComplete="current-password" required className={input} />
            </label>
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">New password (12 characters or more)</span>
              <input name="next" type="password" autoComplete="new-password" minLength={12} required className={input} />
            </label>
            <label className="block text-sm">
              <span className="font-medium text-zinc-700 dark:text-zinc-300">New password again</span>
              <input name="again" type="password" autoComplete="new-password" minLength={12} required className={input} />
            </label>
            {pwMessage ? <Notice tone={pwMessage.tone}>{pwMessage.text}</Notice> : null}
            <button disabled={busy} className="rounded-lg bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-800 disabled:opacity-60">
              {busy ? "Saving..." : "Change password"}
            </button>
          </form>
        </Card>

        <Card
          title="Signed in sessions"
          right={
            sessions.data && sessions.data.sessions.length > 1 ? (
              <ConfirmButton danger confirmText="Yes, sign them out" onConfirm={endOthers}>
                Sign out the others
              </ConfirmButton>
            ) : null
          }
        >
          {sessions.data ? (
            <Table head={["Browser", "IP", "Last seen"]}>
              {sessions.data.sessions.map((x) => (
                <tr key={x.id}>
                  <Td className="max-w-xs text-xs">
                    {x.current ? <Badge tone="good">This one</Badge> : null} <span className="text-zinc-500">{x.userAgent ?? "unknown"}</span>
                  </Td>
                  <Td className="font-mono text-xs">{x.ip ?? "?"}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{ago(x.lastSeenAt)}</Td>
                </tr>
              ))}
            </Table>
          ) : (
            <Loading />
          )}
        </Card>
      </div>

      {s ? (
        <Card title="Server setup (read only)" className="mt-6">
          <DefList
            items={[
              ["Network", `${s.setup.network}${s.setup.testnet ? " (test network)" : ""}`],
              ["VTpass", s.setup.vtpass],
              ["Price margin", `${s.setup.pricingMarginPercent}% · prices held ${s.setup.quoteMinutes} min${s.setup.fixedRate ? ` · fixed rate ₦${s.setup.fixedRate}` : " · live rate"}`],
              ["Treasury", <ExtLink key="t" href={s.setup.treasuryUrl}><span className="font-mono text-xs">{s.setup.treasuryAddress}</span></ExtLink>],
              [
                "Bridge",
                s.setup.bridgeEnabled
                  ? `On · ${s.setup.bridgeLimits.min} to ${s.setup.bridgeLimits.max} USDC per transfer, ${s.setup.bridgeLimits.daily} per day · fee cap ${s.setup.bridgeLimits.maxFee} · ${s.setup.bridgeChains.join(", ")}`
                  : "Off",
              ],
              ["Swaps", s.setup.swapEnabled ? `On · fee ${s.setup.swapFeePercent}% · slippage ${s.setup.swapSlippagePercent}% · ${s.setup.swapDailyCount} per user per day` : "Off"],
              ["Alert emails", s.setup.alertEmail ? "On (ALERT_EMAIL)" : "Off: set ALERT_EMAIL on Render"],
              ["Background worker", s.setup.worker ? "Running" : "Off"],
            ]}
          />
          <p className="mt-4 text-xs text-zinc-500">These come from Render settings. Change them on Render and choose Save, rebuild, and deploy.</p>
        </Card>
      ) : null}
    </>
  );
}
