// Chains the bridge supports, with everything Circle Gateway needs for each.
// Sources: developers.circle.com (Gateway contract addresses, USDC contract
// addresses, Wallets supported blockchains). Testnet only for now; mainnet is
// added before launch, after the same live checks.
import { env } from "../env";

export type BridgeChain = {
  key: string;              // our name, used in the database and the API
  label: string;            // shown to users
  circleBlockchain: string; // Circle Wallets blockchain code
  domain: number;           // Circle domain id (same as CCTP)
  usdc: `0x${string}`;      // USDC token contract
  gatewayWallet: `0x${string}`;
  gatewayMinter: `0x${string}`;
  explorerTx: string;       // + tx hash
  // Safety cap on Circle's fee for transfers TO this chain (USDC). Ethereum gas
  // is expensive, so forwarding there costs more (about 1.3 USDC on testnet).
  maxFeeUsdc?: number;
};

const GATEWAY_WALLET_TESTNET: `0x${string}` = "0x0077777d7EBA4688BDeF3E311b846F25870A19B9";
const GATEWAY_MINTER_TESTNET: `0x${string}` = "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B";

const TESTNET: BridgeChain[] = ([
  { key: "arc", label: "Arc Testnet", circleBlockchain: "ARC-TESTNET", domain: 26,
    usdc: "0x3600000000000000000000000000000000000000", explorerTx: "https://explorer.testnet.arc.io/tx/" },
  { key: "base", label: "Base Sepolia", circleBlockchain: "BASE-SEPOLIA", domain: 6,
    usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", explorerTx: "https://sepolia.basescan.org/tx/" },
  { key: "arbitrum", label: "Arbitrum Sepolia", circleBlockchain: "ARB-SEPOLIA", domain: 3,
    usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", explorerTx: "https://sepolia.arbiscan.io/tx/" },
  { key: "ethereum", label: "Ethereum Sepolia", circleBlockchain: "ETH-SEPOLIA", domain: 0,
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", explorerTx: "https://sepolia.etherscan.io/tx/", maxFeeUsdc: 2 },
  { key: "avalanche", label: "Avalanche Fuji", circleBlockchain: "AVAX-FUJI", domain: 1,
    usdc: "0x5425890298aed601595a70AB815c96711a31Bc65", explorerTx: "https://testnet.snowtrace.io/tx/" },
  { key: "optimism", label: "OP Sepolia", circleBlockchain: "OP-SEPOLIA", domain: 2,
    usdc: "0x5fd84259d66Cd46123540766Be93DFE6D43130D7", explorerTx: "https://sepolia-optimism.etherscan.io/tx/" },
  { key: "polygon", label: "Polygon Amoy", circleBlockchain: "MATIC-AMOY", domain: 7,
    usdc: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582", explorerTx: "https://amoy.polygonscan.com/tx/" },
  { key: "unichain", label: "Unichain Sepolia", circleBlockchain: "UNI-SEPOLIA", domain: 10,
    usdc: "0x31d0220469e10c4E71834a79b1f276d740d3768F", explorerTx: "https://sepolia.uniscan.xyz/tx/" },
] as Omit<BridgeChain, "gatewayWallet" | "gatewayMinter">[]).map((c) => ({ ...c, gatewayWallet: GATEWAY_WALLET_TESTNET, gatewayMinter: GATEWAY_MINTER_TESTNET }));

function registry(): BridgeChain[] {
  if (env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) return TESTNET;
  throw new Error("The bridge has no mainnet chain list yet. Add it (and test it) before launch.");
}

export function bridgeChains(): BridgeChain[] {
  return registry();
}

export function chainByKey(key: string): BridgeChain {
  const chain = registry().find((c) => c.key === key);
  if (!chain) throw new Error(`Unknown bridge chain: ${key}`);
  return chain;
}

// Arc is home: user balances live there.
export function homeChain(): BridgeChain {
  return chainByKey("arc");
}

// The most Circle may take in fees for one transfer to this chain, in micro USDC.
// BRIDGE_MAX_FEE_USDC is the default; a chain can set a higher cap.
export function feeCapMicro(destination: BridgeChain): number {
  return Math.round((destination.maxFeeUsdc ?? env.BRIDGE_MAX_FEE_USDC) * 1_000_000);
}

export function isEvmAddress(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}
