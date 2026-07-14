#!/usr/bin/env bash
# Restore the node from the latest mainnet snapshot.
set -euo pipefail
: "${SNAPSHOT_URL:?SNAPSHOT_URL is required}"

echo "This wipes data/canopy and restores from:"
echo "  $SNAPSHOT_URL"
read -rp "Continue? [y/N]: " ok
[[ "${ok,,}" == "y" ]] || exit 0

docker compose stop node || true

echo "==== downloading snapshot ===="
wget -O snapshot.tar.gz "$SNAPSHOT_URL"
rm -rf data/canopy
mkdir -p data/canopy
echo "==== extracting snapshot ===="
tar -xzvf snapshot.tar.gz -C data/canopy/
rm -f snapshot.tar.gz
echo "==== chain data restored ===="

docker compose up -d node
echo "==== node restarted from snapshot ===="
