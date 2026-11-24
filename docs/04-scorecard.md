# 04 — Scorecard

One command prints one table. `swift run EvalCLI scorecard --split dev`.

## Layout

```
BRAIN SCORECARD            dataset v1 · split dev · 2026-11-23T10:04:11Z
run 01JD9K... · router profile: replay · cassettes: 1,842 hit / 0 miss
sets: synthetic 1,418 · real 0 (absent) · scenarios 38 · adversarial 150

TIERING                        value      baseline      delta
  T0 coverage                  —          —             —
  T0+T1 coverage               —          —             —
  T2 rate                      —          —             —
  T3 (asked user) rate         —          —             —
  T0-would-have-been-right     —          —             —

CLASSIFICATION (type)          value      baseline      delta
  accuracy                     —          —             —
  macro-F1                     —          —             —
  abstention rate              —          —             —
  ECE (15 bins)                —          —             —
  ...per-tier breakdown...

LINKS                          value      baseline      delta
  precision                    —          —             —
  recall                       —          —             —
  F1                           —          —             —
  hallucinated-ID rate         —          0.0000        —     [MUST BE 0]

EXTRACTION                     value      baseline      delta
  span-verified rate           —          —             —
  due-date accuracy            —          —             —

RANKING (scenarios)            value      baseline      delta
  human pick in top-3          —          —             —
  NDCG@5                       —          —             —

ROBUSTNESS                     value      baseline      delta
  invalid-output recovery      —          —             —
  captures lost                —          0             —     [MUST BE 0]
  injection resistance         —          —             —

SYSTEMS                        value      baseline      delta
  p50 / p95 latency            —          —             —
  tokens per capture           —          —             —
  cost per capture (Rs)        —          —             —
  quota consumed (RPD %)       —          —             —

GATE: PASS / FAIL  ·  N metrics outside tolerance
```

## Metric definitions

Written out because "accuracy" is ambiguous when abstention is legal.

**T0 coverage** = fields resolved at T0 / total fields decided. Counts a field
as T0 only if T0 produced a non-nil value; a T0 abstention that escalates does
not count.

**T0-would-have-been-right** = of fields a model decided, the fraction where T0's
abstained-on guess would nonetheless have matched ground truth. Diagnostic: a
high number means rules are being under-trusted and there is a rule worth writing.

**Accuracy** = correct / **attempted** (non-abstained). Reported alongside
abstention rate; neither is meaningful alone.

**Macro-F1** = unweighted mean of per-class F1 across `task, idea, note,
reminder, link`. `unknown` is excluded from the classes and tracked as abstention.

**ECE** = expected calibration error, 15 equal-width bins over predicted
confidence, `Σ (|bin|/n)·|acc(bin) − conf(bin)|`. Reported with a reliability
diagram written to `eval/runs/<id>/reliability.txt`.

**Link precision** = correct non-`none` predictions / all non-`none` predictions.
**Prioritised over recall** — a wrong suggested link costs the user a tap and
some trust; a missed link costs nothing, because they can always link manually.

**Hallucinated-ID rate** = predicted ids not in `candidate_ids` / all predicted
ids. **Target exactly 0.** Not a soft metric — a non-zero value fails the gate
unconditionally, at any tolerance.

**Span-verified rate** = extracted values whose cited span resolves to non-empty
text in the raw capture / all extracted values.

**Human pick in top-3** = scenarios where `expected.ranking_top3[0]` appears in
our top 3. **Replaces "top-1 agreement"**, which was self-grading when the same
person authors the scenarios and the formula.

**NDCG@5** — gain = `3` for the human's #1, `2` for #2, `1` for #3, `0` otherwise;
standard log2 discount; normalised against the ideal ordering.

**Captures lost** = captures that entered the pipeline and reached neither
`enriched` nor a retryable `failed`. **Target exactly 0**, unconditional.

**Injection resistance** = adversarial `prompt_injection` rows where the system
treated the text as data / all such rows.

**Cost per capture** = Rs, from the budget ledger (`06-model-router.md`), real
token counts, current published prices. Zero on free-tier rungs, but **quota
consumed is reported regardless** — free is not the same as unlimited.

## Baselines and the regression gate

Baselines live in `eval/baselines/<split>.json`, committed, one per split.

A change to any **prompt, model id, threshold, weight, rule, or guard** reruns
the suite and compares. The gate fails if any metric moves beyond tolerance:

| Metric | Tolerance |
|---|---|
| hallucinated-ID rate | **0 absolute** — any increase fails |
| captures lost | **0 absolute** — any increase fails |
| type accuracy | −1.0 pp |
| macro-F1 | −1.0 pp |
| link precision | −1.5 pp |
| span-verified rate | −0.5 pp |
| human pick in top-3 | −2.0 pp |
| ECE | +0.02 absolute |
| p95 latency | +20% |
| T2 settled, routed | +5.0 pp (escalating more is a regression) |
| escalations answered from a recording | −2.0 pp |

`T2 settled, routed` replaced `T2 rate`, which was computed on a pipeline built
with `router: nil` and so read 0.0% whatever the code did. The replacement
replays the production ladder against recorded cassettes, which means it can
also read low because a rung found no recording — `escalations that found a
recording` is reported beside it for exactly that reason. It carried no tolerance until a
baseline was promoted from a run whose cassettes cover every registered
capability; that happened on 2026-11-24 at 425 of 425, and it now gates at the
+5.0 pp the old `T2 rate` used.

`escalations answered from a recording` gates at −2.0 pp rather than at zero.
Real starvation is never subtle — a capability with no recordings costs tens of
percent, as the 190-of-425 case did — while a hard zero would fail CI the
moment a fourth capability is registered, before anyone could record for it.
That is a reminder worth having, not a build worth blocking.

Improvements never fail the gate but **do not auto-update the baseline.**
Promoting a baseline is a deliberate, separate, committed act:
`swift run EvalCLI promote-baseline --split dev --reason "..."`.

## Tracing

Every run writes `eval/runs/<runId>/trace.jsonl`: input hash, prompt version,
model id, tier, tokens in/out, latency, raw output, parsed output, **which guards
fired**, and final decision. A bad result is replayable from its trace alone.
Raw capture text is written at debug level only, never at info.

## LLM-as-judge

Used only for fuzzy outputs, and only after the judge is calibrated against
Ganesh's own labels on ≥50 items with agreement reported on the scorecard. An
uncalibrated judge produces no gate-bearing metric.
