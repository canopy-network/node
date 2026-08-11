# Canopy node

Docker-based setup for running a canopy validator (or full node).

## Prerequisites

- A server with `docker` installed
- **Validators only:** a domain name with a DNS `*.<DOMAIN>` wildcard A record pointing at the
  server's IP.

## 1. Node setup

Copy `docker-compose.yml` and the `config/` directory to the server on the same base directory,
then:

> [!NOTE]  
> You may also clone the whole repository with `git clone` to skip copying each file individually.

```bash
# generate the validator key by writing config/keystore.json + config/validator_key.json
docker compose run --rm --no-deps -it keygen

# validators only: modify the "externalAddress" field in config/config.json to point to your domain
#   config/config.json → "externalAddress": "tcp://<your-domain>"

# start the node
docker compose up -d
```

If you also copy the `Makefile`, the equivalent shortcuts are `make init-keys` and `make up` (see
[Operations](#operations)).

### Migrating an existing validator

Skip `keygen`. Instead, copy your existing `config.json`, `keystore.json`, and `validator_key.json`
into `config/` before running `docker compose up -d`.

You may also need to update `config.json` so `rpcURL` is `"/rpc"` and `adminRPCUrl` is
`"/adminrpc"`.

## 2. Monitoring & public access (optional)

`docker-compose.monitoring.yml` runs Caddy (reverse proxy + auto-HTTPS) and the
prometheus/grafana/loki/alloy stack. Caddy is also what exposes the wallet, explorer, and RPC
endpoints for public access. The node container only publishes its P2P port (`9001`) on its own, so
skip this step only if you don't need those endpoints reachable from outside the box.

Copy `docker-compose.monitoring.yml` to the same directory as the previous compose file, along with the `monitoring` folder, then:

```bash
cp .env.example .env
# edit .env: set DOMAIN=<your-domain> (defaults to localhost),
# change AUTH_PASSWORDHASH for production (docker run --rm -it caddy:2.11-alpine caddy hash-password 
# or make hash-password), if the docker command is used, the $ must be escaped as $$ and set GF_ADMIN_PASSWORD

docker compose -f docker-compose.monitoring.yml up -d
```

Local development: leave `DOMAIN=localhost`, you can still access through `<SERVICE>.localhost`.
Production: point the `*.<DOMAIN>` wildcard at the box and certificates are issued automatically via
Let's Encrypt.

### URLs

| Service | URL | Auth |
|---|---|---|
| Wallet | `https://wallet.<DOMAIN>/` | basic-auth |
| Explorer | `https://explorer.<DOMAIN>/` | open |
| RPC | `https://rpc.<DOMAIN>/` | open |
| Admin RPC | `https://adminrpc.<DOMAIN>/` | basic-auth |
| Grafana | `https://monitoring.<DOMAIN>/` | grafana login |
| Loki | `https://loki.<DOMAIN>/` | basic-auth |

## 3. Snapshot (optional)

Sync from a mainnet snapshot instead of genesis. Copy `scripts/snapshot.sh` to the server, then:

```bash
SNAPSHOT_URL=<url> ./scripts/snapshot.sh
```

This stops the node, wipes `data/canopy`, downloads and extracts the snapshot, then restarts the
node. `SNAPSHOT_URL` can also come from `.env` if it's already in place.

You can also run `make snapshot-up` to start the nodes after the snapshot is applied (see
[Operations](#operations)).

## Operations

The `Makefile` wraps both compose files together (`docker compose -f docker-compose.yml -f
docker-compose.monitoring.yml`), so its targets act on node + monitoring as one stack:

```bash
make help       # all targets
make pull       # pull the latest canopynetwork/canopy image
make gen-key    # first boot only: generate the validator key
make up         # start everything
make logs       # follow node logs
make status     # show container status
make restart    # apply config/config.json edits
make snapshot   # sync from the mainnet snapshot instead of genesis
make snapshot-up   # sync from the mainnet snapshot instead of genesis and start the node
make down       # stop everything
```

Upgrading canopy: `make pull && make up` (or `docker compose pull node && docker compose up -d`).
The node also self-updates in place via canopy's auto-update coordinator when `autoUpdate` is
enabled in config (enabled by default).

## Repo layout

```
docker-compose.yml            # node (+ keygen, run once via `docker compose run keygen`)
docker-compose.monitoring.yml # caddy + monitoring stack (configs inlined via `configs:`) 
config/                       # node config + genesis (bind-mounted into the node)
data/                         # runtime state (peers, chain db), gitignored
scripts/                      # snapshot.sh
```
