import { parseEther, Interface } from "./vendor/ethers.js";
export const MINT_VALUE = 1900000000000000n;
export type ProofJob = {
  id: number;
  account: string;
  seed: string;
  target: string;
  refBlock: number;
  refHash: string;
};
export type Quote = {
  buy: boolean;
  input: bigint;
  spent: bigint;
  output: bigint;
  min: bigint;
  bps: bigint;
  at: number;
};
export function parseAmount(value: string): bigint {
  if (!/^\d+(\.\d{1,18})?$/.test(value.trim()))
    throw new Error("Enter a positive amount with up to 18 decimal places.");
  const amount: bigint = parseEther(value.trim());
  if (amount <= 0n) throw new Error("Enter an amount greater than zero.");
  return amount;
}
export function parseSlippage(value: string): bigint {
  if (!/^\d+(\.\d{1,2})?$/.test(value))
    throw new Error(
      "Choose slippage between 0.1% and 5%, with at most two decimal places.",
    );
  const bps = BigInt(Math.round(Number(value) * 100));
  if (bps < 10n || bps > 500n)
    throw new Error("Choose slippage between 0.1% and 5%.");
  return bps;
}
export function makeQuote(
  buy: boolean,
  input: bigint,
  spent: bigint,
  output: bigint,
  bps: bigint,
  now = Date.now(),
): Quote {
  const min = (output * (10000n - bps)) / 10000n;
  if (min === 0n)
    throw new Error("This amount is too small to return a protected quote.");
  return { buy, input, spent, output, min, bps, at: now };
}
export function quoteValid(
  q: Quote | null,
  buy: boolean,
  input: bigint,
  bps: bigint,
  now = Date.now(),
) {
  return (
    !!q &&
    q.buy === buy &&
    q.input === input &&
    q.bps === bps &&
    now - q.at < 60000
  );
}
export function staleProof(
  job: ProofJob,
  seed: string,
  target: bigint,
  head: number,
  hash?: string,
) {
  return (
    job.seed !== seed ||
    job.target !== target.toString() ||
    head - job.refBlock > 48 ||
    head <= job.refBlock ||
    (hash !== undefined && hash !== job.refHash)
  );
}
export function countdown(unlock: number, now: number) {
  const remaining = Math.max(0, Math.ceil(unlock - now));
  if (!remaining) return "Ready now";
  return `${Math.floor(remaining / 3600)}h ${Math.floor((remaining % 3600) / 60)}m ${remaining % 60}s`;
}
export function decodeMetadata(uri: string) {
  if (!uri.startsWith("data:application/json;base64,"))
    throw new Error("Unexpected tokenURI format.");
  const data = JSON.parse(
    new TextDecoder().decode(
      Uint8Array.from(atob(uri.split(",")[1]), (c) => c.charCodeAt(0)),
    ),
  );
  if (
    typeof data.name !== "string" ||
    !data.image?.startsWith("data:image/svg+xml;base64,") ||
    !Array.isArray(data.attributes)
  )
    throw new Error("Unexpected on-chain metadata.");
  return data as {
    name: string;
    description: string;
    image: string;
    attributes: { trait_type: string; value: string }[];
  };
}
export function contractError(error: any, abis: Record<string, any[]> = {}) {
  let name = error?.revert?.name || error?.errorName;
  let args = Array.from(error?.revert?.args || []) as any[];
  const candidates = [
    error?.data,
    error?.info?.error?.data,
    error?.error?.data,
    error?.cause?.data,
  ];
  for (const candidate of candidates) {
    const data = typeof candidate === "string" ? candidate : candidate?.data;
    if (!data) continue;
    for (const abi of Object.values(abis))
      try {
        const decoded = new Interface(abi).parseError(data);
        if (decoded) {
          name = decoded.name;
          args = Array.from(decoded.args);
          break;
        }
      } catch {}
    if (name) break;
  }
  const messages: Record<string, string> = {
    HourFull: `Mint window full. The next slot opens ${args[0] ? new Date(Number(args[0]) * 1000).toLocaleString() : "when the oldest mint leaves the rolling hour"}.`,
    StaleSeed:
      "Another frog changed the seed. Mining continues on the new seed.",
    InvalidReferenceBlock:
      "The reference block expired or changed. Mining continues on a fresh block.",
    InvalidProof:
      "Invalid proof: the hash does not meet the current target. Start mining to find a valid solution.",
    WrongPrice: "Mint requires exactly 0.0019 ETH, plus network gas.",
    SoldOut: "All 2,000 frogs have been minted. Explore the gallery.",
    HolderOnly: "Only the wallet that owns this frog can burn it.",
    TooEarly: `Your unstake delay ends ${args[0] ? new Date(Number(args[0]) * 1000).toLocaleString() : "after 24 hours"}.`,
    BuybackCooldown:
      "Buyback is cooling down. Wait for the countdown to finish.",
    BuybackSlippage:
      "Buyback exceeds the average-price protection. Wait for a better price or use a smaller amount.",
    OracleNotReady:
      "The pool needs 30 minutes of price history before a buyback. Try again later.",
    Slippage:
      "The pool cannot satisfy this minimum output. Request a new quote or reduce the amount.",
    Expired:
      "The transaction deadline passed. Request a new quote and try again.",
    ERC721NonexistentToken:
      "This frog has not been minted or has been burned. Return to the gallery.",
    InvalidAmount: "Check the amount and your available balance.",
    InvalidBuybackAmount:
      "Enter a buyback amount within the vault balance and the 100 IMD limit.",
  };
  if (messages[name]) return { name, text: messages[name] };
  if (error?.code === 4001 || error?.code === "ACTION_REJECTED")
    return {
      name: "Rejected",
      text: "Request declined in your wallet. No new transaction was sent.",
    };
  return {
    name: name || "Unknown",
    text:
      error?.shortMessage || error?.reason || error?.message || String(error),
  };
}
