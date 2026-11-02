#!/usr/bin/env bash
# build.sh — compile the contract artifacts for the Robinhood deployment.
#
#   REVISION=secure (default) -> repo HEAD (6dec5de): chest/pack L1-only guard
#   REVISION=parity           -> 7b0591b: byte-identical to the live Base deployment
#
set -euo pipefail
cd "$(dirname "$0")"

REVISION="${REVISION:-secure}"
CONTRACTS=/workspace/clash-onchain-contracts

if [ "$REVISION" = "parity" ]; then
  echo "== revision: parity (7b0591b, byte-identical to Base) =="
  git -C "$CONTRACTS" show 7b0591b:ClashOnchain_Remix.sol > ./ClashOnchain_Remix_parity.sol
  SOURCE_FILE=./ClashOnchain_Remix_parity.sol node compile.mjs
else
  echo "== revision: secure (repo HEAD, chest/pack L1-only guard) =="
  SOURCE_FILE="$CONTRACTS/ClashOnchain_Remix.sol" node compile.mjs
fi

echo "== reward claim (solc 0.8.34, osaka, OZ v5.6.1) =="
node compile-claim.mjs

echo
echo "== parity vs live Base deployment =="
node parity.mjs
