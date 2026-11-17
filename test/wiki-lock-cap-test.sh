#!/bin/bash
# wiki-lock-cap-test.sh — the machine-wide wiki lock must bound what it hands
# the lock to, and must bound it from the moment the lock is acquired.
#
# 2026-09-06: atlas generated for 6628s after acquiring and then died on a fetch
# timeout; two runs on 2026-09-04/05 burned 7.9h and 7.4h and wrote nothing. All
# three held this lock the whole time, so every other repo behind them lost too.
# The budget must not be spent by the queue: a run that waits three hours for the
# lock has used none of its own time yet.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
lockcmd="$root/scripts/with-wiki-lock.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

export ATLAS_WIKI_LOCK="$tmp/wiki-gen.lock"

# --- 1. a command that overruns the cap is terminated ------------------------
start=$SECONDS
ATLAS_WIKI_LOCK_CAP_SECONDS=2 "$lockcmd" sleep 60 >"$tmp/cap.err" 2>&1
rc=$?
elapsed=$((SECONDS - start))
(( rc != 0 )) && pass "an overrunning command exits non-zero ($rc)" \
  || fail "the cap did not stop a 60s sleep under a 2s cap"
(( elapsed < 30 )) && pass "terminated near the cap, not at the command's own end (${elapsed}s)" \
  || fail "took ${elapsed}s under a 2s cap"

# --- 2. a command that finishes inside the cap is untouched ------------------
ATLAS_WIKI_LOCK_CAP_SECONDS=30 "$lockcmd" true
(( $? == 0 )) && pass "a command inside the cap keeps its own exit status" \
  || fail "a fast command was disturbed by the watchdog"

# --- 3. cap 0 disables the watchdog -----------------------------------------
start=$SECONDS
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" sleep 3
rc=$?
(( rc == 0 && SECONDS - start >= 3 )) && pass "cap 0 leaves the command alone" \
  || fail "cap 0 did not disable the watchdog (rc=$rc)"

# --- 4. the budget starts at acquisition, not at invocation ------------------
# A holder sits on the lock for 4s. The waiter has a 6s cap: counted from
# invocation it would die in the queue having done nothing, which is the bug
# this ceiling must not introduce. Counted from acquisition it gets its 6s.
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" sleep 4 &
holder=$!
sleep 1   # let the holder take the lock first
start=$SECONDS
ATLAS_WIKI_LOCK_CAP_SECONDS=6 "$lockcmd" sleep 3 >"$tmp/queued.err" 2>&1
rc=$?
elapsed=$((SECONDS - start))
wait "$holder" 2>/dev/null
(( rc == 0 )) && pass "a queued command is not killed for time it spent waiting" \
  || fail "the queued command died (rc=$rc), the cap counted the wait"
(( elapsed >= 4 )) && pass "it really did queue behind the holder (${elapsed}s)" \
  || fail "no contention: the test proved nothing (${elapsed}s)"

# --- 5. the watchdog must not hold the lock it was armed under ---------------
# It is a child, so it inherits the lock fd. Before `exec 9>&-` the next waiter
# acquired 30s after the killed command had already died -- the watchdog was
# sitting on the machine-wide lock through its whole TERM-to-KILL grace.
ATLAS_WIKI_LOCK_CAP_SECONDS=2 "$lockcmd" sleep 60 >/dev/null 2>&1
start=$SECONDS
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" true >"$tmp/after-kill.err" 2>&1
elapsed=$((SECONDS - start))
(( elapsed <= 2 )) && pass "the lock is free as soon as the capped command dies (${elapsed}s)" \
  || fail "the watchdog kept the lock for ${elapsed}s after the kill"

# --- 6. the watchdog must not hold the log pipe open after the command ends ---
# It inherits stderr, and the cascade's stderr is a pipe into the timestamped
# openwiki log. A reader on that pipe sees no EOF until the watchdog exits, so
# the whole stage looks hung for one poll step after the work is already done.
start=$SECONDS
ATLAS_WIKI_LOCK_CAP_SECONDS=300 "$lockcmd" true 2>&1 | cat >/dev/null
elapsed=$((SECONDS - start))
(( elapsed <= 2 )) && pass "the stderr pipe closes with the command (${elapsed}s)" \
  || fail "a reader on the stage's log pipe waited ${elapsed}s past the command"

# --- 7. the wait is always reported, so the cascade can split its stage clock --
# atlas-cascade.sh subtracts this number from its stage total. Emitting it only
# when the lock happened to be busy left every uncontended run with nothing to
# subtract, and the whole point is telling a queued run from a slow one.
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" true >"$tmp/free.err" 2>&1
grep -q 'acquired after 0s' "$tmp/free.err" \
  && pass "an uncontended run reports 'acquired after 0s'" \
  || fail "no wait line when the lock was free: $(tr '\n' ' ' <"$tmp/free.err")"

ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" sleep 3 >/dev/null 2>&1 &
holder=$!
sleep 1
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" true >"$tmp/waited.err" 2>&1
wait "$holder" 2>/dev/null
grep -qE 'acquired after [1-9][0-9]*s' "$tmp/waited.err" \
  && pass "a queued run reports the seconds it waited" \
  || fail "a queued run reported: $(tr '\n' ' ' <"$tmp/waited.err")"

# --- 8. --repo swaps the symlink only once the lock is held ------------------
# 2026-09-18: the cascade swapped AGENTS.md before queuing, so a repo that waited
# hours held a real copy the whole time, and a cascade killed while waiting left
# the divergence behind instead of an empty wait. The swap belongs to whoever
# holds the lock, and this asserts both halves of that.
r="$tmp/repo"; mkdir -p "$r"
printf '# demo\n' >"$r/CLAUDE.md"
ln -s CLAUDE.md "$r/AGENTS.md"
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" sleep 3 >/dev/null 2>&1 &
holder=$!
sleep 1
ATLAS_WIKI_LOCK_CAP_SECONDS=0 "$lockcmd" --repo "$r" true >/dev/null 2>&1 &
waiter=$!
sleep 1
[[ -L "$r/AGENTS.md" ]] && pass "a queued --repo run leaves AGENTS.md a symlink" \
  || fail "AGENTS.md was swapped while its run was still queued"
wait "$holder" 2>/dev/null
wait "$waiter" 2>/dev/null
[[ -f "$r/AGENTS.md" && ! -L "$r/AGENTS.md" ]] && pass "--repo swapped it after acquiring" \
  || fail "AGENTS.md was still not a real file after the lock was acquired"

(( fails == 0 )) || exit 1
