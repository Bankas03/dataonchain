"use client";

import { useState } from "react";
import { Badge, Card, ConfirmButton, ExtLink, Loading, Notice, PageTitle, Table, Td } from "@/components/ui";
import { post } from "@/lib/api";
import { when } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Provider = { id: string; label: string; chain: string; address: string; explorerUrl: string | null; active: boolean; note: string | null; createdAt: string };

export default function ProvidersPage() {
  const { data, error, reload } = useLoad<{ providers: Provider[] }>("/providers");
  const [message, setMessage] = useState<string | null>(null);

  async function toggle(p: Provider) {
    setMessage(null);
    try {
      await post(`/providers/${p.id}`, { active: !p.active });
      reload();
    } catch (err) {
      setMessage(err instanceof Error ? err.message : "Could not change it.");
    }
  }

  return (
    <>
      <PageTitle
        title="Providers"
        subtitle="Approved addresses users can send USDC to on other networks. Nothing else can receive bridged USDC."
      />
      <Card title="Approved addresses">
        {error ? <Notice>{error}</Notice> : null}
        {message ? <Notice>{message}</Notice> : null}
        {!data && !error ? <Loading /> : null}
        {data ? (
          <Table head={["Name", "Network", "Address", "Status", "Added", ""]} empty={data.providers.length === 0}>
            {data.providers.map((p) => (
              <tr key={p.id}>
                <Td>
                  {p.label}
                  {p.note ? <span className="block text-xs text-zinc-500">{p.note}</span> : null}
                </Td>
                <Td>{p.chain}</Td>
                <Td>
                  <ExtLink href={p.explorerUrl}>
                    <span className="font-mono text-xs">{p.address}</span>
                  </ExtLink>
                </Td>
                <Td>{p.active ? <Badge tone="good">On</Badge> : <Badge tone="plain">Off</Badge>}</Td>
                <Td className="whitespace-nowrap text-zinc-500">{when(p.createdAt)}</Td>
                <Td>
                  <ConfirmButton danger={p.active} confirmText={p.active ? "Yes, turn off" : "Yes, turn on"} onConfirm={() => toggle(p)}>
                    {p.active ? "Turn off" : "Turn on"}
                  </ConfirmButton>
                </Td>
              </tr>
            ))}
          </Table>
        ) : null}
        <p className="mt-4 text-xs text-zinc-500">
          To add a new provider address, run <span className="font-mono">bash setup/destinations.sh prod add</span> on your computer. Adding
          addresses stays outside the dashboard on purpose, so a stolen admin login cannot send USDC to a new address.
        </p>
      </Card>
    </>
  );
}
