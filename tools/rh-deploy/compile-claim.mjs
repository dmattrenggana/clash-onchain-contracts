// compile-claim.mjs — compile the ClashRewardClaim contract with the settings
// that produced the live Base deployment, then prove parity.
//
// Settings (recovered 2026-11-02 from the deployed Base bytecode):
//   solc 0.8.34 · optimizer DISABLED · NO via-ir · evm osaka · OZ v5.6.1
//
// Usage: node compile-claim.mjs

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const solc = require("solc-034");

const SRC = "/workspace/clash-onchain-contracts/src/ClashRewardClaim.sol";
const OZ_ROOT = path.join(import.meta.dirname, "node_modules/@openzeppelin/contracts");

function readOz(importPath) {
  // "@openzeppelin/contracts/token/ERC20/IERC20.sol" -> node_modules path
  const rel = importPath.replace("@openzeppelin/contracts/", "");
  return fs.readFileSync(path.join(OZ_ROOT, rel), "utf-8");
}

const source = fs.readFileSync(SRC, "utf-8");

// Collect every @openzeppelin import (transitively resolved by solc's import
// callback below).
const sources = { "src/ClashRewardClaim.sol": { content: source } };
const importCallback = (importPath) => {
  if (importPath.startsWith("@openzeppelin/contracts/")) {
    const key = "node_modules/" + importPath;
    if (!sources[key]) {
      sources[key] = { content: readOz(importPath) };
    }
    return { contents: sources[key].content };
  }
  return { error: "not found: " + importPath };
};

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: false, runs: 200 },
    viaIR: false,
    evmVersion: "osaka",
    outputSelection: {
      "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] },
    },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: importCallback }));
const errors = (out.errors || []).filter((e) => e.severity === "error");
if (errors.length) {
  for (const e of errors) console.error(e.formattedMessage);
  process.exit(1);
}
for (const e of out.errors || []) {
  if (e.severity !== "error") console.warn("WARN:", e.formattedMessage?.split("\n")[0]);
}

const art = {};
for (const contracts of Object.values(out.contracts || {})) {
  for (const [name, c] of Object.entries(contracts)) {
    art[name] = {
      abi: c.abi,
      bytecode: "0x" + c.evm.bytecode.object,
      deployedBytecode: "0x" + c.evm.deployedBytecode.object,
    };
    console.log(
      `${name.padEnd(20)} init ${(art[name].bytecode.length - 2) / 2} B` +
        `  runtime ${(art[name].deployedBytecode.length - 2) / 2} B`,
    );
  }
}

const existing = fs.existsSync("artifacts.json")
  ? JSON.parse(fs.readFileSync("artifacts.json", "utf8"))
  : {};
Object.assign(existing, art);
fs.writeFileSync("artifacts.json", JSON.stringify(existing, null, 2));
console.log("\nmerged into artifacts.json");
