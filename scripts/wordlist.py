#!/usr/bin/env python3
# Copyright 2026, Andrew C. Young <andrew@vaelen.org>
# SPDX-License-Identifier: MIT
"""Build the Daily Word lists from cinquel's words.c (docs/daily-word.md).

usage: scripts/wordlist.py [words.c] [outdir]

words.c is the Stanford GraphBase five-letter list, most common first.
Answers are the 2,000 most common words that don't look like plurals
or -s verbs, shuffled once with a fixed seed so the order is stable.
Both files are fixed 6-byte lines (5 lowercase letters + CR) so the
game can read line n at byte 6*n.
"""
import os
import random
import re
import sys

ANSWERS = 2000
SEED = 19040101
# Still valid guesses, never the day's word.
NOT_ANSWERS = {"bitch", "horny", "kinky", "lynch", "pussy", "queer", "sperm"}

src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/repos/cinquel/words.c")
out = sys.argv[2] if len(sys.argv) > 2 else "Words"

words = re.findall(r'"([a-z]{5})"', open(src).read())
assert len(words) == len(set(words)), "duplicate words in source"


def plural(w):
    return w.endswith("s") and not w.endswith(("ss", "us", "is"))


answers = [w for w in words if not plural(w) and w not in NOT_ANSWERS][:ANSWERS]
assert len(answers) == ANSWERS, len(answers)
random.Random(SEED).shuffle(answers)
allowed = sorted(set(words) | set(answers))

os.makedirs(out, exist_ok=True)
for name, lst in (("Words.txt", allowed), ("Answers.txt", answers)):
    with open(os.path.join(out, name), "wb") as f:
        f.write("".join(w + "\r" for w in lst).encode("ascii"))
    print(f"{name}: {len(lst)} words, {len(lst) * 6} bytes")
