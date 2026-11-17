#!/bin/bash
# stale-after-test.sh — the review window must come from the repo, not a constant.
#
# A repo that lands ten commits in a week and one that has not been touched in a
# year were both held to a flat 30 days. `stale_after` (OKF v0.2) is derived from
# the span of the last ten commits, so the two must not come out the same — and a
# burst of commits in one hour must not expire the doc tomorrow.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
scan="$root/scripts/repo-atlas.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# a repo whose last 10 commits span $2 days, the newest landing today
mkrepo() {
  local d="$tmp/dev/experiments/$1" span="$2" i when
  mkdir -p "$d"; git -C "$d" init -q .
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'summary line\n' > "$d/README.md"
  for i in $(seq 9 -1 0); do
    when="$(date -j -v-$(( span * i / 9 ))d +%Y-%m-%dT12:00:00)"
    echo "$i" > "$d/f"
    git -C "$d" add -A
    GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$d" commit -qm "c$i"
  done
}

mkrepo fast 7        # ten commits inside a week
mkrepo slow 300      # ten commits spread over ten months
mkrepo burst 0       # ten commits the same day

export ATLAS_SCAN_LOCK="$tmp/scan.lock.d" ATLAS_RUNS_DIR="$tmp/runs"
mkdir -p "$ATLAS_RUNS_DIR"
# no commits yet: `git log` exits 128 there, which must not take the scan down
mkdir -p "$tmp/dev/experiments/empty"; git -C "$tmp/dev/experiments/empty" init -q .
HOME="$tmp" "$scan" >/dev/null 2>&1
scan_rc=$?

field() { sed -n "s/^$1: *//p" "$tmp/wiki/atlas/repos/$2.md" | head -1; }
days() { # days from manual-reviewed to stale_after
  local r d; r="$(field manual-reviewed "$1")"; d="$(field stale_after "$1")"
  [[ -n $r && -n $d ]] || { echo ""; return; }
  echo $(( ($(date -j -f '%Y-%m-%d' "$d" +%s) - $(date -j -f '%Y-%m-%d' "$r" +%s)) / 86400 ))
}

f="$(days fast)"; s="$(days slow)"; b="$(days burst)"

(( scan_rc == 0 )) && pass "a repo with no commits does not kill the scan" || fail "scan exited $scan_rc with an empty repo present"
[[ -n $f && -n $s ]] && pass "stale_after is emitted" || fail "stale_after missing (fast=$f slow=$s)"
(( f < s )) && pass "a fast repo goes stale sooner than a slow one ($f < $s)" \
  || fail "cadence not discriminating: fast=$f slow=$s"
(( b >= 7 )) && pass "a same-day burst is clamped to 7 days, not 0 ($b)" \
  || fail "burst not clamped: $b"
(( s <= 365 )) && pass "the window is capped at a year ($s)" || fail "uncapped: $s"

(( fails == 0 )) || exit 1
