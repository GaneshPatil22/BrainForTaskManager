# 11 — Using it: every command, what works, what doesn't

## Opening the project

```bash
cd ~/Desktop/FullProdProject/Brain
```

That's it — it's a Swift package, so the folder *is* the project.

| To open in | Run |
|---|---|
| Xcode | `xed .` (or double-click `Package.swift`) |
| VS Code | `code .` |
| Terminal only | nothing, everything below is CLI |

Everything runs from the terminal. Xcode is optional and only useful for
reading code and running tests with a GUI.

## Orientation

```
Brain/
├── Sources/BrainCore/     the logic. graph, scoring, dates. no AI, no network.
├── Sources/BrainCLI/      the command-line tool you actually run
├── Tests/                 59 tests
├── datasets/scenarios/    30 scenarios awaiting your ranking
├── datasets/real/         your captures (gitignored, never leaves this machine)
├── examples/              sample files you can copy and edit
└── docs/                  specs. 00-charter.md is the map.
```

`make help` lists every command at any time.

---

## What works today

Phase B1 is complete. **Everything below is deterministic — no AI is involved
anywhere yet.** That's by design (`docs/09-tiering.md`).

| Capability | Command |
|---|---|
| Rank a task list and say what to do next | `make dogfood` |
| Explain *why*, from graph facts | included in the output |
| Find quick wins | included |
| Find blocked items and their blockers | included |
| Refuse to create a dependency cycle | enforced; try it below |
| Parse English and Hinglish dates | used by every command |
| Rank scenarios blind | `make rank` |
| Author scenarios from one-liners | `make add-scenarios FILE=...` |
| Ingest raw captures | `make ingest FILE=...` |

## What does **not** work yet

Being explicit so nothing looks broken when it's simply not built:

| Not yet | Arrives in |
|---|---|
| Reading a free-text dump and working out type/effort/dates itself | B2.5 (rules) and B3 (AI) |
| Any AI, any model, any network call | B3 |
| Suggesting links between items | B3 |
| `make eval`, `make gate`, `make scorecard` — these print SKIP | B2 |
| Server, API, database, apps | after Brain v1 freezes |

Right now **you tell it the effort and the dependencies**; it does the graph
reasoning. Working out those fields from raw text is the whole point of the
later phases.

---

## Job 1 — Rank the 30 scenarios

```bash
make rank
```

Then, for each scenario, type the numbers of the three tasks you'd actually do
first, best first:

```
  1. Ship the hotfix
     about an hour · due today

  2. Book flights for Diwali
     about 20 min · due in 2 days

  3. Call Amma
     about 5 min

  Your top 3 (best first), or s / q / ? : 1 3 2
```

| Input | Does |
|---|---|
| `1 3 2` | records that order and moves on |
| `1 2` | fine — fewer than three is allowed |
| `s` | skip this scenario |
| `q` | save and quit; resume later, ranked ones are skipped |
| `?` | show help again |

Check progress any time:

```bash
make rank-status      # ranked: 12/30
```

**Answer as yourself on a normal morning**, not as you think the system should
answer. You will never see a score — that's deliberate (`docs/05-targets.md`).

---

## Job 2 — Give it 300 real captures

Put them in a plain text file, **one per line**:

```bash
make ingest FILE=~/Desktop/my-captures.txt
```

Re-running is safe: ids derive from content, so a capture keeps its split
forever and adding more never reshuffles what's there. Dump 80 now and 220 next
week if that's easier.

Read `docs/10-data-collection.md` before you start. The one rule that matters:
**do not clean them up.**

---

## Writing your own scenarios

Copy `examples/my-scenarios.brain`, edit, run:

```bash
make add-scenarios FILE=examples/my-scenarios.brain
```

Write them as one-liners — no JSON:

```
scenario: Hotfix versus the flights
Ship the hotfix          | medium | due aaj
Book flights for Diwali  | small  | due in 2 days
Call Amma                | tiny
```

| Modifier | Meaning |
|---|---|
| `tiny` `small` `medium` `large` `xlarge` | effort (5 min → several days) |
| `due <anything>` | `aaj`, `kal`, `parso`, `15 tarikh`, `next monday`, `in 3 days`, `15/12`, `shaam 5 baje` |
| `category <name>` | one of paperwork, errands, communication, planning, deepWork, chores, money, learning, health — otherwise derived from the title |
| `goal <title>` | serves a goal declared with a `goal:` line |
| `after <title>` | that task must finish first |
| `done` / `dropped` | already closed |

Rules: each scenario needs a `scenario:` line and at least 2 open tasks.
"Today" is always Monday 23 Nov 2026, so every scenario means the same thing
whenever it's read.

Check before writing:

```bash
make add-scenarios FILE=examples/my-scenarios.brain   # add --dry-run via swift run
swift run brain add-scenarios examples/my-scenarios.brain --dry-run
```

---

## Seeing it work on your own task list

This is the dogfood path — use it as a real tool.

```bash
cp examples/sample.brain ~/Desktop/today.brain
# edit it, then:
swift run brain next ~/Desktop/today.brain
```

Useful flags:

```bash
swift run brain next ~/Desktop/today.brain --all          # full list, not top 8
swift run brain next ~/Desktop/today.brain --alpha 0.5    # count unconfirmed links at half weight
swift run brain next ~/Desktop/today.brain --now 2026-12-01T09:00:00+05:30   # pretend it's a different day
swift run brain next ~/Desktop/today.brain --timezone Asia/Kolkata
```

`--now` is the interesting one: it shows how the ranking changes as deadlines
approach, without waiting.

## Proving the guarantees yourself

**Cycle rejection** — add a circular dependency and watch it refuse:

```bash
cat > /tmp/cycle.brain <<'EOF'
A | small | after B
B | small | after A
A | small | after B
B | small | after A
EOF
swift run brain next /tmp/cycle.brain
```

It reports the rejected edge as an issue and still ranks both tasks. It does
not crash, and it does not silently accept a broken graph.

**Determinism** — same input, same output, every time:

```bash
swift run brain next examples/sample.brain --now 2026-11-23T10:00:00+05:30 > /tmp/a
swift run brain next examples/sample.brain --now 2026-11-23T10:00:00+05:30 > /tmp/b
diff /tmp/a /tmp/b && echo "identical"
```

**The test suite** — 59 tests including the Hinglish date cases:

```bash
make test
swift test --filter DateParser        # just the date grammar
swift test --filter Scenario          # the known-answer graph cases
```

---

## Everything, in one place

```bash
make help          # this list, any time
make build         # compile
make test          # 59 tests
make lint          # format check
make ci            # lint + test (eval/gate skip until B2)
make dogfood       # run on the sample file
make rank          # rank scenarios (blind, resumable)
make rank-status   # progress
make add-scenarios FILE=...   # author scenarios from one-liners
make ingest FILE=...          # ingest raw captures
make split         # stamp dev/test splits onto scenarios
make category-eval # measure the T0 category lexicon
make category-sweep# coverage/accuracy curve for the abstention margin
make agreement     # self-agreement ceiling (needs `make rank-again` first)
make clean         # delete build artifacts
```
