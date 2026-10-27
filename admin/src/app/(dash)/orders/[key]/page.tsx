"use client";

import { useParams } from "next/navigation";
import { useState } from "react";
import { Badge, Card, ConfirmButton, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { label, naira, short, usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  order: {
    id: string;
    reference: string;
    status: string;
    serviceType: string;
    network: string;
    planName: string | null;
    phone: string;
    ngnAmount: number;
    marginNgn: number;
    usdcAmount: string;
    rateNgnPerUsdc: number | null;
    rateSource: string | null;
    failureReason: string | null;
    createdAt: string;
    updatedAt: string;
  };
  user: { id: string; name: string; email: string; status: string };
  payments: { id: string; status: string; amount: string; fromAddress: string | null; toAddress: string; txUrl: string | null; txHash: string | null; confirmedAt: string | null; createdAt: string }[];
  deliveries: { id: string; provider: string; requestId: string; providerReference: string | null; status: string; request: unknown; response: unknown; createdAt: string; updatedAt: string }[];
  refund: { status: string; amount: string; toAddress: string; attempt: number; txUrl: string | null; lastError: string | null; confirmedAt: string | null; createdAt: string } | null;
  ledger: { account: string; currency: string; debit: string; credit: string; memo: string | null; createdAt: string }[];
  activity: { id: string; actorType: string; action: string; details: unknown; at: string }[];
  actions: { requery: boolean; retryRefund: boolean; failAndRefund: boolean };
};

export default function OrderPage() {
  const { key } = useParams<{ key: string }>();
  const { data, error, reload } = useLoad<Detail>(key ? `/orders/${key}` : null);
  const [message, setMessage] = useState<{ tone: "good" | "bad"; text: string } | null>(null);
  const [checked, setChecked] = useState("");

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const { order } = data;

  async function act(path: string, what: string, data: unknown = {}) {
    setMessage(null);
    try {
      const r = await post<{ before: string; after: string }>(path, data);
      setMessage({ tone: "good", text: `${what}: ${label(r.before)} → ${label(r.after)}` });
      reload();
    } catch (err) {
      setMessage({ tone: "bad", text: err instanceof Error ? err.message : "That did not work." });
    }
  }

  return (
    <>
      <PageTitle
        title={`Order ${order.reference}`}
        subtitle={`${order.network.toUpperCase()} ${order.serviceType}${order.planName ? `, ${order.planName}` : ""} to ${order.phone}`}
        right={<Badge status={order.status} />}
      />

      {data.actions.requery || data.actions.retryRefund || data.actions.failAndRefund || message ? (
        <Card title="Actions" className="mb-6">
          <div className="flex flex-wrap items-center gap-3">
            {data.actions.requery ? (
              <ConfirmButton confirmText="Ask VTpass now" onConfirm={() => act(`/orders/${order.reference}/recheck`, "Checked with VTpass")}>
                Check with VTpass now
              </ConfirmButton>
            ) : null}
            {data.actions.retryRefund ? (
              <ConfirmButton confirmText="Yes, refund" onConfirm={() => act(`/orders/${order.reference}/refund`, "Refund")}>
                {order.status === "FLAGGED" ? "Retry the failed refund" : "Push the refund now"}
              </ConfirmButton>
            ) : null}
          </div>
          {data.actions.failAndRefund ? (
            <div className="mt-4 space-y-2 border-t border-zinc-100 pt-4 dark:border-zinc-800">
              <p className="text-sm text-zinc-700 dark:text-zinc-300">
                VTpass never gave a clear answer for this order. First check the VTpass dashboard for request id{" "}
                <span className="font-mono text-xs">{data.deliveries[0]?.requestId ?? "?"}</span>. Only if it did not go through:
              </p>
              <input
                value={checked}
                onChange={(e) => setChecked(e.target.value)}
                placeholder="What you checked (kept in the history)"
                className="w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-950"
              />
              <ConfirmButton
                danger
                disabled={!checked.trim()}
                confirmText="Yes, fail and refund"
                onConfirm={() => act(`/orders/${order.reference}/fail-refund`, "Closed and refunded", { reason: checked })}
              >
                Mark failed and refund
              </ConfirmButton>
              <p className="text-xs text-zinc-500">VTpass is asked one last time first. If it answers, the order follows that answer instead.</p>
            </div>
          ) : null}
          <p className="mt-3 text-xs text-zinc-500">
            The background worker does these automatically; use them to check now. A delivery is never sent twice, and a refund can never be paid twice.
          </p>
          {message ? <div className="mt-3"><Notice tone={message.tone}>{message.text}</Notice></div> : null}
        </Card>
      ) : null}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="Order">
          <DefList
            items={[
              ["Customer", <RowLink key="u" href={`/users/${data.user.id}`}>{data.user.name} ({data.user.email})</RowLink>],
              ["Price", `${naira(order.ngnAmount)} = ${usdc(order.usdcAmount)} USDC`],
              ["Our margin", naira(order.marginNgn)],
              ["Rate", order.rateNgnPerUsdc ? `${naira(order.rateNgnPerUsdc)} per USDC (${order.rateSource ?? "?"})` : "—"],
              ["Created", when(order.createdAt)],
              ["Last change", when(order.updatedAt)],
              ["Note to customer", order.failureReason ?? "—"],
              ["Order id", <span key="i" className="font-mono text-xs">{order.id}</span>],
            ]}
          />
        </Card>
        <Card title="Refund">
          {data.refund ? (
            <DefList
              items={[
                ["Status", <Badge key="s" status={data.refund.status} />],
                ["Amount", `${usdc(data.refund.amount)} USDC`],
                ["To", <span key="t" className="font-mono text-xs">{data.refund.toAddress}</span>],
                ["Attempt", String(data.refund.attempt)],
                ["Transaction", <ExtLink key="x" href={data.refund.txUrl}>{data.refund.txUrl ? "View on explorer" : "Not sent yet"}</ExtLink>],
                ["Last error", data.refund.lastError ?? "—"],
                ["Started", when(data.refund.createdAt)],
                ["Confirmed", when(data.refund.confirmedAt)],
              ]}
            />
          ) : (
            <p className="text-sm text-zinc-500">No refund for this order.</p>
          )}
        </Card>
      </div>

      <Card title="Payment on Arc" className="mt-6">
        <Table head={["Status", "Amount", "From", "Transaction", "Confirmed"]} empty={data.payments.length === 0}>
          {data.payments.map((p) => (
            <tr key={p.id}>
              <Td><Badge status={p.status} /></Td>
              <Td className="tabular-nums">{usdc(p.amount)} USDC</Td>
              <Td className="font-mono text-xs">{short(p.fromAddress)}</Td>
              <Td><ExtLink href={p.txUrl}>{short(p.txHash, 10)}</ExtLink></Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(p.confirmedAt)}</Td>
            </tr>
          ))}
        </Table>
      </Card>

      <Card title="Delivery (VTpass)" className="mt-6">
        <Table head={["Status", "Request id", "VTpass ref", "Sent", "Last update", "Request", "Answer"]} empty={data.deliveries.length === 0}>
          {data.deliveries.map((d) => (
            <tr key={d.id}>
              <Td><Badge status={d.status} /></Td>
              <Td className="font-mono text-xs">{d.requestId}</Td>
              <Td className="font-mono text-xs">{d.providerReference ?? "—"}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.createdAt)}</Td>
              <Td className="whitespace-nowrap text-zinc-500">{when(d.updatedAt)}</Td>
              <Td><Json value={d.request} /></Td>
              <Td><Json value={d.response} /></Td>
            </tr>
          ))}
        </Table>
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card title="Ledger">
          <Table head={["Account", "Debit", "Credit", "Memo"]} empty={data.ledger.length === 0}>
            {data.ledger.map((l, i) => (
              <tr key={i}>
                <Td className="font-mono text-xs">{l.account}</Td>
                <Td className="tabular-nums">{l.debit !== "0.000000" && l.debit !== "0" ? `${l.debit} ${l.currency}` : ""}</Td>
                <Td className="tabular-nums">{l.credit !== "0.000000" && l.credit !== "0" ? `${l.credit} ${l.currency}` : ""}</Td>
                <Td className="text-zinc-500">{l.memo ?? ""}</Td>
              </tr>
            ))}
          </Table>
        </Card>
        <Card title="History">
          <Table head={["When", "Who", "What", "Details"]} empty={data.activity.length === 0}>
            {data.activity.map((a) => (
              <tr key={a.id}>
                <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
                <Td>{a.actorType}</Td>
                <Td>{a.action}</Td>
                <Td><Json value={a.details} /></Td>
              </tr>
            ))}
          </Table>
        </Card>
      </div>
    </>
  );
}
