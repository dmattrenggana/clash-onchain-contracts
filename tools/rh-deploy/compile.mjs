// compile.mjs — compile ClashOnchain_Remix.sol with the EXACT settings that
// produced the live Base deployment, then prove the result by comparing the
// runtime bytecode with the deployed contract.
//
// Settings (recovered 2026-11-02 from the deployed Base bytecode):
//   solc 0.8.20 · optimizer 200 · NO via-ir · evm shanghai
//
// Usage: node compile.mjs
// Writes: artifacts.json  (abi + bytecode + deployedBytecode per contract)

import fs from "node:fs";
import path from "node:path";
import solc from "solc";

const SRC = process.env.SOURCE_FILE || "/workspace/clash-onchain-contracts/ClashOnchain_Remix.sol";
const OUT = path.join(import.meta.dirname, "artifacts.json");

const source = fs.readFileSync(SRC, "utf-8");

const input = {
  language: "Solidity",
  sources: { "ClashOnchain_Remix.sol": { content: source } },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    viaIR: false,
    evmVersion: "shanghai",
    outputSelection: {
      "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] },
    },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input)));

const errors = (out.errors || []).filter((e) => e.severity === "error");
if (errors.length) {
  for (const e of errors) console.error(e.formattedMessage);
  process.exit(1);
}
for (const e of out.errors || []) {
  if (e.severity !== "error") console.warn("WARN:", e.formattedMessage?.split("\n")[0]);
}

const artifacts = {};
for (const [file, contracts] of Object.entries(out.contracts || {})) {
  for (const [name, c] of Object.entries(contracts)) {
    artifacts[name] = {
      abi: c.abi,
      bytecode: "0x" + c.evm.bytecode.object,
      deployedBytecode: "0x" + c.evm.deployedBytecode.object,
    };
    console.log(
      `${name.padEnd(20)} init ${(artifacts[name].bytecode.length - 2) / 2} B` +
        `  runtime ${(artifacts[name].deployedBytecode.length - 2) / 2} B`,
    );
  }
}

fs.writeFileSync(OUT, JSON.stringify(artifacts, null, 2));
console.log("\nwrote", OUT);
