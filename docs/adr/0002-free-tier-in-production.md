# ADR-0002 — Free-tier inference in production

**Date** 2026-11-22 · **Status** accepted · **Decided by** Ganesh

## Context
Google's free tier states content is used to improve their products; the paid
tier does not. The product holds private, half-formed personal ideas.

I raised this as a product-level concern. Ganesh's decision: accept it, disclose
it in the T&C, and revisit if the product gets real customers.

## Decision
Production runs on free tier. No paid billing.

## What changed my assessment
The AI Studio numbers (`06-model-router.md`) show the usable free capacity is
Gemma 4 (14,400 RPD) and Gemini Decision 1 (10,000 RPD) — not the headline
models at 20 RPD. Combined ≈ 24,400 calls/day ≈ **~1,500 daily-active users.**
Free tier is viable well past the point where the business question is answered.
I withdraw the objection on capacity grounds.

## Mitigations (cost nothing)
- Deterministic PII stripping before any content leaves the machine (guard 10).
- Everything resolved at T0 or T1 never leaves at all — which is the main point
  of ADR-0004.
- Disclosed in T&C.

## Revisit when
Real users exist, or free-tier limits change again (they changed twice in 2026).
