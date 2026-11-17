#!/bin/bash
# write-if-changed.sh <file> — stdin replaces <file>, unless the two differ only
# in the `generated:` stamp, in which case <file> is left untouched.
#
# The scanners stamped a fresh `generated: { at: }` into every entity doc on
# every run, so every doc got a new hash and qmd dropped its embedding: on
# 2026-10-11, 174 of the 375 docs in the `atlas` collection had no vector and
# `qmd query` was answering from BM25 alone for them. Same inputs must give the
# same bytes. `at` therefore means "last time the content changed".
#
# Also makes the write atomic: `> "$f"` truncated in place, so a reader mid-scan
# could get half a doc.
set -euo pipefail
f="${1:?usage: write-if-changed.sh <file>}"
tmp="$f.tmp.$$"
cat > "$tmp"
if [[ -f "$f" ]] && diff -q <(grep -v '^generated: ' "$f") <(grep -v '^generated: ' "$tmp") >/dev/null; then
  rm -f "$tmp"
else
  mv "$tmp" "$f"
fi
