# DECISIONS

Append-only. Newest at the bottom. Every non-trivial choice, with its reason.
Formal ones get an ADR in `docs/adr/`; this is the running log.

---

### 2026-11-22 — Verified the toolchain instead of recalling it
Swift 6.4.3, Hummingbird 2.29.0, swift-openapi-generator 1.14.4, PostgresNIO
1.33.3, swift-jobs 1.4.0. Gemini docs have moved from `ai.google.dev` to
`aistudio.google.com`; **Gemini 2.5 is deprecated.** Full table in
`docs/08-dev-environment.md`. Re-verify at every phase gate.

### 2026-11-22 — Could not verify two things, and said so
Gemini free-tier limits are no longer published per model (now per-project in AI
Studio), and Supabase's inactivity-pause threshold is not in its official docs.
Both recorded as unknown rather than guessed. The first was resolved when Ganesh
supplied his account's actual numbers.

### 2026-11-22 — ADR-0001: Hummingbird 2 for the server.

### 2026-11-22 — ADR-0002: free tier in production, disclosed in T&C.
I raised the data-use concern; Ganesh decided; the capacity math supports it.
Objection withdrawn on capacity grounds.

### 2026-11-22 — The headline free models are a trap
Gemini 4 Hydrogen / 3.8 Flash / 3.6 Flash sit at **20 RPD** — twenty captures a
day. Usable free capacity is **Gemma 4 (14,400 RPD)** and **Gemini Decision 1
(10,000 RPD)**. The binding constraint is TPM, not RPM.

### 2026-11-22 — Gemini Decision 1 looks structurally well suited, and is unproven
Closed-set decisions with natively calibrated probabilities. It would make three
guards structural rather than defensive: hallucinated IDs become impossible,
there is no JSON to fail parsing, and calibration arrives for free. **But it is
eleven days old and I have not called it.** Therefore **B3 runs two tracks** —
generate-and-parse on Gemma 4 vs. Decision 1 — and the scorecard picks. Costs
1–2 days, derisks the architecture.

### 2026-11-22 — ADR-0005: embeddings local, never API (1,000 RPD ≈ 50 users).

### 2026-11-22 — Per-user fair-share quota is mandatory, not optional
RPD is one bucket shared by all users. Without fair share, one person pasting a
long brain dump starves everyone for the day.

### 2026-11-22 — Hosting: Oracle Always Free primary, Contabo Mumbai fallback
Oracle's Always Free ARM was **halved** (4 OCPU/24 GB → 2/12) in June 2026 with
no announcement, so it is treated as revocable. Hostinger's ₹779 is a promo —
renewal reported at $11.99–$24.49 — so the renewal line must be checked before
committing. Hetzner has no ARM outside the EU and raised prices twice in 2026.

### 2026-11-23 — ADR-0003: one repo per component.
Friction acknowledged, mitigation recorded.

### 2026-11-23 — ADR-0004: deterministic code before any model
Ganesh's calculator framing. Four tiers with **T3 (ask the user) before T2**.
Adds phase **B2.5, the T0 baseline**, which replaces the AI run as the thing
everything must beat. Introduces the **AI Justification Test**.

### 2026-11-23 — Scoring: added a base term `w_b`
Without it every unlinked leaf task scores exactly 0 and the list ties. With it,
a leaf task ranks on effort alone — so **quick wins fall out of the formula**
instead of being a special case. Effort is compressed logarithmically; raw
minutes would make tiny:xlarge 1:192 and a trivial errand would always win.

### 2026-11-23 — Ranking metric changed from top-1 to top-3
Top-1 agreement was self-grading when the same person authors the scenarios and
the formula. Replaced with "human's #1 in our top 3" + NDCG@5, **and Ganesh
authors the ground-truth rankings without seeing the formula.**

### 2026-11-23 — Real captures get a 50/20/30 split, not 70/20/10
300 real captures at 70/20/10 leaves 30 test rows — a 95% interval of 74–97%,
which cannot distinguish 90% from 78%. Weighted toward test instead (90 rows,
±6 pp). Real-data metrics remain **directional**; the synthetic test split
carries the statistical weight. The scorecard never merges the two.

### 2026-11-23 — ADR-0006: CI manual-trigger only. ADR-0007: Supabase JWKS.

### 2026-11-23 — Real captures are gitignored
`datasets/real/` never enters git. A private repo is not the same as
not-on-a-server. Only synthetic data is committed.

### 2026-11-23 — B0 complete. Awaiting approval of 01, 02, 03, 04, 06, 09.

---

### 2026-11-23 — B1 begins. Core is dependency-free on purpose
`BrainCore` has **zero package dependencies**. Property tests use a seeded
`SplitMix64` rather than a property-testing library, so every failure is
reproducible from its seed and printed in the failure message. No flaky tests.

### 2026-11-23 — `next` is the top **startable** item, not the top ranked
Found by scenario test S2, which initially asserted the wrong thing. A blocked
item can legitimately rank first — a two-minute form due today, stuck behind a
multi-day document hunt — but recommending something the user cannot start is
worse than recommending nothing. `ranked` still shows it, marked, with its
blockers. `BrainOutputs` gained a `startable` list; `next` is its head.

### 2026-11-23 — The formula promotes unblockers for free
Discovered while fixing S2: a blocker transitively reaches everything its
dependent reaches, **plus the dependent itself**, so it almost always outranks
it without any special-casing. Constructing a genuinely blocked top-ranker
requires effort or deadline asymmetry. This is emergent, not designed, and is
worth knowing before anyone "fixes" it.

### 2026-11-23 — "kal" and "parso" resolve to the future, with lower confidence
Both words mean their past and future counterparts in Hindi ("kal" is yesterday
*and* tomorrow). In a capture the future reading dominates, so we take it — and
drop confidence from 0.95 to 0.8 so the ambiguity is visible to the cascade
rather than hidden. Asserted by test.

### 2026-11-23 — Hinglish period words are mapped explicitly, not approximated
"raat 12 baje" is midnight, "dopahar 12 baje" is noon, "raat 2 baje" is 2 a.m.
My first implementation got all three wrong by treating the periods as plain
AM/PM. Each is now spelled out in `DateParser.hour(period:rawHour:)`. This is
precisely the class of thing a model gets subtly wrong and code gets exactly
right — the argument for T0, in one function.

### 2026-11-23 — A bare "N baje" is a heuristic and is scored as one
With no period word, 8–11 reads as morning and everything else as evening
("5 baje" → 17:00, "9 baje" → 09:00). Confidence 0.7, deliberately below every
other date rule, so the cascade can escalate it rather than trust it.

### 2026-11-23 — A date with no time is due at end of day
"kal" means *by* the end of tomorrow, not at midnight. Weekdays resolve to the
next occurrence strictly after today; "next Monday" is ambiguous even to native
speakers, so it carries lower confidence rather than a hidden guess.

### 2026-11-23 — swift-format owns formatting
`.swift-format` sets 4-space indent and a 100-column limit; the rest is the
formatter's business. Hand-aligning and then arguing with the linter is waste.

### 2026-11-23 — `make eval` / `make gate` skip loudly until B2
EvalCLI does not exist yet. They print a SKIP line and exit 0 rather than
failing the build or, worse, passing silently. CI calls the same Make targets,
so `make ci` and GitHub Actions cannot diverge.

### 2026-11-23 — B1 complete: 59 tests, Core + dogfood CLI, no AI anywhere.

### 2026-11-23 — Scenarios committed before any scoring ran against them
The 30 ranking scenarios went in at commit `b9d7230` with `expected: null`,
before a single leverage number was computed on them. The history is the
evidence that they were not shaped to suit the formula. I have not looked at
what the formula says about any of them.

### 2026-11-23 — Ranking is blind by construction, not by discipline
`brain rank` never prints a score, a leverage value, or the scenario's `tests`
field. Item order within a scenario and scenario order across the sitting are
both deterministically shuffled, so position and fatigue cannot correlate with
scenario type. Resumable, because 30 in one sitting is optimistic.

### 2026-11-23 — Capture ingest takes the loosest possible input
One capture per line, nothing else. Anything that forces structure at collection
time changes *what gets collected* — and messiness is the thing being measured.
Ids derive from content (FNV-1a), so re-running ingest is idempotent and a
capture keeps its split forever; adding more data never reshuffles existing rows.

### 2026-11-23 — FNV-1a replaces SHA-256 for splitting
Splitting needs stable, well-spread and dependency-free, not cryptographic.
`docs/03-dataset-schema.md` updated to match the implementation rather than
leaving the doc aspirational.

### 2026-11-23 — Scenarios are authored as one-liners, not JSON
`brain add-scenarios` reuses the same `.brain` format as the dogfood CLI, with
`scenario:` lines as separators. Nobody should hand-write JSON to describe four
tasks, and reusing the dump format means there is one syntax to learn, not two.
Absolute dates convert to day offsets on write, so a scenario means the same
thing whenever it is read.

### 2026-11-23 — Backlog file created, so good ideas stop becoming scope creep
`docs/12-backlog.md`. Three entries so far: time-budget "what fits in this gap"
(B-01), timers/pomodoro (B-02), role and mindset (B-03). Each records why it is
not now and what would have to be true to start it. The five hard non-goals are
not backlog — they are rejected.

### 2026-11-23 — Role and mindset: right instinct, wrong mechanism
Ganesh's observation is correct: the same person ranks differently on different
days, and roles differ systematically. But **a feature that cannot be observed
at inference time cannot improve a prediction.** Training
`P(ranking | items, role, mindset)` and then never learning role or mindset for
a real user means averaging over them at inference — identical to never having
used them.

Split into three uses:
- **B-03a — measure the ceiling.** Rank the same scenarios twice on different
  days. If self-agreement is 75%, no model can beat 75% and the ≥90% target in
  `05-targets.md` is fiction. Nobody can supply this number but a human.
  **Built: `make rank-again` and `make agreement`.**
- **B-03b — condition scenario *generation* on role.** Diversifies inputs.
  Folded into B2. But **never** condition ground-truth rankings on an imagined
  role: ranking "as a student would" is data about our model of students, and
  training on it bakes in a stereotype while looking like signal.
- **B-03c — train on declared role to predict ranking.** Dead end as specified.
  **B6 per-user personalisation already solves the real problem**, implicitly,
  from what the person actually does rather than from a label.

### 2026-11-23 — Second-pass rankings stored separately, never overwriting
`rank --again` writes to `second_pass`, leaving `expected` untouched, and never
shows the earlier answer. Overwriting would destroy the only data that can tell
us the noise floor.

### 2026-11-23 — Role is dropped. Measured, not argued.
Three independent analyses plus my own direct check: **404 of 404** same-mood/
different-role pairs across the three generated files have byte-identical picks.
Change the role, hold the mood, and the answer never moves. Same role with a
different mood agrees 0-14% of the time. The pick list is a pure function of
`(scenario, mood)`; 893 role strings carry no decision value.

This is the empirical form of `12-backlog.md` B-03c, and stronger than the
argument there: a model trained on this data would **correctly** learn to ignore
role. Keeping it triples the apparent size of the eval while conditioning on a
null variable.

### 2026-11-23 — The generated datasets are fixtures and a mode spec, not ground truth
15,509 picks with zero hallucinations, zero constraint violations, 100% parse
integrity — and **zero case-only or whitespace-only near-misses**, which over
15,509 opportunities proves they were emitted programmatically rather than
written. A rationale is a pure function of `(mood, slot, effort, due, unblocks)`.

Scoring a ranker against them measures "did we reimplement the generator", not
"do we match human judgment", so they cannot satisfy the AI Justification Test.
**Ganesh's 30 hand-ranked scenarios remain the only human ground truth.**

What they are genuinely good for is recorded in `docs/13-generated-datasets.md`:
a specification of twenty mode policies (17 of them clean T0 rules), and the
discovery of a `category` field we do not model.

### 2026-11-23 — Real bug found: a clock time with no day word was discarded
`shaam 5 baje` and `9am` both parsed to nothing. `parse()` returned nil whenever
no *date* rule matched, throwing away a time it had already found — silently
losing a date the user had plainly stated. Now resolves to the next occurrence
of that clock time (today if still ahead, else tomorrow, matching the
roll-forward convention the dated rules already use), at reduced confidence
because the day was inferred rather than stated. Regression test added.
Also added `this week` / `is hafte` / `weekend`.

### 2026-11-23 — Where our grammar and the data disagree, the grammar wins
The dataset headers claim `agle hafte` = Fri 4 Dec; `matchNextPeriod` gives Mon
30 Nov (now + 7 days). The data is wrong, not the parser. Logged for whoever
regenerates it, along with `large` being rendered "about 3 hr" when
`Domain.swift` says 240 min.

### 2026-11-23 — Generated data moved out of `examples/`
`examples/` is for files a human copies and edits. 1.9 MB of generated fixtures
is not that. Now `datasets/generated/`.

### 2026-11-23 — Scenario dev/test split stamped: 21 dev / 9 test
Assignment is a pure function of the scenario ids, so nobody chose which are
held out. **Stratified rather than per-id hash**: a per-id hash on 30 scenarios
landed 24/6, and a 6-scenario held-out set carries a ±24 point interval. Sorting
by hash and cutting at 70% gives the exact proportion at any n while remaining
deterministic.

The trade-off is that adding scenarios can move one across the boundary, which
is acceptable only while the test set has never been looked at. `brain split`
therefore **stamps the assignment into the files and never overwrites an
existing stamp** without `--restamp`; re-running is a no-op. Once a test number
is reported at a phase gate, the split is frozen by construction, not by
discipline.

At 9 ranked test scenarios a measured 90% carries a ±20 point interval. That is
directional, not decisive, and the tool says so every time it runs. More
scenarios narrow it.

### 2026-11-23 — AI Justification Test: task `category` stays at T0
Required by `docs/09-tiering.md` before any model call could be proposed for this
field.

1. **Deterministic approach tried:** a keyword lexicon over the task title,
   split into strong terms (objects plus unambiguous verbs) and weak terms
   (ambiguous verbs), with a leading-position bonus and an abstention margin.
2. **Measured, on 1,308 labelled titles** extracted from `datasets/generated/`
   (the generators leaked category into their rationale strings, giving a free
   validation set):
   - **accuracy on attempted 80.1%**, **coverage 83.6%**, **accuracy overall 67.0%**
   - strongest: planning 77.7%, errands 76.8%, communication 76.5%
   - weakest: health 43.5%, chores 59.5%
   - all four weights and the margin were **swept**, not chosen by feel
     (`make category-sweep`)
3. **Why the remainder does not yet need a model:** the residual is mostly
   genuinely ambiguous titles ("check the pantry" vs "check the portal"), where
   abstention is the correct output and escalation to T1/T3 is the design. A
   model call is not justified until T0 is exhausted *and* the remaining errors
   are shown to be model-solvable.
4. **Tier and fallback:** T0, abstaining to `unknown`, which escalates.

**A caveat that matters: the labels are themselves generator-assigned**, so 80%
agreement is not 80% correct. The true ceiling is unknown and probably lower than
100%, because many titles are genuinely ambiguous. Treat these as directional.

**Finding worth keeping:** the intuition that the *object* should outweigh the
*verb* ("book a dentist" vs "book a flight") is **wrong on aggregate** —
inverting the weights drops overall accuracy from 67.0% to 64.8%. The leading
verb is the more informative signal. "Book a dentist appointment" classifying as
`planning` is a measured cost of the global optimum, pinned by a test so nobody
"fixes" it and makes things worse.

### 2026-11-23 — Real bug: the dataset split was not random
`DatasetSplit.hash` used raw FNV-1a. Its trailing bytes have weak avalanche —
the last byte is XORed and multiplied exactly once — so ids sharing a prefix
hashed in near-sequential order. The effect was invisible until the scenario
set grew: **all 30 already-ranked scenarios landed in `test`**, leaving nothing
to tune against. That would have silently biased every split in the project,
including the real-capture splits.

Fixed with a SplitMix64 finalizer, so a one-character change moves ~half the
output bits. Two regression tests pin it: rank/sequence correlation must stay
below 0.2, and mean flipped bits between adjacent ids must sit near 32.

### 2026-11-23 — Ranked and unranked scenarios are stratified independently
Pooling them let chance put every ranked scenario on one side. Splitting each
group 70/30 separately guarantees both sides carry human-ranked ground truth.
Now 21 ranked dev / 9 ranked test, with the 100 imported blanks at 70/30.

### 2026-11-23 — 100 generated scenarios imported for human ranking
The generated *task lists* are sound; only the answer key was worthless. So the
answers are stripped and a human ranks them instead.

Random sampling would have wasted that effort. Of 897 generated scenarios:
- **353 rejected** — fewer than 4 startable tasks, so the answer is near-forced
- **281 rejected** — all four candidate policies (leverage, deadline-first,
  quick-win-first, unblocker-first) pick the same top task, so a human answer
  cannot discriminate between designs
- 263 survived; 100 selected, round-robin across structural traits
  (blocked chains, deadline conflicts, goals, mixed effort, mixed category) so
  no single shape dominates

That is active learning (§5.7 of the brief): rank the cases the system is least
sure about. **Only ~29% of the generated set was worth a human's time**, which
is the argument against ranking all 800+.
