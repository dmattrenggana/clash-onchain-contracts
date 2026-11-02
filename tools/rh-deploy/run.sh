#!/usr/bin/env bash
# run.sh — deploy the Clash contracts to Robinhood Chain.
#
# The deployer private key is read from a FILE (never from the command line,
# so it does not end up in shell history or in a process listing):
#   echo -n "0x..." > /workspace/.rh_deployer_key   (chmod 600)
#
# Usage:
#   ./run.sh                 # real deploy
#   DRY_RUN=1 ./run.sh       # print the plan, send nothing
#   REVISION=parity ./run.sh # byte-identical to the Base deployment
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
. ./.env.deploy
set +a

KEY_FILE="${RH_KEY_FILE:-/workspace/.rh_deployer_key}"
if [ ! -f "$KEY_FILE" ]; then
  echo "Missing $KEY_FILE"
  echo "Write the deployer private key there (single line, no quotes):"
  echo "  printf '%s' '0xYOURKEY' > $KEY_FILE && chmod 600 $KEY_FILE"
  exit 1
fi
export RH_DEPLOYER_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"

node deploy.mjs
