#!/bin/bash
# atlas-runs-check.sh — read the run ledger and judge it. Read-only:
# never writes a manifest, never reconciles, never prunes.
# Exit 0 = green, 1 = at least one FAIL.
#
# Separate from atlas-check.sh on purpose: that one validates *output* (is
# ~/wiki/atlas fresh and wired). This validates *execution* (did the jobs that
# produce it actually finish). Different source of truth, different lifecycle.
#
# Why this exists at all: the ledger shipped in 2026-08 and nothing
# ever read it. It recorded a 7.5% success rate for eight days in silence.
# Instrumentation with no consumer is not instrumentation.
set -uo pipefail   # no -e: every check must run, then report together

RUNS="${ATLAS_RUNS_DIR:-$HOME/.local/state/atlas/runs}"
WINDOW_DAYS="${1:-7}"

# Thresholds. Deliberately strict — the 2026-08-16 baseline (7.5% succeeded,
# 52% abandoned) must read FAIL, or the check is decoration.
MIN_SUCCESS_PCT=80    # per operation, over the window
MAX_ABANDONED_PCT=20  # fleet-wide
MAX_SILENT_HOURS=48   # no run at all in this long = the triggers are dead

if [[ ${1:-} == --self-test ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  now="$(date -u +%FT%TZ)"
  w() { printf '{"schema_version":1,"run_id":"%s","operation":"%s","status":"%s","started_at":"%s","updated_at":"%s","kind":"scan","pid":null,"exit_code":null}\n' \
    "$1" "$2" "$3" "${4:-$now}" "$now" > "$tmp/$1.json"; }
  w r1 cascade succeeded; w r2 cascade succeeded; w r3 cascade failed
  out="$(ATLAS_RUNS_DIR="$tmp" "$0" 7)"; rc=$?
  # 2/3 = 66% < 80 → must FAIL, and must say so about 'cascade'
  [[ $rc == 1 ]] || { echo "self-test FAIL: expected exit 1, got $rc"; exit 1; }
  grep -q 'FAIL cascade' <<<"$out" || { echo "self-test FAIL: no cascade failure line"; echo "$out"; exit 1; }
  w r3 cascade succeeded
  ATLAS_RUNS_DIR="$tmp" "$0" 7 >/dev/null || { echo "self-test FAIL: 100% should be green"; exit 1; }
  # 9/10 = 90% passes the rate, but the newest run failed → must FAIL
  old="$(date -u -v-1d +%FT%TZ)"
  for i in 4 5 6 7 8 9 10 11 12; do w "s$i" scan succeeded "$old"; done
  w s13 scan failed
  out="$(ATLAS_RUNS_DIR="$tmp" "$0" 7)" && { echo "self-test FAIL: a failed latest run read green"; exit 1; }
  grep -q 'FAIL scan: latest run failed' <<<"$out" || { echo "self-test FAIL: no latest-run line"; echo "$out"; exit 1; }
  echo "self-test ok"; exit 0
fi

[[ -d $RUNS ]] || { echo "== runs"; echo "  FAIL ledger dir missing: $RUNS"; echo; echo "atlas runs: 1 FAIL"; exit 1; }

python3 - "$RUNS" "$WINDOW_DAYS" "$MIN_SUCCESS_PCT" "$MAX_ABANDONED_PCT" "$MAX_SILENT_HOURS" <<'PY'
import json, os, sys, glob
from datetime import datetime, timezone, timedelta

runs_dir, window, min_pct, max_aband, max_silent = sys.argv[1], int(sys.argv[2]), \
    int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=window)

fails = 0
def pas(m): print(f"  ok   {m}")
def fail(m):
    global fails; fails += 1; print(f"  FAIL {m}")
def note(m): print(f"  note {m}")

def ts(v):
    if not v: return None
    try: return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError: return None

runs, unreadable = [], 0
for p in glob.glob(os.path.join(runs_dir, "*.json")):
    try:
        with open(p) as f: d = json.load(f)
    except (json.JSONDecodeError, OSError):
        unreadable += 1; continue
    started = ts(d.get("started_at"))
    if started and started >= cutoff:
        runs.append(d)

print("== runs")
if unreadable:
    fail(f"{unreadable} unreadable manifest(s) in {runs_dir}")

if not runs:
    fail(f"no run manifests in the last {window}d — triggers dead, or ledger not being written")
    print()
    print(f"atlas runs: {fails} FAIL")
    sys.exit(1)

# schema drift: a manifest this script cannot interpret is worse than none
bad_schema = [r for r in runs if r.get("schema_version") != 1]
if bad_schema:
    fail(f"{len(bad_schema)} manifest(s) with schema_version != 1 — this check reads v1 only")

# 1. liveness — is anything running at all?
latest = max((ts(r.get("started_at")) for r in runs if ts(r.get("started_at"))), default=None)
silent_h = (now - latest).total_seconds() / 3600
if silent_h <= max_silent:
    pas(f"last run {silent_h:.0f}h ago ({len(runs)} runs in {window}d)")
else:
    fail(f"no run in {silent_h:.0f}h (limit {max_silent}h) — check launchd + post-commit hooks")

# 2. abandoned share — the process-group teardown signal.
# 'abandoned' means reconcile found a dead PID with no finish record: the run
# was killed without its EXIT trap firing. nohup does not survive that.
aband = sum(1 for r in runs if r.get("status") == "abandoned")
apct = 100 * aband / len(runs)
if apct <= max_aband:
    pas(f"abandoned {aband}/{len(runs)} ({apct:.0f}%)")
else:
    fail(f"abandoned {aband}/{len(runs)} ({apct:.0f}%, limit {max_aband}%) — runs are dying with the session; detach the cascade")

# 3. per-operation success rate
ops = {}
for r in runs:
    ops.setdefault(r.get("operation") or "unknown", []).append(r.get("status"))
for op in sorted(ops):
    st = ops[op]
    # 'skipped' is a lock collision, not a failure — exclude from the denominator
    scored = [s for s in st if s != "skipped"]
    if not scored:
        note(f"{op}: {len(st)} runs, all skipped (lock contention)")
        continue
    ok = scored.count("succeeded")
    pct = 100 * ok / len(scored)
    detail = f"{ok}/{len(scored)} ({pct:.0f}%)"
    if pct >= min_pct:
        pas(f"{op}: {detail}")
    else:
        worst = max(set(s for s in scored if s != "succeeded"), key=scored.count, default="?")
        fail(f"{op}: {detail}, below {min_pct}% — dominant outcome '{worst}'")

# 3b. is it broken right now? A rate over the window hides a job that died
# today: on 2026-10-11 repo-scan failed every run for a day and nothing said so.
last = {}
for r in runs:
    if r.get("status") in ("skipped", "running"):
        continue
    op = r.get("operation") or "unknown"
    if op not in last or (r.get("started_at") or "") > (last[op].get("started_at") or ""):
        last[op] = r
for op in sorted(last):
    r = last[op]
    if r.get("status") != "succeeded":
        fail(f"{op}: latest run {r.get('status')} (exit {r.get('exit_code')}, {r.get('started_at')})")

# 4. runs still marked running whose start is older than the window's edge:
# reconcile has not been run, so the numbers above understate the damage.
# The `and ts(...)` middle term is load-bearing: ts() returns None for a missing
# or unparseable started_at, and None short-circuits the subtraction below. Keep
# ts() returning None -- making it always return a datetime breaks this filter.
stale_running = [r for r in runs if r.get("status") == "running"
                 and ts(r.get("started_at"))
                 and (now - ts(r.get("started_at"))).total_seconds() > 3600]
if stale_running:
    note(f"{len(stale_running)} run(s) 'running' for >1h — run: atlas-run-state.sh reconcile")

print()
if fails:
    print(f"atlas runs: {fails} FAIL")
    sys.exit(1)
print("atlas runs: green")
PY
