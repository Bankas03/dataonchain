// Circle Gateway API client and burn intent helpers.
// Docs: developers.circle.com/gateway (technical guide, forwarding service,
// ERC-1271 transfers). Amounts are in micro USDC (6 decimals) everywhere.
import { randomBytes } from "node:crypto";
import { env } from "../env";
import type { BridgeChain } from "./chains";

const MAX_UINT256 = ((1n << 256n) - 1n).toString();
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export class GatewayError extends Error {
  constructor(message: string, public status?: number, public body?: string) {
    super(message);
  }
}

export function toBytes32(address: string): `0x${string}` {
  return `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
}

export function microFromDecimal(amount: string): number {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(amount.trim());
  if (!m) throw new Error(`Not a USDC amount: ${amount}`);
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

const json = (value: unknown) => JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v));

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${env.GATEWAY_API_URL}${path}`, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : json(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new GatewayError(`Gateway ${method} ${path} answered ${res.status}: ${text.slice(0, 300)}`, res.status, text);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new GatewayError(`Gateway ${path} sent something that is not JSON: ${text.slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------------------
// Balances and deposits
// ---------------------------------------------------------------------------
// Available (finalized) Gateway balance of a depositor on one chain, in micro USDC
export async function gatewayBalanceMicro(depositor: string, domain: number): Promise<number> {
  const res = await call<{ balances?: { domain: number; depositor: string; balance: string }[] }>("POST", "/v1/balances", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  const row = (res.balances ?? []).find((b) => b.domain === domain);
  return row ? microFromDecimal(row.balance) : 0;
}

// Deposits seen onchain but not final yet
export async function pendingDeposits(depositor: string, domain: number) {
  const res = await call<{ deposits?: { transactionHash: string; amount: string; status: string }[] }>("POST", "/v1/deposits", {
    token: "USDC",
    sources: [{ domain, depositor }],
  });
  return res.deposits ?? [];
}

// ---------------------------------------------------------------------------
// Burn intents
// ---------------------------------------------------------------------------
export type TransferSpec = {
  version: 1;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: `0x${string}`;
  destinationContract: `0x${string}`;
  sourceToken: `0x${string}`;
  destinationToken: `0x${string}`;
  sourceDepositor: `0x${string}`;
  destinationRecipient: `0x${string}`;
  sourceSigner: `0x${string}`;
  destinationCaller: `0x${string}`;
  value: string;
  salt: `0x${string}`;
  hookData: `0x${string}`;
};

export type BurnIntent = { maxBlockHeight: string; maxFee: string; spec: TransferSpec };

export function newSalt(): `0x${string}` {
  return `0x${randomBytes(32).toString("hex")}`;
}

// The depositor wallet both holds the Gateway balance and signs (ERC-1271 for SCA wallets).
export function buildSpec(p: {
  source: BridgeChain;
  destination: BridgeChain;
  depositor: string;
  recipient: string;
  amountMicro: number;
  salt: `0x${string}`;
}): TransferSpec {
  return {
    version: 1,
    sourceDomain: p.source.domain,
    destinationDomain: p.destination.domain,
    sourceContract: toBytes32(p.source.gatewayWallet),
    destinationContract: toBytes32(p.destination.gatewayMinter),
    sourceToken: toBytes32(p.source.usdc),
    destinationToken: toBytes32(p.destination.usdc),
    sourceDepositor: toBytes32(p.depositor),
    destinationRecipient: toBytes32(p.recipient),
    sourceSigner: toBytes32(p.depositor),
    destinationCaller: toBytes32(ZERO_ADDRESS),
    value: String(p.amountMicro),
    salt: p.salt,
    hookData: "0x",
  };
}

export type Estimate = { burnIntent: BurnIntent; maxFeeMicro: number; quotedFeeMicro: number; forwardingFeeMicro: number | null; raw: unknown };

// Circle's forwarding fee follows destination gas prices and can rise in the
// seconds between the estimate and the submission. We allow a margin of 10%
// (at least 0.005 USDC). Circle only takes what it needs; the rest stays in the
// depositor's Gateway balance and is used first next time.
export function withMargin(feeMicro: number): number {
  return feeMicro + Math.max(Math.ceil(feeMicro * 0.1), 5_000);
}

// Asks Gateway for the fee. Forwarding: Circle submits the mint on the destination chain.
export async function estimate(spec: TransferSpec, forward = true): Promise<Estimate> {
  const res = await call<{
    body?: { burnIntent?: { maxFee: string | number; maxBlockHeight: string | number } }[];
    fees?: { forwardingFee?: string; token?: string; total?: string };
  }>("POST", `/v1/estimate?enableForwarder=${forward}`, [{ spec }]);
  const est = res.body?.[0]?.burnIntent;
  if (!est) throw new GatewayError(`Gateway estimate returned no burn intent: ${json(res).slice(0, 300)}`);
  const quoted = Number(est.maxFee);
  const maxFeeMicro = withMargin(quoted);
  return {
    burnIntent: { maxBlockHeight: String(est.maxBlockHeight ?? MAX_UINT256), maxFee: String(maxFeeMicro), spec },
    maxFeeMicro,
    quotedFeeMicro: quoted,
    forwardingFeeMicro: res.fees?.forwardingFee ? microFromDecimal(String(res.fees.forwardingFee)) : null,
    raw: res,
  };
}

// EIP-712 typed data for the burn intent, as Circle's signTypedData expects (a JSON string)
export function typedData(burnIntent: BurnIntent): string {
  return json({
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
      ],
      TransferSpec: [
        { name: "version", type: "uint32" },
        { name: "sourceDomain", type: "uint32" },
        { name: "destinationDomain", type: "uint32" },
        { name: "sourceContract", type: "bytes32" },
        { name: "destinationContract", type: "bytes32" },
        { name: "sourceToken", type: "bytes32" },
        { name: "destinationToken", type: "bytes32" },
        { name: "sourceDepositor", type: "bytes32" },
        { name: "destinationRecipient", type: "bytes32" },
        { name: "sourceSigner", type: "bytes32" },
        { name: "destinationCaller", type: "bytes32" },
        { name: "value", type: "uint256" },
        { name: "salt", type: "bytes32" },
        { name: "hookData", type: "bytes" },
      ],
      BurnIntent: [
        { name: "maxBlockHeight", type: "uint256" },
        { name: "maxFee", type: "uint256" },
        { name: "spec", type: "TransferSpec" },
      ],
    },
    domain: { name: "GatewayWallet", version: "1" },
    primaryType: "BurnIntent",
    message: burnIntent,
  });
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------
export async function submitTransfer(burnIntent: BurnIntent, signature: string, forward = true): Promise<string> {
  const res = await call<{ transferId?: string }>("POST", `/v1/transfer?enableForwarder=${forward}`, [
    // contractSigner: Gateway checks the signature with ERC-1271 on the SCA wallet
    { burnIntent, signature, contractSigner: true },
  ]);
  if (!res.transferId) throw new GatewayError(`Gateway accepted the transfer but sent no transferId: ${json(res).slice(0, 300)}`);
  return res.transferId;
}

export type TransferStatus = {
  status: "pending" | "confirmed" | "finalized" | "failed" | "expired" | string;
  transactionHash?: string; // the mint on the destination chain
  forwardingDetails?: { forwardingEnabled: boolean; failureReason?: string };
  fees?: unknown;
};

export async function getTransfer(transferId: string): Promise<TransferStatus> {
  return call<TransferStatus>("GET", `/v1/transfer/${transferId}`);
}
