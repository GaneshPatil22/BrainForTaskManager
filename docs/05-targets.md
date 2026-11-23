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
| Human pick in top-3 (scenarios) | ≥ 90% | medium |
| NDCG@5 | ≥ 0.85 | low |
| Span-verified rate | ≥ 99% | high — code-enforced |
| **T2 rate** (costs quota, leaves machine) | ≤ 40% | **low — unmeasurable before B5** |
| Accuracy lost vs. always-T2 | ≤ 2 pp macro-F1 | low |
| ECE | ≤ 0.08 | low |

## Why the abstention ceiling exists

Accuracy on attempted items alone is trivially gameable: abstain on everything
hard and report 100%. The pair `(accuracy ≥ 90%, abstention ≤ 15%)` is the real
target. Either number quoted alone is meaningless and should be treated as such
in any future report.

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
