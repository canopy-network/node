# Canopy node stack
SHELL := /bin/bash

# Load environment variables from .env if it exists
ifneq (,$(wildcard .env))
  include .env
  export
endif

NODE_COMPOSE := docker-compose.yml
MONITORING_COMPOSE := docker-compose.monitoring.yml
FULL_COMPOSE := docker compose -f $(NODE_COMPOSE) -f $(MONITORING_COMPOSE)

# Nested chains added by `make add-nested-chain` each drop a compose file; these
# are picked up automatically by up/node-up/down/status (empty when there are none).
CHAIN_COMPOSE := $(wildcard docker-compose.chain-*.yml)
CHAIN_FLAGS := $(patsubst %,-f %,$(CHAIN_COMPOSE))

.PHONY: help hash-password up down restart logs chain-logs status validate snapshot init-keys add-nested-chain add-nested-chain-snapshot

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

hash-password: ## Generate a bcrypt hash for AUTH_PASSWORDHASH (prompts for password)
	@read -s -p "Password: " pw; echo; \
	printf "AUTH_PASSWORDHASH="; \
	docker run --rm -i caddy:2.10-alpine caddy hash-password -p "$$pw" | sed 's/\$$/\$$\$$/g'
	@echo "Copy the exact line above into .env"

pull: ## Pull the latest canopynetwork/canopy image
	$(FULL_COMPOSE) pull node

node-up: ## Start the node + any added nested chains (no monitoring)
	docker compose -f $(NODE_COMPOSE) $(CHAIN_FLAGS) up -d

up: ## Starts everything (node, nested chains, monitoring, etc.)
	$(FULL_COMPOSE) $(CHAIN_FLAGS) up -d

down: ## Stop everything
	$(FULL_COMPOSE) $(CHAIN_FLAGS) --profile monitoring down

restart: ## Restart the nodes (reload config.json changes)
	$(FULL_COMPOSE) restart node

logs: ## Tail the root chain (node) logs
	docker compose -f $(NODE_COMPOSE) logs -f node --tail 200

chain-logs: ## Tail a single nested chain's logs (CHAIN_ID=29)
	@test -n "$(CHAIN_ID)" || { echo "CHAIN_ID is required, e.g. make chain-logs CHAIN_ID=29"; exit 1; }
	@test -f docker-compose.chain-$(CHAIN_ID).yml || { echo "no docker-compose.chain-$(CHAIN_ID).yml -- run 'make add-nested-chain CHAIN_ID=$(CHAIN_ID)' first"; exit 1; }
	docker compose -f $(NODE_COMPOSE) -f docker-compose.chain-$(CHAIN_ID).yml logs -f chain-$(CHAIN_ID) --tail 200

status: ## Show container status
	$(FULL_COMPOSE) $(CHAIN_FLAGS) ps

snapshot: ## Restore root chain + every added nested chain from snapshots (concurrent download) and start them
	./scripts/snapshot.sh

snapshot-up: snapshot up ## Same as snapshot, then also bring up monitoring

add-nested-chain: ## Add a nested chain's files only; start with 'make up' (CHAIN_ID=29)
	./scripts/add-nested-chain.sh "$(CHAIN_ID)" files

add-nested-chain-snapshot: ## Add a nested chain + restore its snapshot + start it (CHAIN_ID=29)
	./scripts/add-nested-chain.sh "$(CHAIN_ID)" snapshot

gen-key: ## First-boot: generate validator key
	@docker run --rm -it \
		--entrypoint /bin/cli \
		-v "$(CURDIR)/config:/app/config" \
		canopynetwork/canopy:latest \
		new-validator-key --data-dir /app/config
