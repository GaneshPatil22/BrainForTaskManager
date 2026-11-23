# ADR-0004 — Deterministic code before any model

**Date** 2026-11-23 · **Status** accepted · **Decided by** Ganesh

## Context
Ganesh's framing: building a calculator, you do not ask a model what 2 + 2 is.
You write the function. You ask a model to *explain* floating-point error.

## Decision
Four tiers — T0 deterministic code, T1 our own model, T2 global LLM, **T3 ask the
user** — with T3 placed *before* T2, not after. Full assignment per pipeline
stage in `09-tiering.md`.

## Consequences
1. **A new phase, B2.5: the T0 baseline.** Rules only, zero model calls. This —
   not the AI run — becomes the baseline everything must beat.
2. B3 is scored as **delta over T0**, never in absolute terms. If a model beats
   the rules by two points, the model call does not ship.
3. The scorecard reports T0 coverage, T0+T1 coverage, and T2 rate separately,
   plus a retrospective "would T0 have got this right?" column.
4. **The AI Justification Test** (`09-tiering.md`) gates every model call: what
   deterministic approach was tried, its *measured* coverage, why the remainder
   needs a model. No measured number, no call.

## Effect on the design
The model's job narrowed from "classify and link everything" to one sentence:
*for captures the rules could not resolve, and candidate pairs in the ambiguous
similarity band — blocking dependency, duplicate, or neither?*
