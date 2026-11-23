# 12 — Backlog: ideas recorded, deliberately not built

Nothing here is in Brain v1. This file exists so good ideas are not lost and do
not become scope creep. Each entry says what it is, why it is not now, and what
would have to be true to start it.

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

- **Cost:** re-rank 12–15 scenarios on a different day, roughly 10 minutes.
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
