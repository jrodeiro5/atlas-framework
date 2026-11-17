#!/bin/bash
# repo-scan-lock-test.sh — two repo scans must not run at once.
#
# repo-atlas.sh is a full regenerate that ends in `qmd update`. Two of them
# collide on the same SQLite index; the loser returns non-zero and, since that
# is the last command under `set -e`, the script exits 1 with every entity doc
# already written. The ledger then reads `failed`. Reproduced 2026-08-16 by
# starting two scans at once (A=0, B=1, B's output stopping at "44 repos
# mapped"); repo-scan sat at 44/57 succeeded and was the dominant FAIL in
# atlas-check's runs section.
#
# ATLAS_SCAN_LOCK and ATLAS_RUNS_DIR are redirected so this never touches the
# lock a real scan may hold, nor writes test rows into the real ledger.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
scan="$root/scripts/repo-atlas.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

lock="$tmp/scan.lock.d"
export ATLAS_SCAN_LOCK="$lock"
export ATLAS_RUNS_DIR="$tmp/runs"
mkdir -p "$ATLAS_RUNS_DIR"

# --- 1. a live holder makes the second scan skip, not fail -------------------
# $$ is this test, which is by definition alive.
mkdir -p "$lock"; echo $$ > "$lock/pid"
out="$("$scan" 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"scan already running"* ]]; then
  pass "live holder: second scan skips with exit 0"
else
  fail "live holder: rc=$rc out=${out:0:160}"
fi

# --- 2. the skipped scan is recorded skipped, not failed or left running ------
# The whole point: a skip must not read as a failure in the ledger, and must not
# be left `running` for reconcile to later call abandoned.
statuses="$(grep -ho '"status": *"[a-z]*"' "$ATLAS_RUNS_DIR"/*.json 2>/dev/null | sed 's/.*"\([a-z]*\)"$/\1/' | sort -u | tr '\n' ' ')"
if [[ "$statuses" == "skipped " ]]; then
  pass "skipped scan recorded status=skipped"
else
  fail "ledger statuses after a skip: '${statuses:-none}'"
fi

# --- 3. skipping does not free the holder's lock -----------------------------
# The dangerous inversion: a skipping process cleaning up on EXIT and releasing
# a lock the *running* scan still owns, which un-serializes everything.
if [[ -d "$lock" && "$(cat "$lock/pid")" == "$$" ]]; then
  pass "skip path leaves the live holder's lock intact"
else
  fail "skip path destroyed a lock it did not own"
fi

# --- 4. a stale lock is taken over, not obeyed forever -----------------------
# A scan killed with -9 never runs its trap. Without the liveness check its lock
# would wedge every future scan silently. A full scan is slow (one gh call per
# remote repo), so this asserts the takeover and then stops the scan rather than
# waiting it out.
rm -rf "$lock"; mkdir -p "$lock"
echo 99999999 > "$lock/pid"   # above PID_MAX, cannot be live
"$scan" >/dev/null 2>&1 &
scan_pid=$!
for _ in $(seq 1 100); do
  [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$scan_pid" ]] && break
  sleep 0.1
done
if [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$scan_pid" ]]; then
  pass "stale lock: taken over by the new scan"
else
  fail "stale lock: not taken over (lock pid=$(cat "$lock/pid" 2>/dev/null || echo none), scan=$scan_pid)"
fi
kill -TERM "$scan_pid" 2>/dev/null   # TERM, so its trap frees the lock it owns
wait "$scan_pid" 2>/dev/null

# --- 5. the reindex no longer decides the scan's exit code -------------------
# `command -v qmd >/dev/null && qmd update ... && echo` was the final line, so
# its status became the script's: a busy index — or no qmd installed at all —
# and a scan that wrote every doc correctly still recorded `failed`. Asserted
# statically; running a whole scan with a broken PATH would prove nothing.
if tail -1 "$scan" | grep -q '^command -v qmd .*&& qmd update'; then
  fail "reindex is still the last command — its exit status is the scan's"
else
  pass "reindex status no longer becomes the scan's exit code"
fi

((fails)) && { printf '\n%d FAIL\n' "$fails"; exit 1; }
printf '\nall checks passed\n'
