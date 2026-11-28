# Brain

> **Dump anything. It organises it, finds what depends on what, and tells you
> the one thing to do next.**

Brain is the **reasoning core** of that product: a standalone Swift package
with no HTTP server, no auth and no database. It takes a raw capture and your
existing graph, and returns a structured item, suggested links, and questions
worth asking you. Separately, it takes the whole graph and returns a ranked
plan.

Everything else — storing it, serving it, drawing it — belongs to the other
two repos.

---

## The product, in one page

A person who jumps between many ideas and tasks types whatever is in their
head. Brain turns each dump into an **item** with a type, a due date, a size
and a category; finds **dependencies** between items; and ranks what is worth
doing next. The user confirms one big task for the day.

**The one rule, which every design below follows:**

> **AI proposes. Deterministic code verifies and decides. The human confirms.**

A model is never the source of truth for ids, dates, arithmetic, rankings or
graph validity.

**Explicitly not this product** — expense tracking, subscriptions, gym/health,
social features, collaboration. These are not "later"; they are rejected.

**The three repos**, built in this order:

| Repo | Role |
|---|---|
| **Brain** (this one) | Understands a capture. Ranks the graph. No I/O. |
| [Server](https://github.com/GaneshPatil22/ServerForTaskManager) | HTTP API, Postgres, auth, background worker. Links Brain in as a library. |
| [Website](https://github.com/GaneshPatil22/WebAppForTaskManager) | React PWA. Captures offline, draws what the server returns. |

iOS and Android come after, and will link this same package directly.

---

## How a capture travels

```
you type  ->  Website  ->  POST /v1/captures  ->  Server stores it (raw)
                                                       |
                                              job queued after commit
                                                       v
                                            Server's worker claims it
                                                       |
                                        EnrichmentPipeline.enrich(...)   <- Brain
                                                       |
                                     item + suggested edges + questions
                                                       v
                                        Server saves it in one transaction
                                                       |
                            later:  GET /v1/plan  ->  Brain.compute(...)  -> ranked
```

Brain is the only part of that picture with no network address. It is compiled
into the server binary and called as a function.

---

## The four tiers

Work is assigned to the cheapest tier that can do it honestly
(`docs/09-tiering.md`).

| Tier | What it is | Used for |
|---|---|---|
| **T0** | Deterministic rules on this machine | Dates, efforts stated in the text, dependencies, duplicates, the category lexicon, **all ranking** |
| **T1** | A small model trained on your own corrections | Not built yet (phase B5) |
| **T2** | A general model behind the ladder | Type, effort and category **only when T0 abstains** |
| **T3** | Ask the person | When every tier abstains, rather than guessing |

**Dates are T0 and only T0.** Guard 5 in `docs/07-harness-spec.md` is marked
non-toggleable: any model-supplied date is rejected. A wrong date is a missed
deadline; a wrong effort is a ranking position.

### The ladder

Per capability, first rung that answers wins:

```
t2-decision     gemini-decision-1       closed set, native confidence, ~124 tokens
t2-gemma        gemma-4-26b-a4b-it      generate-and-parse, ~600 tokens
t2-flash-lite   gemini-3.1-flash-lite   500 req/day — outage cover, not traffic
degrade         -                       mandatory, always last
```

Each provider rung is gated by a circuit breaker, a budget ledger and three
guards. An explicit `unknown` from a model **stops** the ladder: it is an
answer, and asking a weaker model the same question is not a plan.

The **degrade** rung is why a capture is never lost — if everything is
exhausted or broken, the field stays unknown and the capture survives.

---

## Layout

| Path | Contents |
|---|---|
| `Sources/BrainCore` | Pure logic: graph, cycles, scoring, dates, domain types. No AI. |
| `Sources/BrainPipeline` | `EnrichmentPipeline` — one capture in, one item out. Prompts live here. |
| `Sources/BrainHarness` | The router/ladder, guards, budget ledger, cassettes. |
| `Sources/BrainAdapters` | Provider adapters: Decisions API, Google generate, fakes. |
| `Sources/BrainProduction` | The one supported way to build the production ladder. |
| `Sources/BrainDatasets` | Dataset loading and splits. |
| `Sources/BrainEval` | Metrics, scorecard, regression gate. |
| `Sources/BrainCLI` | `brain` — dogfood, enrich, coverage, compare, ranking tools. |
| `Sources/EvalCLI` | `EvalCLI` — the eval suite and gate. |
| `datasets/` | Versioned JSONL. Synthetic is committed; **real captures are gitignored.** |
| `eval/baselines/` | Stored scorecards the regression gate compares against. |
| `docs/` | The specs. Start with `00-charter.md`. |

---

## Run it

    make help          # every command
    make test          # unit + property tests (swift-testing)
    make eval          # full eval suite, replay mode: offline, deterministic, free
    make gate          # regression gate vs. the committed baseline
    make ci            # lint + test + eval + gate. If this passes, CI passes.
    make ci-linux      # the same, inside the Linux container

On your own text:

    make enrich FILE=~/Desktop/captures.txt    # full pipeline, tiers shown
    make coverage FILE=~/Desktop/captures.txt  # what T0 alone can read
    make dogfood                               # rank the sample file

`make eval` spends nothing: it replays recorded cassettes, so CI is offline and
free. Changing a prompt changes the cassette key and invalidates recordings —
re-record before trusting the numbers.

CI is **manual-trigger only**; nothing runs on push (ADR-0006).

---

## The boundary: what the server calls

Brain exposes two entry points. Everything else is support.

### 1. Understand one capture

```swift
let result = await EnrichmentPipeline(timeZone: tz, router: router)
    .enrich(capture: capture, graph: graph, now: now,
            idGenerator: &ids, requester: requester)
```

**In:** the raw `Capture`, the user's whole `BrainGraph`, the current time,
an id generator, and a `Requester` carrying that user's share of the daily
model budget.

**Out:** `EnrichmentResult` —

| Field | Meaning |
|---|---|
| `item` | The structured item. Every classified field carries a value, a confidence, a tier and the span of text it came from. |
| `suggestedEdges` | Dependencies and duplicates. **Always unconfirmed** — invariant 3 reserves `confirmed` for a human. |
| `questions` | T3 questions, when every tier abstained. |
| `pendingReferences` | Dependency phrases whose target does not exist yet, so a later capture can satisfy them. |
| `trace` | Which tier settled each field, guards fired, tokens, what was unresolved. |
| `capture` | The same capture with its status advanced to `enriched` or `failed`. |

`router` is optional. Passing `nil` means rules only — no model is called,
captures still become items, nothing fails.

**No stage throws.** A model outage, a budget refusal or an unparseable date
costs a *field*, never the user's thought.

### 2. Rank the graph

```swift
let outputs = Brain.compute(graph: graph, now: now, calendar: calendar,
                            commitments: commitments, completed: completed)
```

**Out:** `BrainOutputs` — `ranked`, `startable`, `quickWins`, `blocked`,
`commitments`, and `next` (the top *startable* item, not `ranked.first`:
telling someone to start a blocked task is worse than saying nothing).

**No model participates in ranking at all.** Since 0.11.0, open items of type
`idea` or `note` are not ranked — they stay in the graph for goal links and
dependencies, and an open idea can still block a task, but they never appear
in the plan.

### What Brain never does

No database, no HTTP server, no auth, no file I/O on the serving path, and no
knowledge that users exist beyond a `Requester` id. The only outbound network
calls are model requests through the adapters, and only for fields T0
abstained on.

---

## Rules this package keeps

1. **A capture is never lost.** Every stage degrades rather than throwing.
2. **Captures are never edited.** Corrections are new records, not rewrites.
3. **`confirmed` is reserved for a human.** Brain only ever suggests.
4. **Cycles are rejected** (guard 6) — a non-toggleable correctness invariant.
5. **Dates are T0 only** (guard 5) — likewise.
6. **Every field says who decided it**, with a confidence, so a correction
   tells you *which tier* was wrong.
7. **The AI Justification Test** — if deterministic code can do it, a model
   does not get to. Duplicate detection is word overlap, not meaning.

---

## Measurement, honestly

The eval suite reports **end-to-end accuracy = correct / should-have-been-
answered**, so a field left blank counts against it exactly as a wrong answer
does.

Two results worth knowing, both recorded in `DECISIONS.md` rather than tidied
away:

- **Category escalation earns its place.** 67.0% → 87.3% end-to-end (+20.4pp)
  on the dev split, at 90.8% model precision against the lexicon's own 88.0%.
- **Effort escalation does not, yet.** The model answered 207 of 271
  escalations; 6 could be scored; **1 of 6 was right**, at a median confidence
  of 0.393. Effort is a T1 problem (how long a job takes is a fact about the
  person, not the sentence) routed to T2 because T2 is the path that exists.
  Kept as shipped, with sizes corrected by hand, and written down as bad.

The synthetic corpus wrote both the captures and their labels, so a rules win
on it is weak evidence and a model win is strong. Read the numbers that way.

---

## Where the thinking lives

| Doc | What it settles |
|---|---|
| `docs/00-charter.md` | What this is, who it is for, the five hard non-goals |
| `docs/01-domain.md` | Captures, items, goals, edges, and the invariants |
| `docs/02-scoring-spec.md` | How the plan is ordered, and what is in it |
| `docs/07-harness-spec.md` | The twelve guards |
| `docs/09-tiering.md` | T0–T3 and the AI Justification Test |
| `docs/11-using-it.md` | Prove each guarantee yourself |
| `docs/12-backlog.md` | Parked ideas. Nothing here is in v1. |
| `docs/adr/` | Accepted architecture decisions |
| `DECISIONS.md` | Every phase, every measurement, every reversal |
