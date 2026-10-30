"use client";

import { useState } from "react";
import { Card, ExtLink, Loading, Notice, PageTitle, Pager, RowLink, Select, Table, Td } from "@/components/ui";
import { count, short, token, when } from "@/lib/format";
import { useLoad, useQueryParam } from "@/lib/use-load";

type Row = {
  id: string;
  userId: string;
  email: string;
  token: string;
  amount: string;
  network: string;
  fromAddress: string | null;
  txUrl: string | null;
  emailed: boolean;
  receivedAt: string;
};
type List = { total: number; page: number; pageSize: number; deposits: Row[] };

export default function DepositsPage() {
  const [network, setNetwork, ready] = useQueryParam("network");
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<List>(ready ? `/deposits?network=${network}&page=${page}` : null);

  return (
    <>
      <PageTitle
        title="Deposits"
        subtitle="USDC, EURC and cirBTC that arrived in users' wallets from outside dataonchain (exchanges, other wallets, other users), on Arc and Base."
      />
      <Card
        title={data ? `${count(data.total)} deposit(s)` : "Deposits"}
        right={
          <Select
            value={network}
            onChange={(v) => {
              setNetwork(v);
              setPage(1);
            }}
            options={[
              { value: "", label: "All networks" },
              { value: "arc", label: "Arc" },
              { value: "base", label: "Base" },
            ]}
          />
        }
      >
        {error ? <Notice>{error}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <>
            <Table head={["Customer", "Amount", "Network", "From", "Email", "Date"]} empty={data.deposits.length === 0}>
              {data.deposits.map((d) => (
                <tr key={d.id}>
                  <Td>
                    <RowLink href={`/users/${d.userId}`}>{d.email}</RowLink>
                  </Td>
                  <Td>
                    <ExtLink href={d.txUrl}>
                      {token(d.amount)} {d.token}
                    </ExtLink>
                  </Td>
                  <Td>{d.network}</Td>
                  <Td className="font-mono text-xs">{short(d.fromAddress)}</Td>
                  <Td>{d.emailed ? "Sent" : "Not yet"}</Td>
                  <Td className="whitespace-nowrap text-zinc-500">{when(d.receivedAt)}</Td>
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
