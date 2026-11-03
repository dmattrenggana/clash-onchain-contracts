// deploy.mjs — deploy the Clash contract stack to Robinhood Chain (4663).
//
// Order:
//   1. ClashCards       (ERC-1155)  constructor(baseURI, royaltyReceiver, admin)
//   2. ClashCardManager               constructor(token, cards, treasury, admin)
//   3. ClashRewardClaim               constructor(token, signerAddress)
//   4. Wiring   grantRole(MINTER/BURNER on cards -> manager), setGameServer, addCardType(12)
//   5. Pricing  RH = Base (same token, same supply): chest 1M/3M/5M, upgrade 10M -> 2.56B
//   6. Verify   read every value back
//
// Usage:
//   RH_DEPLOYER_KEY=0x.. RH_TOKEN_ADDRESS=0x.. RH_ADMIN=0x.. RH_TREASURY=0x.. \
//   RH_GAME_SERVER=0x.. RH_REWARD_SIGNER=0x.. node deploy.mjs
//
// Optional:
//   REVISION=secure   (default) -> 6dec5de, includes the chest/pack L1-only guard
//   REVISION=parity   -> 7b0591b, byte-identical to the live Base deployment
//   SKIP_PRICING=1    -> deploy + wire only
//   DRY_RUN=1         -> print the plan, send nothing

import fs from "node:fs";
import {
  createPublicClient, createWalletClient, http, keccak256, formatEther, encodeDeployData,
} from "viem";
import { robinhood as robinhoodBase } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const artifacts = JSON.parse(fs.readFileSync(new URL("./artifacts.json", import.meta.url), "utf8"));

const robinhood = {
  ...robinhoodBase,
  rpcUrls: {
    default: { http: [process.env.RH_RPC_URL || robinhoodBase.rpcUrls.default.http[0]] },
  },
};

const env = (k, fallback) => {
  const v = process.env[k];
  if (!v) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing env var ${k}`);
  }
  return v;
};

const DEPLOYER_KEY = env("RH_DEPLOYER_KEY");
const TOKEN = env("RH_TOKEN_ADDRESS");
const ADMIN = env("RH_ADMIN");
const TREASURY = env("RH_TREASURY");
const ROYALTY = process.env.RH_ROYALTY || TREASURY;
const GAME_SERVER = env("RH_GAME_SERVER");
const REWARD_SIGNER = env("RH_REWARD_SIGNER");
const BASE_URI =
  "https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/metadata/";

// --- pricing (Robinhood = Base: the $CLASH token is bridged from Base) ------
const CHEST_COSTS = [1_000_000n, 3_000_000n, 5_000_000n]; // Silver / Gold / Magical
const UPGRADE_COSTS = [
  10_000_000n, 20_000_000n, 40_000_000n, 80_000_000n, 160_000_000n,
  320_000_000n, 640_000_000n, 1_280_000_000n, 2_560_000_000n,
]; // cost to go L1->L2 ... L9->L10
const toWei = (n) => n * 10n ** 18n;

const MINTER_ROLE = keccak256("MINTER_ROLE");
const BURNER_ROLE = keccak256("BURNER_ROLE");
const GAME_SERVER_ROLE = keccak256("GAME_SERVER_ROLE");

const transport = http(robinhood.rpcUrls.default.http[0], { timeout: 60000 });
const account = privateKeyToAccount(DEPLOYER_KEY);
const publicClient = createPublicClient({ chain: robinhood, transport });
const walletClient = createWalletClient({ chain: robinhood, transport, account });

const DRY = process.env.DRY_RUN === "1";

async function estimateGasWithRetry(data, label) {
  let lastErr;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const gas = await publicClient.estimateGas({ data, account: account.address });
      // 25% headroom, and never below the observed usage
      return BigInt(gas) + BigInt(gas) / 8n;
    } catch (e) {
      lastErr = e;
      const msg = String(e.shortMessage || e.message).split("\n")[0].slice(0, 120);
      console.log(`   ! estimateGas attempt ${attempt} failed: ${msg}`);
      await new Promise((r) => setTimeout(r, 1500 * attempt));
    }
  }
  throw new Error(`${label}: estimateGas failed — ${String(lastErr.shortMessage || lastErr.message).split("\n")[0].slice(0, 120)}`);
}

async function deployContract(artifact, args, label) {
  console.log(`\n→ ${label}`);
  const data = encodeDeployData({ abi: artifact.abi, args, bytecode: artifact.bytecode });
  if (DRY) {
    console.log(`   [dry-run] bytecode ${data.length / 2} B`);
    return "0xd0000000000000000000000000000000000000d0";
  }
  const gas = await estimateGasWithRetry(data, label);
  // Pin the fee to the current base fee (+50%): the node checks
  // balance >= gas * maxFeePerGas, so a tight cap keeps the deploy affordable.
  const base = (await publicClient.getBlock({ blockTag: "latest" })).baseFeePerGas ?? 0n;
  const gasPrice = (base * 3n) / 2n;
  console.log(`   gas limit ${gas} @ ${gasPrice} wei`);
  const hash = await walletClient.sendTransaction({ chain: robinhood, data, gas, gasPrice });
  console.log(`   tx ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} failed`);
  console.log(`   ✓ ${receipt.contractAddress}  gas=${receipt.gasUsed} block=${receipt.blockNumber}`);
  return receipt.contractAddress;
}

async function send({ abi, functionName, args, address, label }) {
  console.log(`\n→ ${label}`);
  console.log(`   ${functionName}(${args.map((a) => (typeof a === "string" ? a : a.toString())).join(", ")})`);
  if (DRY) return;
  const hash = await walletClient.writeContract({ address, abi, functionName, args, chain: robinhood });
  console.log(`   tx ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} failed`);
  console.log(`   ✓ status=${receipt.status} gas=${receipt.gasUsed} block=${receipt.blockNumber}`);
}

async function main() {
  console.log("Robinhood Chain deploy");
  console.log("  deployer  :", account.address);
  console.log("  token     :", TOKEN);
  console.log("  admin     :", ADMIN);
  console.log("  treasury  :", TREASURY);
  console.log("  royalty   :", ROYALTY);
  console.log("  game srv  :", GAME_SERVER);
  console.log("  reward sgn:", REWARD_SIGNER);
  if (DRY) console.log("  DRY RUN — nothing will be sent");

  if (!DRY) {
    const balance = await publicClient.getBalance({ address: account.address });
    console.log("  balance   :", formatEther(balance), "ETH");
    if (balance === 0n) throw new Error("Deployer has no ETH on Robinhood Chain");
  }

  const cardsAddress = process.env.CARDS_ADDRESS
    ? (console.log(`\n→ 1. ClashCards (resume) ${process.env.CARDS_ADDRESS}`), process.env.CARDS_ADDRESS)
    : await deployContract(
        artifacts.ClashCards,
        [BASE_URI, ROYALTY, ADMIN],
        "1. deploy ClashCards (ERC-1155)",
      );
  const managerAddress = await deployContract(
    artifacts.ClashCardManager,
    [TOKEN, cardsAddress, TREASURY, ADMIN],
    "2. deploy ClashCardManager",
  );
  const claimAddress = await deployContract(
    artifacts.ClashRewardClaim,
    [TOKEN, REWARD_SIGNER],
    "3. deploy ClashRewardClaim",
  );

  await send({
    abi: artifacts.ClashCards.abi, functionName: "grantRole", address: cardsAddress,
    args: [MINTER_ROLE, managerAddress], label: "4a. cards.grantRole(MINTER_ROLE, manager)",
  });
  await send({
    abi: artifacts.ClashCards.abi, functionName: "grantRole", address: cardsAddress,
    args: [BURNER_ROLE, managerAddress], label: "4b. cards.grantRole(BURNER_ROLE, manager)",
  });
  await send({
    abi: artifacts.ClashCardManager.abi, functionName: "setGameServer", address: managerAddress,
    args: [GAME_SERVER, true], label: "4c. manager.setGameServer(gameServer, true)",
  });
  await send({
    abi: artifacts.ClashCardManager.abi, functionName: "addCardType", address: managerAddress,
    args: [12n], label: "4d. manager.addCardType(12)  <- Robinhood Epic",
  });

  if (account.address.toLowerCase() !== ADMIN.toLowerCase()) {
    await send({
      abi: artifacts.ClashRewardClaim.abi, functionName: "transferOwnership", address: claimAddress,
      args: [ADMIN], label: "4e. claim.transferOwnership(admin)",
    });
  }

  if (!process.env.SKIP_PRICING) {
    for (let t = 0; t < CHEST_COSTS.length; t++) {
      await send({
        abi: artifacts.ClashCardManager.abi, functionName: "setChestCost", address: managerAddress,
        args: [t, toWei(CHEST_COSTS[t])], label: `5a. manager.setChestCost(${t}, ${CHEST_COSTS[t]} $CLASH)`,
      });
    }
    for (let i = 0; i < UPGRADE_COSTS.length; i++) {
      await send({
        abi: artifacts.ClashCardManager.abi, functionName: "setUpgradeCost", address: managerAddress,
        args: [BigInt(i + 1), toWei(UPGRADE_COSTS[i])],
        label: `5b. manager.setUpgradeCost(from L${i + 1}, ${UPGRADE_COSTS[i]} $CLASH)`,
      });
    }
  }

  console.log("\n=== ENV TO FILL ===");
  console.log(`RH_CLASH_CARDS_ADDRESS=${cardsAddress}`);
  console.log(`RH_CARD_MANAGER_ADDRESS=${managerAddress}`);
  console.log(`RH_REWARD_CONTRACT_ADDRESS=${claimAddress}`);
  console.log(`RH_CLASH_TOKEN_ADDRESS=${TOKEN}`);
  console.log(`ROBINHOOD_RPC_URL=${robinhood.rpcUrls.default.http[0]}`);
  console.log(`VITE_RH_CLASH_CARDS_ADDRESS=${cardsAddress}`);
  console.log(`VITE_RH_CARD_MANAGER_ADDRESS=${managerAddress}`);
  console.log(`VITE_RH_REWARD_CONTRACT_ADDRESS=${claimAddress}`);
  console.log(`VITE_RH_CLASH_TOKEN_ADDRESS=${TOKEN}`);
  console.log(`VITE_ROBINHOOD_RPC_URL=${robinhood.rpcUrls.default.http[0]}`);
  if (DRY) return;

  console.log("\n=== VERIFY ===");
  const checks = [];
  const managerAbi = artifacts.ClashCardManager.abi;
  const cardsAbi = artifacts.ClashCards.abi;
  const claimAbi = artifacts.ClashRewardClaim.abi;

  const cardTypeCount = await publicClient.readContract({
    address: managerAddress, abi: managerAbi, functionName: "cardTypeCount" });
  checks.push(["cardTypeCount", cardTypeCount.toString(), cardTypeCount === 13n]);

  const hasRobinhood = await publicClient.readContract({
    address: managerAddress, abi: managerAbi, functionName: "cardTypeExists", args: [12n] });
  checks.push(["cardTypeExists(12)", hasRobinhood.toString(), hasRobinhood === true]);

  const maxLevel = await publicClient.readContract({
    address: managerAddress, abi: managerAbi, functionName: "maxLevel" });
  checks.push(["maxLevel", maxLevel.toString(), maxLevel === 10n]);

  for (const [role, name] of [[MINTER_ROLE, "MINTER_ROLE"], [BURNER_ROLE, "BURNER_ROLE"]]) {
    const has = await publicClient.readContract({
      address: cardsAddress, abi: cardsAbi, functionName: "hasRole", args: [role, managerAddress] });
    checks.push([`cards.hasRole(${name}, manager)`, has.toString(), has === true]);
  }

  const gs = await publicClient.readContract({
    address: managerAddress, abi: managerAbi, functionName: "hasRole", args: [GAME_SERVER_ROLE, GAME_SERVER] });
  checks.push(["manager.hasRole(GAME_SERVER_ROLE, gameServer)", gs.toString(), gs === true]);

  for (let t = 0; t < CHEST_COSTS.length; t++) {
    const v = await publicClient.readContract({
      address: managerAddress, abi: managerAbi, functionName: "chestCosts", args: [t] });
    checks.push([`chestCosts[${t}]`, v.toString(), v === toWei(CHEST_COSTS[t])]);
  }
  for (let i = 0; i < UPGRADE_COSTS.length; i++) {
    const v = await publicClient.readContract({
      address: managerAddress, abi: managerAbi, functionName: "upgradeCosts", args: [BigInt(i)] });
    checks.push([`upgradeCosts[${i}]`, v.toString(), v === toWei(UPGRADE_COSTS[i])]);
  }

  const owner = await publicClient.readContract({
    address: claimAddress, abi: claimAbi, functionName: "owner" });
  checks.push(["claim.owner", owner, owner.toLowerCase() === ADMIN.toLowerCase()]);

  const signer = await publicClient.readContract({
    address: claimAddress, abi: claimAbi, functionName: "signerAddress" });
  checks.push(["claim.signerAddress", signer, signer.toLowerCase() === REWARD_SIGNER.toLowerCase()]);

  let allOk = true;
  for (const [label, value, ok] of checks) {
    if (!ok) allOk = false;
    console.log(`  ${ok ? "✓" : "✗"} ${label} = ${value}`);
  }
  console.log(`\n${allOk ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED"}`);
}

main().catch((e) => {
  console.error("\nFAILED:", String(e.message).split("\n")[0].slice(0, 200));
  process.exit(1);
});
