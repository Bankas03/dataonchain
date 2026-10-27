"use client";

import { useState } from "react";
import { Badge, Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, token, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  status: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: string;
  estimatedOut: string | null;
  minOut: string | null;
  amountOut: string | null;
  feePercent: number;
  txUrl: string | null;
  error: string | null;
  userId: string;
  email: string;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; swaps: Row[] };

export default function SwapsPage() {
  const [status, setStatus, ready] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/swaps?status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Swaps" subtitle="USDC, EURC and cirBTC swaps on Arc. Interrupted swaps (Checking) need a look onchain." />
      <Card
        title={data ? `${count(data.total)} swap(s)` : "Swaps"}
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
              { value: "FAILED", label: "Cancelled" },
              { value: "UNKNOWN", label: "Interrupted" },
              { value: "PENDING", label: "Running" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Customer", "Swap", "Expected", "Minimum", "Fee", "Status", "Date"]} empty={data.swaps.length === 0}>
              {data.swaps.map((s) => (
                <tr key={s.id}>
                  <Td>
                    <RowLink href={`/users/${s.userId}`}>{s.email}</RowLink>
                  </Td>
                  <Td>
                    <ExtLink href={s.txUrl}>
                      {token(s.amountIn)} {s.tokenIn} → {s.amountOut ? token(s.amountOut) : "?"} {s.tokenOut}
                    </ExtLink>
                  </Td>
                  <Td className="tabular-nums">{token(s.estimatedOut)}</Td>
                  <Td className="tabular-nums">{token(s.minOut)}</Td>
                  <Td>{s.feePercent}%</Td>
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
