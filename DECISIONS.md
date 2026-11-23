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
