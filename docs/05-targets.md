# 05 — Targets, and what they can honestly prove

Provisional. Retuned after the **T0 baseline (B2.5)** and the **AI baseline (B3)**.

## Exit targets for Brain v1

| Metric | Target | Confidence |
|---|---|---|
| Hallucinated-ID rate | **exactly 0** | **high** — it is a set-membership check in code, not a model property |
| Captures lost under injected failure | **exactly 0** | **high** — an architectural invariant, not a tuned number |
| Type accuracy (on attempted) | ≥ 90% | medium |
| Abstention rate (type) | ≤ 15% | medium — **paired with the line above; neither is meaningful alone** |
| Suggested-link precision | ≥ 90% | medium — bought with recall, deliberately |
| Suggested-link recall | ≥ 60% | low — will be revised after B3 |
| Human pick in top-3 (scenarios) | ≥ 85% | medium |
| NDCG@5 | ≥ 0.80 | low |
| Human pick is our top-1 | **no target — diagnostic only** | — |
| Span-verified rate | ≥ 99% | high — code-enforced |
| **T2 rate** (costs quota, leaves machine) | ≤ 40% | **low — unmeasurable before B5** |
| Accuracy lost vs. always-T2 | ≤ 2 pp macro-F1 | low |
| ECE | ≤ 0.08 | low |

## Why the abstention ceiling exists

Accuracy on attempted items alone is trivially gameable: abstain on everything
hard and report 100%. The pair `(accuracy ≥ 90%, abstention ≤ 15%)` is the real
target. Either number quoted alone is meaningless and should be treated as such
in any future report.

## Why top-1 has no target at all

**Revised 2026-11-23, at Ganesh's prompting, and he is right.**

There is no single correct answer to "what should I do next". The same person
answers differently by day, hour, mood and urgency. Treating one pick as *the*
truth and everything else as error measures a question that has no answer.

Measured: at 74 ranked dev scenarios, top-1 agreement is 24.3%, and a
900-combination grid search tops out at 36.5%. If three of five tasks are
defensible on a given morning, top-1 agreement has a natural ceiling near 1/3 —
which is roughly where we sit. The number was never going to reach 90%, and
chasing it would have meant fitting noise.

So top-1 stays on the scorecard as a **diagnostic** — a sharp drop still means
something broke — but it carries no target and nothing is tuned against it.

**The goal is sensible grouping, not a perfect prediction.** That is what
top-3 measures.

## What this does not excuse

Top-3 is **71.6%**. Roughly three times in ten, the human's pick lands outside
our top three — in a list of four or five items. That is not imprecision; that
is ranking a reasonable choice near the bottom, and it is still worth fixing.

The honest position: **stop chasing top-1, keep pushing top-3.**

## Why "top-3" and not "top-1"

The original brief specified top-1 agreement ≥ 80% on hand-built scenarios. If
the same person authors both the scenarios and the scoring formula, that number
measures nothing — it is self-grading.

Two changes fix it:

1. **Ganesh authors the ground-truth rankings**, without seeing the formula.
   Required for any scenario in the test split (`03-dataset-schema.md`).
2. **The metric is "human's #1 appears in our top 3"**, because the UI shows a
   ranked list and the user chooses. The metric now matches the product.

## Sample size — what each n can actually distinguish

Wilson 95% intervals around an observed 90%, approximate:

| n | 95% interval | What it distinguishes |
|---|---|---|
| 30 | **74% – 97%** | essentially nothing. Cannot tell 90% from 78% |
| 90 | 82% – 95% | detects a genuinely broken model, not a regression |
| 300 | 86% – 93% | usable. Detects ~5 pp regressions |
| 2,000 | 89% – 91% | detects ~1 pp regressions |

### Consequence: real data gets a different split

The standard 70/20/10 hash split applied to 300 real captures leaves **30 test
rows** — the useless row above. So:

- **Synthetic** — 70 / 20 / 10. Abundant; train split carries the volume.
- **Real** — **50 / 20 / 30** (150 train / 60 dev / **90 test**).

Real data is precious and the test number is what we report, so it gets weighted
toward test. Even then, 90 rows gives ±6 pp. **Real-data metrics are directional;
the synthetic test split carries the statistical weight.** Every scorecard
reports both separately and never merges them into one headline number.

## The ceiling is unmeasured, and it decides whether 85% is even reachable

`12-backlog.md` B-03a asks Ganesh to re-rank ~15 scenarios on a different day.
Until that runs we do not know the noise floor:

- if self-agreement on top-1 is ~60%, our 71.6% top-3 is already above the
  human ceiling and the right move is to stop
- if it is ~90%, the variability argument is weaker and the gap is real work

Ten minutes of his time decides whether to keep pushing or declare this done.
It is now the highest-value outstanding item — ahead of the 300 real captures
and ahead of B3 plumbing.

## Targets I think are shaky, stated now rather than at B7

- **T2 rate ≤ 40%** is a hope, not a projection. The T1 model cold-starts from
  model-labelled synthetic data; its real-world accuracy is unknown until B5.
  If T0 coverage comes in strong at B2.5 this is comfortable; if not, it isn't.
- **Link recall ≥ 60%** is nearly arbitrary. Precision is the one that matters
  and the one being bought. Recall will be set from the B3 curve, not guessed now.
- **ECE ≤ 0.08** assumes we are fitting calibration ourselves. If B3 selects the
  closed-set-decision track, calibrated probabilities come back natively and this
  target should tighten considerably.

These three will be revised at the B3 gate with measured numbers, not defended.
