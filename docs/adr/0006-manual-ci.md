# ADR-0006 — CI is manual-trigger only

**Date** 2026-11-23 · **Status** accepted · **Decided by** Ganesh

## Decision
No GitHub Actions run on push or pull request. `workflow_dispatch` only, plus
identical local targets.

## Implementation
`make ci` runs the exact commands the workflow runs. Divergence between them is
a bug.

CI runs in cassette `replay` mode, so it is offline, deterministic, free, and
**requires no API keys** — which also means no secrets in the repo settings.
