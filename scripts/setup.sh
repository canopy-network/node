#!/usr/bin/env bash
# One-time, idempotent setup. Never overwrites existing runtime state.
#   ./scripts/setup.sh                          # interactive prompts
#   DOMAIN=example.com AUTH_PASSWORD=secret ./scripts/setup.sh   # non-interactive
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- .env -------------------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "created .env from .env.example"
fi

read_or_env() { # $1=var $2=prompt $3=default
  local val="${!1:-}"
  if [[ -z "$val" ]]; then
    read -rp "$2 [$3]: " val
    val="${val:-$3}"
  fi
  printf '%s' "$val"
}

DOMAIN="$(read_or_env DOMAIN 'Domain (localhost for local dev)' localhost)"
ACME_EMAIL="$(read_or_env ACME_EMAIL 'ACME email' admin@example.com)"
AUTH_USER="$(read_or_env AUTH_USER 'Basic-auth username' canopy)"

if [[ -z "${AUTH_PASSWORD:-}" ]]; then
  read -rsp "Basic-auth password (input hidden): " AUTH_PASSWORD; echo
fi
AUTH_PASSWORDHASH="$(docker run --rm caddy:2.10-alpine caddy hash-password --plaintext "$AUTH_PASSWORD")"
# docker compose interpolates $ in .env values — bcrypt hashes are full of
# them, so escape each $ as $$ or the hash is silently mangled.
AUTH_PASSWORDHASH="${AUTH_PASSWORDHASH//$/\$\$}"

# portable in-place sed (BSD + GNU)
sedi() { sed -i.setup-bak "$@" && rm -f "${@: -1}.setup-bak"; }
sedi "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" .env
sedi "s|^ACME_EMAIL=.*|ACME_EMAIL=$ACME_EMAIL|" .env
sedi "s|^AUTH_USER=.*|AUTH_USER=$AUTH_USER|" .env
sedi "s|^AUTH_PASSWORDHASH=.*|AUTH_PASSWORDHASH=$AUTH_PASSWORDHASH|" .env
echo "wrote DOMAIN/ACME_EMAIL/AUTH_USER/AUTH_PASSWORDHASH to .env"

# ---- node config ---------------------------------------------------------------
# config/config.json + config/genesis.json are bind-mounted into the node;
# data/ holds only runtime state (keys, chain db, logs).
mkdir -p data
if grep -q "tcp://canopy.localhost" config/config.json; then
  # externalAddress is the only value that needs the real domain
  sedi "s|tcp://canopy.localhost|tcp://$DOMAIN|" config/config.json
  echo "stamped externalAddress=tcp://$DOMAIN into config/config.json"
else
  echo "config/config.json already customised — left untouched"
fi

cat <<EOF

Setup complete. Next:
  make pull         # pull canopynetwork/canopy:latest
  make init-keys    # generate validator keys (first boot only)
  make snapshot     # optional: sync from mainnet snapshot instead of genesis
  make up           # start node + caddy

Then open:  https://wallet.$DOMAIN/  (login: $AUTH_USER)
            https://explorer.$DOMAIN/
EOF
