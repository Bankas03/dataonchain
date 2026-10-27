"use client";

import { useParams } from "next/navigation";
import { Badge, Card, DefList, ExtLink, Json, Loading, Notice, PageTitle, RowLink, Table, Td } from "@/components/ui";
import { usdc, when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Detail = {
  transfer: {
    id: string;
    direction: string;
    status: string;
    from: string;
    to: string;
    recipientAddress: string;
    depositorAddress: string;
    amount: string;
    maxFee: string | null;
    forwardingFee: string | null;
    failureReason: string | null;
    gatewayTransferId: string | null;
    mintTxHash: string | null;
    mintUrl: string | null;
    userId: string | null;
    email: string | null;
    createdAt: string;
    updatedAt: string;
  };
  events: { step: string; chain: string | null; txHash: string | null; txUrl: string | null; details: unknown; at: string }[];
};

export default function BridgeTransferPage() {
  const { id } = useParams<{ id: string }>();
  const { data, error } = useLoad<Detail>(id ? `/bridge/${id}` : null);
  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;
  const t = data.transfer;

  return (
    <>
      <PageTitle title={`${usdc(t.amount)} USDC, ${t.from} → ${t.to}`} subtitle={t.direction === "IN" ? "Move to Arc" : "Send out"} right={<Badge status={t.status} />} />
      <Card title="Transfer">
        <DefList
          items={[
            ["Customer", t.userId ? <RowLink key="u" href={`/users/${t.userId}`}>{t.email ?? t.userId}</RowLink> : "System test"],
            ["From wallet", <span key="f" className="font-mono text-xs">{t.depositorAddress}</span>],
            ["To address", <span key="t" className="font-mono text-xs">{t.recipientAddress}</span>],
            ["Amount received", `${usdc(t.amount)} USDC`],
            ["Circle fee (max)", t.maxFee ? `${usdc(t.maxFee)} USDC` : "—"],
            ["Forwarding fee", t.forwardingFee ? `${usdc(t.forwardingFee)} USDC` : "—"],
            ["Gateway transfer", <span key="g" className="font-mono text-xs">{t.gatewayTransferId ?? "—"}</span>],
            ["Mint", <ExtLink key="m" href={t.mintUrl}>{t.mintTxHash ?? "Not yet"}</ExtLink>],
            ["Problem", t.failureReason ?? "—"],
            ["Started", when(t.createdAt)],
            ["Last step", when(t.updatedAt)],
            ["Transfer id", <span key="i" className="font-mono text-xs">{t.id}</span>],
          ]}
        />
      </Card>
      <Card title="Every step" className="mt-6">
        <Table head={["When", "Step", "Network", "Transaction", "Details"]} empty={data.events.length === 0}>
          {data.events.map((e, i) => (
            <tr key={i}>
              <Td className="whitespace-nowrap text-zinc-500">{when(e.at)}</Td>
              <Td>{e.step}</Td>
              <Td>{e.chain ?? "—"}</Td>
              <Td>
                <ExtLink href={e.txUrl}>{e.txHash ? `${e.txHash.slice(0, 12)}...` : "—"}</ExtLink>
              </Td>
              <Td>
                <Json value={e.details} />
              </Td>
            </tr>
          ))}
        </Table>
      </Card>
    </>
  );
}
