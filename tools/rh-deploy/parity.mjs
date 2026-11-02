// parity.mjs — compare the freshly compiled runtime bytecode with the live
// Base deployment. Any difference is a red flag for the Robinhood deployment.
//
// Usage: node parity.mjs

import fs from "node:fs";
import { createPublicClient, http } from "viem";
import { base } from "viem/chains";

const artifacts = JSON.parse(fs.readFileSync(new URL("./artifacts.json", import.meta.url), "utf8"));

const BASE = {
  ClashCards: "0xf93643759c9c62e0e2e70969e2397806be5cf609",
  ClashCardManager: "0x425894394a636a95dc5ed947df7ee63d93062682",
  ClashRewardClaim: "0x3226c06ea35f2149c62c92f019d3e18cb95b3f2e",
};

const rpc = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const client = createPublicClient({ chain: base, transport: http(rpc, { timeout: 60000 }) });

for (const [name, address] of Object.entries(BASE)) {
  const onchain = (await client.getBytecode({ address })).toLowerCase();
  const compiled = artifacts[name].deployedBytecode.toLowerCase();

  console.log(`\n=== ${name} (${address}) ===`);
  console.log(`  on-chain : ${(onchain.length - 2) / 2} B`);
  console.log(`  compiled : ${(compiled.length - 2) / 2} B`);

  if (onchain === compiled) {
    console.log("  -> IDENTICAL");
    continue;
  }

  // Strip the trailing metadata (CBOR + hash) to compare executable code only.
  const strip = (hex) => {
    const b = Buffer.from(hex.slice(2), "hex");
    const len = Number(BigInt("0x" + b.slice(b.length - 2).toString("hex")));
    return b.slice(0, b.length - 2 - len).toString("hex");
  };
  const a = strip(onchain);
  const b = strip(compiled);
  console.log(`  executable on-chain : ${a.length / 2} B`);
  console.log(`  executable compiled : ${b.length / 2} B`);

  // Locate the differing byte ranges.
  const n = Math.min(a.length, b.length);
  const diffs = [];
  let start = -1;
  for (let i = 0; i < n; i += 2) {
    if (a.slice(i, i + 2) !== b.slice(i, i + 2)) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      diffs.push([start, i]);
      start = -1;
    }
  }
  if (start >= 0) diffs.push([start, n]);
  console.log(`  differing ranges    : ${diffs.length}`);
  for (const [s, e] of diffs.slice(0, 20)) {
    console.log(
      `    @${s / 2} (len ${(e - s) / 2} B)  onchain=${a.slice(s, s + 66)}  compiled=${b.slice(s, s + 66)}`,
    );
  }
  if (diffs.length > 20) console.log(`    ... and ${diffs.length - 20} more`);
}
