#!/usr/bin/env python3
"""Generate synthetic captures by COMPOSITION (docs/03-dataset-schema.md).

Why compositional, and what that buys
-------------------------------------
Every label here is true *by construction*: the capture is assembled from a
date phrase, a duration phrase, a verb and an object, so we know the answer
because we chose the parts -- not because anyone judged the finished sentence.

That matters. The three supplied `*-300` files were template-generated with
judged labels, and `docs/13-generated-datasets.md` records why that made them
worthless as ground truth: scoring against them measures whether we
reimplemented the generator.

What this set IS good for
-------------------------
  * date / effort / dependency parsing -- these are grammars, and generating
    "kal" then checking we read "kal" is legitimate coverage testing
  * volume and span coverage for the T0 rules
  * finding crashes and edge cases at scale

What it is NOT good for
-----------------------
  * category accuracy. The vocabulary below deliberately mixes terms the
    lexicon knows with terms it does not, so the honest output is a COVERAGE
    number -- which terms we miss -- not an accuracy number. Generating only
    from the lexicon would score ~100% and mean nothing.
  * whether our notion of "type" matches how a real person writes. Only
    Ganesh's 300 real captures test that.

Usage:  python3 scripts/make-synthetic.py [count]
"""
import hashlib
import json
import os
import random
import sys

OUT = "datasets/v1"
SEED = 20261123
TZ = "Asia/Kolkata"


def u16(s):
    """UTF-16 code-unit length. Spans are UTF-16 offsets (docs/01-domain.md),
    and an emoji is two units where Python's len() says one."""
    return len(s.encode("utf-16-le")) // 2


# --- Vocabulary ------------------------------------------------------------
# `known` terms are in the T0 category lexicon; `unknown` ones deliberately are
# not. The mix is what turns this into a coverage measurement instead of a
# self-congratulatory accuracy score.

VERBS = {
    "communication": {
        "known": ["call", "message", "email", "reply to", "whatsapp"],
        "unknown": ["chase", "nudge", "loop in", "circle back to", "buzz"],
    },
    "errands": {
        "known": ["buy", "order", "restock"],
        "unknown": ["grab", "fetch", "swing by for", "stock up on"],
    },
    "money": {
        "known": ["pay", "settle", "reconcile"],
        "unknown": ["clear", "square up", "sort out the bill for"],
    },
    "paperwork": {
        "known": ["submit", "renew", "register"],
        "unknown": ["chase up", "re-file", "countersign"],
    },
    "chores": {
        "known": ["clean", "wash", "fold", "cook"],
        "unknown": ["scrub", "declutter", "sort through", "air out"],
    },
    "deepWork": {
        "known": ["write", "design", "draft"],
        "unknown": ["flesh out", "rework", "think through", "spike"],
    },
    "learning": {
        "known": ["read", "revise", "study"],
        "unknown": ["skim", "work through", "get my head around"],
    },
    "planning": {
        "known": ["book", "schedule", "plan"],
        "unknown": ["pencil in", "lock down", "line up"],
    },
    "health": {
        "known": ["walk", "stretch"],
        "unknown": ["squeeze in a session of", "book time for"],
    },
}

OBJECTS = {
    "communication": ["the plumber", "Priya", "the landlord", "Rahul", "the client"],
    "errands": ["sabzi", "atta and dal", "printer ink", "a gift for Diwali", "milk"],
    "money": ["the electricity bill", "the EMI", "the maintenance", "the GST"],
    "paperwork": ["the school form", "the Aadhaar update", "the lease", "the ITR"],
    "chores": ["the kitchen", "the bedsheets", "the balcony", "the water filter"],
    "deepWork": ["the launch post", "the pricing page", "the onboarding flow"],
    "learning": ["chapter 4", "the Rust book", "the auth docs"],
    "planning": ["the Diwali flights", "a dentist slot", "the team offsite"],
    "health": ["in the park", "before bed", "after lunch"],
}

# Date phrases paired with the day offset they MUST resolve to, relative to the
# fixed "now" of Monday 23 Nov 2026. Every entry carries a real offset: an
# entry labelled None would be a FALSE label -- the text contains a date, so
# the parser would be marked wrong precisely for getting it right.
DATES = [
    ("aaj", 0), ("kal", 1), ("parso", 2), ("today", 0), ("tomorrow", 1),
    ("in 3 days", 3), ("3 din mein", 3), ("next monday", 7), ("somvaar", 7),
    ("agle hafte", 7), ("15 tarikh", 22), ("end of month", 7),
    ("shukravaar", 4), ("this week", 6), ("weekend", 5),
]

# Clock times. These are what make a capture a REMINDER rather than a task.
#
# Without this, `task` and `reminder` were not distinguishable from the text:
# tasks could carry dates too, so "clean the kitchen kal" was labelled task and
# "clean the kitchen kal" was labelled reminder, at random. 51 of 212 tasks were
# "misclassified" against a label no reader could have produced either. A label
# that is not identifiable from the input is a generator bug, not a model
# failure -- so a reminder is now time-anchored and a task is not.
TIMES = ["subah 9 baje", "shaam 5 baje", "raat 10 baje", "9am", "6:30pm", "dopahar 2 baje"]

# Duration phrases paired with the bucket they MUST produce.
DURATIONS = [
    ("5 min", "tiny"), ("20 minutes", "small"), ("45 mins", "medium"),
    ("2 ghante", "large"), ("1 ghanta", "medium"), ("aadha ghanta", "small"),
    ("3 hours", "large"), ("poora din", "xlarge"), ("half an hour", "small"),
    ("2 days", "xlarge"),
]

DEPENDENCIES = [
    ("after {}", "after"), ("once {} is done", "after"),
    ("waiting for {}", "after"), ("{} ke baad", "before"),
    ("{} ka intezaar", "before"),
]

BLOCKERS = ["client approval", "the design review", "Priya's reply", "the migration"]

IDEA_MARKERS = ["idea:", "what if", "kya agar", "thought:"]
NOTE_FRAGMENTS = [
    "pricing for the template pack", "that onboarding thing",
    "the bit about refunds", "notes from the call", "ghar ka hisaab"
]
URLS = [
    "https://arxiv.org/abs/2604.11111",
    "https://example.com/blog/a-post?ref=x",
    "https://news.ycombinator.com/item?id=4242424",
]

# Mess applied on top, because real captures are not tidy.
FILLERS = ["btw", "umm", "also", "aur haan", "ek aur cheez"]
EMOJI = ["\U0001F389", "\U0001F525", "✅", "\U0001F62D"]


def typo(text, rng):
    """Swap two adjacent letters. Real captures have typos; tidy ones do not."""
    positions = [i for i in range(len(text) - 1) if text[i].isalpha() and text[i + 1].isalpha()]
    if not positions:
        return text
    i = rng.choice(positions)
    return text[:i] + text[i + 1] + text[i] + text[i + 2:]


def build(rng, index):
    """Compose one capture. Returns (text, labels) with spans computed as we go."""
    parts = []        # (text, role) in final order
    labels = {"type": None, "effort": None, "due_at": None,
              "category": None, "dependency": None}

    kind = rng.choices(
        ["task", "reminder", "idea", "note", "link"],
        weights=[50, 20, 12, 12, 6])[0]

    if kind == "link":
        if rng.random() < 0.5:
            parts.append((rng.choice(URLS), "url"))
        else:
            parts.append((rng.choice(["read this", "dekhna hai", "save for later"]), "lead"))
            parts.append((rng.choice(URLS), "url"))
        labels["type"] = "link"

    elif kind == "idea":
        parts.append((rng.choice(IDEA_MARKERS), "marker"))
        parts.append((rng.choice([
            "we could batch the reminders", "pricing could be usage based",
            "app khud hi sort kar le", "voice capture pehle rakhein"]), "body"))
        labels["type"] = "idea"

    elif kind == "note":
        parts.append((rng.choice(NOTE_FRAGMENTS), "body"))
        labels["type"] = "note"

    else:  # task or reminder
        category = rng.choice(list(VERBS))
        pool = VERBS[category]
        # 60/40 known vs unknown: the unknown half is what measures lexicon gaps.
        verb = rng.choice(pool["known"] if rng.random() < 0.6 else pool["unknown"])
        obj = rng.choice(OBJECTS[category])
        labels["category"] = category

        # Verb-final Hinglish only reads naturally with a single-word verb:
        # "the landlord ko circle back to karna hai" is not a sentence anyone
        # would write.
        if rng.random() < 0.35 and " " not in verb:
            bare = obj[4:] if obj.startswith("the ") else obj
            parts.append((f"{bare} ko {verb} karna hai", "body"))
        else:
            parts.append((f"{verb} {obj}", "body"))
        labels["type"] = "reminder" if kind == "reminder" else "task"

    # A reminder is time-anchored: a date AND a clock time. A task may carry a
    # deadline but never a time, so the two are distinguishable from the text.
    if kind == "reminder":
        phrase, offset = rng.choice(DATES)
        parts.append((f"{phrase} {rng.choice(TIMES)}", "date"))
        labels["due_at"] = offset
    elif kind in ("task",) and rng.random() < 0.35:
        phrase, offset = rng.choice(DATES)
        parts.insert(0 if rng.random() < 0.4 else len(parts), (phrase, "date"))
        labels["due_at"] = offset

    # Optional duration.
    if rng.random() < 0.3:
        phrase, bucket = rng.choice(DURATIONS)
        parts.append((phrase, "effort"))
        labels["effort"] = bucket

    # Optional stated dependency.
    if kind in ("task", "reminder") and rng.random() < 0.18:
        template, position = rng.choice(DEPENDENCIES)
        blocker = rng.choice(BLOCKERS)
        phrase = template.format(blocker)
        parts.insert(0 if position == "before" else len(parts), (phrase, "dependency"))
        labels["dependency"] = blocker

    # Mess, applied last so it cannot shift the spans we care about mid-build.
    if rng.random() < 0.12:
        parts.insert(0, (rng.choice(FILLERS), "filler"))
    if rng.random() < 0.10:
        parts.append((rng.choice(EMOJI), "emoji"))

    # Join and record UTF-16 spans for the parts that carry a label.
    text, spans, cursor = "", {}, 0
    for i, (chunk, role) in enumerate(parts):
        if i:
            text += " "
            cursor += 1
        start = cursor
        text += chunk
        cursor += u16(chunk)
        if role in ("date", "effort", "dependency"):
            spans[role] = [start, cursor]

    if rng.random() < 0.15:
        text = typo(text, rng)
        spans = {}          # a typo invalidates offsets; drop them honestly
    if rng.random() < 0.25:
        text = text.lower()

    return text, labels, spans


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    rng = random.Random(SEED)
    rows, seen = [], set()

    while len(rows) < count:
        text, labels, spans = build(rng, len(rows))
        if not text.strip() or text in seen:
            continue
        seen.add(text)
        rid = hashlib.sha256(text.encode("utf-8")).hexdigest()[:26].upper()
        rows.append({
            "id": rid,
            "raw_text": text,
            "source": "text",
            "user_tz": TZ,
            "labels": labels,
            "spans": spans,
            "label_source": "synthetic",
        })

    # Hash split, 70/20/10 — a pure function of the id, so adding rows never
    # reshuffles existing ones (docs/03-dataset-schema.md).
    buckets = {"train": [], "dev": [], "test": []}
    for r in rows:
        h = int(hashlib.sha256(r["id"].encode()).hexdigest(), 16) % 10
        buckets["train" if h <= 6 else "dev" if h <= 8 else "test"].append(r)

    for split, items in buckets.items():
        directory = os.path.join(OUT, split)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "synthetic.jsonl")
        with open(path, "w", encoding="utf-8") as f:
            for r in items:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"{path}: {len(items)} rows")

    hinglish = sum(
        1 for r in rows
        if any(w in r["raw_text"].lower() for w in
               ["kal", "aaj", "parso", "ghanta", "ghante", "karna", "hai", "sabzi",
                "atta", "baad", "intezaar", "hafte", "somvaar", "shukravaar",
                "tarikh", "aadha", "poora", "dekhna", "khud", "pehle", "hisaab",
                "ghar", "aur", "haan", "cheez", "ko", "din"]))
    print(f"\ntotal {len(rows)} · Hinglish-containing {hinglish} "
          f"({100 * hinglish / len(rows):.0f}%)")


if __name__ == "__main__":
    main()
