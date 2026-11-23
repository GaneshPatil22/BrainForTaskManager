# Brain — the only interface anyone needs.
# Everything runs in containers. Nothing uses the host toolchain.
.DEFAULT_GOAL := help
.PHONY: help dev build test eval gate lint ci scorecard dogfood rank rank-again agreement rank-status add-scenarios ingest clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev: ## Start the dev containers (Swift + ml-service)
	docker compose up -d

build: ## Build the Swift package
	swift build

test: ## Unit + property tests
	swift test

# EvalCLI arrives in B2. Until then these skip loudly rather than fail the
# build or, worse, pass silently and make `make ci` green for the wrong reason.
HAVE_EVAL := $(shell swift package dump-package 2>/dev/null | grep -c '"EvalCLI"')

eval: ## Full eval suite, replay mode — offline, deterministic, free
ifeq ($(HAVE_EVAL),0)
	@echo "SKIP eval     — EvalCLI lands in B2 (docs/00-charter.md)"
else
	swift run EvalCLI run --split dev --cassettes replay
endif

gate: ## Regression gate vs. the committed baseline
ifeq ($(HAVE_EVAL),0)
	@echo "SKIP gate     — EvalCLI lands in B2 (docs/00-charter.md)"
else
	swift run EvalCLI gate --split dev --baseline eval/baselines/dev.json
endif

scorecard: ## Print the scorecard table
ifeq ($(HAVE_EVAL),0)
	@echo "SKIP scorecard — EvalCLI lands in B2 (docs/00-charter.md)"
else
	swift run EvalCLI scorecard --split dev
endif

dogfood: ## Run the dogfood CLI against the sample dump
	swift run brain next examples/sample.brain

rank: ## Rank the 30 scenarios by hand (blind, resumable)
	@swift build 2>/dev/null; swift run brain rank

rank-again: ## Second-pass ranking on a different day (finds the noise floor)
	@swift build 2>/dev/null; swift run brain rank --again

agreement: ## How much you disagree with yourself — the ceiling for any model
	@swift build 2>/dev/null; swift run brain agreement

rank-status: ## How many scenarios are ranked so far
	@echo "ranked: $$(grep -l ranking_top3 datasets/scenarios/*.json 2>/dev/null | wc -l | tr -d ' ')/$$(ls datasets/scenarios/*.json | wc -l | tr -d ' ')"

add-scenarios: ## Add your own scenarios:  make add-scenarios FILE=examples/my-scenarios.brain
	@test -n "$(FILE)" || (echo "usage: make add-scenarios FILE=path/to/file.brain"; exit 1)
	swift run brain add-scenarios "$(FILE)"

ingest: ## Ingest raw captures:  make ingest FILE=~/Desktop/captures.txt
	@test -n "$(FILE)" || (echo "usage: make ingest FILE=path/to/captures.txt"; exit 1)
	swift run brain ingest "$(FILE)"

lint: ## Format check
	swift format lint --recursive Sources Tests

ci: lint test eval gate ## Exactly what CI runs. If this passes, CI passes.

clean:
	rm -rf .build eval/runs
