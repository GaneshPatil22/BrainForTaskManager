# 15 — The planner: commitments, periods and reviews

> Commitments are **scheduled**. Candidates are **ranked**. Keeping them apart
> is not cosmetic — it is what stops the capture product from dying.

**Accepted 2026-11-24 (Ganesh).** A year-long day planner sits alongside the
capture-and-prioritise core. This document is the spec; it supersedes B-05,
B-06c and B-06d in `12-backlog.md`, and pulls B-01 in with them.

## Why this belongs in Brain rather than beside it

The leverage formula has three terms: `unblocks`, `servesGoals`, `duePressure`.
In production **`servesGoals` is 0 for every item**, because nothing ever
assigns a goal — so ranking is really just unblocks plus due pressure.

Declared monthly and quarterly goals are the missing input. *"Start iOS
contract job hunt flow"* for the month, rolling up to *"iOS contract job"* for
the quarter, is what makes "this task is worth more than that one" defensible.
The planner is not scope creep against the ranking engine. It repairs it.

## The two kinds of thing

| | Commitments | Candidates |
|---|---|---|
| Examples | read 10 pages, Friday 3h office block, Sunday review, rent on the 4th | everything dumped into capture |
| Decided | once, by the user | continuously, by the user |
| Surfaced by | the calendar | the ranking |
| In `ranked`? | **never** | yes |

Nine daily commitments plus rituals and payments is ~10 rows every single day.
If they enter `ranked`, "the one thing to do next" is permanently a habit
checkbox. `Brain.compute` therefore returns commitments as their **own
section**, never as rows in `ranked`.

**The hinge: "one big task".** It is a daily commitment whose *occupant* comes
from the ranked pile. The planner supplies the slots; Brain fills the
discretionary ones. That is what makes these one product and not two.

**This is not the 1-3-5 board.** The board (B-06a, still parked) is a
toggleable *display* that groups today's rows by effort size. "One big task"
is a *commitment*. They share a word and nothing else: the big task surfaces
as Today's Do-next card, which renders whether the board is on or off, so
nothing in this spec depends on the board existing or being any good.
Ganesh's instruction, 2026-11-24: *"that is not our primary thing, it's just
one thing and I like that so I can toggle it on/off from settings."*

## Charter boundaries

`00-charter.md` rejects expense tracking and gym/health without discussion.
The line, agreed with Ganesh:

| In | Out |
|---|---|
| "Pay rent 22k" as a monthly reminder, amount in the title or a note | Any sum, category, trend or report over amounts |
| "Move body" as a daily habit with a streak | Reps, weight, calories, workout plans |

B-05 already listed *"₹10k ICICI SIP on the 15th"* as a legitimate recurring
reminder, so money-on-a-date has precedent in these docs. **Nothing ever adds
amounts together.** The moment a total appears, that is the rejected product.

## Resolved decisions

### D1 — Template plus lazily materialised instances

The B-05 fork, answered: **one `Commitment` template; occurrences computed on
read; a row persisted only when the occurrence carries state** (done, skipped,
moved).

Generating a year eagerly is ~3,000+ rows per user, almost all empty
`pending`. Expansion is pure arithmetic and cheap. The table then stays
proportional to what was actually done, not to how long the app has been
installed.

### D2 — A missed day is forgiving daily, visible weekly

Yesterday's unread 10 pages does **not** carry forward as debt. Tomorrow shows
one fresh occurrence and the streak resets. The Sunday review surfaces the
pattern ("4 of 7 on reading").

**Consequence worth stating:** a miss needs **no row at all**. Expansion gives
the expected occurrences; persisted rows give the actuals; *missed = expected
minus actual*. D2 and D1 reinforce each other — the forgiving model is also
the cheap one.

### D3 — Calendar quarters

`2026-Q1` is January–March, not the Indian financial year. These are personal
goals, not tax periods. (`12-backlog.md` raised the fork; this settles it.)

### D4 — Brain proposes the big task, the user confirms

The next-day planning ritual shows Brain's top-ranked pick; the user accepts
or swaps it. Invariant 3 holds — a proposal is never a decision.

**A swap is a correction.** It records against the tier that ranked, in the
`corrections` table that already exists, with field `bigTask`. That makes the
richest training signal in the product a by-product of normal use.

## Recurrence grammar

Five shapes cover every case in the brief. A closed enum, not an RRULE
library: five shapes do not justify a dependency, and a closed set is
T0-testable.

| Shape | Example from the brief |
|---|---|
| daily | read 10 pages, ukulele, move body, 3-line journal |
| weekly on weekday | Sunday plan/review; Friday 3h office block |
| monthly on day-of-month | rent on the 4th, loan on the 9th |
| monthly on nth weekday | month review on the first Saturday |
| quarterly | quarter goals |

`src/local/repeats.ts` in the web app already implements the first three,
with month-day clamping and streaks, and is tested. Lift it rather than
rewrite it. **New here: nth-weekday and quarterly.**

Calendar edge cases, as `12-backlog.md` enumerated them: the 31st in a 30-day
month (clamp to last day), 29 February, "first Saturday" when the month opens
on a Saturday, quarter boundaries, and DST — everything resolving in the
user's zone, never the server's.

## Entities

| Entity | Notes |
|---|---|
| `Commitment` | title, kind (habit/ritual/payment/block), rule, minutes, category, optional `goalId`, active window, paused |
| `Occurrence` | `commitmentId` + date + state. **Only persisted once it has state** (D1) |
| `Goal` | gains `horizon` (quarter/month), period bounds, `parentGoalId` for month→quarter rollup |
| `JournalEntry` | its own entity, **not an `Item`** |
| `DailyPlan` | the confirmed big task per day, and whether it was a swap (D4) |

**Why the journal is not an `Item`** — the argument B-06c asked for. A 3-line
entry does not rank, does not block, has no effort and no open/done status.
Putting it in `Items` pollutes every list, every filter and every scorecard
slice, in exchange for no reuse.

## Scoring changes

1. Commitments are excluded from `ranked` and returned as their own section.
2. `servesGoals` counts only the **current period's** goals, so a task serving
   this month outranks one serving a lapsed goal.
3. **B-01 (time budget) is pulled in.** Nine daily commitments are 3–4 hours
   before any captured work. Today already computes "about 4h 25min left". A
   planner that recommends a big task into a day with no room is worse than no
   planner, so the committed load is subtracted before Brain offers more.

## Capture stays the single door

"har mahine 4 ko", "every Friday", "roz", "har sunday" — recurrence is the
existing date grammar with a quantifier, and `DateParser` already handles
"15 tarikh". A capture that states a repeat should **propose** a commitment,
confirmed like any other suggestion. No model: T0, passes the Justification
Test without argument.

## Build order

The gate between each step is the usual one: measured, reviewed, then the next.

| Step | Where | Why here |
|---|---|---|
| 1 | Server + Web | Timezone bug; corrections export. The export must exist before friends generate data worth having. |
| 2 | **Brain** | Recurrence engine, period goals, scoring split. Pure, offline-testable, proves itself with no server or UI. |
| 3 | Server | Migrations, endpoints, `/v1/plan` extension, materialise-on-read. |
| 4 | Web | Swap `src/local/*` to the server; then review, journal and month screens. |
| 5 | Web + Server | Reminders and PWA. A planner you must remember to open is not a planner. |
| 6 | Brain | Duplicates, dependency backfill, T3 questions. |

Steps 2–4 are roughly as much work as the capture half already built.

## Deliberately not in this spec

- Any arithmetic over amounts (charter).
- Fitness modelling of any kind (charter).
- Calendar integration, invitations, or anything multi-person (charter:
  collaboration).
- RRULE, iCal import/export. Five shapes, closed enum.
- Auto-generated goals. `01-domain.md`: goals are only ever created by the user.
