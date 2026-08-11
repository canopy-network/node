# Canopy node stack
ifneq (,$(wildcard .env))
  include .env
  export
endif

COMPOSE := docker compose -f docker-compose.yml -f docker-compose.monitoring.yml

.PHONY: help hash-password up down restart logs status validate snapshot init-keys

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

hash-password: ## Generate a bcrypt hash for AUTH_PASSWORDHASH (prompts for password)
	@read -s -p "Password: " pw; echo; \
	echo "AUTH_PASSWORDHASH (\$$ already escaped as \$$\$$ for .env):"; \
	docker run --rm -i caddy:2.10-alpine caddy hash-password -p "$$pw" | sed 's/\$$/\$$\$$/g'


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

snapshot-up: snapshot up ## Download mainnet snapshots into data/ and start nodes

gen-key: ## First-boot: generate validator key
	docker compose run --rm --no-deps -it keygen
