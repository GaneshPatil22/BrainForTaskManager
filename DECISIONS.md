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
