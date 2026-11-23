# 13 — The generated datasets: what they are and what they are for

Three files of ~300 scenarios each, supplied 2026-11-23, each scenario carrying
3 roles × 3 moods of ranked answers. Analysed file-by-file; full reports were
written to `.analysis/` (gitignored scratch).

**897 scenarios · 4,038 tasks · 8,073 mood blocks · 15,509 ranked picks.**

---

## 1. Mechanical quality: essentially perfect

| | c-300 | g-300 | cl-300 |
|---|---|---|---|
| Scenarios | 300 | 297 | 300 |
| Tasks | 1,470 | 1,188 | 1,380 |
| Picks | 5,588 | 4,898 | 5,023 |
| Parse integrity | 100% | 100% | 100% |
| **Hallucinated picks** | **0** | **0** | **0** |
| Picks naming a blocked task | 0 | 0 | 0 |
| Picks naming a closed task | 0 | 0 | 0 |
| Duplicate / empty / oversized blocks | 0 | 0 | 0 |

Zero defects in 15,509 picks. Every `goal X` and `after X` resolves. g-300's
claimed id gap {248, 249, 250} is real. cl-300's `unblocks N` claims match the
spec's **transitive** `U(i)` in 1012/1012 — against a naive direct-successor
count it would fail 420 of them, so the generator had `02-scoring-spec.md` in
hand and implemented it correctly.

## 2. And that perfection is the finding

These are **template-generated, not human-judged**. The evidence:

- 500 distinct rationale strings for 5,588 picks in c-300, and **exactly four
  distinct rationale endings** in the entire file
- A rationale is a pure function of `(mood, slot, effort, due, unblocks)` for
  ~100% of cases
- **Zero case-only or whitespace-only near-misses** across 15,509 picks. Humans
  produce those constantly; generators never do

**Consequence: scoring a ranker against these measures "did we reimplement the
generator", not "do we match human judgment".** They cannot satisfy the AI
Justification Test in `09-tiering.md`, because their labels contain no human
judgment to be right or wrong about.

**Ganesh's 30 hand-ranked scenarios remain the only human ground truth, and are
worth more than all 897 of these for that purpose.** See `05-targets.md`.

## 3. Role carries zero signal — drop it

Measured independently three times, and re-verified directly:

| File | Same mood, different role → identical picks |
|---|---|
| c-300 | 9 / 9 = **100%** |
| g-300 | 298 / 298 = **100%** |
| cl-300 | 97 / 97 = **100%** (mean Jaccard 1.000, byte-identical rationales) |

**404 of 404 pairs identical.** Change the role, hold the mood, and the answer
never moves. Same role with a different mood agrees only 0–14% of the time.

The pick list is a pure function of `(scenario, mood)`. 893 distinct role
strings — 337 appearing exactly once — carry no decision value. In cl-300 the
first `expect:` role equals the `# Created by:` line in 300/300 scenarios;
roles 2 and 3 are padding.

This is the empirical confirmation of `12-backlog.md` B-03c, and it is stronger
than the argument given there: a model trained on this data would **correctly**
learn to ignore role. Keeping it triples the apparent size of the eval and
invites conditioning on a null variable.

**Decision: role is dropped from the scorer.** It survives only as a possible
prior over which mood a user defaults to, which is a UI question, not a model one.

## 4. The genuinely valuable part: a mode taxonomy

The 20 "moods" are not psychological states. They are **deterministic selection
policies** — T0 rules, every one. Measured fit against a best-matching
filter-and-sort rule:

| Group | Moods | Rule | Fit |
|---|---|---|---|
| Effort floor | `clear-the-clutter`, `tired-low-energy` | tiny only | 90–100% |
| Effort floor | `lazy` | single lowest effort | 91–96% |
| Effort ceiling | `quick-wins-hunter`, `short-on-time`, `chill` | effort ≤ small | 71–100% |
| Deadline | `deadline-panic` | dated only, due ascending | 87–100% |
| Deadline | `only-important`, `overwhelmed-pick-one` | due asc, k=1 | 80–100% |
| Size | `big-rock-first` | max effort first, then a tiny add-on | 86–100% |
| Goal | `one-project` | all picks share one goal | 88/88, 196/196 exact |
| **Category** | `one-type-of-work` | all picks one category | 135/135, 101/101 exact |
| **Category** | `few-of-each-type` | all picks distinct categories | 155/155, 121/121 exact |
| **Category** | `people-first`, `money-first`, `self-care-first` | category filter | 91–98% |
| Composite | `productive`, `full-work-mode` | deadline → quick win → next best | 62–88% |

Two are broken in the data itself:

- **`planner` has no discoverable rule** — 29–48% fit across all three files. Its
  rationale says "Prep step", yet only 18–36% of its picks unblock anything.
- **`chill` is underdetermined** — the filter is hard (never medium or large) but
  *which* light task is unpredictable (45–71%).
- **`avoiding-the-hard-thing` is semantically inverted.** Its rationale reads
  "Hardest thing, do it first" and its top pick is max-effort 79% of the time —
  byte-identical to `big-rock-first` in 75/94 co-occurrences. The name says avoid;
  the data says confront.

With only 4–5 tasks per scenario there is not room for 20 distinct policies.
Several collapse: `only-important`/`overwhelmed-pick-one` 77%,
`lazy`/`tired-low-energy` 68%, `full-work-mode`/`productive` 51%. **The files
really exercise 8–10 distinguishable behaviours.**

## 5. A domain field we do not model: task category

Five moods (≈18–20% of all picks) pivot on a task **category** that exists
nowhere in our schema. It leaked only into the rationale text. The taxonomy,
verbatim and consistent across all three files:

```
paperwork and admin      errands and shopping     calls and messages
planning and booking     creative or deep work    hands-on chores and upkeep
money and payments       study or learning        health and self-care
household
```

This is a **T0 keyword lexicon, not a model call** — a one-line regex already
reaches 75% on `money-first`. Recorded as backlog item **B-04**.

## 6. Coverage holes — why these are weak even as regression fixtures

- **Date grammar barely exercised.** c-300 and g-300 use **6 distinct date
  strings each**; cl-300 uses 26. Untested across all three: month-end,
  `agle mahine`, `N din baad`, `in N weeks`, Hinglish weekdays, three-part
  numeric dates, `on the 15th`, and (until today) any time-of-day form.
- **Closed statuses absent.** c-300 has zero `done` and zero `dropped`; cl-300
  has two `done` in one scenario. The "closed tasks are never picked" claim is
  effectively untested.
- **`xlarge` never appears** in c-300 or g-300.
- **One goal per scenario**, so goal *selection* is never tested (G ∈ {0,1}).
- **g-300 confounds blocking with deadlines** — blocked tasks almost never carry
  a due date, so *a ranker that ignored `blocks` entirely would still look
  correct on it.*
- **cl-300's duplicate test is vacuous.** Scenario 092's near-duplicate pairs are
  real, but the second member of each pair is picked zero times across all nine
  blocks, so nothing about dedup is actually exercised.

## 7. Hinglish: thinner than the premise

cl-300, the most Hinglish of the three: **5.9% of task lines** contain a Hinglish
token, 11.7% of scenario titles, zero Devanagari. The commonest tokens are
grammatical particles (`ka`, `karna`, `ke`, `ko`) inside otherwise-English
phrases.

The exception is dates: **75% of dated tasks use a Hinglish date word** — `aaj`,
`kal`, `parso`, `tarikh`, `agle hafte`.

Absent entirely: code-mixed verb-final sentences, Hinglish durations (`2 ghante`,
`jaldi`) **despite that being a named T0 rule**, Hinglish blocking phrases
(`X ke baad`) **despite that being a named T0 rule**, and spelling variance
(`kal`/`kl`, `tarikh`/`tareek`).

**This is English with Indian context, not a Hinglish test.** If Hinglish is a
core requirement — and `00-charter.md` says it is — it needs a purpose-built
companion set.

## 8. What these files actually bought us

A real bug in shipped code, found by data probing:

**A clock time with no day word returned `nil`.** `shaam 5 baje` *and* `9am` both
parsed to nothing, silently discarding a date the user had plainly stated —
`parse()` bailed when no *date* rule matched, ignoring any time it had found.
Now resolves to the next occurrence of that clock time, with confidence reduced
because the day was inferred rather than stated. Regression test added.

Also added while there: `this week` / `is hafte` / `weekend`.

## 9. Known defects in the data, for whoever regenerates it

1. `avoiding-the-hard-thing` is inverted — rename to `eat-the-frog`, or regenerate
2. `planner` has no rule — define it or delete it
3. `chill` is underdetermined
4. `large` is rendered "about 3 hr"; `Domain.swift` says 240 min and
   `Explain.swift` says "about half a day". The data is wrong against both
5. `agle hafte`: the file headers say Fri 4 Dec, `matchNextPeriod` gives Mon
   30 Nov. **Our grammar is the authority; the data is wrong**
6. 16 truncated rationales in g-300 (0.33%), missing the effort/duration tail
7. 46 capitalisation drifts on category labels in g-300

## Verdict

| Use | Verdict |
|---|---|
| Human ground truth for ranking | **No.** No human judgment in the labels |
| Specification of mode behaviour | **Yes — this is the real value** |
| Regression fixtures | **Partly.** Fix the coverage holes in §6 first |
| Hinglish evaluation | **No.** 5.9% token coverage, and the two named Hinglish T0 rules are absent |
| Evidence that role matters | **No — it proves the opposite, conclusively** |
