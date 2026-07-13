# Canopy node stack
ifneq (,$(wildcard .env))
  include .env
  export
endif

COMPOSE := docker compose -f docker-compose.yml -f docker-compose.monitoring.yml

.PHONY: help setup hash-password up down restart logs status validate snapshot init-keys monitoring-up monitoring-down

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup: ## One-time setup: .env, data dirs, node configs, validator keys
	./scripts/setup.sh

hash-password: ## Generate a bcrypt hash for AUTH_PASSWORDHASH (prompts for password)
	@docker run --rm -it caddy:2.10-alpine caddy hash-password

pull: ## Pull the latest canopynetwork/canopy image
	$(COMPOSE) pull node

up:
	$(COMPOSE) up -d node caddy

down: ## Stop everything (all profiles)
	$(COMPOSE) --profile monitoring down

restart: ## Restart the nodes (reload config.json changes)
	$(COMPOSE) restart node

logs: ## Tail node logs
	$(COMPOSE) logs -f node

status: ## Show container status
	$(COMPOSE) ps

validate: ## Validate Caddyfile + compose file
	$(COMPOSE) run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
	$(COMPOSE) config -q && echo "compose OK"

monitoring-up: ## Start with the monitoring profile (prometheus + grafana)
	@test -n "$(GF_ADMIN_PASSWORD)" || (echo "ERROR: set GF_ADMIN_PASSWORD in .env first"; exit 1)
	$(COMPOSE) --profile monitoring up -d

monitoring-down: ## Stop only the monitoring services
	$(COMPOSE) --profile monitoring stop prometheus grafana

snapshot: ## Download mainnet snapshots into data/ (stops nodes first)
	./scripts/snapshot.sh

init-keys: ## First-boot: generate validator keys (safe to re-run)
	./scripts/init-keys.sh
