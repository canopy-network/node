#!/usr/bin/env bash
# First-boot key generation. canopy's first start creates validator_key.json
# and then stops at an interactive keystore prompt when it has no TTY — so we
# run the node once with a timeout. Idempotent: skips if a key already exists.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f data/validator_key.json ]]; then
  echo "data/validator_key.json exists — skipping generation"
else
  echo "priming node (generates validator_key.json, ~15s)..."
  timeout 20 docker compose run --rm --no-deps node start >/dev/null 2>&1 || true
  [[ -f data/validator_key.json ]] || { echo "ERROR: key generation failed — check 'docker compose logs node'"; exit 1; }
  echo "validator key generated"
fi
echo "keys ready"
