# Brain

The reasoning core of a capture-and-prioritise tool: dump anything, it organises
it, finds what depends on what, and ranks what to do next.

Brain is a **standalone Swift package with no HTTP, auth, or database code.**
The server (separate repo) is a thin wrapper around it.

## The one rule

> **AI proposes. Deterministic code verifies and decides. The human confirms.**

A model is never the source of truth for IDs, dates, arithmetic, rankings, or
graph validity. See [`docs/09-tiering.md`](docs/09-tiering.md) for how work is
assigned to tiers, and why most of it never reaches a model at all.

## Layout

| Path | Contents |
|---|---|
| `Sources/BrainCore` | Pure logic. Graph, cycles, scoring, date parsing, rules. No AI. |
| `Sources/BrainPipeline` | Typed stages: extract → classify → link → score → explain |
| `Sources/BrainAdapters` | Provider adapters + Fake and Replay implementations |
| `Sources/BrainHarness` | Guards, schemas, tracing, router, budget ledger |
| `Sources/EvalCLI` | Dataset loader, metrics, regression gate, scorecard |
| `datasets/` | Versioned JSONL. Synthetic committed; **real data is gitignored.** |
| `eval/baselines/` | Stored scorecards the regression gate compares against |
| `docs/` | Specs. Start with `00-charter.md`. |

## Status

**Phase B0 — specification.** No executable code yet, by design.
Phase plan and gates: [`docs/00-charter.md`](docs/00-charter.md).

## Running things

CI is **manual-trigger only** — nothing runs on push. Locally:

    make help
