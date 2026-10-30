"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, short, token, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  token: string;
  amount: string;
  toAddress: string;
  network?: string;
  txUrl: string | null;
  error: string | null;
  userId: string;
  email: string;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; sends: Row[] };

export default function SendsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/sends?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle
        title="Sends"
        subtitle="USDC, EURC and cirBTC sent from users' wallets on Arc, and USDC from their Base wallets, to other wallets. Each send is confirmed with an emailed code."
      />
      <Card
        title={data ? `${count(data.total)} send(s)` : "Sends"}
        right={
          <Select
            value={status}
            onChange={(v) => {
              setStatus(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "All" },
              { value: "COMPLETE", label: "Complete" },
              { value: "SENT", label: "Waiting for Circle" },
              { value: "SENDING", label: "Sending" },
              { value: "FAILED", label: "Failed" },
              { value: "CANCELLED", label: "Cancelled" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Customer", "Amount", "To", "Status", "Date"]} empty={data.sends.length === 0}>
              {data.sends.map((s) => (
                <tr key={s.id}>
                  <Td>
                    <RowLink href={`/users/${s.userId}`}>{s.email}</RowLink>
                  </Td>
                  <Td>
                    <ExtLink href={s.txUrl}>
                      {token(s.amount)} {s.token}
                    </ExtLink>
                    {s.network ? <span className="block text-xs text-zinc-500">on {s.network}</span> : null}
                  </Td>
                  <Td className="font-mono text-xs">{short(s.toAddress)}</Td>
                  <Td>
                    <Badge status={s.status} />
                    {s.error ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{s.error}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(s.createdAt)}</Td>
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
