#!/bin/bash
# with-wiki-lock.sh — run a command holding the machine-wide wiki-generation lock.
# Serializes local-model consumers (openwiki runs from hooks/launchd across repos) so
# concurrent long-context generations don't blow the engine's memory guard and silently
# fall back to cloud. macOS ships no flock(1): lock fd 9 with python fcntl — the
# lock lives on the open file description, so it survives the helper and is held
# until the exec'd command exits.
# ATLAS_WIKI_LOCK is overridable so the test suite can hold its own lock: the
# sandbox fakes HOME/PATH, but a hardcoded /tmp path is machine-wide, so tests
# otherwise block on whatever real openwiki run currently holds it.
set -euo pipefail

# --repo <path> (optional): openwiki writes AGENTS.md and CLAUDE.md from one
# pre-read of each and does the two writes concurrently, so where AGENTS.md is a
# symlink to CLAUDE.md that is one inode truncated twice. Swap the symlink for a
# real copy — only once this shell holds the lock. The caller used to swap before
# calling here, which put it ahead of the queue: repos that queued for hours held
# a real copy the whole time, so a cascade killed while waiting left the
# divergence behind instead of an empty wait.
repo=""
if [[ "${1:-}" == --repo ]]; then
  repo="${2:?--repo needs a path}"
  shift 2
fi

lockfile="${ATLAS_WIKI_LOCK:-/tmp/atlas-wiki-gen.lock}"
exec 9>"$lockfile"
# Two-step instead of one blocking flock, so the wait is visible. The cascade
# times its openwiki stage end to end, and that clock includes however long this
# helper sat behind another repo -- 2026-09-06 atlas waited 21 min for
# one repo. Without this line a queued run and a slow run look identical in
# the log, and the multi-hour stages could not be split into wait vs inference.
waited=0
if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
  echo "with-wiki-lock: waiting for $lockfile" >&2
  waited=$SECONDS
  python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
  waited=$((SECONDS - waited))
fi
# Always, not only when it queued: the cascade splits its stage clock on this
# line, and a run that never waited still needs the number.
echo "with-wiki-lock: acquired after ${waited}s" >&2

if [[ -n $repo && -L $repo/AGENTS.md ]]; then
  # cp follows the link first, so the stand-in starts out identical to what it
  # pointed at: anything reading AGENTS.md mid-stage finds the same bytes rather
  # than no file at all.
  cp "$repo/AGENTS.md" "$repo/.AGENTS.md.atlas-tmp"
  rm -f "$repo/AGENTS.md"
  mv "$repo/.AGENTS.md.atlas-tmp" "$repo/AGENTS.md"
  echo "with-wiki-lock: swapped AGENTS.md for a real copy" >&2
fi
# Wall-clock ceiling on the locked command, armed only once the lock is held so
# a long queue never spends the budget. Without it a stage runs until something
# outside gives up: 2026-09-06 atlas generated for 6628s after acquiring and
# then died on "Node.js fetch timed out waiting for response headers", and two
# runs on 2026-09-04/05 burned 7.9h and 7.4h writing nothing -- all three while
# holding this lock, so every other repo queued behind a run already lost.
# 0 disables. Default 3h: the only two stages that finished under measurement
# took 6628s and (one repo, end to end including its wait) 11680s.
cap="${ATLAS_WIKI_LOCK_CAP_SECONDS:-10800}"
if [[ $cap =~ ^[0-9]+$ ]] && (( cap > 0 )); then
  # exec below keeps this PID, so $$ is the command the watchdog must bound.
  # It polls instead of one long sleep: a watchdog that outlives its target
  # would signal whatever PID the kernel recycled into that slot.
  target=$$
  # Polls every second, not every ten. The watchdog inherits stderr, which in the
  # cascade is a pipe into the timestamped log, so the pipe does not reach EOF
  # until the watchdog exits: whatever the poll step is, the stage appears to
  # hang for that long after the command has already finished.
  step=1
  ( # Drop the lock fd first. The watchdog is a child, so it inherits fd 9 and
    # would hold the machine-wide lock for as long as it lives -- up to one poll
    # step in the normal case, and the whole TERM-to-KILL grace after a kill.
    # Measured: the next waiter acquired 30s after the killed command died.
    exec 9>&-
    waited=0
    while (( waited < cap )); do
      sleep "$step"
      waited=$((waited + step))
      kill -0 "$target" 2>/dev/null || exit 0
    done
    echo "with-wiki-lock: ${cap}s cap reached, terminating" >&2
    kill -TERM "$target" 2>/dev/null
    sleep 30
    kill -KILL "$target" 2>/dev/null ) &
fi

exec "$@"
