"use client";

import { useState, type FormEvent } from "react";
import { Badge, Card, DefList, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { token as fmt, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Token = "USDC" | "EURC" | "cirBTC";
const TOKENS: Token[] = ["USDC", "EURC", "cirBTC"];
type Withdrawal = {
  id: string;
  status: string;
  token: Token;
  amount: string;
  toAddress: string;
  txUrl: string | null;
  error: string | null;
  codeExpiresAt: string | null;
  createdAt: string;
};
type View = {
  treasuryAddress: string;
  payoutAddress: string | null;
  payoutProblem: string | null;
  payoutUrl: string | null;
  reserveUsdc: number;
  balances: Record<Token, string> | null;
  available: Record<Token, string> | null;
  heldBack: { reserve: string; owed: string } | null;
  balanceError: string | null;
  withdrawals: Withdrawal[];
};

const input =
  "w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 outline-none focus:border-emerald-700 dark:border-zinc-700 dark:bg-zinc-950 dark:text-zinc-100";
const button = "rounded-lg bg-emerald-700 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-800 disabled:opacity-50";

export default function TreasuryPage() {
  const { data, error, reload } = useLoad<View>("/treasury");
  const [token, setToken] = useState<Token>("USDC");
  const [amount, setAmount] = useState("");
  const [pending, setPending] = useState<Withdrawal | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ tone: "good" | "bad" | "wait"; text: string } | null>(null);

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;

  async function start(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMessage(null);
    try {
      const r = await post<{ withdrawal: Withdrawal }>("/treasury/withdraw", { token, amount: amount.trim() });
      setPending(r.withdrawal);
      setCode("");
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "Could not start the withdrawal." });
    } finally {
      setBusy(false);
    }
  }

  async function confirm(e: FormEvent) {
    e.preventDefault();
    if (!pending) return;
    setBusy(true);
    setMessage(null);
    try {
      const r = await post<{ withdrawal: Withdrawal }>(`/treasury/withdraw/${pending.id}/confirm`, { code });
      const w = r.withdrawal;
      setPending(null);
      setAmount("");
      setMessage(
        w.status === "COMPLETE"
          ? { tone: "good", text: `Sent ${fmt(w.amount)} ${w.token} to your payout address.` }
          : w.status === "FAILED"
            ? { tone: "bad", text: `The withdrawal failed: ${w.error ?? "unknown reason"}. Nothing left the treasury.` }
            : { tone: "wait", text: "Sent to Circle. It usually finishes within a minute; refresh this page to see it complete." },
      );
      reload();
    } catch (err) {
      const text = err instanceof Error ? err.message : "Could not confirm.";
      setMessage({ tone: "bad", text });
      if (/start again|Start a new one|Nothing was sent/i.test(text)) setPending(null);
    } finally {
      setBusy(false);
    }
  }

  const free = data.available?.[token];

  return (
    <>
      <PageTitle
        title="Treasury"
        subtitle="Fees and payments collect here. Withdraw what is not needed for refunds, to your payout address only."
        right={
          <button onClick={reload} className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900">
            Refresh
          </button>
        }
      />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Balances">
          {data.balanceError ? <Notice>{data.balanceError}</Notice> : null}
          {data.balances && data.available ? (
            <Table head={["Token", "In the treasury", "Can withdraw"]}>
              {TOKENS.map((t) => (
                <tr key={t}>
                  <Td>{t}</Td>
                  <Td className="tabular-nums">{fmt(data.balances![t])}</Td>
                  <Td className="tabular-nums font-medium">{fmt(data.available![t])}</Td>
                </tr>
              ))}
            </Table>
          ) : null}
          {data.heldBack ? (
            <p className="mt-3 text-xs text-zinc-500">
              Kept back from USDC: the reserve of {fmt(data.heldBack.reserve)} USDC (TREASURY_RESERVE_USDC), {fmt(data.heldBack.owed)} USDC for open orders that may
              still need a refund, and 0.05 USDC for the network fee.
            </p>
          ) : null}
        </Card>

        <Card title="Payout address">
          {data.payoutAddress ? (
            <DefList
              items={[
                ["Sends to", <ExtLink key="p" href={data.payoutUrl}><span className="font-mono text-xs">{data.payoutAddress}</span></ExtLink>],
                ["Network", "Arc"],
              ]}
            />
          ) : (
            <Notice tone="warn">{data.payoutProblem}</Notice>
          )}
          <p className="mt-3 text-xs text-zinc-500">
            Set on Render as TREASURY_PAYOUT_ADDRESS. It cannot be changed here, so nobody who gets into this dashboard can send the treasury anywhere else.
            It must be a wallet that works on Arc (your own dataonchain wallet works: then use To Base to reach an exchange).
          </p>
        </Card>
      </div>

      {data.payoutAddress && data.balances ? (
        <Card title="Withdraw" className="mt-6">
          {!pending ? (
            <form onSubmit={start} className="max-w-md space-y-4">
              <div className="flex gap-2">
                {TOKENS.map((t) => (
                  <button
                    type="button"
                    key={t}
                    onClick={() => {
                      setToken(t);
                      setAmount("");
                    }}
                    className={`rounded-lg border px-3 py-1.5 text-sm font-medium ${
                      token === t
                        ? "border-emerald-700 bg-emerald-50 text-emerald-900 dark:border-emerald-500 dark:bg-emerald-950 dark:text-emerald-200"
                        : "border-zinc-300 text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
                    }`}
                  >
                    {t}
                  </button>
                ))}
              </div>
              <div>
                <div className="flex items-center justify-between">
                  <label htmlFor="amount" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                    Amount of {token}
                  </label>
                  {free && Number(free) > 0 ? (
                    <button type="button" onClick={() => setAmount(free)} className="text-xs font-medium text-emerald-700 hover:underline dark:text-emerald-400">
                      Use all I can ({fmt(free)})
                    </button>
                  ) : null}
                </div>
                <input id="amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" className={`mt-1 ${input}`} />
              </div>
              <button type="submit" disabled={busy || !amount.trim()} className={button}>
                {busy ? "Checking..." : "Continue"}
              </button>
              <p className="text-xs text-zinc-500">Next, we email a code to the admin email. Nothing moves until you enter it.</p>
            </form>
          ) : (
            <form onSubmit={confirm} className="max-w-md space-y-4">
              <p className="text-sm text-zinc-700 dark:text-zinc-300">
                Withdraw <b>{fmt(pending.amount)} {pending.token}</b> to <span className="break-all font-mono text-xs">{pending.toAddress}</span> on Arc.
              </p>
              <div>
                <label htmlFor="code" className="text-sm font-medium text-zinc-700 dark:text-zinc-300">
                  Code from your email
                </label>
                <input
                  id="code"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  maxLength={7}
                  value={code}
                  onChange={(e) => setCode(e.target.value)}
                  placeholder="6 digits"
                  className={`mt-1 tracking-widest ${input}`}
                />
                <p className="mt-1 text-xs text-zinc-500">It expires in 10 minutes.</p>
              </div>
              <div className="flex gap-2">
                <button type="submit" disabled={busy || code.replace(/\s/g, "").length !== 6} className={button}>
                  {busy ? "Sending..." : "Confirm and withdraw"}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => setPending(null)}
                  className="rounded-lg border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
                >
                  Cancel
                </button>
              </div>
            </form>
          )}
          {message ? (
            <div className="mt-4">
              <Notice tone={message.tone}>{message.text}</Notice>
            </div>
          ) : null}
        </Card>
      ) : null}

      <Card title="Past withdrawals" className="mt-6">
        <Table head={["Amount", "To", "Status", "Date"]} empty={data.withdrawals.length === 0}>
          {data.withdrawals.map((w) => (
            <tr key={w.id}>
              <Td>
                <ExtLink href={w.txUrl}>
                  {fmt(w.amount)} {w.token}
                </ExtLink>
              </Td>
              <Td className="font-mono text-xs">{`${w.toAddress.slice(0, 6)}...${w.toAddress.slice(-4)}`}</Td>
              <Td>
                <Badge status={w.status} />
                {w.error && w.status !== "CANCELLED" ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{w.error}</span> : null}
              </Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(w.createdAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
}
