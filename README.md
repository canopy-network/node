# canopy node
## Quickstart

```bash
./scripts/setup.sh    # domain, email, basic-auth password → .env + data/
make pull             # pull canopynetwork/canopy:latest
make init-keys        # first boot only: generate the validator key
make up               # node + caddy
```

Optional: `make snapshot` to sync from the mainnet snapshot instead of
genesis, `make monitoring-up` for prometheus + grafana + loki + promtail.

Local development: leave `DOMAIN=localhost` — Caddy signs `wallet.localhost`
etc. with its internal CA. Production: point a `*.<DOMAIN>` wildcard (or
per-host records) at the box and certificates are issued automatically via
Let's Encrypt.

## URLs

| Service | URL | Auth |
|---|---|---|
| Wallet | `https://wallet.<DOMAIN>/` | basic-auth |
| Explorer | `https://explorer.<DOMAIN>/` | open |
| RPC | `https://rpc.<DOMAIN>/` | open |
| Admin RPC | `https://adminrpc.<DOMAIN>/` | basic-auth |
| Grafana | `https://monitoring.<DOMAIN>/` | grafana login (monitoring profile) |
| Loki | `https://loki.<DOMAIN>/` | basic-auth (monitoring profile) |


## How it fits together

```
                     ┌────────────── Caddy (80/443, auto-HTTPS) ─────────────┐
  wallet.<D>/        │ wallet :50000 (+ same-origin /rpc and /adminrpc)      │
  explorer.<D>/      │ explorer :50001 (+ same-origin /rpc and /adminrpc)    │
  rpc.<D>/           │ :50002 (root rewrites to /v1/eth)                     │
  adminrpc.<D>/      │ /v1/admin/* → :50003, everything else → :50002       │
  monitoring.<D>/    │ grafana :3000        (monitoring profile)             │
  loki.<D>/          │ loki :3100, basic-auth (monitoring profile)           │
                     └───────────────────────────────────────────────────────┘
```

## Repo layout

```
docker-compose.yml            # node
docker-compose.monitoring.yml # caddy (Caddyfile inlined via `configs:`) + monitoring stack
config/                       # node config + genesis (bind-mounted into the node)
data/                         # runtime state (keys, chain db), gitignored
scripts/                      # setup, init-keys, snapshot
monitoring/                   # grafana dashboards (all other configs inlined via `configs:`)
```

## Operations

```bash
make help            # all targets
make validate        # caddy validate + compose config
make logs            # follow node logs
make restart         # apply data/config.json edits
make monitoring-up   # prometheus + grafana + loki + promtail
make down            # stop everything (all profiles)
```

Upgrading canopy: `make pull && make up`. The node also self-updates in place
via canopy's auto-update coordinator when `autoUpdate` is enabled in config.
