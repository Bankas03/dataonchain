"use client";

import { useState } from "react";
import { Badge, Card, Json, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = { id: string; actorType: string; action: string; targetType: string | null; targetId: string | null; details: unknown; at: string };
type List = { total: number; page: number; pageSize: number; activity: Row[] };

function target(r: Row) {
  if (!r.targetId) return <span className="text-zinc-400">—</span>;
  if (r.targetType === "order") return <RowLink href={`/orders/${r.targetId}`}>order</RowLink>;
  if (r.targetType === "user") return <RowLink href={`/users/${r.targetId}`}>user</RowLink>;
  if (r.targetType === "bridge_transfer") return <RowLink href={`/bridge/${r.targetId}`}>transfer</RowLink>;
  return <span className="text-zinc-500">{r.targetType}</span>;
}

export default function ActivityPage() {
  const [actor, setActor, ready] = useQueryParam("actor");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/activity?actor=${actor}&page=${page}` : null);

  return (
    <>
      <PageTitle title="Activity" subtitle="Everything the admin and the system did: logins, refunds, alerts, switches, suspensions." />
      <Card
        title={data ? `${count(data.total)} event(s)` : "Activity"}
        right={
          <Select
            value={actor}
            onChange={(v) => {
              setActor(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "Everything" },
              { value: "admin", label: "Admin only" },
              { value: "system", label: "System only" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["When", "Who", "What", "On", "Details"]} empty={data.activity.length === 0}>
              {data.activity.map((a) => (
                <tr key={a.id}>
                  <Td className="whitespace-nowrap text-zinc-500">{when(a.at)}</Td>
                  <Td>
                    <Badge tone={a.actorType === "admin" ? "wait" : "plain"}>{a.actorType}</Badge>
                  </Td>
                  <Td className="font-mono text-xs">{a.action}</Td>
                  <Td>{target(a)}</Td>
                  <Td>
                    <Json value={a.details} />
                  </Td>
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
