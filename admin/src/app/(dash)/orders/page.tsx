"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { count, label, naira, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  reference: string;
  status: string;
  userId: string;
  email: string;
  serviceType: string;
  network: string;
  planName: string | null;
  phone: string;
  ngnAmount: number;
  usdcAmount: string;
  failureReason: string | null;
  createdAt: string;
};
type List = { total: number; page: number; pageSize: number; orders: Row[] };

const STATUSES = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED", "FLAGGED", "FAILED", "REFUND_PENDING", "REFUNDED", "QUOTED", "EXPIRED"];

export default function OrdersPage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const path = readyQ && readyS ? `/orders?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null;
  const { data, error } = useLoad<List>(path);

  return (
    <>
      <PageTitle title="Orders" subtitle="Airtime and data purchases. Unpaid prices are hidden unless you pick All." />
      <Card
        title={data ? `${count(data.total)} order(s)` : "Orders"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[
                { value: "", label: "All paid orders" },
                { value: "open", label: "Still in progress" },
                { value: "all", label: "All (including unpaid)" },
                ...STATUSES.map((s) => ({ value: s, label: label(s) })),
              ]}
            />
            <SearchBox
              initial={q}
              placeholder="Reference, phone or email"
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
            <Table head={["Reference", "Customer", "What", "Phone", "Price", "Status", "Date"]} empty={data.orders.length === 0}>
              {data.orders.map((o) => (
                <tr key={o.id}>
                  <Td>
                    <RowLink href={`/orders/${o.reference}`}>{o.reference}</RowLink>
                  </Td>
                  <Td>
                    <RowLink href={`/users/${o.userId}`}>{o.email}</RowLink>
                  </Td>
                  <Td>
                    {o.network.toUpperCase()} {o.serviceType}
                    {o.planName ? <span className="block text-xs text-zinc-500">{o.planName}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap">{o.phone}</Td>
                  <Td className="whitespace-nowrap tabular-nums">
                    {naira(o.ngnAmount)}
                    <span className="block text-xs text-zinc-500">{usdc(o.usdcAmount)} USDC</span>
                  </Td>
                  <Td>
                    <Badge status={o.status} />
                    {o.failureReason ? <span className="mt-1 block max-w-xs text-xs text-zinc-500">{o.failureReason}</span> : null}
                  </Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(o.createdAt)}</Td>
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
