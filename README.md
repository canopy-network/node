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
make add-nested-chain CHAIN_ID=29            # assemble a nested chain's files (see below)
make add-nested-chain-snapshot CHAIN_ID=29   # assemble + restore its snapshot + start it
make down       # stop everything
```

`make up`, `make node-up`, `make down`, and `make status` automatically include
every `docker-compose.chain-*.yml` that `make add-nested-chain` has generated, so
the root chain and all added nested chains start/stop/report together.

## Nested chains

A node can run extra ("nested") chains alongside the root chain. Each nested
chain runs as its own container that connects to the root chain already running
in this stack. Two targets, both backed by `scripts/add-nested-chain.sh`:

```bash
make add-nested-chain           CHAIN_ID=29   # assemble files only (does NOT start)
make add-nested-chain-snapshot  CHAIN_ID=29   # assemble (if needed) + restore snapshot + start
```

**Assembling the files** (`add-nested-chain`) only prepares the chain; it never
starts a container:

1. Fetches the chain's `genesis.json` and `config.json` from the Canopy
   chain-data API (`https://api.app.canopynetwork.org/api/v1`).
2. Fetches the chain's plugin files if it has any (a `404` means it has none and
   is skipped silently) and writes them where the chain expects them. If the
   plugin needs env vars, they are documented in `.env.example` and you are
   prompted to add them to your `.env`.
3. Rewrites the fetched config's root-chain entry to point at the root chain
   running in *this* node (derived from `config/config.json`, not hardcoded).
4. Reuses this node's `config/keystore.json` and `config/validator_key.json`
   verbatim (the node identity is identical across every chain). Run
   `make gen-key` first if you don't have them yet.
5. Writes everything under `data/chain-<id>/` and generates
   `docker-compose.chain-<id>.yml`, using the Docker image that matches the
   chain's plugin language (`canopynetwork/canopy-plugin-<lang>:latest`,
   defaulting to `go`).

**Starting from genesis** — once the files are assembled, start the whole stack
(root chain + every added nested chain) with `make up` (or `make node-up` for no
monitoring). These targets pick up every `docker-compose.chain-*.yml`
automatically.

**Starting from a snapshot** (`add-nested-chain-snapshot`) assembles the files if
needed, then reuses `scripts/snapshot.sh` to restore the chain's snapshot from
`https://public-snapshots.app.canopynetwork.org/chain/<id>` into `data/chain-<id>/canopy`
and start the container. The snapshot only ever touches the db dir, so the shared
`keystore.json`/`validator_key.json` are never overwritten. The root chain's own
snapshot (`make snapshot`) is unaffected.

Both are idempotent: if `data/chain-<id>` already exists the files are reused, not
re-fetched. To recreate a chain from scratch, remove `data/chain-<id>` and
`docker-compose.chain-<id>.yml` first.

Upgrading canopy: `make pull && make up` (or `docker compose pull node && docker compose up -d`).
The node also self-updates in place via canopy's auto-update coordinator when `autoUpdate` is
enabled in config (enabled by default).

## Repo layout

```
docker-compose.yml            # node (+ keygen, run once via `docker compose run keygen`)
docker-compose.monitoring.yml # caddy + monitoring stack (configs inlined via `configs:`) 
config/                       # node config + genesis (bind-mounted into the node)
data/                         # runtime state (peers, chain db), gitignored
scripts/                      # snapshot.sh, add-nested-chain.sh
```
