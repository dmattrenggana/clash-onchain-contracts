// e2e-chest.mjs — end-to-end test of the Robinhood Chain chest flow.
//
// Replicates exactly what the `open-chest` edge function does:
//   1. the player approves the manager for the chest price
//   2. the game server signs the EIP-712 ChestRequest
//   3. the player calls buyChest(request, signature, tokenIds, amounts)
//
// The signer is the GAME_SERVER_ROLE holder (the admin wallet).
// Usage: RH_PK=0x.. node e2e-chest.mjs [chestType 0|1|2]

import {
  createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
  parseAbiParameters, stringToHex, toHex, formatEther,
} from "viem";
import { robinhood } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const CHEST_TYPE = Number(process.argv[2] ?? 0); // 0 silver, 1 gold, 2 magical
const TOKEN = "0xe577182a9a29af25675b3563f3b96aa948b5df19";
const MANAGER = "0x17d7509ab855d7fda63d1391cc3d81c891f68f32";
const CARDS = "0x92f1185a7668c3730a2b3222db3047ae6135beca";

const CHEST_CONFIG = {
  0: { common: 20, rare: 0, epic: 0, cost: 10_000n },
  1: { common: 60, rare: 8, epic: 2, cost: 30_000n },
  2: { common: 120, rare: 25, epic: 5, cost: 50_000n },
};
const COMMON = ["knight", "archer", "wizard", "goblin", "barrel_bomb", "meteor", "incubus"].map(
  (n) => ["knight", "archer", "giant", "wyvern", "wizard", "goblin", "barbarian", "healer",
    "gunslinger", "barrel_bomb", "meteor", "incubus", "robinhood"].indexOf(n),
);
const RARE = ["wyvern", "giant", "barbarian", "healer", "gunslinger"].map((n) =>
  ["knight", "archer", "giant", "wyvern", "wizard", "goblin", "barbarian", "healer",
    "gunslinger", "barrel_bomb", "meteor", "incubus", "robinhood"].indexOf(n));
const EPIC = [12];

const cfg = CHEST_CONFIG[CHEST_TYPE];
const account = privateKeyToAccount(process.env.RH_PK);
const transport = http("https://rpc.mainnet.chain.robinhood.com", { timeout: 60000 });
const publicClient = createPublicClient({ chain: robinhood, transport });
const walletClient = createWalletClient({ chain: robinhood, transport, account });

const erc20Abi = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "approve", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "allowance", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
];
const managerAbi = [
  { name: "chestCosts", type: "function", stateMutability: "view", inputs: [{ type: "uint8" }], outputs: [{ type: "uint256" }] },
  { name: "buyChest", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "request", type: "tuple", components: [
      { name: "user", type: "address" }, { name: "chestType", type: "uint8" },
      { name: "clashCost", type: "uint256" }, { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }] },
    { name: "signature", type: "bytes" },
    { name: "tokenIds", type: "uint256[]" },
    { name: "amounts", type: "uint256[]" },
  ], outputs: [] },
];
const cardsAbi = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
];

const wei = (n) => n * 10n ** 18n;
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

async function main() {
  console.log(`Chest type ${CHEST_TYPE} (${["silver", "gold", "magical"][CHEST_TYPE]})`);
  console.log("  player/signer:", account.address);

  // --- contents (same distribution as the edge function) ---
  const contents = [];
  for (let i = 0; i < cfg.common; i++) contents.push(pick(COMMON));
  for (let i = 0; i < cfg.rare; i++) contents.push(pick(RARE));
  for (let i = 0; i < cfg.epic; i++) contents.push(pick(EPIC));

  const agg = new Map();
  for (const t of contents) agg.set(t, (agg.get(t) ?? 0n) + 1n);
  const tokenIds = [...agg.keys()].map((t) => BigInt(t) * 256n); // L1 => id % 256 === 0
  const amounts = [...agg.values()];

  // --- read the on-chain price ---
  const onChainCost = await publicClient.readContract({
    address: MANAGER, abi: managerAbi, functionName: "chestCosts", args: [CHEST_TYPE],
  });
  console.log("  chestCosts on-chain:", (onChainCost / 10n ** 18n).toString(), "$CLASH");

  const before = await publicClient.readContract({
    address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  const treasuryBefore = await publicClient.readContract({
    address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: ["0x3e419a7949AF95194471Ea293d9a3BE821d3a991"] });

  // --- 1. approve ---
  const allowance = await publicClient.readContract({
    address: TOKEN, abi: erc20Abi, functionName: "allowance", args: [account.address, MANAGER] });
  if (allowance < onChainCost) {
    console.log("  approve…");
    const h = await walletClient.writeContract({
      address: TOKEN, abi: erc20Abi, functionName: "approve",
      args: [MANAGER, onChainCost], chain: robinhood });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log("    ✓ approved", (onChainCost / 10n ** 18n).toString(), "$CLASH");
  }

  // --- 2. sign the EIP-712 ChestRequest ---
  const nonce = BigInt(Math.floor(Math.random() * 2 ** 48));
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const EIP712_DOMAIN_TYPEHASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  const CHEST_TYPEHASH = keccak256(
    "ChestRequest(address user,uint8 chestType,uint256 clashCost,uint256 nonce,uint256 deadline)");

  const domainSeparator = keccak256(encodeAbiParameters(
    parseAbiParameters("bytes32,bytes32,bytes32,uint256,address"),
    [EIP712_DOMAIN_TYPEHASH, keccak256(stringToHex("ClashCardManager")), keccak256(stringToHex("1")), 4663n, MANAGER],
  ));
  const structHash = keccak256(encodeAbiParameters(
    parseAbiParameters("bytes32,address,uint8,uint256,uint256,uint256"),
    [CHEST_TYPEHASH, account.address, CHEST_TYPE, onChainCost, nonce, deadline],
  ));
  const digest = keccak256(concatBytes("0x1901", domainSeparator, structHash));

  // The contract recovers the RAW digest (r,s,v) — NOT EIP-191 personal_sign.
  const signature = await account.sign({ hash: digest });
  console.log("  signed digest:", digest.slice(0, 20), "…");

  // --- 3. buyChest ---
  console.log(`  buyChest (${contents.length} cards, ${tokenIds.length} unique)…`);
  const hash = await walletClient.writeContract({
    address: MANAGER, abi: managerAbi, functionName: "buyChest",
    args: [
      { user: account.address, chestType: CHEST_TYPE, clashCost: onChainCost, nonce, deadline },
      signature, tokenIds, amounts,
    ],
    chain: robinhood,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("    tx", hash);
  console.log("    status:", receipt.status, "gas:", receipt.gasUsed, "block:", receipt.blockNumber);
  if (receipt.status !== "success") throw new Error("buyChest reverted");

  // --- verify ---
  const after = await publicClient.readContract({
    address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  const treasuryAfter = await publicClient.readContract({
    address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: ["0x3e419a7949AF95194471Ea293d9a3BE821d3a991"] });

  console.log("\n  player $CLASH :", (before / 10n ** 18n).toString(), "->", (after / 10n ** 18n).toString(),
    `(spent ${((before - after) / 10n ** 18n).toString()})`);
  console.log("  treasury      :", (treasuryBefore / 10n ** 18n).toString(), "->", (treasuryAfter / 10n ** 18n).toString());

  console.log("\n  minted NFTs:");
  for (const [t, amt] of agg) {
    const bal = await publicClient.readContract({
      address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [account.address, BigInt(t) * 256n] });
    console.log(`    type ${String(t).padStart(2)} (${["knight","archer","giant","wyvern","wizard","goblin","barbarian","healer","gunslinger","barrel_bomb","meteor","incubus","robinhood"][t]}) L1 x${amt} => balance ${bal}`);
  }
  console.log("\n  chainId used  : 4663  ✓");
}

function concatBytes(...parts) {
  return "0x" + parts.map((p) => p.replace(/^0x/, "")).join("");
}

main().catch((e) => {
  console.error("\nFAILED:", e?.message ?? e?.shortMessage ?? String(e));
  if (e?.details) console.error("details:", String(e.details).slice(0, 500));
  console.error("STACK:", String(e?.stack || "").split("\n").slice(0,6).join("\n"));
  process.exit(1);
});
