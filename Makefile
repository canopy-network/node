# Canopy node stack
ifneq (,$(wildcard .env))
  include .env
  export
endif

COMPOSE := docker compose -f docker-compose.yml -f docker-compose.monitoring.yml

.PHONY: help setup hash-password up down restart logs status validate snapshot init-keys

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

setup: ## One-time setup: .env, data dirs, node configs, validator keys
	./scripts/setup.sh

hash-password: ## Generate a bcrypt hash for AUTH_PASSWORDHASH (prompts for password)
	@docker run --rm -it caddy:2.10-alpine caddy hash-password

pull: ## Pull the latest canopynetwork/canopy image
	$(COMPOSE) pull node

up: ## Starts everything (node, monitoring, etc.)
	$(COMPOSE) up -d

down: ## Stop everything
	$(COMPOSE) --profile monitoring down

restart: ## Restart the nodes (reload config.json changes)
	$(COMPOSE) restart node

logs: ## Tail node logs
	$(COMPOSE) logs -f node

status: ## Show container status
	$(COMPOSE) ps

snapshot: ## Download mainnet snapshots into data/ (stops nodes first)
	./scripts/snapshot.sh

init-keys: ## First-boot: generate validator keys
	docker compose run --rm --no-deps -it keygen
