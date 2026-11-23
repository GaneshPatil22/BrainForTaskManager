# Brain — the only interface anyone needs.
# Everything runs in containers. Nothing uses the host toolchain.
.DEFAULT_GOAL := help
.PHONY: help dev build test eval gate lint ci scorecard promote-baseline dogfood rank rank-again agreement split synthetic adversarial category-eval category-sweep rank-status add-scenarios ingest clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

dev: ## Start the dev containers (Swift + ml-service)
	docker compose up -d

build: ## Build the Swift package
	swift build

test: ## Unit + property tests
	swift test

# Category labels are derived from the committed corpus, so the eval needs no
# network and no API key.
LABELS := /tmp/category-truth.json
$(LABELS): scripts/category-truth.py datasets/generated
	@python3 scripts/category-truth.py > $(LABELS) 2>/dev/null

eval: $(LABELS) ## Full eval suite, replay mode — offline, deterministic, free
	swift run EvalCLI run --split dev --cassettes replay

gate: $(LABELS) ## Regression gate vs. the committed baseline
	swift run EvalCLI gate --split dev --cassettes replay

scorecard: $(LABELS) ## Print the scorecard table
	swift run EvalCLI scorecard --split dev

promote-baseline: $(LABELS) ## Store the current scorecard as baseline. REASON="..."
	@test -n "$(REASON)" || (echo 'usage: make promote-baseline REASON="why"'; exit 1)
	swift run EvalCLI promote-baseline --split dev --reason "$(REASON)"

dogfood: ## Run the dogfood CLI against the sample dump
	swift run brain next examples/sample.brain

rank: ## Rank the 30 scenarios by hand (blind, resumable)
	@swift build 2>/dev/null; swift run brain rank

rank-again: ## Second-pass ranking on a different day (finds the noise floor)
	@swift build 2>/dev/null; swift run brain rank --again

agreement: ## How much you disagree with yourself — the ceiling for any model
	@swift build 2>/dev/null; swift run brain agreement

synthetic: ## Regenerate the synthetic captures (seeded, reproducible)
	python3 scripts/make-synthetic.py 2000

adversarial: ## Regenerate the adversarial set (seeded, reproducible)
	python3 scripts/make-adversarial.py

category-eval: ## Measure the T0 category lexicon against labelled titles
	@python3 scripts/category-truth.py > /tmp/category-truth.json 2>/dev/null
	@swift build 2>/dev/null; swift run brain category-eval

category-sweep: ## Coverage/accuracy curve for the category abstention margin
	@python3 scripts/category-truth.py > /tmp/category-truth.json 2>/dev/null
	@swift build 2>/dev/null; swift run brain category-eval --sweep

split: ## Stamp dev/test splits into scenarios (deterministic from id)
	@swift build 2>/dev/null; swift run brain split

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
