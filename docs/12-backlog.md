# 12 — Backlog: ideas recorded, deliberately not built

Nothing here is in Brain v1. This file exists so good ideas are not lost and do
not become scope creep. Each entry says what it is, why it is not now, and what
would have to be true to start it.

**Everything parked lives here. `make ideas` prints this index.**

| id | idea | tier | gated on |
|---|---|---|---|
| B-01 | Time-budget: "what fits in this gap" | T0 | v1 frozen |
| B-02 | Timers: pomodoro, multiple concurrent | T0 | v1 frozen |
| B-03 | Role and mindset as signals | mixed | B-03a is nearly free; B-03c is a dead end |
| B-04 | Task `category` and the mode taxonomy | T0 | v1 frozen |
| B-05 | Recurring tasks (SIPs, monthly reviews) | T0 | one-item-vs-series question |
| B-06 | Views, each toggleable | mostly T0 | ranking validated (`make agreement`) |
| B-06a | 1-3-5 board (1 big, 3 small, 5 quick) | T0 | after B-06d |
| B-06b | Quick-wins list (the long one) | T0 | cheapest in B-06 |
| B-06c | Journal | T0 + new type | needs its own argument |
| B-06d | Daily review and next-day planning | T0 | **highest value — generates training signal** |
| B-06e | Weekend / long-pending view | T0, except suggestions | split it; suggestion engine is a new claim |

Entries B-01 through B-05 are single features. B-06 is a cluster of *views*:
ways of showing the same data, each one something the user can switch off.

The five hard non-goals from `00-charter.md` — expense tracking, subscriptions,
gym/health, social, collaboration — are not backlog. They are rejected.

---

## B-01 — Time-budget: "what fits in this gap"

**Idea (Ganesh, 2026-11-23).** While ranking scenarios: *"I picked three tasks
that take an hour, so I have time left and could fit other things in."*

That is a different question from both ranking and quick wins:

| Output | Question it answers |
|---|---|
| ranked list | what is most worth doing |
| quick wins | what is cheap *and* worthwhile |
| **time budget** | **what fits in the 25 minutes I actually have** |

Quick wins rank by leverage-per-minute. A time budget is a knapsack over a slot:
*given 25 minutes, what is the best set of tasks that fits?* Different problem,
different answer.

**Why not now.** It is pure T0 arithmetic over the existing graph — no AI, no new
data — so it stays cheap whenever we want it. It is not needed to prove the
Brain works, which is what every phase up to v1 freeze is for.

**Start when** Brain v1 is frozen and a UI exists that knows the user's calendar,
or can simply ask "how long have you got?".

---

## B-02 — Timers: pomodoro, and multiple concurrent timers

**Idea (Ganesh, 2026-11-23).** Let the user time a task, run a pomodoro, or keep
several timers running for different tasks.

**Honest flag, since scope discipline was an explicit instruction.** This is the
first idea that moves from *"know what to do next"* to *"do the thing"*. Those
are different products with different surfaces. It is not on the rejected list
and it is adjacent to the "focus" pain point in the brief, so it is recorded
rather than refused — but it should be a deliberate decision, not a drift.

**What it would genuinely buy us, beyond the feature itself:** real effort data.
Today `effort` is a guess — the user's, or later a model's. A timer turns it into
**measured ground truth**, which is the single best training signal available for
effort classification, and it arrives free as a by-product of normal use.

That is a strong argument for eventually building it. It is also an argument for
building it *after* the effort classifier exists, so we can measure how wrong the
guesses were.

**Start when** Brain v1 is frozen, an app exists, and we explicitly decide to own
execution as well as prioritisation.

---

## B-03 — Role and mindset as signals

**Idea (Ganesh, 2026-11-23).** The same person ranks differently on different
days depending on mindset, and different roles (founder, employee, student,
freelancer) order things differently. We are not building this only for Ganesh.
Proposal: label training data with role and mindset — without asking the user —
and train on them.

**The observation is correct and it matters.** Treating all ranking disagreement
as model error, when much of it is genuine human variation, would make every
target on the scorecard meaningless.

**The proposed mechanism has a flaw worth being precise about.** A feature that
cannot be observed at inference time cannot improve a prediction. If we train
`P(ranking | items, role, mindset)` but never learn role or mindset for a real
user, then at inference we must average over them — which gives exactly the same
answer as never having used them at all. Training on a hidden variable does not
help. It only helps if the variable can be observed or inferred.

The idea therefore splits into three uses. Two are good; one is a dead end.

### B-03a — Measure the ceiling. Do this; it is nearly free.

If Ganesh ranks the same scenario differently on Monday and Friday 25% of the
time, then **no model can exceed about 75% agreement**, and the ≥90% target in
`05-targets.md` is fiction.

Nobody can tell us this number except a human ranking the same scenarios twice.

- **Cost:** re-rank **~30** scenarios on a different day, roughly 15 minutes.
  Not all 130: 30 gives a ±16pp interval, and because the comparison is
  **paired** — our score and the self-agreement score come from the same
  scenarios — that is enough to decide. 15 would give ±23pp and settle nothing.
- **Buys:** the noise floor, and honest targets calibrated against it.

Highest value-per-minute item in this file.

### B-03b — Diversify scenario *generation*, not *rankings*. Fold into B2.

Conditioning the synthetic generator on role produces more varied scenarios and
captures than one person's imagination otherwise yields. Legitimate and useful —
it diversifies the **inputs**.

The caveat is on the **outputs**. Ganesh ranking a scenario "as a student would"
is not data about students; it is data about Ganesh's model of students, and
training on it bakes a stereotype in while looking like real signal. So:

- role conditions the **scenarios** → good, do it
- role conditions the **ground-truth rankings** → do not

Ranked answers should always be someone ranking honestly as themselves.

### B-03c — Train on declared role to predict ranking. Dead end as specified.

Covered above: unobservable at inference. Worse, *inferring* role from capture
content in order to reorder someone's priorities is a stereotyping risk with
little upside.

**What actually solves the real problem:** per-user personalisation, already
planned as **B6** — kNN over the user's own corrections. It captures role and
mindset effects implicitly, from what the person actually does, with no guessing
and no stereotype. A founder and a student diverge in the model because they
*behave* differently, not because we labelled them.

**Verdict.** The instinct is right; the mechanism needs changing. Do B-03a now
(ten minutes, high value), fold B-03b into the B2 generator, and drop B-03c in
favour of B6.

---

## B-04 — Task `category`, and the mode taxonomy

**Source: the generated datasets, 2026-11-23** (`docs/13-generated-datasets.md`).

Two findings from 15,509 generated picks, both actionable and both T0.

### B-04a — A `category` field we do not model

Five of the twenty "moods" pivot on a task **category** that exists nowhere in
our schema; it only leaked into the rationale text. ~18-20% of all picks are
unimplementable without it. The taxonomy is consistent across all three files:

```
paperwork and admin      errands and shopping     calls and messages
planning and booking     creative or deep work    hands-on chores and upkeep
money and payments       study or learning        health and self-care
household
```

**DONE 2026-11-23.** `Item` gained `category: Classified<TaskCategory>`, derived
at T0 from the title by a keyword lexicon (`Sources/BrainCore/Category.swift`).

Measured on 1,308 labelled titles: **80.1% accuracy on attempted, 83.6%
coverage, 67.0% overall.** Weights and abstention margin were swept, not chosen
by feel. Full AI Justification Test entry in `DECISIONS.md`; re-measure with
`make category-eval`.

### B-04b — Modes are deterministic policies, not inferred states

The twenty moods are filter-and-sort rules over the graph we already have, with
measured fit of 71-100% for seventeen of them. That reframes the whole
role/mindset question from `12-backlog.md` B-03:

> Do not *infer* the user's mode. **Offer modes**, each a T0 policy.

`short-on-time` is exactly **B-01**. `quick-wins-hunter` is the quick-wins set we
already compute. `deadline-panic` is due-ascending. `overwhelmed-pick-one` is
`next` with k=1. Most of the taxonomy is already implicit in `BrainCore`.

With 4-5 tasks per scenario the twenty collapse to **8-10 distinguishable
behaviours**, which is a more honest starting point for a UI than twenty.

**Start when** Brain v1 is frozen and there is a UI with somewhere to put a mode
switch. Until then the taxonomy is recorded, not built.

---

## B-05 — Recurring tasks

**Idea (Ganesh, 2026-11-23).** Users create repeating items:

| Example | Pattern |
|---|---|
| ₹10k ICICI SIP on the 15th | day-of-month |
| ₹1.5k SBI SIP on the 20th | day-of-month |
| Monthly plan on the first Sunday | nth weekday of month |
| Previous-month review, first Sunday of the next month | nth weekday, offset period |
| Previous and next quarter review, first week of a new quarter | quarterly, week-of-period |

### The fork that decides everything else

**One item that moves its due date, or a series of instances?**

| | One moving item | A series of instances |
|---|---|---|
| Graph | one node, edges stay put | a node per occurrence; what do edges attach to? |
| History | no record of past completions | full record — "did I miss November's SIP?" |
| Ranking | one row, never clutters | the list fills with future occurrences unless filtered |
| Storage | trivial | needs generation, pruning, a horizon |

Neither is obviously right. "Did I skip a SIP?" is a real question, which argues
for instances; a list drowning in future occurrences argues against. The likely
answer is **one template plus materialised instances within a horizon**, but
that is a decision to make deliberately, not drift into.

### Why this is mostly T0

Recurrence is a grammar and calendar arithmetic — `DateParser` already handles
"15 tarikh". The repeating forms are the same grammar with a quantifier:
"har 15 tarikh", "every first Sunday", "har mahine 20 ko". **No model needed**,
which puts it squarely in T0 and means it passes the AI Justification Test
without argument.

The genuinely fiddly parts are calendar edge cases, not language:
- the 31st in a 30-day month, and 29 February
- "first Sunday" when the month starts on a Sunday
- quarter boundaries against an Indian financial year (April–March) rather than
  the calendar year — worth asking which the user means
- a timezone-correct "first week", given everything resolves in the user's zone

### What it touches

- `Item` gains a recurrence rule, or a new `RecurrenceTemplate` entity
- `status` needs a per-occurrence notion of done
- ranking needs a horizon filter so next month's SIP is not competing with today
- the scoring formula needs a view on whether a recurring item's leverage
  differs from a one-off's

### Interaction already visible

PII stripping (guard 10) redacts amounts, so "pay ₹10k SIP" becomes
"pay [amount] SIP" before it reaches a model. That is correct and harmless —
the original is kept locally and the amount is not needed for classification —
but worth knowing before someone reports it as a bug.

**Start when** Brain v1 is frozen and the one-item-vs-series question is
answered. The grammar work could land earlier if it is useful standalone.

---

## B-06 — Views: the same data, shown several ways, each toggleable

**Idea (Ganesh, 2026-11-24).** *"These are various ideas how to show user the
data and user can turn off or on these views."*

The framing matters more than any single view in it. Brain's output today is
one ranked list plus a `startable` set. These ideas are **not new ranking
logic** — they are different windows onto the same scored graph, and the user
decides which ones exist for them. That keeps the charter's one purpose intact
while admitting the obvious truth that one list does not suit every moment.

Two of the five do add new data (journal, weekend intentions). Those are the
expensive ones, and they are flagged below.

### The architectural point: views are projections, not features

A view is a filter plus a sort plus a cap over the already-ranked set. If a
view needs its own scoring rule, that is a signal the scoring formula is
missing a term — and `docs/05-targets.md` already records one open question of
exactly that kind (the top-1 gap, where Ganesh's picks are 8× heavier than the
formula expects). **Resolve that before adding views that paper over it.**

A view registry with per-user on/off also means the UI layers must not hardcode
a list of views, which is a server/web/iOS design constraint worth knowing now
rather than after three clients ship.

### B-06a — The 1-3-5 board

*"1 big thing, 3 small things, 5 quick-win things."*

A shape that constrains the day rather than describing it. Pure T0: bucket the
ranked startable items by effort, take the top 1 / 3 / 5 from each bucket.

The effort buckets already exist (`02-scoring-spec.md`, geometric midpoints), so
"big", "small" and "quick" need thresholds drawn against those buckets rather
than invented. **Open question:** what happens when there is no big thing, or
seven quick wins of equal score? A board that silently drops items contradicts
the "captures lost 0" invariant in spirit even though the data is intact. The
honest answer is probably to under-fill the board and say so.

### B-06b — The quick-wins list (the long one)

B-06a shows five. This is the full set, ranked by leverage-per-minute. Already
half-built: `04-scorecard.md` measures a quick-wins notion, and B-04b named
`quick-wins-hunter` as a mode. This is that mode as a standing view.

Cheapest item in B-06 — a sort over existing numbers. No new data, no model.

### B-06c — Journal

**Adds data.** Free-text entries that are not tasks, not ideas, not notes bound
for the graph. The capture pipeline would need to learn that some input is not
meant to be organised at all.

This one deserves scrutiny before it is built. "Dump anything, it organizes it"
is the product; a journal is explicitly *un*-organised text. It may well belong
— reflection feeds planning — but it is the entry in B-06 closest to the
charter's edge, and it should be argued for on its own merits rather than
arriving as part of a batch. The type taxonomy would gain a sixth member, which
touches `TypeClassifier`, the label set, every dataset split and the T0/T2
comparison. That is not a small change.

### B-06d — Daily review and next-day planning

An end-of-day pass: what got done, what did not, what moves to tomorrow.

Mostly T0 — it is a diff over item status between two timestamps. The valuable
part is not the summary, it is that **a daily review is the only place the
product can learn whether its ranking was right.** Today Brain proposes an
order and never finds out. A review that records "I did these three, not the
three you suggested" is a labelled example generated by ordinary use, which is
exactly the training signal B5 and B6 need and currently have to buy with
Ganesh's manual ranking sessions.

That makes this the highest-value entry in B-06 by a distance, and it should be
sequenced accordingly — ahead of the board, despite the board being easier.

### B-06e — The weekend / long-pending view

*"Weekend big new thing, or pending from too much time."* Examples given: read
a full book, sit with yourself for an hour. The user can pre-plan — *"this
weekend I'll do this new thing"* — and we recommend from their own list or
suggest our own.

Three distinct mechanisms wearing one name, and they should be separated:

| Part | What it needs | Tier |
|---|---|---|
| Stale items ("pending too long") | age since capture, already stored | T0 |
| Pre-planned weekend intentions | **new data** — a user-authored list with a target weekend | T0 storage |
| Recommend from the user's own list | rank stale + large-effort items against a long free slot | T0, close to B-01 |
| Suggest something we invented | generating an activity the user never captured | **T2, and a new product claim** |

The first three are a time-budget problem with a long slot — B-01 with a
weekend-sized gap — plus an age signal Brain does not currently use. Staleness
is a genuinely missing input: nothing in the leverage formula notices that an
item has sat untouched for two months.

The fourth is different in kind. Suggesting "read a book this weekend" when the
user never captured it means Brain inventing content, and the charter is built
on the opposite principle — *AI proposes, deterministic code verifies, the
human confirms* — with proposals grounded in what the user actually dumped.
Not forbidden, but it is a new product claim, it is the only part of B-06 that
requires a model call, and by the AI Justification Test it needs measured T0
coverage first. Build the first three; argue the fourth separately.

### Why none of this is now

Every item here is a presentation layer over a ranked set whose ranking is
still being validated. Ganesh's re-ranking pass and `make agreement` will say
whether top-3 at 71.4% is at the human noise floor or genuinely short. Building
five ways to display a number we are not yet confident in would multiply the
cost of changing it.

**Start when** Brain v1 is frozen and the agreement number is in. Sequence:
B-06d first (it generates training signal), then B-06b (nearly free), then
B-06a, then B-06e's T0 parts. B-06c and B-06e's suggestion engine each need an
argument of their own before they are scheduled at all.
