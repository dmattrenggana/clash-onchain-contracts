// withdraw-reward.mjs — sweep the whole $CLASH balance out of a ClashRewardClaim
// contract to its owner (the deployer EOA). The contract only allows the owner
// to move tokens, and withdrawTokens() transfers straight to owner().
import fs from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const account = privateKeyToAccount(process.env.BASE_DEPLOYER_KEY);
const transport = http(process.env.BASE_RPC_URL || "https://mainnet.base.org");
const publicClient = createPublicClient({ chain: base, transport });
const walletClient = createWalletClient({ chain: base, transport, account });

const CLAIM = process.env.CLAIM_ADDRESS;
const TOKEN = process.env.TOKEN_ADDRESS;
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const claimAbi = parseAbi([
  "function withdrawTokens(uint256 amount)",
  "function owner() view returns (address)",
  "function balanceOf(address) view returns (uint256)",
]);

const owner = await publicClient.readContract({ address: CLAIM, abi: claimAbi, functionName: "owner" });
const balance = await publicClient.readContract({ address: TOKEN, abi: erc20, functionName: "balanceOf", args: [CLAIM] });
console.log("claim   :", CLAIM);
console.log("owner   :", owner, owner.toLowerCase() === account.address.toLowerCase() ? "(= deployer ✓)" : "(≠ deployer ✗)");
console.log("balance :", formatUnits(balance, 18), "$CLASH");
if (balance === 0n) { console.log("nothing to withdraw"); process.exit(0); }

const hash = await walletClient.writeContract({
  address: CLAIM, abi: claimAbi, functionName: "withdrawTokens",
  args: [balance], chain: base,
});
const r = await publicClient.waitForTransactionReceipt({ hash });
if (r.status !== "success") throw new Error("withdraw failed");
console.log("tx      :", hash, "block", r.blockNumber, "gas", r.gasUsed);
console.log("after   : claim balance =", formatUnits(await publicClient.readContract({ address: TOKEN, abi: erc20, functionName: "balanceOf", args: [CLAIM] }), 18));
console.log("        owner  balance =", formatUnits(await publicClient.readContract({ address: TOKEN, abi: erc20, functionName: "balanceOf", args: [owner] }), 18));
