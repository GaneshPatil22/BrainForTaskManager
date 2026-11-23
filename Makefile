# Brain — the only interface anyone needs.
# Everything runs in containers. Nothing uses the host toolchain.
.DEFAULT_GOAL := help
.PHONY: help dev build test eval gate lint ci scorecard clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev: ## Start the dev containers (Swift + ml-service)
	docker compose up -d

build: ## Build the Swift package
	swift build

test: ## Unit + property tests
	swift test

eval: ## Full eval suite, replay mode — offline, deterministic, free
	swift run EvalCLI run --split dev --cassettes replay

gate: ## Regression gate vs. the committed baseline
	swift run EvalCLI gate --split dev --baseline eval/baselines/dev.json

scorecard: ## Print the scorecard table
	swift run EvalCLI scorecard --split dev

lint: ## Format check
	swift format lint --recursive Sources Tests

ci: lint test eval gate ## Exactly what CI runs. If this passes, CI passes.

clean:
	rm -rf .build eval/runs
