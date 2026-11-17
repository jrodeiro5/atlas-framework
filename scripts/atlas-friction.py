#!/usr/bin/env python3
"""atlas-friction.py — the errors this machine keeps hitting that no page mentions.

The almanac mines the repo (what was decided); deja indexes the sessions (what
actually happened). They only overlap where a recurring failure already made it
into a page — and the gap between them is the interesting part: `command not
found: timeout` has cost 55 sessions and is written down nowhere.

This does not write pages. It reports the gap and leaves the writing to a human,
because a generated pitfall is exactly the kind of invented prose the design
refused for `description:` on services.

Read-only. Stdlib plus `deja friction`. No LLM.

usage: atlas friction [--limit N] [--undocumented]
       --undocumented  only the GAP and WEAK rows
"""
import json
import os
import re
import subprocess
import sys

# words that carry no signal: they appear in every error and in every page
STOP = {
    "command", "found", "error", "errors", "file", "files", "directory", "such",
    "module", "named", "fatal", "cannot", "failed", "exist", "line", "none",
    "usage", "invalid", "unable", "missing", "expected", "argument", "caused",
    "would", "this", "that", "with", "from", "have", "your", "code", "path",
}
WORD = re.compile(r"[a-z][a-z0-9_.-]{3,}")


def corpus():
    """What an agent actually reads cold: the wiki bundle and the repo contracts.

    Kept per file, not as one blob: naming the pages is the whole report. A word
    that appears 11 times says nothing on its own — seeing that all 11 are in
    unrelated pages is what tells you the failure is undocumented.
    """
    home = os.path.expanduser("~")
    docs = []
    for root, dirs, names in os.walk(os.path.join(home, "wiki")):
        for n in names:
            if n.endswith(".md"):
                path = os.path.join(root, n)
                docs.append((path, read(path).lower()))
    for base in (home, os.path.join(home, ".claude"), os.path.join(home, "dev")):
        for root, dirs, names in os.walk(base):
            if root.count(os.sep) - base.count(os.sep) > 2:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if not d.startswith(".") or d == ".claude"]
            for n in names:
                if n in ("CLAUDE.md", "AGENTS.md"):
                    path = os.path.join(root, n)
                    docs.append((path, read(path).lower()))
    return docs


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def main(argv):
    limit = "20"
    if "--limit" in argv:
        limit = argv[argv.index("--limit") + 1]
    only_gaps = "--undocumented" in argv

    try:
        out = subprocess.run(["deja", "friction", "--limit", limit, "--json"],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"atlas friction: deja unavailable ({exc})", file=sys.stderr)
        return 2
    try:
        rows = json.loads(out.stdout)["rows"]
    except (ValueError, KeyError):
        print("atlas friction: deja friction --json returned nothing usable", file=sys.stderr)
        return 2

    docs = corpus()
    home = os.path.expanduser("~")
    gaps = 0
    for row in rows:
        err = row.get("error", "")
        words = {w for w in WORD.findall(err.lower()) if w not in STOP}
        if not words:
            continue
        # Coverage, not a verdict: how many of the error's distinctive words
        # appear in any page at all, and which page carries the most of them.
        # A single absent word proves nothing (`unrecognized` is rare prose);
        # zero words present is the case where nothing here describes the
        # failure. The page is named so a human decides in one glance.
        covered = [w for w in words if any(w in t for _, t in docs)]
        best, hits = max(
            ((p, sum(w in t for w in words)) for p, t in docs),
            key=lambda pair: pair[1],
        ) if docs else ("", 0)
        # GAP: no word of the error appears anywhere. WEAK: no single page
        # carries half of them, so whatever coverage exists is scattered across
        # unrelated pages. Neither is a verdict — word overlap cannot tell a
        # page that explains the failure from one that happens to use the word
        # (`timeout` is in four pages, none of which says macOS has no
        # timeout(1)). The row is ranked and the page named; the judgement is
        # the reader's.
        weak = not covered or hits * 2 < len(words)
        if only_gaps and not weak:
            continue
        gaps += weak
        mark = "GAP " if not covered else ("WEAK" if weak else "    ")
        print(f"{mark}{row.get('sessions', 0):>4} sessions  {err[:70]}")
        if not covered:
            print(f"          none of {len(words)} distinctive word(s) appear in any page")
            continue
        print(f"          {len(covered)}/{len(words)} word(s) appear somewhere, best page "
              f"({hits}/{len(words)}): {best.replace(home, '~')}")
    print(f"friction rows={len(rows)} gap-or-weak={gaps}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
