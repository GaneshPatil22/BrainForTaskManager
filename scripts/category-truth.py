#!/usr/bin/env python3
"""Extract task-title -> category ground truth from the generated datasets.

The generators leaked the category into rationale strings ("Variety: X",
"X batch"). That makes datasets/generated/ a free labelled set for validating
the T0 category lexicon -- see docs/13-generated-datasets.md.

Usage:  python3 scripts/category-truth.py > /tmp/category-truth.json
"""
import collections, glob, json, re, sys

PATTERNS = [re.compile(r"Variety:\s*([a-z][a-z \-]+?)(?:,|$)"),
            re.compile(r"^([A-Za-z][a-z \-]+?)\s+batch(?:,|$)")]

MERGE = {
    "household": "chores", "hands-on chores and upkeep": "chores",
    "paperwork and admin": "paperwork", "calls and messages": "communication",
    "errands and shopping": "errands", "creative or deep work": "deepWork",
    "planning and booking": "planning", "money and payments": "money",
    "study or learning": "learning", "health and self-care": "health",
}

votes = collections.defaultdict(collections.Counter)
for path in sorted(glob.glob("datasets/generated/*.brain")):
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^      \d+\.\s*(.+?)\s*\|\s*(.+?)\s*$", line)
        if not m:
            continue
        title, rationale = m.group(1), m.group(2)
        for pattern in PATTERNS:
            hit = pattern.search(rationale)
            if hit:
                votes[title][hit.group(1).strip().lower()] += 1
                break

truth = {}
for title, counter in votes.items():
    label = counter.most_common(1)[0][0]
    if label in MERGE:
        truth[title] = MERGE[label]

json.dump(truth, sys.stdout, indent=0, ensure_ascii=False)
print(f"\n# {len(truth)} labelled titles", file=sys.stderr)
