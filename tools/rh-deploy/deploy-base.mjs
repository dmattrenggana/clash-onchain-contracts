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
import { base as baseChain } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const artifacts = JSON.parse(fs.readFileSync(new URL("./artifacts.json", import.meta.url), "utf8"));

const baseCfg = {
  ...baseChain,
  rpcUrls: {
    default: { http: [process.env.BASE_RPC_URL || baseChain.rpcUrls.default.http[0]] },
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

const DEPLOYER_KEY = env("BASE_DEPLOYER_KEY");
const TOKEN = env("BASE_TOKEN_ADDRESS");
const ADMIN = env("BASE_ADMIN");
const TREASURY = env("BASE_TREASURY");
const ROYALTY = process.env.BASE_ROYALTY || TREASURY;
const GAME_SERVER = env("BASE_GAME_SERVER");
const REWARD_SIGNER = env("BASE_REWARD_SIGNER");
const BASE_URI =
  "https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/metadata/";

// --- pricing (Robinhood = Base: the $CLASH token is bridged from Base) ------
const CHEST_COSTS = [1_000_000n, 3_000_000n, 5_000_000n]; // Silver / Gold / Magical
const UPGRADE_COSTS = [
  10_000_000n, 20_000_000n, 40_000_000n, 80_000_000n, 160_000_000n,
  320_000_000n, 640_000_000n, 1_280_000_000n, 2_560_000_000n,
]; // cost to go L1->L2 ... L9->L10
const toWei = (n) => n * 10n ** 18n;

// 2026-11-18: the new Base $CLASH has a 1e9 supply (the old one had 1e11),
// so every price is scaled down by the same factor. PRICE_SCALE=0.01 keeps
// the economy ratios identical (a chest still costs 1/10 of an L1->L2
// upgrade, and the priciest upgrade still costs 2.56% of the supply).
const PRICE_DIVISOR = BigInt(process.env.PRICE_DIVISOR || "100");
const scalePrice = (n) => n / PRICE_DIVISOR;

const MINTER_ROLE = keccak256("MINTER_ROLE");
const BURNER_ROLE = keccak256("BURNER_ROLE");
const GAME_SERVER_ROLE = keccak256("GAME_SERVER_ROLE");

const transport = http(baseCfg.rpcUrls.default.http[0], { timeout: 60000 });
const account = privateKeyToAccount(DEPLOYER_KEY);
const publicClient = createPublicClient({ chain: baseCfg, transport });
const walletClient = createWalletClient({ chain: baseCfg, transport, account });

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
  const hash = await walletClient.sendTransaction({ chain: baseCfg, data, gas, gasPrice });
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
  const hash = await walletClient.writeContract({ address, abi, functionName, args, chain: baseCfg });
  console.log(`   tx ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} failed`);
  console.log(`   ✓ status=${receipt.status} gas=${receipt.gasUsed} block=${receipt.blockNumber}`);
}

async function main() {
  console.log("Base Chain deploy (2026-11-18, new $CLASH token)");
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
    if (balance === 0n) throw new Error("Deployer has no ETH on Base");
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
  // The constructor registers card types 0-11. The three Epics (Robinhood,
  // Clanker, Warlord Jesse) have to be added explicitly.
  for (const [t, name] of [[12n, "robinhood"], [13n, "clanker"], [14n, "warlord_jesse"]]) {
    await send({
      abi: artifacts.ClashCardManager.abi, functionName: "addCardType", address: managerAddress,
      args: [t], label: `4d. manager.addCardType(${t})  <- ${name}`,
    });
  }

  // The previous manager keeps its MINTER/BURNER roles on the shared
  // ClashCards contract — revoke them so it cannot mint or burn anymore.
  if (process.env.OLD_MANAGER_ADDRESS) {
    for (const [role, label] of [[MINTER_ROLE, "MINTER"], [BURNER_ROLE, "BURNER"]]) {
      await send({
        abi: artifacts.ClashCards.abi, functionName: "revokeRole", address: cardsAddress,
        args: [role, process.env.OLD_MANAGER_ADDRESS],
        label: `4e. cards.revokeRole(${label}_ROLE, old manager ${process.env.OLD_MANAGER_ADDRESS})`,
      });
    }
  }

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
        args: [t, toWei(scalePrice(CHEST_COSTS[t]))], label: `5a. manager.setChestCost(${t}, ${scalePrice(CHEST_COSTS[t])} $CLASH)`,
      });
    }
    for (let i = 0; i < UPGRADE_COSTS.length; i++) {
      await send({
        abi: artifacts.ClashCardManager.abi, functionName: "setUpgradeCost", address: managerAddress,
        args: [BigInt(i + 1), toWei(scalePrice(UPGRADE_COSTS[i]))],
        label: `5b. manager.setUpgradeCost(from L${i + 1}, ${scalePrice(UPGRADE_COSTS[i])} $CLASH)`,
      });
    }
  }

  console.log("\n=== ENV TO FILL ===");
  console.log(`BASE_CLASH_CARDS_ADDRESS=${cardsAddress}`);
  console.log(`BASE_CARD_MANAGER_ADDRESS=${managerAddress}`);
  console.log(`BASE_REWARD_CONTRACT_ADDRESS=${claimAddress}`);
  console.log(`BASE_CLASH_TOKEN_ADDRESS=${TOKEN}`);
  console.log(`BASE_RPC_URL=${baseCfg.rpcUrls.default.http[0]}`);
  console.log(`VITE_BASE_CLASH_CARDS_ADDRESS=${cardsAddress}`);
  console.log(`VITE_BASE_CARD_MANAGER_ADDRESS=${managerAddress}`);
  console.log(`VITE_BASE_REWARD_CONTRACT_ADDRESS=${claimAddress}`);
  console.log(`VITE_BASE_CLASH_TOKEN_ADDRESS=${TOKEN}`);
  console.log(`VITE_BASE_RPC_URL=${baseCfg.rpcUrls.default.http[0]}`);
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
