// finish-base.mjs — the two steps the main deploy could not finish:
//   1. revoke MINTER/BURNER from the OLD manager on the shared ClashCards
//   2. set the chest + upgrade pricing on the NEW manager
import fs from "node:fs";
import { createPublicClient, createWalletClient, http, keccak256, parseAbi } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const artifacts = JSON.parse(fs.readFileSync(new URL("./artifacts.json", import.meta.url), "utf8"));
const KEY = process.env.BASE_DEPLOYER_KEY;
const CARDS = process.env.CARDS_ADDRESS;
const MANAGER = process.env.NEW_MANAGER_ADDRESS;
const OLD_MANAGER = process.env.OLD_MANAGER_ADDRESS;
const account = privateKeyToAccount(KEY);
const transport = http(process.env.BASE_RPC_URL || "https://mainnet.base.org");
const publicClient = createPublicClient({ chain: base, transport });
const walletClient = createWalletClient({ chain: base, transport, account });

const MINTER_ROLE = keccak256("MINTER_ROLE");
const BURNER_ROLE = keccak256("BURNER_ROLE");
const toWei = (n) => n * 10n ** 18n;
const DIV = BigInt(process.env.PRICE_DIVISOR || "100");
const CHEST = [1_000_000n, 3_000_000n, 5_000_000n].map((n) => n / DIV);
const UPGRADE = [10_000_000n, 20_000_000n, 40_000_000n, 80_000_000n, 160_000_000n,
  320_000_000n, 640_000_000n, 1_280_000_000n, 2_560_000_000n].map((n) => n / DIV);

async function send({ abi, functionName, args, address, label }) {
  console.log(`→ ${label}`);
  const hash = await walletClient.writeContract({ address, abi, functionName, args, chain: base });
  const r = await publicClient.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${label} failed`);
  console.log(`   ✓ tx ${hash}  gas=${r.gasUsed} block=${r.blockNumber}`);
}

for (const [role, name] of [[MINTER_ROLE, "MINTER"], [BURNER_ROLE, "BURNER"]]) {
  await send({
    abi: artifacts.ClashCards.abi, functionName: "revokeRole", address: CARDS,
    args: [role, OLD_MANAGER], label: `cards.revokeRole(${name}_ROLE, old manager)`,
  });
}
for (let t = 0; t < 3; t++) {
  await send({
    abi: artifacts.ClashCardManager.abi, functionName: "setChestCost", address: MANAGER,
    args: [t, toWei(CHEST[t])], label: `manager.setChestCost(${t}, ${CHEST[t]})`,
  });
}
for (let i = 0; i < UPGRADE.length; i++) {
  await send({
    abi: artifacts.ClashCardManager.abi, functionName: "setUpgradeCost", address: MANAGER,
    args: [BigInt(i + 1), toWei(UPGRADE[i])], label: `manager.setUpgradeCost(L${i + 1}->L${i + 2}, ${UPGRADE[i]})`,
  });
}
console.log("\n=== VERIFY ===");
const mgr = artifacts.ClashCardManager.abi, cards = artifacts.ClashCards.abi;
const r = async (addr, abi, fn, args) => publicClient.readContract({ address: addr, abi, functionName: fn, args });
console.log("manager.clashToken   :", await r(MANAGER, mgr, "clashToken"));
console.log("manager.clashCards   :", await r(MANAGER, mgr, "clashCards"));
console.log("manager.treasury     :", await r(MANAGER, mgr, "treasury"));
console.log("manager.cardTypeCount:", await r(MANAGER, mgr, "cardTypeCount"));
for (const t of [0, 1, 2]) console.log(`  chestCost(${t}) =`, (await r(MANAGER, mgr, "chestCosts", [BigInt(t)])) / 10n ** 18n);
for (const l of [1, 5, 9]) console.log(`  upgradeCost(L${l}) =`, (await r(MANAGER, mgr, "upgradeCosts", [BigInt(l - 1)])) / 10n ** 18n);
console.log("cards.hasRole(MINTER, new manager):", await r(CARDS, cards, "hasRole", [MINTER_ROLE, MANAGER]));
console.log("cards.hasRole(MINTER, OLD manager):", await r(CARDS, cards, "hasRole", [MINTER_ROLE, OLD_MANAGER]));
