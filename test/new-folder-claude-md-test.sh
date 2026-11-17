#!/bin/bash
# new-folder-claude-md-test.sh — a mkdir inside a repo that already has a root
# CLAUDE.md must write nothing.
#
# The script only looked at the new folder itself, so every mkdir inside a repo
# left a template CLAUDE.md + AGENTS.md symlink: 18 of them across ~/dev on
# 2026-10-11, four committed in one repo.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
script="$root/scripts/new-folder-claude-md.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

mkdir -p "$tmp/documented/src/assets" "$tmp/bare/src" "$tmp/loose"
git -C "$tmp/documented" init -q .
git -C "$tmp/bare" init -q .
echo "# documented" > "$tmp/documented/CLAUDE.md"

HOME="$tmp" "$script" "$tmp/documented/src/assets" >/dev/null 2>&1
[[ -z "$(ls -A "$tmp/documented/src/assets")" ]] && pass "nothing written under a repo with a root CLAUDE.md" \
  || fail "wrote into a documented repo: $(ls -A "$tmp/documented/src/assets")"

HOME="$tmp" "$script" "$tmp/bare/src" >/dev/null 2>&1
[[ -f "$tmp/bare/src/CLAUDE.md" ]] && pass "repo without a root CLAUDE.md still gets the template" \
  || fail "no CLAUDE.md under a repo that has none at its root"

HOME="$tmp" "$script" "$tmp/loose" >/dev/null 2>&1
[[ -f "$tmp/loose/CLAUDE.md" && -L "$tmp/loose/AGENTS.md" ]] && pass "folder outside any repo still gets template + symlink" \
  || fail "no CLAUDE.md/AGENTS.md for a folder outside any repo"

# .git/info and a tool dot-folder in a repo without a root CLAUDE.md.
mkdir -p "$tmp/bare/.git/info" "$tmp/bare/.pi"
for d in "$tmp/bare/.git/info" "$tmp/bare/.pi"; do
  HOME="$tmp" "$script" "$d" >/dev/null 2>&1
  [[ ! -e "$d/CLAUDE.md" ]] && pass "nothing written in ${d#"$tmp"/}" \
    || fail "wrote CLAUDE.md into ${d#"$tmp"/}"
done

((fails == 0)) && echo "ALL OK" || { echo "$fails FAILED"; exit 1; }
