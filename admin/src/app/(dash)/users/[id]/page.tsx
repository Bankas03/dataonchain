"use client";

import { useParams } from "next/navigation";
import { useState, type ReactNode } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { label, naira, short, token, usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  user: { id: string; name: string; email: string; phone: string | null; emailVerified: boolean; status: string; createdAt: string };
  totals: { orders: number; spentUsdc: string; spentNgn: number };
  arcWallet: { address: string; explorerUrl: string; balances: Record<string, string> | null } | null;
  wallets: { address: string; blockchain: string; accountType: string; retiredAt: string | null; createdAt: string }[];
  otherChains: { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null }[];
  orders: { id: string; reference: string; status: string; serviceType: string; network: string; planName: string | null; phone: string; ngnAmount: number; usdcAmount: string; createdAt: string }[];
  bridges: { id: string; status: string; from: string; to: string; amount: string; recipientAddress: string; createdAt: string }[];
  swaps: { id: string; status: string; tokenIn: string; tokenOut: string; amountIn: string; amountOut: string | null; txUrl: string | null; createdAt: string }[];
  sweeps: { id: string; status: string; amount: string; toAddress: string; txUrl: string | null; createdAt: string }[];
  activity: { id: string; actorType: string; action: string; details: unknown; at: string }[];
};

export default function UserPage() {
  const { id } = useParams<{ id: string }>();
  const { data, error, reload } = useLoad<Detail>(id ? `/users/${id}` : null);
  const [reason, setReason] = useState("");
  const [actionError, setActionError] = useState<string | null>(null);

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const { user } = data;

  async function setStatus(status: "active" | "suspended") {
    setActionError(null);
    try {
      await post(`/users/${user.id}/status`, { status, reason });
      setReason("");
      reload();
    } catch (err) {
      setActionError(err instanceof Error ? err.message : "Could not change the status.");
    }
  }

  return (
    <>
      <PageTitle title={user.name} subtitle={user.email} right={<Badge status={user.status} />} />

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Account">
          <DefList
            items={[
              ["Email", <span key="e">{user.email} {user.emailVerified ? <Badge tone="good">Confirmed</Badge> : <Badge tone="warn">Not confirmed</Badge>}</span>],
              ["Phone", user.phone ?? "—"],
              ["Joined", when(user.createdAt)],
              ["Orders", `${data.totals.orders} (delivered: ${usdc(data.totals.spentUsdc)} USDC, ${naira(data.totals.spentNgn)})`],
              ["User id", <span key="i" className="font-mono text-xs">{user.id}</span>],
            ]}
          />
          <div className="mt-5 border-t border-zinc-100 pt-4 dark:border-zinc-800">
            {user.status === "suspended" ? (
              <div className="flex flex-wrap items-center gap-3">
                <p className="text-sm text-zinc-600 dark:text-zinc-400">This user cannot buy, send or swap.</p>
                <ConfirmButton confirmText="Yes, restore" onConfirm={() => setStatus("active")}>
                  Restore user
                </ConfirmButton>
              </div>
            ) : (
              <div className="space-y-2">
                <input
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Reason for suspending (kept in the activity log)"
                  className="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950"
                />
                <ConfirmButton danger confirmText="Yes, suspend" disabled={!reason.trim()} onConfirm={() => setStatus("suspended")}>
                  Suspend user
                </ConfirmButton>
                <p className="text-xs text-zinc-500">Suspending signs the user out. Orders in progress still finish and refunds still go out.</p>
              </div>
            )}
            {actionError ? <div className="mt-3"><Notice>{actionError}</Notice></div> : null}
          </div>
        </Card>

        <Card title="Wallets">
          {data.arcWallet ? (
            <DefList
              items={[
                ["Arc wallet", <ExtLink key="a" href={data.arcWallet.explorerUrl}><span className="font-mono text-xs">{data.arcWallet.address}</span></ExtLink>],
                [
                  "Balances",
                  data.arcWallet.balances
                    ? Object.entries(data.arcWallet.balances).map(([t, v]) => `${t === "cirBTC" ? token(v) : usdc(v)} ${t}`).join(" · ")
                    : "Could not read",
                ],
                ...data.otherChains.map(
                  (c) =>
                    [c.chainLabel, <span key={c.chain}><ExtLink href={c.explorerUrl}>{short(c.address)}</ExtLink> · {c.balance === null ? "?" : `${usdc(c.balance)} USDC`}</span>] as [string, ReactNode],
                ),
              ]}
            />
          ) : (
            <p className="text-sm text-zinc-500">No wallet yet (created on the first dashboard visit after confirming the email).</p>
          )}
          {data.wallets.some((w) => w.retiredAt) ? (
            <p className="mt-4 text-xs text-zinc-500">
              Old wallets: {data.wallets.filter((w) => w.retiredAt).map((w) => `${short(w.address)} (${w.accountType}, retired ${when(w.retiredAt)})`).join(", ")}
            </p>
          ) : null}
        </Card>
      </div>

      <Card title="Orders" className="mt-6">
        <Table head={["Reference", "What", "Phone", "Price", "Status", "Date"]} empty={data.orders.length === 0}>
          {data.orders.map((o) => (
            <tr key={o.id}>
              <Td><RowLink href={`/orders/${o.reference}`}>{o.reference}</RowLink></Td>
              <Td>{o.network.toUpperCase()} {o.serviceType}{o.planName ? <span className="block text-xs text-zinc-500">{o.planName}</span> : null}</Td>
              <Td>{o.phone}</Td>
              <Td className="whitespace-nowrap tabular-nums">{naira(o.ngnAmount)}<span className="block text-xs text-zinc-500">{usdc(o.usdcAmount)} USDC</span></Td>
              <Td><Badge status={o.status} /></Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(o.createdAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card title="Bridge transfers">
          <Table head={["Route", "Amount", "Status", "Date"]} empty={data.bridges.length === 0}>
            {data.bridges.map((b) => (
              <tr key={b.id}>
                <Td><RowLink href={`/bridge/${b.id}`}>{b.from} → {b.to}</RowLink></Td>
                <Td className="tabular-nums">{usdc(b.amount)}</Td>
                <Td><Badge status={b.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(b.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
        <Card title="Swaps">
          <Table head={["Swap", "Status", "Date"]} empty={data.swaps.length === 0}>
            {data.swaps.map((s) => (
              <tr key={s.id}>
                <Td>
                  <ExtLink href={s.txUrl}>{token(s.amountIn)} {s.tokenIn} → {s.amountOut ? token(s.amountOut) : "?"} {s.tokenOut}</ExtLink>
                </Td>
                <Td><Badge status={s.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
      </div>

      {data.sweeps.length ? (
        <Card title="Wallet upgrade sweeps" className="mt-6">
          <Table head={["Amount", "To", "Status", "Date"]}>
            {data.sweeps.map((s) => (
              <tr key={s.id}>
                <Td><ExtLink href={s.txUrl}>{usdc(s.amount)} USDC</ExtLink></Td>
                <Td className="font-mono text-xs">{short(s.toAddress)}</Td>
                <Td><Badge status={s.status} /></Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
              </tr>
            ))}
          </Table>
        </Card>
      ) : null}

      <Card title="Admin actions on this user" className="mt-6">
        <Table head={["When", "Action", "Details"]} empty={data.activity.length === 0}>
          {data.activity.map((a) => (
            <tr key={a.id}>
              <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
              <Td>{label(a.action.replace(/^admin\./, ""))}</Td>
              <Td><Json value={a.details} /></Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
}
