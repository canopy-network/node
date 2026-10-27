#!/usr/bin/env bash
# Restore a chain from a snapshot.
#
# Defaults restore the root chain (data/canopy, service "node"). The nested-chain
# helper (scripts/add-nested-chain.sh) reuses this script by overriding:
#   SNAPSHOT_URL           the snapshot archive to download (required)
#   SNAPSHOT_DATA_DIR      db dir to wipe & extract into   (default: data/canopy)
#   SNAPSHOT_SERVICE       compose service to stop/start    (default: node)
#   SNAPSHOT_COMPOSE_FILES extra `docker compose` -f args   (default: none)
set -euo pipefail
: "${SNAPSHOT_URL:?SNAPSHOT_URL is required}"

DATA_DIR="${SNAPSHOT_DATA_DIR:-data/canopy}"
SERVICE="${SNAPSHOT_SERVICE:-node}"
read -ra COMPOSE_FILES <<< "${SNAPSHOT_COMPOSE_FILES:-}"
compose() { docker compose ${COMPOSE_FILES[@]+"${COMPOSE_FILES[@]}"} "$@"; }

if [[ -d "$DATA_DIR" && -n "$(ls -A "$DATA_DIR")" ]]; then
	echo "This wipes $DATA_DIR and restores from:"
	echo "  $SNAPSHOT_URL"
	read -rp "Continue? [y/N]: " ok
	[[ "$ok" == [Yy] ]] || exit 0
else
	echo "$DATA_DIR is missing or empty; skipping wipe confirmation."
	echo "Restoring from:"
	echo "  $SNAPSHOT_URL"
fi

compose stop "$SERVICE" || true

echo "==== downloading snapshot ===="
wget -O snapshot.tar.gz "$SNAPSHOT_URL"
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
echo "==== extracting snapshot ===="
if command -v pv >/dev/null 2>&1; then
	pv snapshot.tar.gz | tar -xzf - -C "$DATA_DIR/"
else
	# no pv, fall back to a running file count.
	tar -xzvf snapshot.tar.gz -C "$DATA_DIR/" 2>&1 |
		awk '{printf "\r  %d files extracted", NR} END {print ""}'
fi
rm -f snapshot.tar.gz
echo "==== chain data restored ===="

compose up -d "$SERVICE"
echo "==== node restarted from snapshot ===="
