#!/bin/bash
# session-context-test.sh — the SessionStart hook prints the repo's entity doc and
# stays silent (exit 0) everywhere else: a hook that fails or chatters outside a
# scanned repo pollutes every session on the machine.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
hook="$root/scripts/atlas-session-context.sh"

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

export ATLAS_WIKI="$tmp/wiki"
mkdir -p "$ATLAS_WIKI/repos" "$tmp/known/sub" "$tmp/unknown" "$tmp/plain"
printf 'title: known\nMARKER\n' > "$ATLAS_WIKI/repos/known.md"
git init -q "$tmp/known"; git init -q "$tmp/unknown"
git -C "$tmp/known" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$tmp/known" worktree add -q "$tmp/wt-other-name" 2>/dev/null

# --- 1-3. the doc arrives from the root, a subdirectory and a linked worktree ---
for d in known known/sub wt-other-name; do
  if (cd "$tmp/$d" && "$hook") | grep -q MARKER; then pass "doc printed from $d"
  else fail "no doc from $d"; fi
done

# --- 4-5. no doc for the repo, or no repo at all → silent, exit 0 --------------
for d in unknown plain; do
  out="$(cd "$tmp/$d" && "$hook" 2>&1)"; rc=$?
  if [[ $rc -eq 0 && -z $out ]]; then pass "silent in $d"
  else fail "$d: rc=$rc out=$out"; fi
done

[[ $fails -eq 0 ]] && echo "session-context: all passed" || { echo "session-context: $fails failed"; exit 1; }
