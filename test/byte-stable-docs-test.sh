#!/bin/bash
# byte-stable-docs-test.sh — a scan over unchanged repos must not change a byte.
#
# Every scan used to restamp `generated: { at: }` in every entity doc. A new
# hash per scan means qmd throws the embedding away each time, and nothing
# re-embeds. Two scans a second apart must leave the docs identical; a real
# change must still land, with a fresh stamp.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
scan="$root/scripts/repo-atlas.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

d="$tmp/dev/experiments/stable"
mkdir -p "$d"; git -C "$d" init -q .
git -C "$d" config user.email t@t; git -C "$d" config user.name t
printf 'summary line\n' > "$d/README.md"
git -C "$d" add -A; git -C "$d" commit -qm first

export ATLAS_SCAN_LOCK="$tmp/scan.lock.d" ATLAS_RUNS_DIR="$tmp/runs"
mkdir -p "$ATLAS_RUNS_DIR"
doc="$tmp/wiki/atlas/repos/stable.md"
sums() { find "$tmp/wiki/atlas" -name '*.md' ! -name log.md -exec shasum {} + | sort -k2; }

HOME="$tmp" "$scan" >/dev/null 2>&1
[[ -f $doc ]] && pass "first scan writes the doc" || fail "no doc at $doc"
before="$(sums)"; stamp1="$(grep '^generated: ' "$doc")"

sleep 1   # the stamp has one-second resolution
HOME="$tmp" "$scan" >/dev/null 2>&1
[[ "$(sums)" == "$before" ]] && pass "second scan over unchanged repos changes no byte" \
  || fail "docs changed without a cause: $(diff <(echo "$before") <(sums) | grep -c '^>') file(s)"

echo more > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm second
echo dirty > "$d/g"
sleep 1
HOME="$tmp" "$scan" >/dev/null 2>&1
grep -q '^dirty: yes' "$doc" && pass "a real change still lands" || fail "doc not updated after the repo changed"
[[ "$(grep '^generated: ' "$doc")" != "$stamp1" ]] && pass "and takes a fresh stamp" \
  || fail "stamp not refreshed on a real change"

compgen -G "$tmp/wiki/atlas/*/*.tmp.*" >/dev/null && fail "temp files left behind" || pass "no temp files left behind"

(( fails == 0 )) || exit 1
