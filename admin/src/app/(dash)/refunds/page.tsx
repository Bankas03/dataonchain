"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  amount: string;
  attempt: number;
  lastError: string | null;
  txUrl: string | null;
  reference: string;
  orderStatus: string;
  email: string;
  userId: string;
  createdAt: string;
  confirmedAt: string | null;
};
type List = { total: number; page: number; pageSize: number; refunds: Row[] };

export default function RefundsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/refunds?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle
        title="Refunds"
        subtitle="USDC sent back from the treasury when a paid order could not be delivered. Failed refunds can be retried from the order page."
      />
      <Card
        title={data ? `${count(data.total)} refund(s)` : "Refunds"}
        right={
          <Select
            value={status}
            onChange={(v) => {
              setStatus(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "All" },
              { value: "PENDING", label: "Waiting to send" },
              { value: "SENT", label: "Sent, confirming" },
              { value: "CONFIRMED", label: "Confirmed" },
              { value: "FAILED", label: "Failed (needs retry)" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Order", "Customer", "Amount", "Status", "Attempt", "Note", "Started", "Confirmed"]} empty={data.refunds.length === 0}>
              {data.refunds.map((r) => (
                <tr key={r.id}>
                  <Td>
                    <RowLink href={`/orders/${r.reference}`}>{r.reference}</RowLink>
                  </Td>
                  <Td>
                    <RowLink href={`/users/${r.userId}`}>{r.email}</RowLink>
                  </Td>
                  <Td className="tabular-nums">
                    <ExtLink href={r.txUrl}>{usdc(r.amount)} USDC</ExtLink>
                  </Td>
                  <Td>
                    <Badge status={r.status} />
                  </Td>
                  <Td className="tabular-nums">{r.attempt}</Td>
                  <Td className="max-w-xs text-xs text-zinc-500">{r.lastError ?? ""}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(r.createdAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(r.confirmedAt)}</Td>
                </tr>
              ))}
            </Table>
            <Pager page={data.page} pageSize={data.pageSize} total={data.total} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </>
  );
}
