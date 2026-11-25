# 02 — Scoring

Entirely T0. No model participates in ranking, ever.

## Context

The UI shows a **ranked list with the top item highlighted and its reason**, not
a single answer. The user decides. This lowers the stakes of the formula — but
the ordering still has to be principled, stable, and explainable.

## The formula

```
leverage(i) = ( w_b + w_u·ln(1+U(i)) + w_g·ln(1+G(i)) + w_d·D(i) ) / E(i)
```

### Terms

**`U(i)` — transitively unblocked.** Count of distinct **open** items reachable
from `i` through `blocks` edges, depth-capped at 5.

```
U(i) = U_confirmed(i) + α · U_unconfirmed(i)
```

- `U_confirmed` — reachable using confirmed edges only
- `U_unconfirmed` — *additional* items reachable when unconfirmed edges are also traversed
- `α` ∈ {0, 0.25, 0.5}, **default 0.** Evaluated in B4; the chosen value is a
  scorecard line, not a guess.

**`G(i)` — goals served.** Distinct goals served by `i` itself or by any item
counted in `U_confirmed(i)`. Same `α` treatment.

**`D(i)` — due pressure**, in `[0, 1]`:

```
D(i) = 1.0                              if overdue or due today
     = max(0, 1 − daysUntilDue / 14)    otherwise
     = 0                                if no due date
```

Only confirmed, T0-parsed due dates count. A model-guessed date never creates
deadline pressure.

**`E(i)` — effort denominator**, compressed so effort matters without dominating:

```
E(i) = ln(1 + minutes) / ln(1 + 20)
```

| Bucket | Minutes | E |
|---|---|---|
| tiny | 5 | 0.589 |
| small | 20 | 1.000 |
| medium | 60 | 1.350 |
| large | 240 | 1.802 |
| xlarge | 960 | 2.256 |

Ratio tiny : xlarge ≈ 1 : 3.8. Raw minutes would make it 1 : 192, which would
mean a trivial errand always outranks a half-day task that unblocks six things.

### Weights (defaults, tunable on the dev split only)

| Weight | Default | Role |
|---|---|---|
| `w_b` | 0.5 | **base term** — see note |
| `w_u` | 1.0 | unblocking |
| `w_g` | 1.5 | goal service, weighted above unblocking |
| `w_d` | 0.8 | deadline pressure |

**Why `w_b` exists:** without a base term, every unlinked leaf task scores
exactly 0 and the whole list ties. With it, a leaf task's rank falls out of its
effort alone — which is precisely what "quick win" means. Quick wins emerge from
the formula instead of being a bolted-on special case.

## Worked examples (hand-computed; these are the B1 test oracle)

**A — "Call plumber"** · tiny · no due date · U=0 · G=0
```
num = 0.5                                   = 0.500
E   = 0.589
leverage                                    = 0.850
```

**B — "Finalize API spec"** · medium · due in 3 days · U=4 · G=2
```
ln(1+4) = 1.6094    ln(1+2) = 1.0986    D = 1 − 3/14 = 0.7857
num = 0.5 + 1.0(1.6094) + 1.5(1.0986) + 0.8(0.7857)
    = 0.5 + 1.6094 + 1.6479 + 0.6286     = 4.3859
E   = 1.350
leverage                                    = 3.248
```

**C — "Rewrite onboarding copy"** · large · no due date · U=1 · G=1
```
ln(2) = 0.6931
num = 0.5 + 0.6931 + 1.5(0.6931) + 0        = 2.2328
E   = 1.802
leverage                                    = 1.239
```

**Ranking: B (3.248) > C (1.239) > A (0.850).** The deadline-bearing hub wins;
the half-day task with real leverage beats the trivial errand; A is still
correctly surfaced as a quick win.

## Tie-breaking — a strict total order

Applied in order until one discriminates. The last key guarantees no ties ever:

1. `leverage` descending
2. `dueAt` ascending, **nulls last**
3. effort minutes ascending
4. `createdAt` ascending
5. `id` ascending (ULID, lexicographic)

Invariant 4 of `01-domain.md` depends on key 5.

## What the plan contains — membership by type

The plan answers *"what should I do next"*, and **an idea is not a thing to
do.** Open items whose type is `idea` or `note` are **not ranked**, and are
therefore absent from `ranked`, `startable`, `next`, `quickWins` and `blocked`
— every derived output comes off the ranked list, so one filter in
`Scoring.rank` settles all five.

| type | in the plan | why |
|---|---|---|
| `task` | yes | the thing this product is for |
| `reminder` | yes | a thing to do, at a time |
| `link` | yes | "read this" is an action with a real duration |
| `idea` | **no** | capturing a thought is not committing to act on it |
| `note` | **no** | reference material — written down to keep, not to finish |

**Why this exists.** `rank` scored every open item whatever its type, so
"rust vs go for the backend?" could outrank real work, become `next`, and be
proposed as the day's big task. A tool that treats a captured thought as
committed work punishes you for thinking out loud, which is the one thing the
product exists to make cheap.

**`link` is in and `note` is out, deliberately.** Revisit `link` if saved
links turn out to be hoarded rather than read: that shows up as links piling
at the top of `quickWins` and being dismissed, and it is a measurement, not an
opinion.

**An item whose type is not yet known still ranks.** `type` is `Classified`
and is nil while the ladder abstained and a T3 question is unanswered. Hiding
those would mean a capture silently missing from the plan until the user
answers a question they have not been shown. A capture is never lost, and
showing something dismissible is the recoverable direction.

**Excluded is not deleted.** These items stay in the graph: they keep goal
links, they still block and get blocked, and an open idea blocking a task is
still named as that task's blocker — otherwise "decide the stack, then build
it" would quietly become startable. Membership is computed at rank time from
the current type, so **correcting a type to `task` makes it rank normally**,
with no migration.

One consequence worth naming: `quickWins` takes the median leverage over
startable candidates, so a backlog of captured thoughts can no longer drag the
quick-win bar down.

## Derived outputs

**Quick wins** — `effort ∈ {tiny, small}` **and** `leverage ≥ median(leverage)`
over open items. Deterministic given the graph.

**Blocked** — items with at least one incoming `blocks` edge from an **open**
item. Returned with their blockers, so the UI can show the chain.

**Next** — the head of the ranked list, returned with its reason. Not a separate
algorithm.

## Explanation template — T0 only

Filled from graph facts, never generated:

```
"Unblocks {U} tasks · serves {G} goals · {effort} · {dueClause}"
```

Clauses whose underlying count is zero are omitted. If a model ever rephrases
this, a deterministic check confirms that **no claim exists in the rephrasing
that is absent from the facts**. A rephrasing that adds a claim is discarded and
the template is shown instead.
