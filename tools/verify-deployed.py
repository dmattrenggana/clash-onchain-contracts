#!/usr/bin/env python3
"""
Verify that the contract sources in this repository compile to the EXACT bytecode
that is deployed on-chain.

Usage:
    python3 tools/verify-deployed.py [--rpc https://mainnet.base.org]

For each contract the script
  1. compiles the repository source with the exact compiler settings that were used
     for the original deployment,
  2. fetches the runtime bytecode from the chain,
  3. compares them.

Two kinds of difference are tolerated and reported separately:
  * immutable placeholders - the compiler emits zeroed 32-byte slots in the build
    artifact and the real address / hash is patched in at construction time.
  * the trailing metadata hash - it covers the source file paths and the literal
    source text, so it changes whenever the file is renamed or a comment is edited.
    The executable code in front of it must still match byte for byte.

Exit code 0 when every contract matches, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DEFAULT_RPC = "https://mainnet.base.org"

# solc versions are looked up in the foundry svm store first, then on PATH.
SVM_DIRS = [
    Path.home() / ".local/share/svm",
    Path.home() / ".svm",
    Path("/workspace/.home/.local/share/svm"),
]

# name -> (source file, contract name, solc version, settings)
CONTRACTS = [
    {
        "name": "ClashCards",
        "address": "0xF93643759c9C62E0e2E70969E2397806bE5CF609",
        "file": "ClashOnchain_Remix.sol",
        "contract": "ClashCards",
        "solc": "0.8.20",
        "settings": {"optimizer": {"enabled": True, "runs": 200}, "evmVersion": "shanghai"},
    },
    {
        "name": "ClashCardManager",
        "address": "0x425894394a636A95dc5Ed947dF7eE63D93062682",
        "file": "ClashOnchain_Remix.sol",
        "contract": "ClashCardManager",
        "solc": "0.8.20",
        "settings": {"optimizer": {"enabled": True, "runs": 200}, "evmVersion": "shanghai"},
        # The deployed manager is revision 7b0591b. The repository working tree is
        # revision 6dec5de, which adds the L1-only guard to buyPack/buyChest
        # ("Chest: L1 only"). That guard is NOT live on chain, so this contract
        # is expected to report a mismatch until the manager is redeployed.
        "note": "repo revision 6dec5de (has the L1-only guard) vs deployed 7b0591b "
                "(guard missing on chain) - redeploy the manager to close this gap",
    },
    {
        "name": "ClashRewardClaim",
        "address": "0x3226c06Ea35F2149C62c92f019d3E18cB95b3F2E",
        "file": "src/ClashRewardClaim.sol",
        "contract": "ClashRewardClaim",
        "solc": "0.8.34",
        "settings": {"optimizer": {"enabled": False, "runs": 200}, "evmVersion": "osaka"},
    },
]

# $CLASH is a Doppler DERC20 launch; its source lives in the Doppler launchpad
# tree and is intentionally not vendored here.
EXTERNAL = [
    {
        "name": "$CLASH (DERC20)",
        "address": "0xf3C66dc3afF9d04CbCEAfA8f9dE762a39EE0BBA3",
        "note": "Doppler DERC20 launch - source lives in the Doppler launchpad tree, "
                "not vendored in this repo. Compiled source verified identical to the "
                "deployed bytecode (solc 0.8.26, optimizer runs=0, viaIR, cancun).",
    }
]


def solc_path(version: str) -> str | None:
    for d in SVM_DIRS:
        p = d / version / f"solc-{version}"
        if p.exists():
            return str(p)
    found = shutil.which(f"solc-{version}")
    return found


def rpc_call(rpc: str, method: str, params: list) -> str:
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1})
    out = subprocess.run(
        ["curl", "-s", "--max-time", "30", "-X", "POST", rpc,
         "-H", "Content-Type: application/json", "-d", payload],
        capture_output=True, text=True,
    ).stdout
    return json.loads(out)["result"]


def onchain_code(rpc: str, address: str) -> bytes:
    return bytes.fromhex(rpc_call(rpc, "eth_getCode", [address, "latest"])[2:])


def compile_contract(spec: dict) -> bytes:
    solc = solc_path(spec["solc"])
    if not solc:
        raise RuntimeError(
            f"solc {spec['solc']} not found - install foundry (foundryup) so the "
            f"version manager can download it"
        )
    source = REPO / spec["file"]
    if not source.exists():
        raise FileNotFoundError(f"{spec['file']} not found in repo")

    settings = dict(spec["settings"])
    settings["outputSelection"] = {"*": {"*": ["evm.deployedBytecode.object"]}}
    remappings = []
    for mapping in ("@openzeppelin/=lib/openzeppelin-contracts/",
                    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"):
        remappings.append(mapping)
    settings["remappings"] = remappings

    std_input = {
        "language": "Solidity",
        "sources": {spec["file"]: {"content": source.read_text()}},
        "settings": settings,
    }
    proc = subprocess.run([solc, "--standard-json"], input=json.dumps(std_input),
                          capture_output=True, text=True)
    out = json.loads(proc.stdout)
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors:
        raise RuntimeError(errors[0].get("formattedMessage", errors[0].get("message", "compile failed")))

    contracts = out.get("contracts", {})
    # standard-json keys the source by the path used in the input
    for path, by_name in contracts.items():
        if spec["contract"] in by_name:
            return bytes.fromhex(by_name[spec["contract"]]["evm"]["deployedBytecode"]["object"])
    raise RuntimeError(f"contract {spec['contract']} not found in compile output")


def strip_metadata(code: bytes) -> bytes:
    """Drop the trailing CBOR metadata (length-prefixed) from runtime bytecode."""
    if len(code) < 3:
        return code
    n = int.from_bytes(code[-2:], "big")
    if n <= len(code) - 2:
        return code[: len(code) - n - 2]
    return code


def diff_ranges(a: bytes, b: bytes) -> list[tuple[int, int]]:
    ranges = []
    i = 0
    while i < min(len(a), len(b)):
        if a[i] != b[i]:
            j = i
            while j < min(len(a), len(b)) and a[j] != b[j]:
                j += 1
            ranges.append((i, j))
            i = j
        else:
            i += 1
    return ranges


def compare(name: str, local: bytes, remote: bytes) -> bool:
    print(f"\n=== {name} ===")
    print(f"  local build : {len(local)} bytes")
    print(f"  on-chain    : {len(remote)} bytes")

    if local == remote:
        print("  RESULT: IDENTICAL (byte for byte, including metadata)")
        return True

    if len(local) != len(remote):
        print(f"  RESULT: DIFFERENT LENGTH -> the source does not match the deployment")
        return False

    ranges = diff_ranges(local, remote)
    code_local = strip_metadata(local)
    code_remote = strip_metadata(remote)
    code_match = code_local == code_remote

    print(f"  differing ranges: {len(ranges)} ({sum(b - a for a, b in ranges)} bytes)")
    only_immutables = all(set(local[a:b]) == {0} for a, b in ranges)

    for a, b in ranges[:12]:
        tag = "immutable placeholder" if set(local[a:b]) == {0} else "value"
        print(f"    offset {a:>6}-{b:<6} local=0x{local[a:b].hex()} onchain=0x{remote[a:b].hex()}  ({tag})")

    if code_match:
        if only_immutables:
            print("  RESULT: MATCH - executable code identical, differences are constructor immutables")
        else:
            print("  RESULT: MATCH - executable code identical, differences are in the metadata hash")
        return True

    print("  RESULT: MISMATCH - executable code differs, the source is NOT the deployed code")
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=DEFAULT_RPC)
    args = ap.parse_args()

    print(f"Verifying repository sources against {args.rpc}")
    ok = True

    for spec in CONTRACTS:
        try:
            local = compile_contract(spec)
            remote = onchain_code(args.rpc, spec["address"])
        except Exception as exc:  # noqa: BLE001
            print(f"\n=== {spec['name']} ===\n  ERROR: {exc}")
            ok = False
            continue
        match = compare(spec["name"], local, remote)
        if not match and spec.get("note"):
            print(f"  NOTE: {spec['note']}")
        ok = match and ok

    print("\n=== external contracts (source not vendored here) ===")
    for spec in EXTERNAL:
        print(f"  {spec['name']} @ {spec['address']}\n    {spec['note']}")

    print("\n" + ("ALL CONTRACTS MATCH THE DEPLOYED BYTECODE" if ok else
                  "VERIFICATION FAILED - at least one contract differs from its deployment"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
