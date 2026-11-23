# 10 — Collecting the real data

Two jobs, both yours, both one-off. Everything downstream — the synthetic
generator, the T0 rules, the cascade threshold, every number on the scorecard —
is shaped by what you put in here. It is worth doing properly once.

---

## Job 1 — 300 real captures (~45 min, can be split up)

### What to do

Create a plain text file. **One capture per line.** Then:

```bash
make ingest FILE=~/Desktop/my-captures.txt
```

It assigns stable ids, splits 50/20/30, and writes
`datasets/real/captures.jsonl` — which is **gitignored and never leaves your
machine** (ADR, `.gitignore`).

### Where to get them

Don't invent them. Harvest them:

- Notes app — everything, including the half-finished ones
- WhatsApp messages to yourself
- Old to-do lists, in any app you abandoned
- Browser tabs you've kept open "to deal with"
- Starred/flagged emails
- The calendar, for things that were really tasks
- Photos of whiteboards and sticky notes
- Then sit for ten minutes and dump what's in your head

### What makes this set good or useless

**The single most important instruction: do not clean them up.**

The whole point is that captures are messy. If you write 300 tidy lines like
"Call the plumber on Tuesday", the system will learn to handle a world that does
not exist, and every metric will look great and mean nothing.

| Keep | Why |
|---|---|
| Hinglish exactly as you'd type it | "kal plumber ko call karna hai" is the real input |
| Fragments with no verb | "that pricing thing" — the system must handle it or abstain |
| Typos and autocorrect damage | they're in the real distribution |
| **Near-duplicates** | dedup is a core feature; we need real ones, not synthetic ones |
| Vague ones you can't classify yourself | these calibrate abstention. **Especially valuable** |
| Bare URLs, emoji, one-word lines | adversarial cases that actually occur |
| Things that are clearly ideas, not tasks | type classification needs the contrast |
| Things with implicit dependencies | "after the client replies, send the invoice" |
| Very old stale ones | status and staleness matter |

### Rough mix to aim for

Not a quota — a check that you haven't collected only one kind of thing.

| Kind | Rough share |
|---|---|
| Work / client tasks | 25% |
| Side project | 20% |
| Home / admin / money | 20% |
| Ideas and "what if"s | 15% |
| Things to read or watch | 10% |
| Reminders with a time or date | 10% |

Aim for **at least 30% containing some Hindi or Hinglish**, since that's the
case nobody else's tooling handles and the one most likely to break ours.

### A good file looks like this

```
kal subah plumber ko call karna hai
pricing for the template pack — 3 tiers? or just 2
reply to Priya re: invoice
https://arxiv.org/abs/2604.11111
gym join karna hai
that thing about the onboarding flow
idea: what if it could read my whatsapp-to-self messages
file GST before 20th
reply to priya about the invoice!!
buy dog food
🎧
after client sends assets, start the homepage
```

Note what's in there: a near-duplicate of the Priya line, a bare URL, an emoji,
a fragment with no verb, Hinglish, an implicit dependency, and a date in Indian
phrasing. That's twelve lines doing real work.

### Fewer than 300?

Ingest what you have and run it again later — ids derive from content, so
**re-running is idempotent and a capture keeps its split forever.** Nothing
reshuffles when you add more.

---

## Job 2 — Rank 30 scenarios (~30 min, resumable)

```bash
make rank
```

You'll see a list of tasks with their effort, deadlines, goals and
dependencies, and be asked which three you'd actually do first.

**You will never see a score, a ranking, or what the scenario is testing.**
That's deliberate: if you can see the formula's opinion, your answer stops being
independent and the metric measures nothing (`docs/05-targets.md`). Item order
within each scenario is shuffled, and scenario order is shuffled too, so
position and fatigue don't bias the result.

### How to answer

**As yourself, on a normal morning. Not as you think the system should answer.**

If the answer is "none of these, I'd do the one that's overdue because it's
nagging me" — that *is* the answer. Picking the overdue nag over the clever
high-leverage task is real data about how you actually work, and the formula
should be judged against that, not against an idealised version of you.

Where two feel equally good, pick either. Where the list feels wrong, press `s`
to skip and tell me afterwards — a bad scenario is worth knowing about.

- `3 1 5` — your top three, best first
- `s` — skip
- `q` — save and quit; resume any time, ranked ones are skipped

### What happens next

Your answers go into `expected.ranking_top3` in each scenario file, and become
the ground truth for **"human pick in top-3"** and **NDCG@5** on the scorecard.

The 30 scenarios were **committed before any scoring code was run against
them** (commit `b9d7230`), so the history shows they weren't shaped to flatter
the formula. I have not looked at what the formula says about any of them.
