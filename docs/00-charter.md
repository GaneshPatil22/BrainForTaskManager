# 00 — Charter

## The job

Help a person who jumps between many ideas and tasks to capture them instantly,
organise them, see what depends on what, and know what is worth doing next.

**Pitch:** "Dump anything. It organises it, finds what depends on what, and tells
you the one thing to do next."

## Explicitly out of scope

Expense tracking · subscriptions · gym/health · social features · collaboration.

These are not "later." They are **not this product.** Any proposal that adds one
is rejected without discussion.

## Users

Individuals, primarily in India. Expect English and Hinglish, messy and vague
captures, duplicates, and very short fragments. Free for users.

## The one rule

> **AI proposes. Deterministic code verifies and decides. The human confirms.**

A model is never the source of truth for IDs, dates, arithmetic, rankings, or
graph validity. See `09-tiering.md`.

## Cost discipline

Hard constraint: ~Rs 1,000/month at small scale, and cost must scale with usage.
Production runs on free-tier inference (ADR-0002). Embeddings run locally and
cost nothing (ADR-0005).

## Data-use position

Production uses free-tier model APIs, where provider terms permit content to be
used for product improvement. This is a deliberate, accepted trade (ADR-0002).
It is disclosed in the Terms & Conditions. Mitigations that cost nothing:

- Deterministic PII stripping (phone, email, amounts, OTPs) before any content
  leaves the machine — see `07-harness-spec.md`.
- Everything resolved at tier T0 or T1 never leaves the machine at all.

## Phase plan and gates

Work stops at every gate. Nothing proceeds without a scorecard shown and approved.

| Phase | Deliverable | Gate |
|---|---|---|
| **B0** | Specs: domain, scoring, dataset schema, scorecard, router, tiering | Ganesh approves 01, 02, 03, 04, 06, 09 |
| **B1** | Pure Core: graph, cycles, scoring, quick wins, blocked, next, date parsing. Property tests + scenarios. **Plus the dogfood CLI.** | All tests green; Ganesh uses the CLI on real captures |
| **B2** | Datasets v1: synthetic generator, loader, splits, graph scenarios, adversarial set. Ganesh supplies 300 real captures and authors ground-truth rankings. | Dataset schema frozen; human spot-check done |
| **B2.5** | **T0 baseline — rules only, zero model calls.** Accuracy *and* coverage per field. | **This is the baseline AI must beat.** |
| **B3** | AI baseline, measured as *delta over T0*. Two tracks: generate-and-parse vs. closed-set decisions. | Scorecard picks a track; delta justifies the quota |
| **B4** | Guards, added one at a time, each with its measured effect | Per-guard before/after numbers |
| **B5** | Own model (T1) and router: cost saved vs. accuracy lost, threshold selection | Cascade curve shown |
| **B6** | Personalisation: simulated corrections on held-out users | Accuracy improves measurably |
| **B7** | Soak + adversarial: long runs, failure injection, injection attacks | Zero lost captures |
| **—** | **Brain v1 freeze** with final scorecard | Server work may begin |

## Working agreements

- Plan first, build in small reviewable steps, one phase at a time.
- Never guess library APIs, versions, model names, or free-tier limits. Verify
  against current docs or package source, and state what was verified.
- Be honest about uncertainty. A bad metric is reported as a bad metric. The
  test split is never used to tune prompts or thresholds.
- Small commits, clear messages, append-only `DECISIONS.md`.
- Never commit secrets. Never commit real user captures.
