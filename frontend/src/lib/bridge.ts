// Shared bridge types and labels for the website.
export type Destination = { id: string; label: string; chain: string; chainLabel: string; address: string | null; own: boolean };

export type ChainWallet = { chain: string; chainLabel: string; address: string; explorerUrl: string; balance: string | null };

export type BridgeQuote = {
  destination: { id: string; label: string; chainLabel: string; address: string };
  amount: string;
  fee: string;
  total: string;
  receives: string;
  available: string;
  allowed: boolean;
  note: string;
};

export type BridgeStep = { step: string; chainLabel: string | null; txHash: string | null; url: string | null; at: string };

export type BridgeView = {
  id: string;
  direction: "OUT" | "IN";
  status: string;
  slowFinality: boolean;
  destinationLabel: string;
  sourceLabel: string;
  destinationChainLabel: string;
  recipientAddress: string;
  amount: string;
  maxFee: string | null;
  mintTxHash: string | null;
  mintUrl: string | null;
  failureReason: string | null;
  createdAt: string;
  steps: BridgeStep[];
};

export const BRIDGE_DONE = ["COMPLETE", "FAILED"];

export const BRIDGE_LABELS: Record<string, { text: string; tone: "wait" | "good" | "bad" }> = {
  QUOTED: { text: "Starting", tone: "wait" },
  DEPOSITING: { text: "Moving into Gateway", tone: "wait" },
  DEPOSITED: { text: "Waiting for confirmation", tone: "wait" },
  FINALIZED: { text: "Ready to send", tone: "wait" },
  INTENT_SIGNED: { text: "Signed", tone: "wait" },
  SUBMITTED: { text: "Sending", tone: "wait" },
  MINTED: { text: "Arrived", tone: "good" },
  COMPLETE: { text: "Complete", tone: "good" },
  EXPIRED: { text: "Retrying", tone: "wait" },
  FAILED: { text: "Failed", tone: "bad" },
};

export const STEP_LABELS: Record<string, string> = {
  quoted: "Fee checked",
  deposit_planned: "Preparing deposit",
  approve: "USDC approved for Gateway",
  deposit: "Deposited into Circle Gateway",
  finalized: "Gateway balance confirmed",
  requote: "Fee updated",
  signed: "Transfer signed by your wallet",
  submitted: "Sent to Circle",
  minted: "USDC minted at the destination",
  complete: "Complete",
  expired: "Expired before minting (nothing taken), retrying",
  retry: "Signing again",
  failed: "Failed",
};

export const shortAddress = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;

export type BridgeListItem = {
  id: string;
  direction: "OUT" | "IN";
  status: string;
  sourceChainLabel: string;
  destinationChainLabel: string;
  recipientAddress: string;
  amount: string;
  createdAt: string;
};
