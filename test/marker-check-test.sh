#!/bin/bash
# marker-check-test.sh — the gate must see a torn marker block, not just a present one.
#
# Presence of <!-- atlas:start --> was all atlas-check.sh ever asserted, so four
# repos went torn and three were committed that way (atlas:start 1/3 or 1/6,
# OPENWIKI 1/2). Cause and measurements: atlas-marker-check.sh.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
checker="$root/scripts/atlas-marker-check.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# an onboarded repo: hooksPath must point at this checkout or the gate skips it
mkrepo() {
  local d="$tmp/dev/$1"; mkdir -p "$d"
  git -C "$d" init -q .
  git -C "$d" config core.hooksPath "$root/hooks"
  printf '%s' "$2" > "$d/CLAUDE.md"
}

blk=$'<!-- atlas:start -->\n## Atlas\n<!-- atlas:end -->\n'
mkrepo clean  "# clean"$'\n\n'"$blk"
mkrepo torn   "# torn"$'\n\n'"$blk"$'orphaned half-sentence\n<!-- atlas:end -->\n'
mkrepo owtorn "# owtorn"$'\n\n<!-- OPENWIKI:START -->\nx\n<!-- OPENWIKI:END -->\ntail\n<!-- OPENWIKI:END -->\n'
mkrepo ignored "# ignored"$'\n\n'"$blk"$'tail\n<!-- atlas:end -->\n'
touch "$tmp/dev/ignored/.atlas-ignore"

out="$(HOME="$tmp" "$checker" "$root")"; rc=$?

(( rc == 1 )) && pass "exits 1 when something is torn" \
  || fail "exit code was $rc, expected 1"
[[ $out == *"torn:atlas=1/2"* ]] && pass "names repo, block and counts" \
  || fail "missing torn:atlas=1/2 in: $out"
[[ $out == *"owtorn:OPENWIKI=1/2"* ]] && pass "checks OPENWIKI, not only atlas" \
  || fail "missing owtorn:OPENWIKI=1/2 in: $out"
[[ $out != *"clean:"* ]] && pass "a clean pair is not reported" \
  || fail "false positive on a clean pair: $out"
[[ $out != *"ignored:"* ]] && pass ".atlas-ignore is honoured" \
  || fail "reported a repo carrying .atlas-ignore: $out"

rm -f "$tmp/dev/torn/CLAUDE.md" "$tmp/dev/owtorn/CLAUDE.md"
if HOME="$tmp" "$checker" "$root" >/dev/null; then
  pass "exits 0 and prints nothing when every block is clean"
else
  fail "false alarm on an all-clean tree"
fi

((fails)) && exit 1 || exit 0
