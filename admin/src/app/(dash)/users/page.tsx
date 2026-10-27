"use client";

import { useState } from "react";
import { Badge, Card, Loading, Notice, PageTitle, Pager, RowLink, SearchBox, Select, Table, Td } from "@/components/ui";
import { ago, count, usdc, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  name: string;
  email: string;
  phone: string | null;
  emailVerified: boolean;
  status: string;
  createdAt: string;
  orders: number;
  spentUsdc: string;
  lastOrderAt: string | null;
};
type List = { total: number; page: number; pageSize: number; users: Row[] };

export default function UsersPage() {
  const [q, setQ, readyQ] = useQueryParam("q");
  const [status, setStatus, readyS] = useQueryParam("status");
  const [page, setPage] = useState(1);
  const path = readyQ && readyS ? `/users?q=${encodeURIComponent(q)}&status=${status}&page=${page}` : null;
  const { data, error } = useLoad<List>(path);

  return (
    <>
      <PageTitle title="Users" subtitle="Everyone who signed up. Click a name for wallets, balances and history." />
      <Card
        title={data ? `${count(data.total)} user(s)` : "Users"}
        right={
          <div className="flex flex-wrap gap-2">
            <Select
              value={status}
              onChange={(v) => {
                setStatus(v);
                setPage(1);
              }}
              options={[
                { value: "", label: "Everyone" },
                { value: "active", label: "Active" },
                { value: "suspended", label: "Suspended" },
                { value: "unverified", label: "Email not confirmed" },
              ]}
            />
            <SearchBox
              initial={q}
              placeholder="Name, email or phone"
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
            <Table head={["User", "Phone", "Status", "Orders", "Spent (USDC)", "Last order", "Joined"]} empty={data.users.length === 0}>
              {data.users.map((u) => (
                <tr key={u.id}>
                  <Td>
                    <RowLink href={`/users/${u.id}`}>{u.name}</RowLink>
                    <span className="block text-xs text-zinc-500">{u.email}</span>
                  </Td>
                  <Td className="whitespace-nowrap">{u.phone ?? "—"}</Td>
                  <Td>
                    <span className="flex flex-wrap gap-1">
                      <Badge status={u.status} />
                      {u.emailVerified ? null : <Badge tone="warn">Unconfirmed</Badge>}
                    </span>
                  </Td>
                  <Td className="tabular-nums">{u.orders}</Td>
                  <Td className="tabular-nums">{usdc(u.spentUsdc)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{ago(u.lastOrderAt)}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(u.createdAt)}</Td>
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
