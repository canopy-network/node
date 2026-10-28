#!/usr/bin/env bash
# Restore chain(s) from snapshots.
#
# Single-chain mode (used by scripts/add-nested-chain.sh): active whenever
# SNAPSHOT_SERVICE is set. Restores exactly that one service. Overrides:
#   SNAPSHOT_URL           snapshot archive to download   (required)
#   SNAPSHOT_DATA_DIR      db dir to wipe & extract into  (default: data/canopy)
#   SNAPSHOT_SERVICE       compose service to stop/start  (default: node)
#   SNAPSHOT_COMPOSE_FILES extra `docker compose` -f args (default: none)
#
# Multi-chain mode (default, i.e. `make snapshot`): restores the root chain
# (SNAPSHOT_URL -> data/canopy, service "node") plus EVERY added nested chain
# (each docker-compose.chain-<id>.yml -> data/chain-<id>/<db>, service
# "chain-<id>", snapshot from $SNAPSHOT_BASE/<id>). All snapshots download
# concurrently; services are then stopped, extracted, and started together.
set -euo pipefail

SNAPSHOT_BASE="${SNAPSHOT_BASE:-https://public-snapshots.app.canopynetwork.org/chain}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# download_snapshot URL OUTFILE [extra wget args...]
download_snapshot() {
	wget "${@:3}" -O "$2" "$1"
}

# extract_into TARBALL DATA_DIR [LABEL]  (wipes DATA_DIR first; keeps only the db
# subdir, so keystore.json/validator_key.json at the chain's data-dir root are
# untouched). Shows a % progress bar via `pv` when installed, else a live file
# count (install `pv` for the percentage bar: sudo apt-get install -y pv).
extract_into() {
	local tarball="$1" data_dir="$2" label="${3:-snapshot}"
	rm -rf "$data_dir"
	mkdir -p "$data_dir"
	if command -v pv >/dev/null 2>&1; then
		pv -N "$label" "$tarball" | tar -xzf - -C "$data_dir/"
	else
		tar -xzvf "$tarball" -C "$data_dir/" 2>&1 \
			| awk -v l="$label" '{printf "\r  [%s] %d files extracted", l, NR} END {print ""}'
	fi
}

# ---- single-chain mode (scripts/add-nested-chain.sh) -----------------------
if [[ -n "${SNAPSHOT_SERVICE:-}" ]]; then
	: "${SNAPSHOT_URL:?SNAPSHOT_URL is required}"
	DATA_DIR="${SNAPSHOT_DATA_DIR:-data/canopy}"
	read -ra COMPOSE_FILES <<< "${SNAPSHOT_COMPOSE_FILES:-}"
	compose() { docker compose ${COMPOSE_FILES[@]+"${COMPOSE_FILES[@]}"} "$@"; }

	if [[ -d "$DATA_DIR" && -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
		echo "This wipes $DATA_DIR and restores from:"
		echo "  $SNAPSHOT_URL"
		read -rp "Continue? [y/N]: " ok
		[[ "$ok" == [Yy] ]] || exit 0
	fi

	# Stop the service if it happens to be running, so wiping its db dir is safe.
	# We deliberately do NOT start it afterwards -- `make up` starts the chain.
	compose stop "$SNAPSHOT_SERVICE" || true
	tmp="snapshot.$SNAPSHOT_SERVICE.tar.gz"
	echo "==== downloading snapshot ($SNAPSHOT_SERVICE) ===="
	download_snapshot "$SNAPSHOT_URL" "$tmp"
	echo "==== extracting snapshot ($SNAPSHOT_SERVICE) ===="
	extract_into "$tmp" "$DATA_DIR" "$SNAPSHOT_SERVICE"
	rm -f "$tmp"
	echo "==== $SNAPSHOT_SERVICE snapshot restored (not started; run 'make up') ===="
	exit 0
fi

# ---- multi-chain mode (default `make snapshot`) ----------------------------
: "${SNAPSHOT_URL:?SNAPSHOT_URL is required (root chain snapshot; see .env)}"

# Build parallel arrays of restore targets: root chain + each nested chain.
urls=() dirs=() services=() tmps=()
urls+=("$SNAPSHOT_URL");  dirs+=("data/canopy"); services+=("node"); tmps+=("snapshot.node.tar.gz")

compose_flags=(-f docker-compose.yml)
shopt -s nullglob
for f in docker-compose.chain-*.yml; do
	id="${f#docker-compose.chain-}"; id="${id%.yml}"
	[[ "$id" =~ ^[0-9]+$ ]] || continue
	compose_flags+=(-f "$f")
	db_name="canopy"
	if [[ -f "data/chain-$id/config.json" ]]; then
		db_name="$(jq -r '.dbName // "canopy"' "data/chain-$id/config.json" 2>/dev/null || echo canopy)"
	fi
	urls+=("$SNAPSHOT_BASE/$id")
	dirs+=("data/chain-$id/$db_name")
	services+=("chain-$id")
	tmps+=("snapshot.chain-$id.tar.gz")
done
shopt -u nullglob

echo "Will restore ${#services[@]} chain(s) from snapshots:"
for i in "${!services[@]}"; do
	printf '  - %-10s %s -> %s\n' "${services[$i]}" "${urls[$i]}" "${dirs[$i]}"
done
read -rp "This wipes the db dirs above. Continue? [y/N]: " ok
[[ "$ok" == [Yy] ]] || exit 0

# Stop everything first (ignore services that aren't running yet).
docker compose "${compose_flags[@]}" stop "${services[@]}" || true

# ---- concurrent downloads (with per-chain progress) ------------------------
# `dot:giga` prints progress as whole lines (percentage + speed) rather than a
# carriage-return bar, so prefixing with the chain name stays readable even when
# several downloads interleave. The subshell + PIPESTATUS makes `wait` below see
# wget's real exit status (not sed's).
echo "==== downloading ${#urls[@]} snapshots concurrently ===="
pids=()
for i in "${!urls[@]}"; do
	(
		wget --progress=dot:giga -O "${tmps[$i]}" "${urls[$i]}" 2>&1 \
			| sed -u "s/^/[${services[$i]}] /"
		exit "${PIPESTATUS[0]}"
	) &
	pids+=("$!")
done
fail=0
for i in "${!pids[@]}"; do
	if ! wait "${pids[$i]}"; then
		echo "error: download failed for ${services[$i]} (${urls[$i]})" >&2
		fail=1
	fi
done
if [[ "$fail" -ne 0 ]]; then
	rm -f "${tmps[@]}"
	echo "aborting: one or more snapshot downloads failed." >&2
	exit 1
fi
echo "==== all snapshots downloaded ===="

# ---- extract (sequential, clean output) ------------------------------------
for i in "${!urls[@]}"; do
	echo "==== extracting ${services[$i]} snapshot ===="
	extract_into "${tmps[$i]}" "${dirs[$i]}" "${services[$i]}"
	rm -f "${tmps[$i]}"
done

# ---- start all chains ------------------------------------------------------
echo "==== starting all chains ===="
docker compose "${compose_flags[@]}" up -d "${services[@]}"
echo "==== done: restored & started ${services[*]} ===="
