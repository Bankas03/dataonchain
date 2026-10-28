"use client";

import Link from "next/link";
import { Badge, Card, Loading, Notice, PageTitle, Stat } from "@/components/ui";
import { ago, count, label, naira, token, usdc } from "@/lib/format";
import { useLoad } from "@/lib/use-load";

type Window = { all: number; d1: number; d7: number; d30: number };
type Overview = {
  generatedAt: string;
  testnet: boolean;
  vtpassSandbox: boolean;
  pauses: { purchasesPaused: boolean; bridgePaused: boolean; swapPaused: boolean; sendPaused?: boolean };
  users: { total: number; verified: number; suspended: number; new1: number; new7: number; new30: number };
  volume: {
    orders: Window;
    usdc: { all: string; d1: string; d7: string; d30: string };
    ngn: Window;
    marginNgn: { all: number; d30: number };
  };
  ordersByStatus: Record<string, number>;
  refunds: Record<string, { count: number; usdc: string }>;
  bridge: { enabled: boolean; complete: number; usdc: string; complete30: number; usdc30: string; open: number; stuck: number };
  swaps: { enabled: boolean; complete: number; complete30: number; volume30: Record<string, number>; fees30: Record<string, number>; unknown: number };
  balances: { treasuryAddress: string; treasuryUrl: string; treasury: Record<string, string> | null; vtpassNgn: number | null };
  days: { day: string; orders: number; usdc: string; ngn: number; newUsers: number }[];
  issues: { text: string; href: string }[];
};

const STATUS_ORDER = ["PAYMENT_PENDING", "PAYMENT_CONFIRMED", "FULFILMENT_PENDING", "FULFILLED", "FLAGGED", "FAILED", "REFUND_PENDING", "REFUNDED", "QUOTED", "EXPIRED"];

export default function OverviewPage() {
  const { data, error, loading, reload } = useLoad<Overview>("/overview");

  if (error && !data) return <Notice>{error}</Notice>;
  if (!data) return <Loading />;

  const paused = [
    data.pauses.purchasesPaused ? "Purchases" : null,
    data.pauses.bridgePaused ? "Bridge" : null,
    data.pauses.swapPaused ? "Swaps" : null,
    data.pauses.sendPaused ? "Sends" : null,
  ].filter(Boolean);
  const maxUsdc = Math.max(1, ...data.days.map((d) => Number(d.usdc)));
  const refundsDone = data.refunds.CONFIRMED;

  return (
    <>
      <PageTitle
        title="Overview"
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            {data.testnet ? <Badge tone="warn">Arc Testnet</Badge> : <Badge tone="good">Mainnet</Badge>}
            {data.vtpassSandbox ? <Badge tone="warn">VTpass sandbox</Badge> : <Badge tone="good">VTpass live</Badge>}
            {paused.length ? <Badge tone="bad">Paused: {paused.join(", ")}</Badge> : null}
            <span>Updated {ago(data.generatedAt)}</span>
          </span>
        }
        right={
          <button
            onClick={reload}
            disabled={loading}
            className="rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-white disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
          >
            {loading ? "Refreshing..." : "Refresh"}
          </button>
        }
      />

      {data.issues.length ? (
        <Card title="Needs attention" className="mb-6 border-amber-300 dark:border-amber-800">
          <ul className="space-y-2 text-sm">
            {data.issues.map((i) => (
              <li key={i.text} className="flex items-start gap-2">
                <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-amber-500" />
                <Link href={i.href} className="text-zinc-800 hover:underline dark:text-zinc-200">
                  {i.text}
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      ) : (
        <div className="mb-6">
          <Notice tone="good">All clear: no flagged orders, failed refunds, stuck transfers or low balances.</Notice>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Users" value={count(data.users.total)} hint={`${count(data.users.new7)} new this week · ${count(data.users.verified)} confirmed`} href="/users" />
        <Stat
          label="Orders delivered"
          value={count(data.volume.orders.d30)}
          hint={`Last 30 days · today ${count(data.volume.orders.d1)} · all time ${count(data.volume.orders.all)}`}
          href="/orders?status=FULFILLED"
        />
        <Stat label="Volume (USDC)" value={usdc(data.volume.usdc.d30)} hint={`Last 30 days · 7 days ${usdc(data.volume.usdc.d7)} · all ${usdc(data.volume.usdc.all)}`} />
        <Stat label="Volume (naira)" value={naira(data.volume.ngn.d30)} hint={`Last 30 days · all ${naira(data.volume.ngn.all)}`} />
        <Stat label="Margin earned" value={naira(data.volume.marginNgn.d30)} hint={`Last 30 days · all ${naira(data.volume.marginNgn.all)}`} />
        <Stat
          label="Refunds"
          value={count(refundsDone?.count ?? 0)}
          hint={`${usdc(refundsDone?.usdc ?? 0)} USDC returned · ${count(data.ordersByStatus.REFUND_PENDING ?? 0)} in progress`}
          href="/refunds"
        />
        <Stat
          label="Bridge transfers"
          value={data.bridge.enabled ? count(data.bridge.complete30) : "Off"}
          hint={data.bridge.enabled ? `${usdc(data.bridge.usdc30)} USDC in 30 days · ${data.bridge.open} open · ${data.bridge.stuck} stuck` : "BRIDGE_ENABLED is off"}
          href="/bridge"
        />
        <Stat
          label="Swaps"
          value={data.swaps.enabled ? count(data.swaps.complete30) : "Off"}
          hint={
            data.swaps.enabled
              ? `Last 30 days · fees ${Object.entries(data.swaps.fees30).map(([t, v]) => `${token(v)} ${t}`).join(", ") || "none yet"}`
              : "SWAP_ENABLED is off"
          }
          href="/swaps"
        />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <Card title="Volume, last 14 days (USDC, delivered orders)" className="lg:col-span-2">
          <div className="flex h-44 items-end gap-1.5">
            {data.days.map((d) => (
              <div key={d.day} className="group relative flex h-full flex-1 flex-col justify-end">
                <div
                  className="rounded-t bg-emerald-600/80 group-hover:bg-emerald-700 dark:bg-emerald-500/70"
                  style={{ height: `${Math.max(Number(d.usdc) > 0 ? 3 : 0, (Number(d.usdc) / maxUsdc) * 100)}%` }}
                />
                <div className="pointer-events-none absolute bottom-full left-1/2 z-10 mb-1 hidden -translate-x-1/2 whitespace-nowrap rounded bg-zinc-900 px-2 py-1 text-xs text-white group-hover:block">
                  {d.day}: {d.orders} orders · {usdc(d.usdc)} USDC · {naira(d.ngn)} · {d.newUsers} new users
                </div>
              </div>
            ))}
          </div>
          <div className="mt-2 flex justify-between text-xs text-zinc-500">
            <span>{data.days[0]?.day}</span>
            <span>today</span>
          </div>
        </Card>

        <Card title="Balances">
          <dl className="space-y-3 text-sm">
            <div>
              <dt className="text-zinc-500">
                Treasury on Arc{" "}
                <a href={data.balances.treasuryUrl} target="_blank" rel="noreferrer noopener" className="text-emerald-700 hover:underline dark:text-emerald-400">
                  (view)
                </a>
              </dt>
              <dd className="mt-1 font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
                {data.balances.treasury
                  ? Object.entries(data.balances.treasury)
                      .map(([t, v]) => `${t === "USDC" || t === "EURC" ? usdc(v) : token(v)} ${t}`)
                      .join(" · ")
                  : "Could not read"}
              </dd>
            </div>
            <div>
              <dt className="text-zinc-500">VTpass wallet</dt>
              <dd className="mt-1 font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
                {data.balances.vtpassNgn === null ? "Could not read" : naira(data.balances.vtpassNgn)}
              </dd>
            </div>
          </dl>
        </Card>
      </div>

      <Card title="Orders by status" className="mt-6">
        <div className="flex flex-wrap gap-2">
          {STATUS_ORDER.filter((s) => data.ordersByStatus[s]).map((s) => (
            <Link
              key={s}
              href={`/orders?status=${s}`}
              className="flex items-center gap-2 rounded-lg border border-zinc-200 px-3 py-2 text-sm hover:border-zinc-300 dark:border-zinc-800 dark:hover:border-zinc-700"
            >
              <Badge status={s} />
              <span className="font-semibold tabular-nums text-zinc-900 dark:text-zinc-100">{count(data.ordersByStatus[s])}</span>
            </Link>
          ))}
          {Object.keys(data.ordersByStatus).length === 0 ? <p className="text-sm text-zinc-500">No orders yet.</p> : null}
        </div>
        <p className="mt-3 text-xs text-zinc-500">{label("QUOTED")} and expired orders are prices that were never paid.</p>
      </Card>
    </>
  );
}
