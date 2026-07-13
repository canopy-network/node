#!/usr/bin/env bash
# Restore the node from the latest mainnet snapshot.
# Explicit + guarded: stops the node, replaces only data/canopy/.
set -euo pipefail
cd "$(dirname "$0")/.."
# .env is a docker-compose env file, NOT shell syntax (hashes contain $) —
# never `source` it; extract the one value we need.
SNAPSHOT_URL="$(grep -E '^SNAPSHOT_URL=' .env | head -1 | cut -d= -f2-)"
[[ -n "$SNAPSHOT_URL" ]] || { echo "ERROR: SNAPSHOT_URL is not set in .env"; exit 1; }

echo "This wipes data/canopy and restores from:"
echo "  $SNAPSHOT_URL"
read -rp "Continue? [y/N]: " ok
[[ "${ok,,}" == "y" ]] || exit 0

docker compose stop node || true

echo "downloading snapshot..."
wget -q -O snapshot.tar.gz "$SNAPSHOT_URL"
rm -rf data/canopy
mkdir -p data/canopy
tar -xzf snapshot.tar.gz -C data/canopy/
rm -f snapshot.tar.gz
echo "chain data restored"

docker compose up -d node
echo "node restarted from snapshot"
