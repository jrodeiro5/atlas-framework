#!/bin/bash
# almanac-fold.sh <repo> — F4 transform (gate: GO 2026-07-24).
# Prints the "top decisions / pitfalls" markdown section that repo-atlas.sh folds
# into the entity doc. Frontmatter extraction only — no LLM, no raw almanac dump.
# Silent (exit 0, no output) when the repo has no almanac content to fold.
# ponytail: recency = ranking. No relevance signal exists in almanac frontmatter,
# and mtime tracks the garden cycle that mined it; revisit if a rank field lands.
set -euo pipefail
repo="${1:?usage: almanac-fold.sh <repo>}"
al="$repo/almanac"
[[ -d $al ]] || exit 0

MAX=5      # read-budget guard: entity doc stays skimmable
LEAD=200   # chars of summary/lead per entry

# first frontmatter block only; unquotes the scalar
fm() { sed -n '/^---$/,/^---$/p' "$2" | sed -n "s/^$1: *//p" | head -1 \
       | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"; }

# first real prose line after the frontmatter — fallback when summary: is absent
# (CodeAlmanac emits summary: on decisions but not reliably on incidents)
lead() {
  awk 'NR==1 && /^---$/ {fm=1; next}
       fm && /^---$/ {fm=0; next}
       fm {next}
       /^[#!\[<>|-]/ {next}
       NF {print; exit}' "$1"
}

section() { # <heading> <almanac subdir>
  local dir="$al/$2" out=() f t s
  [[ -d $dir ]] || return 0
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    t="$(fm title "$f")"; [[ -z $t ]] && t="$(basename "$f" .md)"
    s="$(fm summary "$f")"; [[ -z $s ]] && s="$(lead "$f")"
    # the summary is prose from the almanac: its own relative links resolve
    # inside that repo, never inside the bundle
    s="$(head -c "$LEAD" <<<"$s" | sed -E 's@\[([^]]*)\]\(([.a-zA-Z0-9_][^):]*)\)@\1@g')"
    out+=("- [$t](${f/#"$HOME"/~})${s:+ — $s}")
  done < <(ls -t "$dir"/*.md 2>/dev/null | head -"$MAX")
  ((${#out[@]})) || return 0
  printf '## %s\n\n' "$1"
  printf '%s\n' "${out[@]}"
  echo
}

section "Decisions" decisions
section "Pitfalls & incidents" incidents
