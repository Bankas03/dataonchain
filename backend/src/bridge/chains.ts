// Chains the bridge supports, with everything Circle Gateway needs for each.
// Sources: developers.circle.com (Gateway contract addresses, USDC contract
// addresses, Wallets supported blockchains). Which of them users can use is set
// by BRIDGE_CHAINS (see openChains).
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

// Mainnet (checked against Circle's and Arc's contract address pages, October 2026).
// Ethereum is left out at launch: smart wallet set up and gas there cost several
// dollars, paid through Gas Station. Add it back here when that makes sense.
const GATEWAY_WALLET_MAINNET: `0x${string}` = "0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE";
const GATEWAY_MINTER_MAINNET: `0x${string}` = "0x2222222d7164433c4C09B0b0D809a9b52C04C205";

const MAINNET: BridgeChain[] = ([
  { key: "arc", label: "Arc", circleBlockchain: "ARC", domain: 26,
    usdc: "0x3600000000000000000000000000000000000000", explorerTx: "https://explorer.arc.io/tx/" },
  { key: "base", label: "Base", circleBlockchain: "BASE", domain: 6,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", explorerTx: "https://basescan.org/tx/" },
  { key: "arbitrum", label: "Arbitrum", circleBlockchain: "ARB", domain: 3,
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", explorerTx: "https://arbiscan.io/tx/" },
  { key: "avalanche", label: "Avalanche", circleBlockchain: "AVAX", domain: 1,
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", explorerTx: "https://snowtrace.io/tx/" },
  { key: "optimism", label: "OP Mainnet", circleBlockchain: "OP", domain: 2,
    usdc: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", explorerTx: "https://optimistic.etherscan.io/tx/" },
  { key: "polygon", label: "Polygon", circleBlockchain: "MATIC", domain: 7,
    usdc: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", explorerTx: "https://polygonscan.com/tx/" },
  { key: "unichain", label: "Unichain", circleBlockchain: "UNI", domain: 10,
    usdc: "0x078D782b760474a361dDA0AF3839290b0EF57AD6", explorerTx: "https://uniscan.xyz/tx/" },
] as Omit<BridgeChain, "gatewayWallet" | "gatewayMinter">[]).map((c) => ({ ...c, gatewayWallet: GATEWAY_WALLET_MAINNET, gatewayMinter: GATEWAY_MINTER_MAINNET }));

export const isMainnet = () => !env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET");

function registry(): BridgeChain[] {
  if (env.CIRCLE_BLOCKCHAIN.endsWith("TESTNET")) return TESTNET;
  if (env.CIRCLE_BLOCKCHAIN === "ARC") return MAINNET;
  throw new Error(`No bridge chain list for ${env.CIRCLE_BLOCKCHAIN}.`);
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

// The networks users can send to and bring USDC back from right now
// (BRIDGE_CHAINS; on mainnet Arc and Base, the networks with a Gas Station policy).
export function openChains(): BridgeChain[] {
  const all = registry();
  if (env.BRIDGE_CHAINS.includes("*")) return all;
  return all.filter((c) => c.key === "arc" || env.BRIDGE_CHAINS.includes(c.key));
}

export function isOpenChain(key: string): boolean {
  return openChains().some((c) => c.key === key);
}

// The most Circle may take in fees for one transfer to this chain, in micro USDC.
// BRIDGE_MAX_FEE_USDC is the default; a chain can set a higher cap.
export function feeCapMicro(destination: BridgeChain): number {
  return Math.round((destination.maxFeeUsdc ?? env.BRIDGE_MAX_FEE_USDC) * 1_000_000);
}

export function isEvmAddress(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}
