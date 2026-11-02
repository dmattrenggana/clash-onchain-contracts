// e2e-upgrade.mjs — end-to-end test of the Robinhood Chain upgrade flow.
//
// Replicates the `upgrade-card` edge function:
//   1. approve the manager for the upgrade price
//   2. the game server signs the EIP-712 UpgradeRequest
//   3. the player calls upgradeCard(request, signature)
//
// Usage: RH_PK=0x.. node e2e-upgrade.mjs [cardType] [fromLevel]

import {
  createPublicClient, createWalletClient, http, keccak256, encodeAbiParameters,
  parseAbiParameters, stringToHex,
} from "viem";
import { robinhood } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const CARD_TYPE = BigInt(process.argv[2] ?? 0);
const FROM_LEVEL = BigInt(process.argv[3] ?? 1);
const TO_LEVEL = FROM_LEVEL + 1n;

const TOKEN = "0xbD719784F6BF693E20bA520dF81FDa6B202249Aa";
const MANAGER = "0x83547652ba08aa70ba7c96b8369bd2bcfe4fefd2";
const CARDS = "0x92f1185a7668c3730a2b3222db3047ae6135beca";
const TREASURY = "0x3e419a7949AF95194471Ea293d9a3BE821d3a991";

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
  { name: "upgradeCosts", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "upgradeBurnCounts", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "tokenIdOf", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "upgradeCard", type: "function", stateMutability: "nonpayable", inputs: [
    { name: "request", type: "tuple", components: [
      { name: "user", type: "address" }, { name: "cardType", type: "uint256" },
      { name: "fromLevel", type: "uint256" }, { name: "toLevel", type: "uint256" },
      { name: "tokenIdBurn", type: "uint256" }, { name: "tokenIdMint", type: "uint256" },
      { name: "burnAmount", type: "uint256" }, { name: "clashCost", type: "uint256" },
      { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" }] },
    { name: "signature", type: "bytes" },
  ], outputs: [] },
];
const cardsAbi = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "setApprovalForAll", type: "function", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bool" }], outputs: [] },
];

async function main() {
  const tokenIdBurn = CARD_TYPE * 256n + (FROM_LEVEL - 1n);
  const tokenIdMint = CARD_TYPE * 256n + (TO_LEVEL - 1n);

  const cost = await publicClient.readContract({ address: MANAGER, abi: managerAbi, functionName: "upgradeCosts", args: [FROM_LEVEL - 1n] });
  const burnCount = await publicClient.readContract({ address: MANAGER, abi: managerAbi, functionName: "upgradeBurnCounts", args: [FROM_LEVEL - 1n] });
  const expectedMint = await publicClient.readContract({ address: MANAGER, abi: managerAbi, functionName: "tokenIdOf", args: [CARD_TYPE, TO_LEVEL] });

  console.log(`Upgrade cardType=${CARD_TYPE} L${FROM_LEVEL}->L${TO_LEVEL}`);
  console.log("  cost        :", (cost / 10n ** 18n).toString(), "$CLASH");
  console.log("  burn count  :", burnCount.toString());
  console.log("  tokenIdBurn :", tokenIdBurn.toString(), "| tokenIdMint:", tokenIdMint.toString(), "(contract says", expectedMint.toString() + ")");

  const owned = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdBurn, account.address] });
  console.log("  owned L" + FROM_LEVEL + "  :", owned.toString());
  if (owned < burnCount) throw new Error(`need ${burnCount} L${FROM_LEVEL} cards, have ${owned}`);

  // approve token spend
  const allowance = await publicClient.readContract({ address: TOKEN, abi: erc20Abi, functionName: "allowance", args: [account.address, MANAGER] });
  if (allowance < cost) {
    const h = await walletClient.writeContract({ address: TOKEN, abi: erc20Abi, functionName: "approve", args: [MANAGER, cost], chain: robinhood });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log("  approved ✓");
  }
  // the manager must be allowed to move the NFT
  const approval = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdBurn, MANAGER] });
  void approval;
  const isApproved = await publicClient.readContract({
    address: CARDS,
    abi: [{ name: "isApprovedForAll", type: "function", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "bool" }] }],
    functionName: "isApprovedForAll", args: [account.address, MANAGER] });
  if (!isApproved) {
    const h = await walletClient.writeContract({ address: CARDS, abi: cardsAbi, functionName: "setApprovalForAll", args: [MANAGER, true], chain: robinhood });
    await publicClient.waitForTransactionReceipt({ hash: h });
    console.log("  setApprovalForAll(manager) ✓");
  }

  // sign
  const nonce = BigInt(Math.floor(Math.random() * 2 ** 48));
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
  const UPGRADE_TYPEHASH = keccak256(
    "UpgradeRequest(address user,uint256 cardType,uint256 fromLevel,uint256 toLevel,uint256 tokenIdBurn,uint256 tokenIdMint,uint256 burnAmount,uint256 clashCost,uint256 nonce,uint256 deadline)");

  const domainSeparator = keccak256(encodeAbiParameters(
    parseAbiParameters("bytes32,bytes32,bytes32,uint256,address"),
    [DOMAIN_TYPEHASH, keccak256(stringToHex("ClashCardManager")), keccak256(stringToHex("1")), 4663n, MANAGER]));
  const structHash = keccak256(encodeAbiParameters(
    parseAbiParameters("bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256"),
    [UPGRADE_TYPEHASH, account.address, CARD_TYPE, FROM_LEVEL, TO_LEVEL, tokenIdBurn, tokenIdMint, burnCount, cost, nonce, deadline]));
  const digest = keccak256("0x1901" + domainSeparator.slice(2) + structHash.slice(2));
  const signature = await account.sign({ hash: digest });

  const before = await publicClient.readContract({ address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  const l1Before = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdBurn, account.address] });
  const l2Before = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdMint, account.address] });

  console.log("  upgradeCard…");
  const hash = await walletClient.writeContract({
    address: MANAGER, abi: managerAbi, functionName: "upgradeCard",
    args: [{
      user: account.address, cardType: CARD_TYPE, fromLevel: FROM_LEVEL, toLevel: TO_LEVEL,
      tokenIdBurn, tokenIdMint, burnAmount: burnCount, clashCost: cost, nonce, deadline,
    }, signature],
    chain: robinhood,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("    tx", hash);
  console.log("    status:", receipt.status, "gas:", receipt.gasUsed, "block:", receipt.blockNumber);
  if (receipt.status !== "success") throw new Error("upgradeCard reverted");

  const after = await publicClient.readContract({ address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  const treasuryAfter = await publicClient.readContract({ address: TOKEN, abi: erc20Abi, functionName: "balanceOf", args: [TREASURY] });
  const l1After = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdBurn, account.address] });
  const l2After = await publicClient.readContract({ address: CARDS, abi: cardsAbi, functionName: "balanceOf", args: [tokenIdMint, account.address] });

  console.log("\n  player $CLASH :", (before / 10n ** 18n).toString(), "->", (after / 10n ** 18n).toString(),
    `(spent ${((before - after) / 10n ** 18n).toString()})`);
  console.log("  treasury      :", (treasuryAfter / 10n ** 18n).toString());
  console.log(`  L${FROM_LEVEL} cards      : ${l1Before} -> ${l1After}   (burned ${l1Before - l2Before * 0n - (l1Before - l1After)})`);
  console.log(`  L${TO_LEVEL} cards      : ${l2Before} -> ${l2After}`);
}

main().catch((e) => {
  console.error("\nFAILED:", e?.message ?? String(e));
  if (e?.details) console.error("details:", String(e.details).slice(0, 400));
  process.exit(1);
});
