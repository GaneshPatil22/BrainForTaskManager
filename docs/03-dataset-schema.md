# 03 — Dataset schema

Versioned JSONL under `datasets/`. One JSON object per line, UTF-8, no trailing
commas. Schema version is in the directory name (`v1`), never inside the rows.

## What is committed and what is not

| Set | Committed? | Why |
|---|---|---|
| `datasets/v1/{train,dev,test}/synthetic.jsonl` | **yes** | reproducible, not private |
| `datasets/scenarios/*.json` | **yes** | hand-built graphs |
| `datasets/adversarial/*.jsonl` | **yes** | injection, empty, huge, emoji-only |
| `datasets/real/` | **NO — gitignored** | Ganesh's private captures. A private repo is not the same as not-on-a-server |

The loader treats real and synthetic identically. Real data simply isn't there
on a fresh clone, and the eval reports which sets were present in the run.

## Splitting

**Hash-based, not random.** `split(id) = ["train","dev","test"][ sha256(id)[0] % 10 ]`
mapped `0–6 → train`, `7–8 → dev`, `9 → test`.

Adding new data **never reshuffles existing rows** — an item's split is a pure
function of its id. This is what makes baselines comparable across months.

**The test split is read at phase gates only.** It is never used to tune a
prompt, a threshold, a weight, or a rule. Enforced socially, and by the eval CLI
refusing `--split test` unless `--gate` is also passed.

## `capture.jsonl` — classification and extraction

```json
{
  "id": "01JD8F3K2M4N5P6Q7R8S9T0UVW",
  "raw_text": "kal subah plumber ko call karna hai, 10 min ka kaam",
  "source": "text",
  "created_at": "2026-11-23T04:30:00Z",
  "user_tz": "Asia/Kolkata",
  "labels": {
    "type":   { "value": "task",     "span": [24, 28] },
    "effort": { "value": "tiny",     "span": [34, 40] },
    "due_at": { "value": "2026-11-24T03:30:00Z", "span": [0, 10] },
    "goal":   { "value": null }
  },
  "label_source": "human",
  "notes": "Hinglish imperative + relative date + explicit duration"
}
```

- `span` is `[startUTF16Offset, endUTF16Offset)` into `raw_text`. **Every
  extracted value must cite one**, and the loader verifies the span resolves to
  non-empty text. A label with an unresolvable span is a dataset bug and fails
  loading loudly.
- `"value": null` means **unknown is the correct answer.** Abstention is a real
  label, not missing data.
- `label_source` ∈ `human` · `model_assisted` · `synthetic`. Only `human` counts
  as ground truth in the test split.

## `edges.jsonl` — link labels

```json
{
  "id": "01JD8F...",
  "capture_id": "01JD8F...",
  "candidate_ids": ["01JA...", "01JB...", "01JC..."],
  "labels": [
    { "to": "01JA...", "kind": "duplicate" },
    { "to": "01JB...", "kind": "blocks" },
    { "to": "01JC...", "kind": "none" }
  ]
}
```

`candidate_ids` is the **whitelist** the model is shown. Every label's `to` must
be a member. Any predicted id outside it is a hallucinated ID (`04-scorecard.md`).

## `scenarios/*.json` — ranked-output ground truth

```json
{
  "id": "scenario-012",
  "description": "Hub task with deadline vs. three quick wins",
  "now": "2026-11-23T09:00:00Z",
  "user_tz": "Asia/Kolkata",
  "items": [ { "id": "...", "title": "...", "type": "task",
               "effort": "medium", "due_at": null, "status": "open" } ],
  "goals": [ { "id": "...", "title": "Ship v1" } ],
  "edges": [ { "from": "...", "to": "...", "kind": "blocks", "confirmed": true } ],
  "expected": {
    "ranking_top3": ["...", "...", "..."],
    "quick_wins":   ["..."],
    "blocked":      ["..."],
    "ranked_by":    "human"
  }
}
```

`expected.ranking_top3` is authored **by Ganesh, without seeing the formula.**
`ranked_by: "human"` is required for any scenario in the test split — a scenario
I authored cannot grade my own formula.

## `adversarial/*.jsonl`

Same shape as `capture.jsonl` plus `"attack"`:

`empty` · `whitespace_only` · `emoji_only` · `huge` (>50k chars) · `url_only` ·
`mixed_script` · `prompt_injection` · `contradictory` · `nested_quotes` ·
`control_chars`

For injection rows, `labels` encodes the **correct non-compliant behaviour** —
i.e. the system treated the text as data and did not follow it.

## Target volumes (B2)

| Set | Target | Source |
|---|---|---|
| Real captures | **300** | Ganesh, local only |
| Synthetic | ~2,000 | generated, human spot-check |
| Graph scenarios | ~40 | hand-built, ~30 human-ranked |
| Adversarial | ~150 | hand-built + generated |

**Human spot-check burden:** review **120 synthetic rows** (6% of 2,000) —
stratified 20 per type bucket. That is the smallest sample that detects a
systematic generator bias at a rate worth catching. Roughly 45–60 minutes.

## Loader contract

1. Rejects unknown fields (no silent drops).
2. Verifies every span resolves.
3. Verifies every edge label's `to` is in `candidate_ids`.
4. Reports which sets were present, with counts, at the top of every scorecard.
5. Is **format-compatible with the real 300 before they arrive** — nothing about
   the loader changes when real data lands.
