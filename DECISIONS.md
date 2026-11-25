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

### 2026-11-23 — EvalCLI and the scorecard exist; first baseline promoted
The eval harness now reports real numbers. Structure: `BrainEval` is a
**library**, not code buried in the executable, because the thing that reports
every number this project will ever claim must itself be tested. 14 tests cover
NDCG (perfect / miss / reversed / monotonic / empty), the gate (regression,
tolerance, improvement, hard limit, unmeasured, lower-is-better, new metric) and
rendering.

`BrainDatasets` was extracted so file formats are shared by the CLI and the eval
runner while `BrainCore` stays pure — no I/O, no file formats.

**Unmeasured metrics print `not measured`, never `0.000`.** A zero that looks
like a result is worse than no result, so the type makes `value` optional and
the renderer refuses to invent one. Six metrics are currently unmeasured, each
annotated with the phase it arrives in.

**The test split is refused outside a gate run**, enforced in code rather than by
discipline: `EvalCLI run --split test` errors and tells you to use `dev`.

First baseline promoted at `eval/baselines/dev.json`, committed so it can gate.
Promotion requires `--reason` and is never automatic — an improvement is
reported but never silently absorbed.

### 2026-11-23 — First real ranking numbers, on the dev split
From 28 human-ranked dev scenarios, T0 only, no model anywhere:

- **human pick in top-3: 85.7%** (±19pp at 95%, n=28)
- **human pick is our top-1: 35.7%**
- **NDCG@5: 0.782**
- category resolved at T0: 82.3% · date phrasings parsed: 100% of 27
- ranking deterministic: yes · graphs with cycles: 0 · p95 latency: 0.1 ms

Read honestly: top-3 is near the ≥90% target but the interval is ±19pp, so it is
directional. **Top-1 at 35.7% is the interesting number** — our first pick is
usually not Ganesh's first pick, even though his is usually in our top three.
That is a real signal about the weights, and the right thing to investigate once
the full 91 dev scenarios are ranked. Tuning on 28 would be fitting noise.

### 2026-11-23 — The two missing Hinglish T0 rules are implemented
Both were named in `docs/09-tiering.md` and neither existed. There was no
duration parsing at all — not even English "20 min".

**`EffortParser`** — English and Hinglish durations, fixed phrases
("aadha ghanta", "poora din", "half an hour") and low-confidence qualitative
hints ("jaldi", "quick"). Bucket boundaries are the **geometric** midpoints of
the bucket minutes (10 / 35 / 120 / 480), matching the log-scale denominator in
`Scoring.effortDenominator`; arithmetic midpoints would sit in the wrong places.
Boundary values round *up*, the conservative choice — over-estimating effort
lowers leverage, so a borderline task is never over-promoted.

**`DependencyParser`** — "after X", "once X is done", "waiting for X",
"blocked by X", "needs X first", plus Hinglish "X ke baad", "X hone ke baad",
"X ka intezaar". Hinglish puts the referent *before* the marker and English
after it; one `Position` field handles both word orders.

**`TitleMatcher`** resolves a referent to an item, deliberately conservatively:
below threshold it returns nothing, so an unmatched reference produces **no
edge** rather than a wrong one.

Three things worth recording:

1. **"due in 2 days" is a deadline, not a duration.** Without a date-lead-in
   guard, every relative due date also registered as xlarge effort. Both
   parsers now cross-check against the date grammar.
2. **The date cross-check needed two parts.** Checking the referent alone missed
   "after 3 days" (the grammar needs the "in"/"after" prefix, already consumed).
   Checking anything date-shaped would have rejected "after the client meeting
   on monday", a genuine dependency. So: a bare-duration pattern, **plus** a
   date match covering ≥60% of the referent. Both cases are pinned by tests.
3. **A self-matching title shadowed the real target.** An item's own title
   contains its referent, so it tied with the real match, won on id order, and
   was then discarded by an `!= itemId` check — losing the genuine edge with it.
   Callers must exclude self *before* matching. Regression test added.

Inferred edges are `source: .t0Rule, confirmed: false`. The user wrote the
phrase, but the *parse* may be wrong, and invariant 3 reserves `confirmed` for a
human. Blocking still applies structurally — the item is correctly excluded from
`next` — only the leverage credit waits for a confirming tap.

99 tests green.

### 2026-11-23 — Adversarial set built; it found two real bugs immediately
34 rows across all ten attack types named in `docs/03-dataset-schema.md`,
generated by `scripts/make-adversarial.py` rather than hand-written: some rows
are 60k characters and others carry invisible control or zero-width characters,
neither of which survives a careless edit. The script, not the JSONL, is the
source of truth, and regeneration is verified idempotent.

**Bug 1 — catastrophic regex backtracking. 53 seconds on one capture.**
`DependencyParser` patterns open with a lazy quantifier; on a 60k-character
input with no match, NSRegularExpression retries from every position. Measured
**52,630 ms**. In production a single large capture would have hung a worker for
most of a minute. Fixed with a cheap literal pre-check per rule plus bounding
the referent to 80 characters: **13 ms**, a 4,000× improvement. `Category` was
also 230 ms because it probed an Array; a Set took it to 15 ms.

**Bug 2 — declaration order was deciding, not text position.**
"kal kal kal parso kal" resolved to *parso*, because the parso rule must be
listed before kal so "day after tomorrow" is not eaten by the "tomorrow" rule.
Same flaw in `EffortParser`: "1 ghante 20 min" scored 20 minutes. Both now pick
the **earliest match**, ties broken by rule order — specificity still wins where
two rules overlap, because the longer phrase starts earlier. Qualitative effort
hints remain a last resort regardless of position.

Also found: `planning` was not in the category lexicon, only `plan`.

**Six of my own expectations were wrong, not the code.** I had asserted
abstention for texts that plainly carry category signal ("call the plumber",
"read this…"). Corrected the data, not the classifier.

**Injection rows are staged, not scored.** Ten rows exist and are marked
`evaluated_at: B3`. With no model in the loop there is nothing to be
non-compliant with, so the metric counts them as *deferred* and
`injection resistance` still reads `not measured`. Scoring them now would be
theatre.

### 2026-11-23 — The gate now distinguishes a sample change from a regression
Promoting the first baseline at n=28 and re-running at n=54 failed the gate on
all three ranking metrics. The code had not regressed — Ganesh had simply ranked
more scenarios. The gate now annotates any failure where the sample moved by
more than 20%: `[SAMPLE CHANGED n=28→54: likely not a code regression]`.
Without that, a growing dataset makes the gate cry wolf until it is ignored.

### 2026-11-23 — The first ranking number was flattering, and the honest one is worse
At n=28: top-3 **85.7%**. At n=54: top-3 **70.4%**, top-1 **27.8%**, NDCG@5
**0.737**. The early figure was small-sample noise, which is exactly why no
weights were tuned against it. 70.4% is far below the ≥90% exit target in
`docs/05-targets.md`, and the interval is now ±13pp rather than ±19pp.

This is real signal, not a defect in the data: our top pick matches Ganesh's
roughly a quarter of the time. Weight tuning waits for the full 91 ranked dev
scenarios, then happens on dev only.

### 2026-11-23 — Synthetic captures are composed, not judged
2,000 captures from `scripts/make-synthetic.py`, every label true **by
construction**: the text is assembled from a chosen date phrase, duration, verb
and object. Judged labels on generated text measure whether we reimplemented
the generator — `docs/13-generated-datasets.md` has the full argument.

Vocabulary deliberately mixes terms the lexicon knows (60%) with terms it does
not (40%), so the honest output is a **coverage** number. Generating only from
the lexicon would score ~100% and mean nothing. 65% of rows contain Hinglish.

### 2026-11-23 — B2.5 T0 baseline measured. This is what B3 must beat.
```
type accuracy            80.7%   n=415
type — unfamiliar verb   56.4%   n=163   ← the honest slice
date accuracy            97.9%   n=187
effort accuracy          91.8%   n=147
dependency recall        68.1%   n=69
span-verified rate      100.0%   n=406
```
Almost every type failure is one thing: **an imperative we do not recognise**
(36 tasks read as notes). That is precisely the gap a model is for, and
precisely the comparison B3 has to make.

### 2026-11-23 — Real bug: the eval harness had the wrong clock
`now` existed as three separate literals and one was `1_795_000_000` —
**Wednesday 18 Nov 2026**, not Monday the 23rd. Date accuracy read **52.2%**;
with the correct constant it is **97.9%**. The parser was right the whole time
and the harness was scoring it against the wrong day.

A wrong clock in the harness is worse than a wrong parser: it makes correct code
look broken, and the obvious response is to "fix" the part that is fine. Now
defined once, in `SyntheticLoader.now`, with a comment saying why.

### 2026-11-23 — My generator produced an unlearnable label
`task` rows could carry dates and `reminder` rows always did, so "clean the
kitchen kal" was labelled `task` in one row and `reminder` in another, at
random. 51 of 212 tasks were scored wrong against a label no reader could have
produced either.

Fixed by making the distinction real: **a reminder is time-anchored** ("call
Priya kal subah 9 baje"), **a task merely has a deadline** ("clean the kitchen
kal"). `TypeClassifier` now keys on a clock time rather than any date. Type
accuracy went 66.5% → 80.7% — not because the classifier improved, but because
the question became answerable.

**A label that is not identifiable from the input is a generator bug, not a
model failure.** Worth remembering when B3's numbers look bad.

### 2026-11-23 — B3 begins with the guards, not the model
No API key exists yet, so B3 splits: everything except live calls is buildable
and testable now. Starting with the guards is deliberate — they are the reason
a model is allowed near this system at all.

`BrainHarness` added: the `LLMProvider` protocol, `Capability` (the pipeline
asks for a capability, never a model), request/response types, and guards
1, 3, 4, 7, 10 and 12 from `docs/07-harness-spec.md`. 28 tests.

Three design points worth recording:

**The request carries its own closed option set.** `allowedAnswers` is part of
`ModelRequest`, so the ID whitelist is a set-membership check in code rather
than a property we hope the model has. That is what makes the hallucinated-ID
target *exactly 0* instead of "low".

**Schema validation normalises before rejecting.** Models wrap answers in
quotes, markdown and prose. Discarding a correct answer in a slightly wrong
shape would be its own bug, so decoration is stripped and a single permitted
value inside a wordy reply is recovered — but two permitted values is genuine
ambiguity and is rejected.

**Token estimation is deliberately pessimistic.** ~3.2 chars/token plus a
non-ASCII surcharge, not the usual 4. Romanised Hindi fragments into more
tokens than English, so an English-tuned divisor would under-count exactly the
inputs we care about — and TPM is the binding free-tier constraint.

Guards 5 (deterministic dates) and 6 (cycle rejection) are deliberately absent
from `GuardConfig`: they are invariants enforced in `BrainCore`, not features to
toggle and measure. A configuration where a model supplies a date is not one we
want to be able to run.

### 2026-11-23 — Correction: the previous commit claimed `make ci` passes. It did not.
Commit `3efc6d8` ("B3: the harness guards") says "make ci passes" in its
message. The gate failed immediately afterwards. I checked `swift test` and
assumed the rest followed. Recorded rather than quietly fixed, because a commit
message that overstates verification is worse than one that says nothing.

### 2026-11-23 — Gate tolerances must respect the metric's own sampling noise
The failure above was real, and the cause was my tolerance design. Ranking
top-3 moved 71.2% → 69.1% with n going 66 → 68 — a 2.1pp wobble against a
declared 2pp tolerance, on a metric whose 95% interval is ±12pp.

**One standard error at n=68, p≈0.7 is about 5.6pp.** A 2pp tolerance was
inside the noise, so the gate was flagging randomness as regression. A gate
that cries wolf gets ignored, which is worse than having no gate.

Effective tolerance is now `max(declared, 1 standard error)`, computed only for
proportions — counts, booleans and latencies are not sampled that way. The
failure message says when it has been widened and why. As n grows the widening
shrinks on its own, so the gate tightens automatically as the dataset improves
rather than needing a hand-tuned constant.

Also lowered the sample-change annotation from a 20% move to 5%: an 11% drift
had previously slipped through unannotated and looked like a code regression.

### 2026-11-23 — The scoring formula is missing a term, not mistuned. Measured.
Top-1 agreement sat at 24.3% on 74 ranked dev scenarios. Diagnosis (`make
diagnose`, read-only) says what the disagreements look like:

```
When we disagree (53 cases):        ours      theirs
  effort (minutes)                 18.87    150.09
  due pressure                      0.38      0.27
  unblocks                          0.23      0.34
  goals served                      0.58      0.34

  their pick is heavier              77.4%
  their pick is more urgent          18.9%
  their pick unblocks more           15.1%
  their pick has no deadline         71.7%
```

**Ganesh picks the big substantive thing; the formula picks the cheap quick
thing.** His picks are eight times heavier on average. They are not more
urgent, do not unblock more, and mostly have no deadline at all — so none of
our existing terms explain them.

A 900-combination grid search over `effortExponent × w_unblocked × w_due ×
w_goals × w_base` tops out at **36.5%**, and its best point is degenerate:
effort off, due off, goals off, base near zero. That is the formula saying
none of its terms predict the choice. The exit target is 90%.

**So this is not a tuning problem.** No weight assignment closes a 54-point
gap, and more scaffolding on top of this formula would be wasted work. Good
that the diagnosis ran before B3 rather than after.

Two readings, both plausible, not yet distinguished:
1. A missing **importance** term, independent of graph position and effort —
   "how much this matters", which correlates with size but is not size.
2. A single global ranking is the wrong product model. Ganesh ranked in one
   stated frame ("productive, happy"), and in that frame the right policy is
   **big-rock-first** — which is literally one of the twenty modes the
   generated datasets turned out to encode (`docs/12-backlog.md` B-04b).

The second is the more interesting possibility and the two converge on the
same evidence, which is suggestive rather than conclusive at n=74 (±11pp).

**Nothing was changed.** `effortExponent` was added to `ScoringWeights`
defaulted to 1.0, so behaviour is identical; it exists because effort is a
divisor and no weighted term could undo its bias. Scorecard is unmoved
(top-3 71.6%, top-1 24.3%) and the three hand-computed worked examples in
`docs/02-scoring-spec.md` still pass.

### 2026-11-23 — Recurring tasks recorded as B-05, not built
Ganesh's examples cover three distinct patterns: day-of-month (SIP on the
15th), nth-weekday-of-month (first Sunday), and quarterly week-of-period.

Recorded rather than started, with the fork that decides the rest made
explicit: **one item whose due date moves, or a series of instances?** "Did I
miss November's SIP?" argues for instances; a list drowning in future
occurrences argues against. Probably a template plus materialised instances
within a horizon — but that is a decision to take deliberately.

Worth noting it is **T0, not AI**: recurrence is the date grammar plus a
quantifier ("har 15 tarikh"), and the hard parts are calendar edge cases — the
31st in a 30-day month, "first Sunday" when a month starts on one, and whether
"quarter" means the calendar year or the Indian financial year. That last one
is a question for Ganesh when we build it.

### 2026-11-23 — Top-1 loses its target. Ganesh is right, and the data agrees.
His argument: there is no single correct answer to "what should I do next" —
the same person answers differently by day, hour, mood and urgency. Treating
one pick as *the* truth measures a question that has no answer.

The measurements back it. Top-1 sits at 24.3% and a 900-combination grid tops
out at 36.5%. If three of five tasks are defensible on a given morning, top-1
has a natural ceiling near 1/3 — roughly where we are. It was never reaching
90%, and chasing it would have meant fitting noise.

**Changed:** top-1 keeps its place on the scorecard as a diagnostic (a sharp
drop still means something broke) but carries no target and nothing is tuned
against it. Top-3 target lowered 90% → 85%, NDCG@5 0.85 → 0.80.

**Not changed:** top-3 is 71.6%, so roughly three times in ten the human's pick
falls outside our top three of four or five items. That is not imprecision, it
is ranking a reasonable choice near the bottom, and it is still worth fixing.

**Consequence:** I will not add an "importance" term to chase top-1 — that
would be fitting noise, and the diagnosis ran just in time to avoid it.

**B-03a is now the highest-value outstanding item.** Without the self-agreement
ceiling we cannot tell whether 71.6% is already above the human noise floor
(stop) or well below it (keep working). Ten minutes of `make rank-again`
decides which.

### 2026-11-23 — 300 real captures arrived, and they demolished a guess
First contact with Ganesh's actual writing. `make coverage` is new, read-only,
and reports **coverage not accuracy** since real captures are unlabelled:

```
                     before   after
  type recognised     46.7%   98.0%
  nothing recognised  18.0%    1.0%
  category            67.3%   67.3%
  date found          17.3%   17.3%
```

**The cause: we were tuned to a spelling he does not use.** Our Hinglish
imperative rule was a list — "karna hai", "karna h". In 300 real captures
`karna` appears **once**; `krna`/`krni` appear **108 times**. The synthetic set
and all three generated `*-300` files used the textbook spelling, so nothing
caught it. Only real data could.

**The fix is morphology, not more spellings.** The pattern
`<verb ending na|ni|ne> + copula h|hai` matches krna, karna, lena, dena,
banana, dekhna, kharidna — every infinitive, including the ones nobody has
written down yet. A spelling list can only cover spellings someone thought of.

Checked for a precision trade on the **labelled** synthetic set: type accuracy
80.7% → 81.0%, unfamiliar-verb slice 56.4% → 57.1%. Both marginally up, so 51
points of real-world coverage cost nothing.

Also added 22 English verbs that appeared in real captures and fell through to
`note` — research, explore, discuss, publish, settle, sell, attend, visit.

**Honest limit:** 95.7% of real captures now classify as `task`. The file
genuinely is mostly tasks, but with no labels this is *recognition*, not
*correctness*. We can say we produce a type, not that it is the right one.

**B-05 validated by the data:** 25 captures carry recurrence markers —
"Har month" ×16, "Har Sunday" ×3, "Har 6 months", "Har 3 months", "Har Friday",
"Har 15 days". The feature request was not hypothetical.

### 2026-11-23 — All 130 scenarios ranked. The dev number has converged.
Dev split is complete at 91 ranked. Top-3 was 71.6% at n=74 and is **71.4% at
n=91** — the number has stopped moving, so it is real rather than small-sample
noise. Top-1 23.1%, NDCG@5 0.743, interval now ±10pp.

### 2026-11-23 — `agreement` now makes the paired comparison, not two loose numbers
The command measured self-agreement and left it sitting next to a top-3 figure
from a different sample, which decides nothing. It now computes **our**
performance on exactly the scenarios that were ranked twice, so the comparison
is paired and does not depend on sample sizes matching. It then states the
verdict outright:

- if our top-3 ≥ his top-1 self-agreement → we are already inside the noise of
  his own judgement, further ranking work is fitting Tuesday's mood against
  Friday's, **stop and build the product**
- otherwise the gap is real work

**Second pass is ~30 scenarios, not 130.** At n=30 the interval is ±16pp, and
paired that is enough to decide; n=15 gives ±23pp and settles nothing. `make
rank-again` now defaults to `--limit 30`.

### 2026-11-23 — B3 plumbing: ledger, breaker, cassettes, router
`BrainHarness` is now complete enough to run a pipeline, with no provider SDK
and no key. 43 harness tests.

**BudgetLedger** — rolling RPM/TPM windows plus a calendar-day RPD counter, as
an actor because the job worker is concurrent and a double-spend means a 429.
TPM is charged **on the estimate, before dispatch**: you cannot stay under a
token budget you only measure after spending it.

Per-user fair share is enforced separately from the pool, at
`max(50, 2 × daily / activeUsers)`. Without it one person pasting a long brain
dump takes the whole 14,400 RPD and starves everyone until midnight.

**CircuitBreaker** — opens after consecutive failures, half-opens after a
cooldown, and a failed probe restarts the cooldown rather than half-opening
again immediately. While open the router skips the rung without calling it, so
a dead provider costs one timeout rather than one per request.

**CassetteStore** — one JSON file per recording, so they merge in git without
conflicts and a stale one can be deleted by hand. In `replay` a miss is a
**hard error**, never a silent live call: a cassette gap must not quietly turn
an offline run into a surprise bill and a non-deterministic result.

**ModelRouter** — walks the ladder, applying schema → ID whitelist →
abstention in that order. Three behaviours worth pinning, all tested:

1. A rung whose answer the guards reject is **skipped**, not reported as an
   abstention — the ladder has not finished considering.
2. `askUser` (T3) sits *before* the paid rungs and charges no budget.
3. Exhausting the ladder degrades to "field unknown"; it never throws. A
   capture is never lost.

**FakeModel** ships four behaviours — first-allowed, always-abstains,
misbehaves (answers `item-99999`, to prove guard 1 is not decorative) and
always-fails. The pipeline can be exercised end to end before any key exists.

### 2026-11-23 — The pipeline is wired end to end, T0 only
`BrainPipeline`: normalise → extract → classify → link, each stage degrading to
"unknown" rather than throwing. 13 pipeline tests.

Run over Ganesh's 300 real captures:

```
  items created     300
  captures lost       0      <- the invariant, tested directly
  marked failed       0
  edges suggested     0      (all unconfirmed when there are any)

  tier that settled each field:
    type      t0=294
    category  t0=202
    dueAt     t0=52
    effort    t0=15
```

**Not one model call.** Everything the pipeline produced on real data came from
deterministic rules, which is the tiering doctrine working as intended rather
than as an aspiration.

Three design points:

**The original text is never modified.** `Normalizer` returns the cleaned form
alongside the untouched original, and every `Span` indexes the original. A
pipeline that rewrites text before parsing cannot prove where a value came
from, and guard 2 becomes decorative. This is also why a "normalise with a
model" layer was rejected.

**PII is redacted into a separate field**, not in place. The capture keeps the
phone number; only the copy bound for a provider loses it.

**Zero edges on 300 captures is the honest result**, not a bug. These are
independent one-liners; none references another by title. `TitleMatcher`
returning nothing rather than a weak guess is precision over recall working.

Known fidelity loss, not fixed: effort displays the canonical bucket, so a
capture saying "15 minutes" renders as "about 20 min". The bucket is the model
and the parse is correct; only the wording rounds.

### 2026-11-23 — First live calls. The wiring works; three bugs found doing it.
`GoogleProvider` calls `generateContent`. Model ids were taken from the live
`models` listing for this account, not from documentation that has moved twice
this year: `gemma-4-26b-a4b-it`, `gemma-4-31b-it`, `gemini-3.1-flash-lite`,
`gemini-3.5-flash-lite`. **`gemini-decision-1` is not a `generateContent`
model** — it is a separate Decisions API, so the B3 second track needs its own
adapter rather than a model-id swap.

**Bug 1 — cassette identity did not include the model.** Recording with
`gemma-4-26b` and then running `gemma-4-31b` reported "already had 1": the
second model read the first one's answers as cache hits. That would have made
the B3 two-track comparison **compare a model against itself**. Caught on the
second live call. Identity is now `(model, request)`.

**Bug 2 — Gemma 4 is a thinking model, and we recorded its reasoning.** The
reply carries the working in a part flagged `"thought": true`, then the answer
in a separate part. Joining all parts produced a cassette containing a bullet
list of the model's deliberation instead of the word `task`. Thought parts are
now filtered out.

**Bug 3 — token estimation was nine times under.** A 27-token prompt produced
223 thinking tokens and a 1-token answer: 251 total. The ledger was reserving
27. Over a run that walks straight into 429s. Thinking **cannot be disabled**
on this model (`"Thinking budget is not supported"`), so the estimate now adds
a measured 350-token allowance and `completionTokens` includes
`thoughtsTokenCount`.

Response parsing was extracted from `complete` into a testable `parse`, because
that is precisely where both output bugs lived and network code cannot be unit
tested. Six adapter tests now pin them against captured payloads.

### 2026-11-23 — The free tier is unreliable, and that is a design input
Of 25 attempted recordings, **10 failed with HTTP 503 "model experiencing high
load" after three retries each** — a 40% failure rate on a quiet afternoon.
Timeouts needed raising from 20s to 60s because a thinking model spends 300+
tokens before answering.

This is not a reason to abandon the free tier; it is the reason the fallback
ladder and circuit breaker exist, and it argues for recording cassettes well
ahead of needing them rather than on demand.

### 2026-11-23 — First T2 number, on the only set where it matters
`brain t2-score` measures the model on the captures **T0 abstained on**, where
T0 scores 0% by construction. Scoring it over the whole dataset would flatter
it with 390 captures the rules already handle for free.

```
  captures T0 could not type   25
  of those, recorded           15
  T0 accuracy on this set     0.0%   (it abstained)
  T2 accuracy on this set   100.0%
  rejected by guards             0
  tokens                       601/call
```

**15 calls decides nothing**, and the command says so itself rather than
letting the number stand unqualified. The escalation set is also synthetic with
labels true by construction, and the signal T0 missed is mostly an unfamiliar
verb — which a language model finds easy almost by definition. Read this as
"the wiring works end to end", not "the model is good".

At 601 tokens per call, 16,000 TPM allows ~26 calls/minute and the 14,400 RPD
cap is the real ceiling: roughly 14,000 escalations a day.

### 2026-11-23 — The Decisions API, reverse-engineered
`aistudio.google.com/docs/decisions` 404s and the model metadata only says
`supportedGenerationMethods: ['createDecision']`. The schema below came from
probing the live endpoint and reading its validation errors, in about eight
calls. Recorded in `DecisionProvider.swift` because it is not findable
elsewhere:

```
POST /v1beta/decisions
{"model":"models/gemini-decision-1",
 "input":[{"type":"text","text":"<capture>"}],
 "questions":{"<key>":{"type":"choice",            // or "score", "noul"
                       "instructions":"...",
                       "criteria":{"task":"...",}  // a MAP, 2-255 entries
 }}}
```

### 2026-11-23 — B3 two-track comparison. I was wrong about calibration.
17 captures both models answered, on the escalation set where T0 scores 0%:

```
                          gemma-4-26b-a4b-it   gemini-decision-1
  accuracy                94.1%                94.1%
  accepted at conf >= 0.7 17/17                12/17
  …and correct            16                   12
  mean tokens/call        693                  281
  ECE (lower is better)   0.059                0.203
  mean confidence         1.00                 0.78
  distinct confidences    1                    6
```

**What I predicted:** Decision 1 returns calibrated confidence, so guard 4
becomes meaningful. **What the data says:** its ECE is three times *worse*.

The reason matters more than the number. Gemma answers **1.00 to everything**
and is 94% right, so its gap is only 0.06 — it is *accidentally* calibrated.
`distinct confidences: 1` is the tell: that confidence carries no information
at all, and no threshold can separate its good answers from its bad ones.
Decision 1 produces six distinct values — real signal — but is systematically
**under-confident**, so a fixed 0.7 threshold throws away five correct answers.

So the honest conclusion is the reverse of the naive reading: **under-
confidence is fixable** (temperature scaling and a fitted threshold, which is
precisely what B5 is for); **a constant confidence is not.** ECE alone would
have picked the wrong model, so `t2-score` now prints the distinct-confidence
count beside it and explains the trap.

**Reliability, which was not close:**
- Gemma: 17 of 25 recorded. 10 failures, all HTTP 503, after three retries each.
- Decision 1: **25 of 25, zero failures, 18 seconds.**

Cost: 281 tokens against 693, and Decision 1's free RPD is 10,000 against
Gemma's 14,400 — comparable headroom at under half the tokens.

**No winner declared on accuracy.** 17 captures cannot separate 94.1% from
94.1%. The reliability, token and confidence-signal differences are
structural, and those are the ones worth acting on.

### 2026-11-24 — B3 complete. Every metric is now measured.
The scorecard had been reporting four metrics as "not measured — no model
calls exist yet" long after model calls existed. **A metric nobody wired up
and a metric that cannot be computed look identical in a report**, which made
the scorecard quietly wrong. All now measured:

```
  captures lost              0        n=415   invariant holds on real text
  hallucinated-ID rate       0.0%     n=52    every answer inside the option set
  answers needing rescue     0.0%     n=52    guard 3 never had to normalise
  injection containment    100.0%     n=10    structural, see below
  T0 settled                62.0%     n=1725
  T2 rate                    0.0%     n=1725
  tokens per escalation      418      n=52
  escalations/day affordable 10,000
```

**`hallucinated-ID rate 0.0%` is the headline exit target, and it is now a
measurement rather than an aspiration.**

Two framings worth keeping honest:

**Injection containment is structural, not behavioural.** The model did not
"resist" anything. With a closed-set call it has no vocabulary in which to
comply — the answer is a key from the option set, so "ignore previous
instructions" can at worst produce the wrong *type*. That is a stronger
property than a model choosing to behave, but it is a different claim, and the
metric says so. It holds only while no tools are exposed; if that changes the
number stops meaning anything.

**Cost is reported in tokens, not rupees.** On a free tier the rupee figure is
zero and says nothing about whether we can afford to run. 418 tokens per
escalation against Decision 1's caps gives ~10,000 escalations a day — that is
the number that constrains us.

## 2026-11-24 — B4: guards measured one at a time

`brain guard-eval` (new, replay-only, spends no quota). Each guard measured
against the data where it can actually fire, rather than against cases
invented for it.

| guard | measured | verdict |
|---|---|---|
| 1 ID whitelist | 0 of 52 answers out-of-set | Expected. Both providers get a closed option set; with the Decisions API an out-of-set answer is inexpressible. Keeps the 0% target a property of the code, not of the model. |
| 3 schema | 0 normalised, 0 rejected | Never fired. Kept: the first Gemma call of this project returned a bullet list of its own reasoning. |
| 4 abstention | see below | The one with a real finding. |
| 7 cross-check | 15/15 agreements correct; 2 disagreements, both with one correct side | Precision bought with recall, as `docs/04-scorecard.md` asks for. |
| 10 PII strip | **0 of 300 → 5 of 300** after a fix | A real gap on real data. |
| 12 claim check | 0 opportunities | Nothing rephrases explanations yet. Reported as unmeasurable rather than as 100% effective. |

### Guard 10 had a real gap, found only because it was measured on real text

It redacted **0 of 300** of Ganesh's captures. Every amount he writes is bare
Indian shorthand — "50K", "10k", "1.5k sip", "2 lakh" — with no currency
marker, and the pattern required one. A guard that never fires on real data is
not a guard. Added `\b\d+(?:\.\d+)?\s?(?:k|lakh|lacs?|lakhs?|cr|crores?)\b`;
now 5 of 300 (2%), `[amount]×5`. Regression test added.

Known false positive: "5k run" is a distance, not money, and gets redacted
too. Accepted — over-redaction is the safe direction for a guard whose job is
keeping content away from a provider that may train on it, and the only cost
is that the model sees "[amount] run" instead of "5k run" when typing the
capture. At 5 of 300 it is not over-firing in practice.

This is the second time measuring on Ganesh's own captures rather than
synthetic ones overturned something that looked fine (the first: Hinglish
tuned to `karna`, which appears once in 300, against `krna`/`krni` at 108).

### Guard 4: no threshold is being set, and two things I had wrong

Sweep on gemini-decision-1 (the only provider reporting a real confidence —
35 recorded, genuine spread 0.32–0.95):

```
threshold   accepted   correct   wrong-through   right-discarded
    0.0         25        24               1                 0
    0.5         23        23               0                 1
    0.7         17        17               0                 7
    0.9          7         7               0                17
```

**Correction 1.** I had this written up as "change the default from 0.7 to
0.5". There is no 0.7 default. The live default is `Rung.acceptAbove = 0`
(`Sources/BrainHarness/Router.swift:30`) — nothing is gated today. 0.7 existed
only as a reporting constant in `T2ScoreCommand`, now annotated as
illustrative.

**Correction 2.** A weighted sweep picks 0.35, and that number is not
trustworthy: there is exactly **one** wrong answer in the sample, so the
"optimal" cut is just below that single answer's confidence. That is fitting a
parameter to one data point. The command now refuses to recommend a threshold
below 10 errors and says why, rather than printing a number someone would ship.

What the data *does* support is an upper bound: the lowest confidence on a
correct answer is 0.50, so any threshold above 0.50 is measurably costing
correct answers and catching nothing. **Decision: leave `acceptAbove` at 0**
until there are enough errors to fit against — recorded as a deliberate choice
rather than left as an unexamined default.

Gemma remains ungateable at any threshold: it answers 1.00 to everything
(1 distinct value), so its confidence carries no information. Its low ECE is
accidental, as recorded on 2026-11-23.

## 2026-11-24 — Open questions carried into the server phase

Brain is complete through B4 and `make ci` passes. Recording what is settled
and what is not, so the server phase starts from the record rather than from
memory.

**Settled, and written down:** Hummingbird 2 (ADR-0001), free-tier inference
with disclosure (ADR-0002), one repo per component (ADR-0003), Supabase with
asymmetric JWT (ADR-0007), manual-trigger CI (ADR-0006). Hosting research is
above — Hostinger's ₹779 is a promo, Hetzner has no ARM outside the EU.

**Agreed in conversation but never recorded, and so not yet a decision:**

*Do not hand-roll the job queue.* Ganesh's call, and the reasoning was that a
queue is exactly the kind of component where a hand-rolled version looks fine
until it loses work under load.

**Correction, same day.** I first recorded this as "the replacement was never
chosen". That was wrong, and I found it while auditing the repo for a phase
handoff: ADR-0001 already lists `swift-jobs` 1.4.0 and `swift-jobs-postgres`
1.5.0 among the satellite packages verified on 2026-11-22. Postgres-backed,
same org as Hummingbird, no second process and no Redis. That is the choice,
and the only open part is confirming the versions are still current at the
time the server starts.

**Still open from Brain, and not blocking the server:** `make rank-again`
then `make agreement`, which decide whether top-3 at 71.4% sits at the human
noise floor or genuinely short of it. Diagnostic only. If agreement comes back
near 71%, the formula is at the ceiling and `docs/05-targets.md` should say so.

## 2026-11-24 — Server starts now; Brain B5–B7 continue in parallel

**Amends the charter.** `00-charter.md` puts "Brain v1 freeze" before any
server work. Ganesh's decision: the server starts now, and B5, B6 and B7 carry
on in parallel. The freeze line was a sequencing preference, not a technical
dependency, so it is replaced rather than quietly ignored.

**Why nothing blocks.** The server uses Brain only through its interfaces
("enrich this capture", "rank this graph"). Each remaining phase changes what is
behind them:

- **B5 (own model, T1)** adds one rung to the ladder. Until it lands, the
  production ladder is T0 → T3 → T2 → degrade. Picking up T1 later is a config
  change plus a Brain version bump.
- **B6 (personalisation)** learns from confirms and rejects. The server stores
  every user correction from day one, so B6 gets real data rather than waiting
  for it.
- **B7 (soak and adversarial)** tests Brain harder and does not change its
  interface.

**Cost accepted.** Each Brain change the server needs is a tag plus a bump in
Server (ADR-0003). Brain is tagged `0.4.0` at the end of B4.

**Two server facts found while planning, recorded so they are not rediscovered:**

1. `hummingbird-auth` 2.5.0 has no JWT support (checked against its source:
   bcrypt, basic auth, OTP only). JWKS verification for ADR-0007 uses
   `vapor/jwt-kit` (5.9.1 on 2026-11-24), a standalone library. **This is not
   a move to Vapor.** The server stays on Hummingbird (ADR-0001).
2. `BudgetLedger` keeps its counts in memory. On a server a restart resets the
   daily count to zero, and we overspend the free tier without knowing. Before
   the enrichment worker makes live calls (server step S4), Brain gets a small
   storage hook so the server can keep the counts in Postgres. Then Brain is
   re-tagged.

**Still open:** whether the shared docs move out of `Brain/docs/` now (ADR-0003
says "when Server starts"). They stay in Brain until a second component needs
them.

## 2026-11-24 — 0.5.0: what the server needs from Brain (R1, R2, R3)

Three changes requested by the Server session before its enrichment worker
makes live calls. All three premises checked against the code first; all three
were real, one smaller than stated and one riskier.

### R1 — BudgetStore, and the day boundary was wrong

`BudgetLedger` kept the daily counters in memory, so a restart handed the
deployment a fresh free-tier allowance. Added `BudgetStore` (async protocol,
one atomic `reserve`), `InMemoryBudgetStore` as the default, and
`BudgetLedger(store:now:)`.

**The real work was concurrency, not storage.** `consume` was synchronous
inside the actor, which is what made check-and-charge atomic. Adding an
`await` to a storage call makes the actor re-entrant at that point: two
concurrent captures can both pass the RPM check before either records itself.
Writing it the obvious way — charge the day, then append to the minute window
— reintroduces precisely the double-spend the actor exists to prevent. The
minute slot is now taken *before* the await and released if the day refuses.

Measured, not argued: with the naive ordering a limit of **RPM 5 let all 40
concurrent callers through**. The test asserts 5 and fails on the naive
version, which was checked by writing it both ways.

**The day boundary was also wrong**, and independently. The old code rolled
24 hours after the *first call* — a rolling window, so a deployment whose
first call landed at 23:00 would carry the previous day's count through most
of the next day. Verified against Google's own docs on 2026-11-24
(`aistudio.google.com/docs/rate-limits`, which
`ai.google.dev/gemini-api/docs/rate-limits` now 301s to): *"Requests per day
(RPD) quotas reset at midnight Pacific time."* Now keyed by `ProviderDay` in
`America/Los_Angeles` — the zone identifier, not a fixed offset, so DST is
handled rather than shifting the reset by an hour twice a year.

**No caller churn.** `BudgetLedger` is an actor, so `consume` was already
`await`-ed everywhere. Making it genuinely async changed no call sites.

Refunds: **fail-closed, no `release` in the protocol.** A request charged and
then failing in transport stays charged. Simpler, and it errs toward
under-spending a free tier. Revisit if B7's soak shows transport failures are
a material share.

Also found: `BudgetLedger` had **no dedicated test file**. Its entire coverage
was two cases inside `RouterTests`. Now has one.

### R2 — the fair share was built and unreachable

`ModelRouter.route` has always taken `user:` and `userLimit:`, both defaulting
to nil. `EnrichmentPipeline.enrich` called `route(request)` and passed
neither, so the per-user fair share was fully implemented and never once
exercised on the real path. One line.

**`Requester` is required, not defaulted.** A defaulted parameter is exactly
how this bug happened; repeating the pattern would invite it back. Callers
with no real user pass `.local` explicitly. Cost is a dozen call sites updated
once.

The regression test is at the *pipeline* level deliberately: a ledger-level
fair-share test passes even with the bug, because the bug was that the
pipeline never told the router who was asking. Confirmed by reintroducing the
bug — greedy got 4 model answers against a share of 2.

### R3 — a production ladder, in code, and no T3 rung

`docs/06` described `config/router.prod.yaml`. **That file never existed and
nothing loaded it.** Now `BrainProduction.ProductionRouter`, a new composition
-root target — the only place that needs to see both the adapters and the
pipeline's prompts, so neither has to depend on the other.

Code over YAML: a parser dependency Brain lacks, no type checking, and silent
drift from the `Rung` API — which is what happened to the sketch in `docs/06`.
The limits stay data, carrying a verification date and source.

**The requested ladder would not have worked.** The ask was "T3 (ask the
user), T2 rungs, degrade last". `Rung` has no condition field and `.askUser`
returns unconditionally the moment it is reached, so a T3 rung ahead of the T2
rungs would turn every escalated capture into a question and the free-tier
providers below would never be called. The YAML sketch hid this in a
`when: { stakes: low, reversible: true }` clause the code cannot express.
It is also not what `docs/09` asks for: its table routes classify-type as
T0 → T1 → T2, no T3. T3-before-T2 belongs to `judgeLink`, which nothing routes
yet, and needs a predicate on `Rung` first. Ladder is therefore
decision-1 → gemma → flash-lite → degrade. A test fails if an `askUser` rung
is added ahead of the providers.

**Limits could only be partly re-verified.** Google's public page no longer
publishes a per-model free-tier table; it shows only Decision 1 (200 / 50,000
/ 10,000, matching what we had) and directs you to the AI Studio dashboard.
The Gemma and Flash-Lite rows cannot be checked without signing in to Ganesh's
account. They are dated and sourced, and `staleLimits(now:)` reports any row
older than 90 days rather than letting it quietly govern spending. `docs/06`
amended to say so instead of claiming verification it does not have.

Replay is the default mode, so a server CI run with no key spends nothing.

## 2026-11-24 — Linux verified (swift:6.4.3-noble)

The deploy target is Linux; the dev machine is arm64 macOS. Foundation differs
between them, and 0.5.0 added code that leans on exactly the parts that differ
— `TimeZone(identifier: "America/Los_Angeles")`, `DateFormatter`, `Calendar`
arithmetic in `ProviderDay`. "Passes on my Mac" was not evidence.

Verified the image tag exists before using it (`docker manifest inspect
swift:6.4.3-noble`), rather than assuming the version.

| Step | Result |
|---|---|
| `swift build` | clean, 8.95s |
| `swift test` | **219 tests, all pass** |
| `swift format lint --strict` | clean |
| eval (replay) | identical metrics to macOS |
| regression gate | **PASS** |

No Foundation differences surfaced. The tzdata lookup and `DateFormatter`
behave the same, which is the part that could plausibly have broken.

**One real gap found: the Swift image has no `python3`.** The eval's category
labels are derived from the committed corpus by `scripts/category-truth.py`,
so `make ci` cannot run end to end inside the container as written. For now
`make ci-linux` generates the labels on the host and mounts them read-only. A
real Linux CI must either add python3 to the image or commit the labels file —
recorded here so the server's CI does not discover it at deploy time.

Added `make ci-linux`. It uses a separate `--scratch-path .build-linux`,
because SwiftPM would otherwise mix two triples' artifacts under `.build` and
flip the `debug` symlink between them. Gitignored.

## 2026-11-24 — The CI image: python3, make, and two latent bugs

Following the Linux check, `python3` is now in a purpose-built image rather
than worked around.

**This was not a convenience fix.** `.github/workflows/ci.yml` declared
`container: swift:6.4.3-noble` and ran `make eval`. That image has no python3,
so the category labels could not be generated and the eval — and therefore the
regression gate — would have failed outright. CI is manual-trigger only
(ADR-0006), so it had never been run and the breakage was invisible. It also
has no `make`, so the container could not run the project's own targets
either.

`Dockerfile.ci` is `swift:6.4.3-noble` plus `python3` and `make`, with a build
-time assertion on all three tools so a missing one fails the image build
rather than a later CI run. The scripts are standard-library only, so there is
no pip step and nothing to pin beyond the interpreter.

**`make ci-linux` now runs the real `make ci`**, not a hand-copied
approximation of it. A `SCRATCH` variable supplies `--scratch-path` so the
container's artifacts never share `.build` with the host's; empty on the host,
so host behaviour is unchanged. Local and CI can no longer drift, which is the
whole point of ADR-0006's "identical local targets".

### Two latent bugs found while wiring it up

**The `split` input was cosmetic.** The workflow offered a dev/test choice and
every target hardcoded `--split dev`. Choosing `test` would have evaluated dev
and uploaded the result labelled `scorecard-test` — a wrong number with a
convincing name. Added `SPLIT ?= dev`, threaded through eval, gate, scorecard,
diagnose and promote-baseline.

**The labels rule hid its own failures.** It ended in `2>/dev/null`, which
suppressed the informative label count *and* any real error, leaving an empty
file the eval would then have measured nothing against. Suppression removed
and a non-empty assertion added.

**`make dev` was broken.** It ran `docker compose up -d` against a
`docker-compose.yml` that does not exist; the ml-service it refers to is B5.
Now prints what is actually true and exits non-zero.

Verified: `make ci` passes on macOS and `make ci-linux` passes in the
container, same metrics, same gate.

## 2026-11-24 — 0.5.1: BrainProduction is a package product

`BrainProduction` was declared as a target but never as a `.library` product,
so it stopped at the package boundary and the server could not import the one
supported way to build the production ladder. One line in `Package.swift`.

Verified by building a throwaway package that depends on Brain by path and
imports `BrainProduction`, rather than assuming the declaration was enough:
it resolves, `ProductionRouter.make` runs, and the ladder comes back
`t2-decision -> t2-gemma -> t2-flash-lite -> degrade`. Consumers need
`import Foundation` for `staleLimits(now:)`, which takes a `Date`.

### `BudgetRefusal.storeUnavailable(detail:)`

Requested as optional; worth taking. Without it a Postgres-backed store with
a dead connection has to borrow a reason that did not happen — and the logs
would report a quota problem in the middle of a database outage, which is the
sort of thing that costs an hour at 2am.

**Fail-closed**, consistent with the refund decision in 0.5.0: an unreachable
store refuses the call. Failing open would mean spending unmetered against a
free tier with no way to know how much went out, which is the exact failure
`BudgetStore` exists to prevent. The capture is not lost — the router
degrades.

A test asserts the outage does **not** leak the minute slot it was holding.
Without that, a store outage would also burn the RPM pool and the model would
stay unreachable for a minute after the store recovered.

Adding an enum case is source-breaking for exhaustive switches; nothing in
Brain switches over `BudgetRefusal` except its own `description`, and the
server has not integrated yet.

Tag `0.5.1`. The two commits since `0.5.0` (Linux verification, CI image) are
tooling and docs only, so this remains a patch release.

## 2026-11-24 — 0.6.0: writing styles, and four gaps the eval could not see

Ganesh pushed back on a claim I had made: I cited "type recognition 46.7% →
98.0%" as evidence that cleaning text would hurt, but that number is
**single-author**. The product is not for one person. He was right, and the
probe that followed found more than the question asked.

**Scope decided: English and romanised Hinglish only.** Pure Devanagari is out
for now — real data from test users comes first. Measured for the record:
Devanagari returns no date, no category and no dependency, and every item
scores an identical 0.370, so the ranking is input order. Brain does not yet
know it cannot read it, which is worse than failing loudly.

### What the probe found — none of it visible to the eval

28 captures, the same 8 intents in four styles:

| Style | type | category | date | dependency |
|---|---|---|---|---|
| English | 100% | 87.5% | 62.5% | 12.5% |
| Hinglish (Ganesh) | 100% | 75.0% | 62.5% | 0% |
| Hinglish (formal) | 100% | 62.5% | 37.5% | 12.5% |
| Devanagari | 100%* | 0% | 0% | 0% |

\* hollow: T0 claims the type but reads nothing else.

**1. `before` had no rule in any language.** 0 of 5, English included. Every
rule was an *after*: `once…done`, `blocked by`, `waiting for`, `ke baad`,
`after`. Half of dependency grammar was missing and the scorecard said 68.1%.

This could not be a new regex alone. `ParsedDependency` meant "this item is
blocked by the referent", full stop. "Review the PR before standup" is the
mirror — the PR review blocks the standup — so reusing the old shape would
have emitted a backwards edge and made the task look unstartable. Added
`ParsedDependency.Direction`, and `Enrichment` now picks the edge ends from it.

**2. `uske baad` parsed as nothing** while formal `ke baad` worked —
`\bke\b` cannot match the "ke" inside "uske". The informal form is the common
one; our own captures use it constantly.

**3. Hinglish durations invented phantom blockers.** `3 din ke baad deploy
krna h` produced a dependency on a thing called "3 din". The cross-check that
catches this ran only for `.afterMarker`, so English `after 3 days` was
correctly ignored the whole time — which is exactly why nobody noticed. Now
runs for both word orders.

**4. Spelled-out Hindi numerals were unparsed.** `15 tarikh` worked,
`pandrah tarikh` did not; same for `teen baje`, `das baje`.

Implemented as a lookup matched **in place**, not as a text rewrite. Rewriting
"pandrah" to "15" is less code and would move every span after it;
`span-verified rate` is a 100% invariant and spans index the user's original
text. `no` for 9 is deliberately omitted — it collides with English "no", and
a missed time costs less than a wrong one. Checked for collisions: "do the
laundry", "sat with the team", "char the vegetables" read no date, because the
numeral only fires before `baje`/`tarikh`.

A fifth gap surfaced from the new tests themselves: the duration cross-check
accepted only digits, so `ek mahine ke baad` was still a phantom. Word
numerals now count there too.

### The metric did not move, and that is the finding

`dependency recall` is **still 68.1%**. Not because the fixes did nothing — the
synthetic corpus is generated from our own rule vocabulary, so it contains no
`before` construction and cannot measure one. Twelve hand-written sentences
found four gaps that 69 generated ones could not. `span-verified` rose from
n=406 to n=415: every capture is now grounded.

`Tests/BrainCoreTests/WritingStyleTests.swift` is the committed fixture, so
all three supported styles are checked on every run instead of only synthetic
data. Treat the generated datasets as a floor, never as coverage.

Tagged `0.6.0` rather than `0.5.2`: `ParsedDependency` gained a field and Brain
now emits edges it never emitted before. No compile break for the server —
`Edge` is unchanged — but the behaviour differs.

### 2026-11-24 — The planner is accepted, and it repairs the ranking

Ganesh's second main use case: a year-long day planner — nine daily habits, a
Friday 3h office block, a Sunday weekly review, a first-Saturday monthly
review, fixed payments, and monthly/quarterly goals — alongside capture.
Specified in `docs/15-planner.md`; B-01, B-05, B-06c and B-06d are promoted
out of the backlog.

**Why it is not scope creep.** `servesGoals` is 0 for every item in
production, because nothing assigns a goal, so leverage is really just
unblocks plus due pressure. Declared month and quarter goals are the missing
input to the formula we already built.

**The load-bearing separation.** Commitments are scheduled; candidates are
ranked. Nine daily commitments entering `ranked` would make "the one thing to
do next" a habit checkbox forever. `Brain.compute` returns them as their own
section. The bridge is "one big task": a commitment whose occupant comes from
the ranked pile.

**Four decisions taken** (detail in the spec): D1 template plus lazily
materialised instances, persisted only when an occurrence carries state —
answering B-05's fork. D2 a miss is forgiving daily, visible in the weekly
review; its consequence is that a miss needs **no row at all** (expected minus
actual), so the forgiving model is also the cheap one. D3 calendar quarters,
not the Indian financial year. D4 Brain proposes the big task and the user
confirms; a swap records into the existing `corrections` table.

**Charter line, agreed.** "Pay rent 22k" as a dated reminder is in — B-05
already had SIPs as an example. Any sum, category or trend over amounts is
out. "Move body" as a habit with a streak is in; reps, weight and calories are
out. Nothing ever adds amounts together.

**Noted, not resolved:** B-02 timers, B-06a board and B-06b quick wins are
marked "deliberately not built" in `12-backlog.md` but are already shipped in
the web app as device-local features. The records contradict. Device-local
also means a test user's board and habit data never reaches us, which is the
signal the friends test is for — step 4 of the build order fixes that.

### 2026-11-24 — The recurrence engine (planner step 2, first half)

`Sources/BrainCore/Commitment.swift` plus 34 tests. All T0: no model, no
network, nothing to record or replay.

**Arithmetic happens on calendar days, never on `Date`.** "The first Saturday
of March" is a question about a calendar, not about an instant, so a
`CalendarDay` of year/month/day keeps DST, offsets and leap seconds out of the
expansion entirely. A day becomes an instant only at the boundary, through
`start(in:)`. Verified with America/Los_Angeles across both 2027 transitions
(14 March, 7 November): a daily commitment yields exactly one occurrence per
day, none doubled, none missing. Month lengths and date validity come from
`Foundation`, not from arithmetic written here.

**Five shapes, a closed enum, not RFC 5545 `RRULE`.** Five shapes cover every
commitment in the brief, and a closed set is exhaustively testable — which is
the argument for keeping this in T0 at all. A dependency would buy generality
nobody asked for.

**`monthlyOnDay` clamps, it does not skip.** A rule on the 31st falls on the
30th in a 30-day month and the 28th or 29th in February. Skipping would
silently drop a rent payment in four months of the year. `monthlyOnNthWeekday`
does the opposite and skips: there is no "5th Saturday" to clamp to in a month
without one, and inventing the 4th would change what the user asked for.

**Minutes, not `EffortBucket`.** A commitment's duration is stated by the user
("3 hours on Friday"), not inferred, so there is nothing to classify and no
reason to lose precision — the buckets jump 60 → 240 and would turn three
hours into one or four. B-01's arithmetic needs the real number.

**A miss needs no stored row** (D2): `missed` is expected minus actual, with
today excluded because the day is not over. The forgiving model is also the
cheap one.

Verified: `make ci` GATE: PASS, `make ci-linux` GATE: PASS, 259 tests. The
Linux run matters here because `Calendar` behaviour has differed between
corelibs-Foundation and Darwin, and the server builds on Linux.

**Still to come in step 2:** period goals (`Goal` gains a horizon and a
parent), and the scoring split that returns commitments as their own section
rather than rows in `ranked`.

### 2026-11-24 — Removing a dead field 0.6.0 introduced

`DependencyParser.rules` carried a `Position` column on all fifteen rules that
nothing read. It went dead in 0.6.0, when the time cross-check started running
for both marker positions instead of only `.afterMarker` — the compiler warned
and the warning was not acted on, because `swift build` warnings do not fail
`make ci`.

Its doc comment claimed `Position` was "what lets one parser handle both"
word orders. That was never true: which side the referent sits on is
expressed by where the capture group goes in each pattern. The field said the
same thing a second time, in a place that could drift out of agreement with
the patterns. Removed, with the comment corrected to describe what actually
does the work.

### 2026-11-24 — Period goals (planner step 2, second half)

`Sources/BrainCore/GoalPeriod.swift`, `Goal` gains `period` and `parentId`,
and `goalsServed` learns to drop lapsed goals. 18 tests.

**A lapsed period goal stops pulling on the ranking.** Last month's goal must
not keep inflating today's scores, or the ranking drifts further from the
user's intent every month. Closing a goal out is what the monthly review is
for; until the user does, the period boundary speaks for them. A **future**
period goal still counts — working ahead on next month's goal is a good thing
and penalising it would be strange.

**Nothing changed for existing data, and that is checked.** `period` is
optional and a goal without one never lapses, so every current goal scores
exactly as before. Verified: every ranking metric came back `=` — top-3
71.4%, top-1 23.1%, NDCG@5 0.7425. Had the filter touched existing scoring,
NDCG would have moved.

**No signature changed.** `Scoring.score` already takes `now` and a
`Calendar`, so "today in the user's zone" is derived from what is already
there rather than added as a parameter. `goalsServed` gained a defaulted
`on:`, so the server keeps compiling, and `Goal.init` gained two defaulted
parameters for the same reason.

**`canRollUp(into:)` is a predicate, not an enforced invariant.** A month goal
may roll up only into a quarter that contains it, but `BrainGraph.insert`
stays non-throwing: the server owns rejecting a bad write, and one odd row
must never cost the user their whole plan. `children(of:)` leaves out a child
that names a parent it does not fit inside, rather than counting it.

**Noted:** `eval/baselines/dev.json` was last written at 00:16 on 24 Nov,
before 0.6.0 shipped at 10:51, so the scorecard's delta column has been
comparing against a pre-0.6.0 run. That is why `T0 settled` reads `+0.1pp` —
it is 0.6.0's new dependency rules, not this change. Left stale deliberately:
refreshing a baseline is how a regression signal gets lost, and when to
refresh it is Ganesh's call.

Verified: `make ci` GATE: PASS, `make ci-linux` GATE: PASS.

### 2026-11-24 — Self-agreement measured; B-06's ranking gate resolved

Ganesh ranked 30 scenarios a second time, days after the first pass
(`make rank-again`, 130/130 scenarios now ranked). `make agreement`:

| | Ganesh vs. himself | Brain, same 30 |
|---|---|---|
| same #1 | 37% | 27% |
| top-3 overlap | 67% | 80% |
| identical order | 10% | — |

**The top-1 prediction in `docs/05-targets.md` was confirmed.** That doc
argued for a natural ceiling "near 1/3" from a 900-combination grid search
topping out at 36.5%, and kept top-1 target-free on that basis. Measured
ceiling: 37%. The reasoning held.

**Top-3 has no headroom worth chasing.** Brain's 80% over the paired subset is
above the 67% a human managed against his own earlier self. **B-06's gate —
"ranking validated (`make agreement`)" — is resolved, and the answer is that
the ranker is done.** No further scoring work; the effort belongs in the
planner and in the dead UI surfaces instead.

**The ≥85% top-3 target was deliberately *not* moved.** 30 pairs is thin — the
37% alone spans 22–54% at 95% — and the 80% is over the paired subset while
the scorecard's 71.4% is over all 91 dev scenarios: two samples, not a change.
Ganesh's call, and the right one: the variance is expected at this size rather
than evidence about the ranker. `05-targets.md` is annotated, not revised, and
records what would settle it (~90 pairs).

### 2026-11-24 — Three bugs in the `agreement` command

Found while reading the output above, all three in `AgreementCommand.swift`.

1. **It computed Brain's own agreement and threw it away.** `ourTop1` and
   `ourTop3` were calculated and never printed, so the command reported a
   ceiling with nothing measured against it — the one comparison it exists to
   make. Printing them is what showed top-3 has no headroom; without it the
   report looked like bad news.
2. **It cited a target that does not apply.** The verdict read "below the ≥90%
   target in docs/05-targets.md" whenever top-1 came in under 90%. That doc
   gives top-1 **no target at all** — the ≥90% figures are type accuracy and
   link precision. It was telling the reader to revise down a target that was
   already correct, and said nothing about the one that is actually in
   question.
3. **It hid the interval exactly when it mattered.** The 95% interval printed
   only below 20 paired scenarios, so 30 pairs reported a bare 37% with no
   uncertainty attached. The same failure mode as the B4 threshold command:
   a thin sample allowed to look authoritative. Now always printed, and with
   a Wilson interval rather than the normal approximation, which is poor at
   these proportions and this sample size.

### 2026-11-24 — The plan split: commitments are a section, not rows (step 2 complete)

`BrainOutputs` gains `commitments: [ScheduledCommitment]` and `day`, and
`Brain.compute` gains defaulted `commitments:` and `completed:`. Planner step 2
is finished: recurrence engine, period goals, and now the split.

**The separation is structural, not a filter.** A `ScheduledCommitment` is not
a `RankedItem`, so there is no code path that could place a commitment into
`ranked`. This matters more than a test would: a filter is something a future
change can forget to apply, and the cost of forgetting is that "the one thing
to do next" becomes a habit checkbox every day of the year and the capture
product quietly dies.

**Nothing the server calls changed shape.** Both new parameters are defaulted,
so `/v1/plan` compiles and behaves identically until it chooses to pass them.
Verified by test: computing with and without commitments gives byte-identical
`ranked`, `startable`, `quickWins` and `next`.

**`committedMinutes` is exposed, not applied.** Subtracting it and choosing
what still fits is B-01's knapsack — a decision about the user's available
time, not part of a ranking pass. Putting it inside `compute` would have made
the ranker depend on how much of the day was left, which is a different
question from what is worth doing.

**The day comes from the calendar's zone.** Tested with the case that would
bite in production: 02:00 IST on Monday 23 November is still Sunday the 22nd
in UTC, so a server computing in UTC would show an Indian user the previous
day's ritual. The test asserts both behaviours so the zone dependency is
visible rather than incidental.

290 tests. `make ci` GATE: PASS, `make ci-linux` GATE: PASS, every ranking
metric unchanged.

### 2026-11-24 — T3 questions actually exist now (step 6, first of three)

Nothing in the system had ever produced a question. `/v1/questions` returned
`[]` unconditionally, the web app's "Brain has a question" card could not
appear in production, and a capture every tier abstained on kept an unknown
type for good. `Enrichment` now asks.

**Asked after the ladder abstains, not before it — and this deviates from
`docs/09-tiering.md`, deliberately.** That doc places T3 between T1 and T2, on
the argument that asking is free while a model call costs quota. The ordering
cannot be expressed as a rung: `Rung` has no condition and `.askUser` returns
unconditionally, so a T3 rung ahead of T2 starves every provider below it —
there is a test in `BrainProductionTests` that fails if one is put there.

Two reasons asking *after* is the better trade today:

- **Quota is not the scarce resource the doc assumed.** Measured T2 rate is
  0.0% against 10,000 affordable escalations a day. A field left permanently
  blank is a cost paid now; the quota is not.
- **It asks about less.** In the production trial six of seven captures
  settled at T0 and the seventh at T2. Asking ahead of T2 would have produced
  a question the model answered correctly for free. Asking after means the
  user is only asked about captures that genuinely defeated every tier.

**Revisit if** quota becomes scarce, or T2's measured accuracy on captures the
rules abstain on turns out to be no better than asking.

The question quotes the user's own words, truncated at 60 characters. That is
not a guard 9 violation: the text is shown to the person who wrote it and is
never sent to a model. Options are exactly `ItemType.allCases`, so the answer
coming back over HTTP is checkable against a closed set — the same
hallucination-prevention property, applied to a human's answer.

9 tests. No scorecard metric moved, as expected: nothing in the eval reads
`askUser` or questions. `make ci` and `make ci-linux` both GATE: PASS.

### 2026-11-24 — Duplicate detection (step 6, second of three)

Nothing in Brain had ever created a `duplicate` edge. The kind existed in the
graph, the storage and the API; the web prototype's mock invented them from a
title overlap; production could not produce one. The Inbox therefore looked
far richer in the mock than it could ever be for a real user.

**Plain overlap, not `TitleMatcher.score`.** `score` carries a containment
bonus so a short dependency reference matches a longer title — "client"
should find "email the client about pricing". For duplicates that is fatal:
measured on a 15-pair hand-written fixture, "the pricing thing" against
"pricing" scores **0.850** under `score`, the same as two genuine duplicates,
so no threshold on it can separate them. Being *contained in* something is
close to the opposite of being *the same as* it.

**Threshold 0.7, chosen conservatively rather than measured.** On the fixture
the separating band is 0.600–0.667 — one pair wide. Fifteen pairs cannot set a
threshold, and treating that band as a measurement would repeat B4's mistake.
0.7 sits a clear 0.1 above the highest observed false positive, which is the
right side to err on: `docs/04-scorecard.md` takes precision over recall,
because a missed duplicate costs nothing a user cannot fix by hand and a wrong
one costs a tap and some trust. Accepted cost, recorded as a test: "call
plumber" against "plumber ko call krna h" scores 0.667 and is missed.

**Links are compared whole, never as words — a real false positive, caught by
auditing rather than by the gate.** Two *different* posts on one domain,
`…/blog/a-post?ref=x` against `…/blog/b-post?ref=x`, score **1.000** under
word overlap: the single character that distinguishes them is dropped as a
one-letter token. Two different Hacker News items score 0.750. Saving links is
something this user does constantly, so that would have fired often and
visibly.

Exact matching alone would be the opposite error. The same link saved twice
scores 0.700 under word overlap — on the threshold by luck — and 0.438 or
0.286 once a sentence surrounds it, missing the clearest duplicate there is.
The rule: both sides have links → duplicates iff they share one; neither has
→ word overlap; one has → word overlap of the prose, which will not reach the
threshold and should not.

**A correction to my own reasoning:** the doc comment first justified this
with a hand-calculated 0.25 for that pair. It is 0.700 — I had forgotten the
URL's own words contribute shared tokens. The conclusion survived; the number
did not, and the measured figures are now in the comment and asserted in a
test.

**Audited, not assumed.** Over the dev split: 32 suggestions on 415 captures
(7.7%), 9 involving links, and every one of those nine shares the actual link.
**But the synthetic corpus generates decorated variants of shared bases**, so a
high hit rate there is expected and says little about real precision. The
honest measure will be confirm-versus-reject on real captures, which the server
records. Until then the threshold stays conservative.

21 tests across the two suites, 320 in the package. `make ci` and
`make ci-linux` both GATE: PASS; no ranking metric moved.

## 2026-11-24 — Dependency backfill, and what auditing it found

Step 6's third piece (`docs/15-planner.md`). A dependency stated before its
referent exists — "deploy after the pooler thing", captured first — parsed
correctly and matched nothing, and nothing ever looked again: the sweeper
requeues captures that are `raw`, stuck or `failed`, and a capture whose
dependency missed is `enriched` and perfectly healthy. The edge was lost
permanently and silently.

`EnrichmentResult.pendingReferences` now carries unmatched referents out as
structured data, and `DependencyBackfill.resolve` offers them back when a new
item arrives. The claim, asserted end to end: **capture order does not change
the graph.**

Deliberately *not* filed in `trace.unresolved`: `BrainEval/Metrics.swift:317`
counts that into `fieldsConsidered`, the denominator of every tier-share
percentage, so recording it there would move the whole scorecard for a
bookkeeping reason. A test asserts it stays out, because the next person to
touch this will reach for `unresolved` as I did.

### The audit failed, and the first version was wrong

`brain backfill-audit` replays a split in capture order and offers kept
references to each later item. The first run, using the live path's
`TitleMatcher.score`: **seven resolutions on the dev split, none of them
correct.** Every one linked an item waiting for X to *another item waiting for
X* — "after the design review" contains "the design review" and therefore
scores 0.850 against a reference to it, through the containment bonus.

**Why the live path survives this and the backfill does not.** `bestMatch`
takes the argmax over every open item, so when the real referent exists it
scores higher and wins. The backfill has no competition: it asks "does this
one item satisfy this reference?" against a floor, one reference at a time, so
a containment hit is accepted on its own. The asymmetry is structural, which
is what justifies the backfill using a different matcher rather than
inconsistency for its own sake.

Switched to `TitleMatcher.overlap` at 0.5. Measured separation on nine pairs:
wrong ones 0.100–0.286, right ones 0.500–1.000, where `score` gives 0.850 to
both kinds alike. Nine hand-picked pairs are not a validation set; the solid
part is the negative result, that no floor on `score` separates them at all.

### Where it stands, honestly

| split | captures | live edges | kept | resolved | correct by eye |
|---|---|---|---|---|---|
| dev | 415 | 70 | 16 | 1 | 1 |
| train | 1401 | 248 | 16 | 3 | 1 |

**Two of four, not a working feature.** Every remaining error has one cause,
and it is not the backfill: **"after lunch" and "before bed" are parsed as
dependencies at all.** They are times of day. `DependencyParser.isTimeExpression`
catches "after 3 days" and not these, so the parser invents a blocker named
"lunch", and then anything else mentioning lunch satisfies it.

That bug is in T0 and affects the **live path's 248 edges too**, so fixing it
changes which `blocks` edges are proposed, which changes startability, which
moves the ranking metrics. It is a measured change of its own and not
something to slip in beside a feature.

**Consequence: the server must not wire the backfill up yet.** The mechanism
is right and tested; the parser feeding it is not. The daypart fix comes
first, measured on its own.

One false positive survives the matcher fix and is asserted as a test:
"call manager about raise" overlaps "call manager about leave" at **0.600**,
above the floor. 0.7 would clear it and would also reject "Priya's reply"
against "reply to priya" at 0.500 — the one dev resolution that was right.
One true positive against one false positive is not a decision 16 references
can make.

343 tests, `make ci` GATE: PASS, every ranking metric unchanged.

## 2026-11-24 — Three T0 parser fixes, all found by real captures

Ganesh captured six items through the deployed app and reported that nothing
useful came back. Running his exact text through the pipeline settled where
the fault was and where it was not.

**Brain reads it correctly.** Four of six got a due date at T0, all six a
type, including both Hinglish lines:

```
 1.  Call shakti in 2 days                0.878  due in 2 days
 2.  Need to pay somil 10k in 5 days      0.751  due in 5 days
 3.  2 din me diwali ki packing krni h    0.526  multi-day · due in 2 days
 4.  5 din me shakti ko call krna h       0.450  multi-day · due in 5 days
 5.  Craete one project call Gym tracker  0.370  No links or deadline yet
 6.  Need to pay bill which is due 3 days 0.370  No links or deadline yet
```

The deployed bundle is `VITE_API_MODE: "http"` (read from the live JS), the
worker runs the full pipeline and persists every classified field
(`Enricher.swift:77-105`), and the deployed `ItemMeta` renders type, effort
and due chips. So the engine and the wiring are sound, and anything he is
seeing flat is either captures that never reached the worker or a product
expectation the chips do not meet. **Row 6 was a genuine parser bug.**

### 1. `due N days` without `in`

`matchInNDays` required `in` or `after`. "due 3 days" is ordinary
Indian-English for "due in 3 days" and got no date at all — the worst kind of
miss, because the item looks like it simply has no deadline. On six phrasings
of the same sentence, date coverage went **33.3% → 100%**.

### 2. Times of day are not dependencies

"stretch after lunch" produced a dependency on an item named *lunch*, and
anything else mentioning lunch then satisfied it. `isTimeExpression` catches
"after 3 days" and not these, because a daypart is neither a duration nor a
date. A closed, deliberately short set — meals and bedtime. "after the gym"
and "after work" are left alone: those genuinely can be on the list.

### 3. The referent captured to the end of the string

The root defect behind both the backfill's false positives and the polluted
referents. The English rules capture from the marker to the end of the text,
which is right only when the dependency phrase comes last:

| capture | referent before | after |
|---|---|---|
| stretch after lunch today 20 minutes | `lunch today 20 minutes` | *(none)* |
| book time for after lunch tomorrow | `lunch tomorrow` | *(none)* |
| deploy after schema review tomorrow 2 hours | `schema review tomorrow 2 hours` | `schema review` |
| Send the deck after the client meeting on monday | `client meeting on monday` | `client meeting` |
| after lunch ko walk karna hai | `lunch ko walk karna hai` | *(none)* |

A trailing date or effort belongs to the task, never to the thing waited on;
`ko` ends the object, so a Hinglish predicate after it is the speaker's verb.
Dangling connectives left by the cut ("client meeting **on**") are stripped.

**One earlier decision reversed, deliberately.** `dateInsideReferent` asserted
that "the client meeting on monday" keeps its date, on the argument that the
date says *which* meeting. Both readings are legitimate and the parser cannot
tell them apart from surface form. Trimming wins because the error is
**recoverable**: a short referent still matches the long title, which the test
now proves. A polluted referent matches the wrong item and nothing downstream
can undo it.

### Measured

| | dev before | dev after | train before | train after |
|---|---|---|---|---|
| live `blocks` edges | 70 | **62** | 248 | **213** |
| references kept | 16 | 11 | 16 | 11 |
| backfill resolutions | 1 | 1 | 3 | 1 |
| …correct by eye | 1 | **1 of 1** | 1 | **1 of 1** |

**43 phantom dependency edges removed**, and the backfill's false positives
are gone — 2 of 2 correct across both splits, from 0 of 7 when the audit
started. Scorecard: **T0 settled +0.6pp**, T2 rate 0.0% and category 82.3%
unchanged. 352 tests, `make ci` GATE: PASS.

### Still broken, stated plainly

- **Decomposition does not exist.** "Create one project called Gym tracker app
  and create few subtasks out of it…" becomes one flat item, because nothing
  in Brain breaks a capture into several items. That is a real product gap and
  a new claim (T2, a model proposing subtasks) — backlog, not a quiet fix.
- The backfill is still **not wired into the server**. 2 of 2 is two.

## 2026-11-24 — Effort escalates to T2. Due dates do not.

Ganesh asked why Google AI was not catching the things T0 got wrong. The
answer was in `ProductionRouter.swift:160`:

```swift
ladders: [.classifyType: classifyTypeLadder(apiKey: apiKey)]
```

**One ladder, one field.** The router is called from exactly one place in the
pipeline, for `type`, and only when the type rules abstain. `dueAt`, `effort`
and `category` have no ladder at all: when T0 abstains they are recorded in
`trace.unresolved` and the field stays blank forever. `judgeLink` exists as a
capability and nothing routes it.

Measured on the dev split, T0 coverage per field:

| field | T0 reads | escalation set |
|---|---|---|
| type | 94.0% | 25 of 415 |
| dueAt | 44.6% | 230 of 415 |
| effort | **34.7%** | **271 of 415** |

So the model was wired to the field the rules already settle 94% of, and left
out of the field they settle 35% of. On Ganesh's own six captures the model
was called **zero times**.

### Effort now escalates

**The Justification Test passes on cost, not on cleverness.**
`EffortBucket.unknown` is scored as medium — 60 minutes, by
`docs/02-scoring-spec.md` — so a capture whose size the rules cannot read does
not score neutrally. It silently claims an hour of the day, and it does so for
65% of captures. A closed set of six buckets is verifiable in code, and being
one bucket out costs a ranking position rather than a missed deadline.

Same three rungs as `classifyType`, Decisions API first. Call volume rises
roughly **tenfold** — 6% of captures escalated before, 65% now — which is
still nothing against Decision 1's 10,000 requests a day (verified
2026-11-24). Reaching that ceiling would take about 15,000 captures in a day.

### Due dates do not, and that reverses my own recommendation

I proposed widening T2 to `dueAt` *and* `effort`, and Ganesh approved it.
Checking `docs/07-harness-spec.md` before writing the code found guard 5:

| 5 | **Deterministic dates** | *always on, not toggleable* | any model-supplied date | T0 parse is the only source |

> "Guards 5 and 6 are **not toggleable.** They are correctness invariants, not
> tunable features — a configuration in which a model supplies a date or
> creates a cycle is not a configuration we want to measure."

So the recommendation was half wrong and the dates half is not mine to
override. Recorded here rather than quietly dropped.

**A rationalisation rejected on the way.** The design had the model answer
"how many days from today" so that `CalendarDay` did the arithmetic, which
keeps a date string out of the response. In substance the model still picks
the deadline, and returning it as an integer changes nothing about that. That
is the sort of dressing-up guard 5 exists to prevent.

**Guard-5-compatible options, if dates are to improve:**

1. **Extend the rules.** The bet guard 5 makes is that dates are a closed
   grammar. Today's evidence supports it: adding `due` to one regex took that
   phrasing from 33.3% to 100%. Cheapest and already working.
2. **The model flags, the human fills.** A yes/no "does this state a
   deadline?" never supplies a date, and turns a silent blank into a T3
   question. Fully compatible; not built.
3. **Change guard 5 deliberately** — a charter-level decision, with the
   trade-off written down, not a line in a feature commit.

### Not yet measured, and that is the honest status

The eval runs `--cassettes replay` and no cassettes exist for
`estimateEffort`, so those calls miss, abstain, and the scorecard reads
exactly as before: **T2 rate 0.0%, T0 settled 62.6%, category 82.3%,
unchanged**. The accuracy of effort escalation against a real model is
**unknown**.

`brain record` was hardcoded to `classifyType`, so it could not have been
measured at all; it now takes `--capability estimate-effort`, with
`--escalations-only` filtered by the effort rules rather than the type rules
(the two escalation sets barely overlap). Recording the dev escalation set is
271 calls — about two minutes against Decision 1's 200 rpm, and 2.7% of one
day's free quota. That spends Ganesh's key, so it is his call to run.

352 tests, `make ci` GATE: PASS.

## 2026-11-24 — The comparison harness, and what its first run proved

Ganesh's argument: "due 3 days" failing is not a date bug, it is evidence that
hand-written rules do not scale, and we should not keep paying a regression
tax per phrasing forever. `brain compare` exists to settle that with numbers
instead of two opinions — it scores the **pipeline's output** against labels,
so any path can be measured, where `Metrics.extraction` can only ever measure
T0 because it calls the parsers directly.

The metric is **end-to-end: correct / should-have-been-answered.** A blank
field counts against a path exactly as a wrong one does, because to a user
they are the same thing.

First run, dev split, 415 captures:

| field | rules only | rules + model | answered / expected |
|---|---|---|---|
| type | 81.0% | 81.2% | 390 / 415 |
| dueAt | **97.9%** | 97.9% | 185 / 187 |
| effort | 91.8% | 91.8% | 140 / 147 |
| category | **67.0%** | 67.0% | 258 / 339 |

### The finding that matters, and it is not the comparison

**`dueAt` measures 97.9% here and broke on Ganesh's first real capture.**

Both are true, and that is the whole problem. 187 of 415 captures carry a date
label, and the rules read 183 of them — because `scripts/make-synthetic.py`
writes dates in the forms the rules were built to read. "Need to pay bill
which is due 3 days" is not in the corpus and never would be.

So the eval is **blind to the entire class of failure a real user finds in six
captures.** This is the third time the same circularity has bitten: it hid the
missing `before` rule, it hid the duplicate containment flaw, and it hides
this. Each time it was found by hand, not by the gate.

**Consequence: this harness cannot decide rules-versus-model on synthetic
data.** It can only compare paths on the distribution the rules were authored
against, which is the one place rules are guaranteed to look good. Read a
model win here as strong evidence and a rules win as almost none. The real
answer needs labelled captures of Ganesh's own — which the corrections table
already collects, and which is now the reason to collect them.

### A second finding, which changes the priority order

**Category is the weakest field by a wide margin — 67.0% — and it is the one
with no escalation path at all.** It also answers only 258 of 339. On measured
weakness the order to route is **category, then effort, then type**, and
`dueAt` is last. The field this whole argument started over is the field the
rules handle best.

That is not a reason to dismiss the argument. It is a reason to stop treating
dates as the example and treat the *approach* as the subject.

### Honest status of the comparison itself

296 model calls were attempted and **one** produced an answer: in replay a
capability with no cassette abstains, and only `classifyType` has recordings.
So the two columns are very nearly the same path, and the comparison is not
yet a comparison. The command says so in its own output rather than letting
the near-identical columns read as a result.

352 tests, `make ci` GATE: PASS.

## 2026-11-24 — Category escalation, behind a flag

First field moved onto the proposal-and-verification path, chosen by the
comparison harness rather than by which failure was noticed most recently:

| field | end-to-end | answered / expected | escalation path before today |
|---|---|---|---|
| **category** | **67.0%** | 258 / 339 | **none** |
| type | 81.0% | 390 / 415 | T2 ladder |
| effort | 91.8% | 140 / 147 | T2 ladder (added today) |
| dueAt | 97.9% | 185 / 187 | none (guard 5) |

Category is both the weakest field and the only one with no escalation at
all. Dates — the failure that started this whole argument — are the field the
rules handle best. That does not make the argument wrong; it makes dates the
symptom rather than the subject.

### Why a flag, and what the flag protects

`EnrichmentFeatures` is an `OptionSet` on the pipeline, empty by default.
With the flag off, nothing changes anywhere: `make ci` and the scorecard read
exactly as before (T0 settled 62.6%, T2 rate 0.0%, category 82.3%), and a
test asserts the model is never asked.

The flag exists because moving a field from rules to a model is a **claim
about accuracy**, and the synthetic labels cannot test it — the generator
wrote both the captures and the labels, so the rules are scored on the
distribution they were authored against. Building behind a flag means the
path can be written, tested and measured without production betting on an
argument. Every flag here should either graduate or be deleted.

### What "Stage 2" honestly is for a closed set

For `category` the verification step is `TaskCategory.init(rawValue:)` plus
the abstention check, and that is **all it can be**: the answer comes from a
nine-item closed set, so guard 1 is structural and there is no hallucinated
category to reject.

The quote-and-verify layer this architecture actually needs arrives with the
first **open-ended** field — an amount, a deadline span, a subtask — where a
model can invent something that is not in the text and a literal-substring
check is the thing that catches it. Building that ceremony around an enum
would have been theatre, so it is not here.

### Measurement, and the honest gap

`brain compare --features category` now switches path B's flag on. On the dev
split it raises attempted model calls from 296 to **425** — 129 category
escalations — and changes no score, because **no cassettes exist for
`classifyCategory`**. In replay a capability with no recording abstains.

`brain record --capability classify-category --escalations-only` records
them, with the escalation filter running the *category* lexicon rather than
the type classifier. 129 calls is about 1.3% of one day's free quota on
Decision 1. It spends Ganesh's key, so it is his to run.

Until then this is **built and tested, not measured**. The flag stays off.

### One fixture worth recording

My first test fixture for "a capture the lexicon cannot read" was "sort out
the thing with the landlord's cousin". The lexicon classifies it `chores`.
"follow up on that" is `communication`; "decide about the thing" is
`planning`. The lexicon reaches much further than it looks, which is the
second time today an invented fixture was wrong where a measured one was
needed. The fixture is now `"that matter we discussed"`, checked.

359 tests, `make ci` GATE: PASS.

## 2026-11-24 — The first real rules-vs-model number, and two bugs that hid it

Recorded 129 `classifyCategory` cassettes against `gemini-decision-1` (124
calls plus 5 from a trial, 0 failed, **1.3% of one day's free quota**) and ran
`brain compare --split dev --features category`.

**The first run said +0.6pp. It was wrong, and the harness said so itself** —
the "how much could be scored" row reported that category answered 3 when 129
cassettes with real answers were on disk. Two bugs, found by chasing that gap.

### Bug 1 — a cassette miss tripped the circuit breaker

`ModelRouter` keyed the breaker by **rung name**, and every ladder in
`ProductionRouter` uses the same names (`t2-decision`, …) because it uses the
same models. `estimateEffort` has no recordings, so its first few captures
threw `cassetteMiss`, `recordFailure()` opened the breaker, and every *other*
capability behind that rung was skipped as "circuit open" — before it ever
looked up its own cassette. 425 calls attempted, **26 reached the store.**

A missing recording is not a provider outage. The catch now distinguishes
them; a real failure still trips the breaker, asserted by its own test.

**This was suppressing every T2 measurement in the project, not just this
one.** `classifyType` jumped from **+0.2pp to +5.8pp** once the breaker
stopped closing on it — it had been starved in every earlier run.

### Bug 2 — guard 1 judged every cassette against the type option set

With the breaker fixed, `make ci` failed: **hallucinated-ID rate 71.3%**,
examples `money | errands`, against a hard invariant of zero. Nothing was
wrong with the answers. `auditCassettes` took one global `allowed` array, which
was correct only while `classifyType` was the sole capability with
recordings; category answers were being judged against the *type* set.
129/181 = 71.3% exactly.

Now keyed per capability via `Metrics.auditOptionSets`, and a recording whose
capability has no registered set is **counted** rather than skipped —
skipping would let guard 1 pass by not looking.

### The result

| field | rules only | rules + model | delta | model answered / scored |
|---|---|---|---|---|
| type | 81.0% | **86.7%** | **+5.8pp** | 25 / 25 |
| **category** | 67.0% | **87.3%** | **+20.4pp** | 106 / 76 |
| dueAt | 97.9% | 97.9% | = | guard 5, never routed |
| effort | 91.8% | 91.8% | = | no cassettes yet |

Of the 76 scored category escalations the model answered, **69 were correct —
90.8% precision**, against the lexicon's own 227/258 = 88.0%. So the model is
both more complete *and* slightly more precise than the rules on exactly the
captures the rules cannot read. It abstained on 23 of 129, which is the
behaviour asked for.

**Ganesh's argument is supported by the measurement**, and with the caveat
pointing the right way: this corpus's labels were written by the generator the
lexicon was authored against, so a model win here is the strong direction. A
+20.4pp win against that handicap is real.

### A number I quoted twice today that was not a measurement

`Metrics.pipeline` builds `EnrichmentPipeline(timeZone:, router: nil)`. The
scorecard's **"T2 rate 0.0%" is structurally zero** — the pipeline it measures
has no router, so no tier above T0 can ever appear in it.

I cited that 0.0% to justify the T3-after-ladder ordering and again to argue
quota is not scarce. Both conclusions survive on other evidence — only
`classifyType` had a ladder at all, and the production trial settled six of
seven captures at T0 — but the figure itself was a tautology, not a finding,
and I presented it as a finding. The metric should either route in replay or
be renamed; changing it moves a gate metric, so it is Ganesh's call.

359 tests, `make ci` GATE: PASS.

---

## 2026-11-24 — Category graduates, effort is measured and fails, and the scorecard stops reporting a zero that meant nothing

Three things, in the order Ganesh asked for them: turn the category flag on,
record the effort cassettes, fix the T2-rate metric.

### 1. `EnrichmentFeatures` is gone

`.categoryEscalation` graduated on its own measurement — **67.0% → 87.3%,
+20.4pp end-to-end**, with the model right on 69 of the 76 scored escalations
(90.8%, against the lexicon's own 88.0%). Category now escalates whenever a
router is attached, exactly as effort and type already did.

The whole option set went with it rather than being left empty. Its own doc
comment said every flag there should "either graduate into unconditional
behaviour or be deleted", and a zero-member `OptionSet` behind a `--features`
switch that accepts no values is worse than no switch. Re-adding one is eight
lines when something else needs proving.

The Server needs no change for this: `Sources/Worker/Enricher.swift` builds
`EnrichmentPipeline(timeZone:router:)` and never passed `features:`, so the
behaviour arrives with the next Brain pin bump. **That is a real behaviour
change to a deployed service** and belongs in the pin-bump note, not in a
silent dependency update.

### 2. Effort: 271 recordings, and the number is bad

271 `estimateEffort` cassettes against `gemini-decision-1` — the full dev
escalation set, 0 failed, 271 of 10,000 daily quota.

| field | rules only | rules + model | delta |
|---|---|---|---|
| type | 81.0% | 86.7% | +5.8pp |
| category | 67.0% | 87.3% | +20.4pp |
| dueAt | 97.9% | 97.9% | = (guard 5, never routed) |
| **effort** | 91.8% | 92.5% | **+0.7pp — do not believe this** |

**Effort is not measurable on this corpus and what little can be measured is
against it.** The model answered 207 of 271 escalations; **6** of those had a
label. Rules answer 140 of 147 at 135 correct; the hybrid answers 146 at 136.
So of six new answers, **one was right**. On a sample of six that is not a
result, but it is certainly not the +20.4pp category produced.

The stronger evidence is the model's own calibrated probabilities over all 271,
which need no labels at all:

| capability | n | median confidence | below 0.50 | answered `unknown` |
|---|---|---|---|---|
| classifyType | 52 | 0.880 | 10% | 0 |
| classifyCategory | 129 | 0.657 | 30% | 23 |
| **estimateEffort** | **271** | **0.393** | **72%** | **64** |

Chance over six buckets is 0.167. A median of 0.393 with 72% of answers under
a coin flip is a model that does not know, and says so.

That is not surprising on reflection and it is the useful part: **how long a
job takes is a fact about the person, not about the sentence.** "Call Shakti"
is two minutes or an hour depending on who Shakti is and what the call is
about, and no amount of reading the text recovers that. Effort is the clearest
T1 case in the product — a model trained on *this user's* completion times —
and it was escalated to T2 because T2 was the path that already existed.

**Effort escalation is shipped and currently on, unmeasured when it shipped
and now weakly measured against.** It should either be reverted or given a
confidence floor (`Rung.acceptAbove`, which every ladder currently leaves at
0). Not changed here: Ganesh asked for a measurement, and turning shipped
behaviour off on n=6 would be the same sin as turning it on was.

### 3. The T2 rate now measures something

`Metrics.pipeline` hard-coded `router: nil`, so "T2 rate 0.0%" was structurally
zero — a figure quoted twice as evidence that quota is cheap. It now takes a
router, and the eval runner passes one backed by `eval/cassettes` in replay,
which spends nothing and walks the ladder production walks.

- **`T2 rate` → `T2 settled, routed (costs quota)`**, now **19.3%** against the
  ≤40% target in `docs/05-targets.md`. Renamed rather than retuned: the old
  name has a baseline entry and the new measurement is not a regression against
  it, it is a different quantity. It carries no tolerance until a baseline is
  promoted from a run whose cassettes cover every registered capability.
- **`escalations answered from a recording`**, new, currently **425 of 425**.

That second metric exists because a low T2 rate means one of two opposite
things — the rules did the work, or the ladder never reached a recording — and
twice now it has been the second.

**It caught a starvation in its own commit.** First run read 190 of 425:
`ProductionRouter.make` writes the verified free-tier limits onto the ledger
itself, so my lifting them *before* calling it lifted nothing, and 235
escalations were refused on a per-minute ceiling that cannot apply to a
recording. `brain compare` already had the limits in the right order; the eval
runner did not.

### The 174 cassette "misses" that were not misses

425 hits against 174 misses looked like the starvation bug again. It is not:
a rung whose answer the guards reject falls through to rungs that have no
recording, so one escalation logs one hit and two misses. **87 answers were
`unknown` — 64 effort, 23 category — and 87 × 2 = 174 exactly.** Every
escalation found its recording.

The store's miss count is therefore not the starvation signal, and both
`brain compare` and the scorecard now print escalations-answered beside it.

365 tests, `make ci` GATE: PASS.

---

## 2026-11-24 — The two new metrics start gating, and the baseline is promoted

Follow-up to the entry above, after tagging **0.9.0** on `0beb889`.

`T2 settled, routed` and `escalations answered from a recording` shipped with
**no tolerance**, which meant the gate skipped them entirely: `Scorecard.gate`
requires both a baseline entry and a declared tolerance, so a metric with
either missing is decoration. Promoting a baseline alone would not have fixed
that.

- **`T2 settled, routed (costs quota)`: +5.0 pp**, the same tolerance the old
  `T2 rate` carried. Baseline 19.3% against the ≤40% target in
  `docs/05-targets.md`.
- **`escalations answered from a recording`: −2.0 pp**, not zero. Real
  starvation is never subtle — a capability with no recordings costs tens of
  percent, as the 190-of-425 case did on the first run — while a hard zero
  would fail CI the moment a fourth capability is registered, before anyone
  could record for it. That is a reminder worth having, not a build worth
  blocking. Baseline 425 of 425.

Baseline promoted with the reason recorded in `eval/baselines/dev.json`: it is
the first run whose cassettes cover every registered capability, which is the
precondition `docs/04-scorecard.md` states. It also absorbs the measured gains
from category escalation; nothing in it regressed, and `T0 settled` moved
62.0% → 62.6% because escalated fields now settle instead of staying blank.

Also cleared the one lint warning the previous commit introduced
(`CategoryEscalationTests.swift`, an end-of-line comment past the line length).
It was left in `0beb889` deliberately rather than silently tagging a different
commit than the one Ganesh named for the Server pin; the fix lands after the
tag, where it changes nothing for a consumer.

365 tests, `make ci` GATE: PASS.

---

## 2026-11-24 — One verification date, next to the data

Found by the Server session on a final read before it pinned 0.9.0, and it is
the right kind of find: **the free-tier verification date existed twice and the
two copies disagreed.** `GoogleLimits` said the rows were read from Ganesh's
AI Studio dashboard on `2026-11-23`; `ProductionRouter.gemma` and
`.flashLite` carried their own `verifiedOn: "2026-11-22"`. `staleLimits` reads
the router's, so **the date that governed spending was the copy furthest from
the numbers it described.**

Git says which drifted: `GoogleProvider.swift` was created at 2026-11-23 23:37
IST with the table and the `2026-11-23` comment in one commit, and the router
rows were written at 2026-11-24 02:27 IST — three hours later, after midnight,
in a different file. The table has not changed since. So the `2026-11-22` is
almost certainly a date typed on the wrong side of midnight.

Now a single `GoogleLimits.verifiedOn`, which both router rows read.

**Set to the earlier date anyway.** The contemporaneous evidence points at the
23rd, but a staleness marker must not claim to be fresher than it can prove,
and one day out of ninety costs nothing. Ganesh can move it to the 23rd if
that is when he actually opened the dashboard — the point is that there is now
one place to move.

Decision 1's row is untouched: it is the only one verified against Google's
own published documentation rather than a login-only dashboard, and it keeps
its own date for that reason.

365 tests, `make ci` GATE: PASS.

---

## 2026-11-24 — An abstention is an answer, and the ladder stops

`unknown` is offered to the model as a permitted choice, so a model that picks
it has told us something. Until now `Guards.schema` mapped it to nil — which is
exactly what a malformed answer looks like — so the router walked on and asked
Gemma, then Flash-Lite, the same question Decision 1 had already declined.

Measured on the dev split before the change: **87 of 425 escalations ended in
an explicit `unknown`** — 64 effort, 23 category — each trying two further
rungs. In replay those were 174 harmless cassette misses. In production they
are live calls: about **0.21 per capture to each of two pools**, and
Flash-Lite's free tier is **500 requests a day against Decision 1's 10,000**.
The scarcest quota we have, sitting last on every ladder, receiving the
hardest questions.

`Router.route` now sets `modelAbstained` and skips later **provider** rungs.

### Three distinctions this rests on

**A T3 or degrade rung is still reached.** When the model says it does not
know, the person is exactly who to ask next — stopping the ladder must not
stop asking. Tested.

**Empty output is not an explicit abstention.** An existing test,
"An abstaining provider does not block a later rung", failed the moment the
two were conflated, and it was right to. A blank body is a provider that
produced nothing — a blocked response, an empty candidate list, a truncated
stream — and that says nothing about whether the *question* is answerable, so
a later rung may well answer it. A named `unknown` is a decision about the
question. `Guards.schema` still reduces both to nil, because neither is a
usable value; only the ladder's choice to stop turns on the difference.

**It assumes a later rung is no better informed, which holds only while every
provider rung is T2.** A T1 rung — a model trained on this user's own
corrections — genuinely may know what a generic model does not. When one
lands, this must compare tiers and stop only at the same tier or above, rather
than stopping outright. Written into the code where the flag is declared, not
just here.

### Result

`brain compare`, dev split: **174 cassette misses → 0**, 425 of 425 escalations
still answered from a recording, and **every accuracy figure unchanged** — type
86.7%, dueAt 97.9%, effort 92.5%, category 87.3%. The calls it removes were
buying nothing.

The abstention words now live in one place, `Guards.abstentionWords`, with the
normalisation beside them, because the router and the schema guard both need
them. 372 tests, `make ci` GATE: PASS.

---

## 2026-11-25 — Ideas are not work: plan membership by type

`Scoring.rank` scored every open item whatever its type, so "rust vs go for the
backend?" could outrank real work, become `next`, and be proposed as the day's
big task. **Capturing a thought is not committing to act on it**, and a tool
that treats the two alike punishes you for thinking out loud — the one thing
this product exists to make cheap.

`idea` and `note` are now excluded from the plan. `task`, `reminder` and `link`
stay in.

### The decisions inside the decision

**One filter, not five.** `ranked`, `startable`, `next`, `quickWins` and
`blocked` all derive from the ranked list, so a single filter in `Scoring.rank`
settles all of them. The tests assert all five anyway rather than trusting the
derivation.

**`note` out, `link` in**, as Ganesh proposed and for his reason: a note is
reference material, written down to keep rather than to finish, while "read
this" is an action with a real duration. Revisit `link` if saved links turn out
to be hoarded rather than read — that shows up as links piling at the top of
`quickWins` and being dismissed, which is a measurement, not an opinion.

**An item whose type is not yet known still ranks.** `type` is `Classified` and
is nil while the ladder abstained and a T3 question is unanswered — which, now
that the server stores questions, is a live state rather than a theoretical
one. Hiding those would mean a capture silently missing from the plan until the
user answers a question they have not been shown yet. A capture is never lost,
and showing something dismissible is the recoverable direction.

**Excluded is not deleted.** They stay in the graph with their goal links, and
an open idea blocking a task is still named as that task's blocker — otherwise
"decide the stack, then build it" would quietly become startable. Membership is
computed at rank time from the current type, so **correcting a type to `task`
makes it rank normally, with no migration.**

One consequence named rather than discovered: `quickWins` takes the median
leverage over startable candidates, so a backlog of captured thoughts can no
longer drag the quick-win bar down. Tested.

### Measured

Ranking metrics are **unchanged** — human pick in top-3 71.4%, top-1 23.1%,
NDCG@5 0.7425, all flat against the baseline. The ranked scenarios contain no
ideas or notes, so this moved nothing it was not meant to move. On Ganesh's own
five captures: 5 items created, **3 ranked**, 0 lost.

### Also recorded, built nowhere

`docs/00-charter.md` gains "Outside Brain, not outside the product": comments
on items, goals and commitments, and opt-in **count** goals (N circles, each
fill dated and optionally commented), are planned as **Server and Web**
features that **Brain does not read**. They are the user's own records, not
ranking inputs, and nothing in scoring, tiering or the graph may come to depend
on them. If a comment ever becomes a signal that is a new decision made on
purpose, with a measurement.

**Counts of things, never money.** A count goal counts occurrences — pages
read, sessions done, calls made — and holds no amounts, prices or balances.
Expense tracking is a rejected non-goal and a count field is exactly how it
would arrive by the back door, so the limit is written down now rather than
discovered later.

379 tests, `make ci` GATE: PASS.
