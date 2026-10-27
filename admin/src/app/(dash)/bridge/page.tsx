"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { count, label, short, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  direction: string;
  status: string;
  from: string;
  to: string;
  recipientAddress: string;
  amount: string;
  maxFee: string | null;
  failureReason: string | null;
  userId: string | null;
  email: string | null;
  createdAt: string;
  updatedAt: string;
};
type List = { total: number; page: number; pageSize: number; transfers: Row[] };

const STATUSES = ["QUOTED", "DEPOSITING", "DEPOSITED", "FINALIZED", "INTENT_SIGNED", "SUBMITTED", "MINTED", "COMPLETE", "EXPIRED", "FAILED"];

export default function BridgePage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(readyQ && readyS ? `/bridge?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Bridge transfers" subtitle="USDC moved between Arc and other networks through Circle Gateway, every step recorded from deposit to mint." />
      <Card
        title={data ? `${count(data.total)} transfer(s)` : "Transfers"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[{ value: "", label: "All" }, { value: "open", label: "Still moving" }, ...STATUSES.map((s) => ({ value: s, label: label(s) }))]}
            />
            <SearchBox
              initial={q}
              placeholder="Email, address or id"
              onSearch={(v) => {
                setQ(v);
                setPage(1);
              }}
            />
          </div>
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Route", "Customer", "Amount", "To address", "Status", "Started", "Last step"]} empty={data.transfers.length === 0}>
              {data.transfers.map((t) => (
                <tr key={t.id}>
                  <Td>
                    <RowLink href={`/bridge/${t.id}`}>
                      {t.from} → {t.to}
                    </RowLink>
                    <span className="block text-xs text-zinc-500">{t.direction === "IN" ? "Move to Arc" : "Send out"}</span>
                  </Td>
                  <Td>{t.userId ? <RowLink href={`/users/${t.userId}`}>{t.email ?? t.userId}</RowLink> : <span className="text-zinc-500">System test</span>}</Td>
                  <Td className="tabular-nums">{usdc(t.amount)}</Td>
                  <Td className="font-mono text-xs">{short(t.recipientAddress)}</Td>
                  <Td>
                    <Badge status={t.status} />
                    {t.failureReason ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{t.failureReason}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(t.createdAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(t.updatedAt)}</Td>
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
