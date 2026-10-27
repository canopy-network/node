#!/usr/bin/env bash
# Set up and (optionally) start a nested chain alongside this node's root chain.
#
# Fetches the chain's genesis, config and (optional) plugin files from the
# Canopy chain-data API, reuses this node's keystore/validator_key, and writes a
# per-chain docker-compose file. Depending on the mode it then starts the chain,
# either from genesis or from its snapshot.
#
# Usage: ./scripts/add-nested-chain.sh <chain-id> [files|snapshot]
#   files     (default) only assemble the files; don't start anything.
#             Start it afterwards with `make up` (or `make node-up`), which picks
#             up every docker-compose.chain-*.yml automatically.
#   snapshot  assemble if needed, then restore its snapshot and start the chain.
#
# Via make:
#   make add-nested-chain           CHAIN_ID=29   # assemble files only (no start)
#   make add-nested-chain-snapshot  CHAIN_ID=29   # assemble + restore snapshot + start
#   make up                                        # start the root chain + every added nested chain
set -euo pipefail

# ---- configuration (overridable via env) ----------------------------------
API_BASE="${API_BASE:-https://api.app.canopynetwork.org/api/v1}"
# Nested-chain snapshots live at <base>/<chain-id>. The root chain keeps its own
# SNAPSHOT_URL (see scripts/snapshot.sh / .env) and is intentionally untouched.
SNAPSHOT_BASE="${SNAPSHOT_BASE:-https://public-snapshots.app.canopynetwork.org/chain}"

# ---- resolve repo layout --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
DATA_DIR="$REPO_ROOT/data"

die() { echo "error: $*" >&2; exit 1; }

# ---- validate arguments & tooling -----------------------------------------
CHAIN_ID="${1:-}"
MODE="${2:-files}"
[[ -n "$CHAIN_ID" ]] || die "CHAIN_ID is required (usage: make add-nested-chain CHAIN_ID=29)"
[[ "$CHAIN_ID" =~ ^[0-9]+$ ]] || die "CHAIN_ID must be numeric, got: '$CHAIN_ID'"
[[ "$CHAIN_ID" != "1" ]] || die "chain 1 is the root chain of this node, not a nested chain"
case "$MODE" in files|snapshot) ;; *) die "unknown mode '$MODE' (expected: files, snapshot)";; esac

for tool in curl jq tar docker; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

CHAIN_DIR="$DATA_DIR/chain-$CHAIN_ID"
COMPOSE_FILE="$REPO_ROOT/docker-compose.chain-$CHAIN_ID.yml"
COMPOSE_BASENAME="docker-compose.chain-$CHAIN_ID.yml"

# ---- assemble the chain's files (idempotent) ------------------------------
# Fetches genesis/config/plugin-files, copies the shared node identity, and
# writes the per-chain compose file. No snapshot, no container start.
assemble_files() {
	# keystore.json + validator_key.json must already exist and be shared
	# verbatim across every chain (same node identity). Generate them once with
	# `make gen-key`.
	local keystore_src="$CONFIG_DIR/keystore.json"
	local valkey_src="$CONFIG_DIR/validator_key.json"
	[[ -f "$keystore_src" ]] || die "missing $keystore_src -- run 'make gen-key' first"
	[[ -f "$valkey_src" ]] || die "missing $valkey_src -- run 'make gen-key' first"
	[[ -f "$CONFIG_DIR/config.json" ]] || die "missing $CONFIG_DIR/config.json"

	# Build everything in a temp dir, promote atomically on success.
	local tmp_dir="$DATA_DIR/.chain-$CHAIN_ID.partial"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	rm -rf "$tmp_dir"
	mkdir -p "$tmp_dir"

	# curl helper: writes body to $2, returns the HTTP status code on stdout.
	http_get() { curl -sS -L -o "$2" -w '%{http_code}' "$1"; }

	local code
	# ---- genesis.json (every chain has it) --------------------------------
	echo "==== fetching genesis (chain $CHAIN_ID) ===="
	code="$(http_get "$API_BASE/chains/$CHAIN_ID/genesis" "$tmp_dir/genesis.resp.json")" \
		|| die "network failure fetching genesis"
	[[ "$code" == "200" ]] || die "genesis fetch returned HTTP $code for chain $CHAIN_ID"
	jq -e '.data.genesis' "$tmp_dir/genesis.resp.json" >/dev/null \
		|| die "unexpected genesis response shape (missing .data.genesis)"
	jq '.data.genesis' "$tmp_dir/genesis.resp.json" >"$tmp_dir/genesis.json"
	rm -f "$tmp_dir/genesis.resp.json"

	# ---- config.json (every chain has it) ---------------------------------
	echo "==== fetching config (chain $CHAIN_ID) ===="
	code="$(http_get "$API_BASE/chains/$CHAIN_ID/config" "$tmp_dir/config.resp.json")" \
		|| die "network failure fetching config"
	[[ "$code" == "200" ]] || die "config fetch returned HTTP $code for chain $CHAIN_ID"
	jq -e '.data.config' "$tmp_dir/config.resp.json" >/dev/null \
		|| die "unexpected config response shape (missing .data.config)"

	# Use the launchpad's config.json verbatim (including its rootChain entry);
	# we no longer rewrite rootChain to point at this node's local root chain.
	jq '.data.config' "$tmp_dir/config.resp.json" >"$tmp_dir/config.json"

	# Container-internal data dir (/root/.canopy) and the P2P port; both come
	# straight from the served config so we stay in lockstep with it.
	local data_dir_path p2p_port db_name plugin_lang image
	data_dir_path="$(jq -r '.data.config.dataDirPath // "/root/.canopy"' "$tmp_dir/config.resp.json")"
	p2p_port="$(jq -r '.data.p2pPort // (.data.config.listenAddress | split(":") | last)' "$tmp_dir/config.resp.json")"
	[[ "$p2p_port" =~ ^[0-9]+$ ]] || die "could not determine P2P port for chain $CHAIN_ID"

	# Image is chosen by the chain's plugin language (the base node image does
	# not carry the plugin runtime). Mirrors the canopy-plugin-<lang> images the
	# platform builds; `go` is the safe default used for unknown/empty values.
	plugin_lang="$(jq -r '.data.config.plugin // "" | ascii_downcase' "$tmp_dir/config.resp.json")"
	case "$plugin_lang" in
		go|python|kotlin|csharp|typescript) image="canopynetwork/canopy-plugin-$plugin_lang:latest" ;;
		*) image="canopynetwork/canopy-plugin-go:latest" ;;
	esac
	echo "Plugin: ${plugin_lang:-<none>} -> image $image"
	rm -f "$tmp_dir/config.resp.json"

	# ---- plugin files (optional: 404 is normal) ---------------------------
	# plugin_env_pairs  -> KEY=value lines, documented in .env.example
	# plugin_env_compose-> compose "environment:" lines referencing ${KEY} so the
	#                      operator sets the actual values in .env.
	local plugin_env_pairs="" plugin_env_compose=""
	echo "==== fetching plugin files (chain $CHAIN_ID) ===="
	code="$(http_get "$API_BASE/chains/$CHAIN_ID/plugin-files" "$tmp_dir/plugin.resp.json")" \
		|| die "network failure fetching plugin files"
	case "$code" in
		200)
			# Write each file to its containerPath, mapped into the chain's data
			# dir (containerPath is absolute under dataDirPath -> CHAIN_DIR).
			local count i cpath rel dest kv key
			count="$(jq '.data.files | length' "$tmp_dir/plugin.resp.json")"
			for i in $(seq 0 $((count - 1))); do
				cpath="$(jq -r ".data.files[$i].containerPath" "$tmp_dir/plugin.resp.json")"
				rel="${cpath#"$data_dir_path"/}"
				[[ "$rel" != "$cpath" ]] || die "plugin file containerPath '$cpath' is not under dataDirPath '$data_dir_path'"
				dest="$tmp_dir/$rel"
				mkdir -p "$(dirname "$dest")"
				jq -r ".data.files[$i].content" "$tmp_dir/plugin.resp.json" >"$dest"
				echo "  wrote plugin file: $rel"
			done
			# The env the plugin needs to find those files. We document the keys
			# (with the API's values) in .env.example and reference them from the
			# compose file, so the operator owns the real values in .env.
			while IFS= read -r kv; do
				[[ -n "$kv" ]] || continue
				key="${kv%%=*}"
				plugin_env_pairs+="$kv"$'\n'
				plugin_env_compose+="      $key: \"\${$key}\""$'\n'
			done < <(jq -r '.data.env // {} | to_entries[] | "\(.key)=\(.value)"' "$tmp_dir/plugin.resp.json")
			;;
		404)
			echo "  chain $CHAIN_ID has no plugin files (404) -- skipping."
			;;
		*)
			die "plugin-files fetch returned HTTP $code for chain $CHAIN_ID"
			;;
	esac
	rm -f "$tmp_dir/plugin.resp.json"

	# ---- shared node identity (byte-identical across all chains) -----------
	echo "==== copying shared keystore + validator_key ===="
	cp "$keystore_src" "$tmp_dir/keystore.json"
	cp "$valkey_src" "$tmp_dir/validator_key.json"

	# Empty db dir so a from-genesis start and a snapshot restore have a home.
	# The snapshot flow (scripts/snapshot.sh) only ever touches this subdir, so
	# keystore.json/validator_key.json at the data dir root are never clobbered.
	db_name="$(jq -r '.dbName // "canopy"' "$tmp_dir/config.json")"
	mkdir -p "$tmp_dir/$db_name"

	# ---- promote the staged dir atomically --------------------------------
	mv "$tmp_dir" "$CHAIN_DIR"
	trap - EXIT
	echo "==== data/chain-$CHAIN_ID is ready ===="

	# ---- generate the per-chain compose file ------------------------------
	# A dedicated service joined to this stack's default network, so it resolves
	# the root chain container by name. Only the P2P port is published.
	{
		echo "# Generated by scripts/add-nested-chain.sh for chain $CHAIN_ID. Do not edit by hand."
		echo "services:"
		echo "  chain-$CHAIN_ID:"
		echo "    image: $image"
		echo "    container_name: chain-$CHAIN_ID"
		echo "    restart: unless-stopped"
		echo "    command: [\"start\", \"--external-address\", \"\${DOMAIN:-localhost}\"]"
		if [[ -n "$plugin_env_compose" ]]; then
			echo "    environment:"
			printf '%s' "$plugin_env_compose"
		fi
		echo "    ports:"
		echo "      - \"$p2p_port:$p2p_port\" # TCP P2P"
		echo "    volumes:"
		echo "      - ./data/chain-$CHAIN_ID:/root/.canopy"
		echo "    deploy:"
		echo "      resources:"
		echo "        limits:"
		echo "          memory: 4G"
		echo "          cpus: \"2.0\""
	} >"$COMPOSE_FILE"
	echo "Wrote $COMPOSE_BASENAME"

	# ---- document the plugin env in .env.example --------------------------
	if [[ -n "$plugin_env_pairs" ]]; then
		ensure_env_example_keys "$plugin_env_pairs"
	fi
}

# ---- document plugin env keys in .env.example (dedup by key) ---------------
ensure_env_example_keys() {
	local pairs="$1" env_example="$REPO_ROOT/.env.example" key line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		key="${line%%=*}"
		grep -qE "^${key}=" "$env_example" 2>/dev/null && continue
		grep -q '^# ---- nested chain plugin env' "$env_example" 2>/dev/null \
			|| printf '\n# ---- nested chain plugin env (used by docker-compose.chain-*.yml) ----\n' >>"$env_example"
		printf '%s\n' "$line" >>"$env_example"
		echo "  documented $key in .env.example"
	done <<< "$pairs"
}

# ---- prompt the operator to set any plugin env not yet in .env -------------
warn_missing_env() {
	local env_file="$REPO_ROOT/.env" env_example="$REPO_ROOT/.env.example"
	local keys key line missing=()
	# `grep` exits 1 when a plugin-less chain's compose has no ${VAR} refs; under
	# `set -o pipefail` that would abort the script, so swallow it with `|| true`.
	keys="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$COMPOSE_FILE" 2>/dev/null | sed -E 's/[${}]//g' | sort -u || true)"
	for key in $keys; do
		if [[ -f "$env_file" ]] && grep -qE "^${key}=" "$env_file"; then continue; fi
		missing+=("$key")
	done
	[[ ${#missing[@]} -gt 0 ]] || return 0
	echo
	echo ">> ACTION REQUIRED: chain $CHAIN_ID's plugin needs these variables in your .env:"
	for key in "${missing[@]}"; do
		line="$(grep -E "^${key}=" "$env_example" 2>/dev/null | head -1 || true)"
		echo "     ${line:-$key=<value>}"
	done
	if [[ -f "$env_file" ]]; then
		echo "   Add the line(s) above to $(basename "$env_file") before starting the chain."
	else
		echo "   Run 'cp .env.example .env' (it now contains them) or add the line(s) to a new .env."
	fi
	echo
}

# ---- warn (don't fail) if the root chain isn't running --------------------
warn_if_root_down() {
	if ! docker ps --format '{{.Names}}' | grep -qx node; then
		echo "note: the root chain container 'node' is not running -- start it with 'make up'."
		echo "      The nested chain will keep retrying until the root chain is reachable."
	fi
}

# ---- obtain the files ------------------------------------------------------
if [[ -d "$CHAIN_DIR" ]]; then
	echo "using existing data/chain-$CHAIN_ID (not re-fetching)."
	if [[ "$MODE" == "files" ]]; then
		warn_missing_env
		echo "To recreate it: remove data/chain-$CHAIN_ID and $COMPOSE_BASENAME first, then re-run."
		exit 0
	fi
	[[ -f "$COMPOSE_FILE" ]] || die "data/chain-$CHAIN_ID exists but $COMPOSE_BASENAME is missing; remove data/chain-$CHAIN_ID and re-run 'make add-nested-chain CHAIN_ID=$CHAIN_ID'"
else
	assemble_files
fi

# ---- act on the chosen mode -----------------------------------------------
case "$MODE" in
	files)
		warn_missing_env
		echo "Files ready (nothing started)."
		echo "Start the root chain + every added nested chain with:"
		echo "  make up        # node + monitoring"
		echo "  make node-up   # node only"
		echo "Or restore this chain from its snapshot and start it with:"
		echo "  make add-nested-chain-snapshot CHAIN_ID=$CHAIN_ID"
		;;
	snapshot)
		warn_missing_env
		warn_if_root_down
		echo "==== restoring chain-$CHAIN_ID from snapshot ===="
		# Reuse the existing snapshot script, pointed at this chain's db dir and
		# its own compose service. It stops the service (noop if not yet up),
		# wipes/extracts the db dir, and starts the service. keystore.json and
		# validator_key.json live at the data dir root, outside the db dir, so
		# they are never touched.
		SNAPSHOT_URL="$SNAPSHOT_BASE/$CHAIN_ID" \
		SNAPSHOT_DATA_DIR="data/chain-$CHAIN_ID/$(jq -r '.dbName // "canopy"' "$CHAIN_DIR/config.json")" \
		SNAPSHOT_SERVICE="chain-$CHAIN_ID" \
		SNAPSHOT_COMPOSE_FILES="-f docker-compose.yml -f $COMPOSE_BASENAME" \
			"$SCRIPT_DIR/snapshot.sh"
		echo "==== done ===="
		echo "Logs: docker compose -f docker-compose.yml -f $COMPOSE_BASENAME logs -f chain-$CHAIN_ID"
		;;
esac
