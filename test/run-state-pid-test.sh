#!/bin/bash
# run-state-pid-test.sh — the ledger must not invent incidents.
#
# Regression guard for the 2026-08-16 finding: cmd_begin recorded $PPID, which
# under the universal `$( helper begin ... )` call shape is the command-
# substitution subshell, dead milliseconds later. reconcile then marked every
# live owner "abandoned" — 59/59 abandoned runs, all error "pid dead", while
# cascade.log showed those same runs completing. atlas-check read 31% abandoned
# and blamed session teardown.
#
# The load-bearing check is #2: it fails against the old $PPID code and passes
# against --pid $$. The rest pin the contract around it.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
rs="$root/scripts/atlas-run-state.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
export ATLAS_RUNS_DIR="$tmp/runs"

fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

status_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$ATLAS_RUNS_DIR/$1.json"; }
pid_of()    { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])'    "$ATLAS_RUNS_DIR/$1.json"; }

# --- 1. the owner's pid is what lands in the manifest ------------------------
# Called exactly the way every real caller calls it: $( ... ) with a redirect.
# The recorded pid must be this shell, not the subshell bash forks for the
# substitution. Comparing to $$ is the whole point — a helper that guesses
# cannot get this right.
rid="$( "$rs" begin owner-pid --kind scan --operation repo-scan --pid $$ 2>/dev/null )"
if [[ "$(pid_of "$rid")" == "$$" ]]; then
  pass "begin --pid records the caller's pid, not the substitution subshell"
else
  fail "begin --pid recorded $(pid_of "$rid"), expected $$"
fi

# --- 2. reconcile leaves a live owner alone (the actual regression) ----------
if [[ "$(status_of "$rid")" == running ]] && "$rs" reconcile >/dev/null 2>&1 \
   && [[ "$(status_of "$rid")" == running ]]; then
  pass "reconcile does not abandon a run whose owner is alive"
else
  fail "reconcile abandoned a live run (status now '$(status_of "$rid")')"
fi

# --- 3. ...but still reaps a genuinely dead one ------------------------------
# A real short-lived process, so the pid is one that truly existed and is now
# gone. Without this, check #2 would also pass if reconcile did nothing at all.
dead_pid="$(bash -c 'echo $$')"
while kill -0 "$dead_pid" 2>/dev/null; do :; done
drid="$( "$rs" begin dead-owner --kind scan --operation repo-scan --pid "$dead_pid" 2>/dev/null )"
"$rs" reconcile >/dev/null 2>&1
if [[ "$(status_of "$drid")" == abandoned ]]; then
  pass "reconcile still abandons a run whose owner is gone"
else
  fail "reconcile left a dead run as '$(status_of "$drid")'"
fi

# --- 4. no --pid means null, and null is never judged ------------------------
nrid="$( "$rs" begin no-pid --kind scan --operation repo-scan 2>/dev/null )"
"$rs" reconcile >/dev/null 2>&1
if [[ "$(pid_of "$nrid")" == None && "$(status_of "$nrid")" == running ]]; then
  pass "a pid-less run records null and reconcile skips it"
else
  fail "pid-less run: pid=$(pid_of "$nrid") status=$(status_of "$nrid")"
fi


# --- 6. every begin call site in the tree passes --pid ------------------------
# The bug was not in one caller, it was in all six. A new script that forgets
# --pid silently drops out of reconcile's reach, so pin the convention here.
# Every real call spans two lines with a trailing backslash, so collapse
# continuations before looking — a line-wise grep reports all five as failures.
missing="$(python3 - "$root/scripts" <<'PY'
import os, re, sys
bad = []
for f in sorted(os.listdir(sys.argv[1])):
    if not f.endswith(".sh") or f == "atlas-run-state.sh": continue
    p = os.path.join(sys.argv[1], f)
    src = open(p).read().replace("\\\n", " ")
    for line in src.splitlines():
        if re.search(r"\bbegin\b.*--kind", line) and "--pid" not in line:
            bad.append(f)
            break
print(" ".join(bad))
PY
)"
[[ -n "$missing" ]] && fail "begin without --pid in: $missing" \
  || pass "every begin call site in scripts/ passes --pid"

# --- 7. the `run` wrapper survives a concurrent reconcile --------------------
# cmd_run is its own path into cmd_begin — the helper is the owner there, so it
# passes its own $$. End-to-end: a real wrapped command, a real reconcile firing
# while it is mid-flight (which is exactly how the cascade got reaped: every
# other cascade start calls reconcile).
"$rs" run slow --kind scan --operation repo-scan -- sleep 6 &
wrapper=$!
sleep 2
"$rs" reconcile >/dev/null 2>&1
slow_id="$(python3 - "$ATLAS_RUNS_DIR" <<'PY'
import json, os, sys
for n in sorted(os.listdir(sys.argv[1])):
    if not n.endswith(".json"): continue
    m = json.load(open(os.path.join(sys.argv[1], n)))
    if "-slow-" in m["run_id"]:
        print(m["run_id"] + " " + m["status"]); break
PY
)"
if [[ "$slow_id" == *" running" ]]; then
  pass "run wrapper: reconcile mid-flight leaves it running"
else
  fail "run wrapper: reconcile clobbered it ('${slow_id:-no manifest}')"
fi
wait "$wrapper"
if [[ "$(status_of "${slow_id%% *}")" == succeeded ]]; then
  pass "run wrapper: finishes succeeded once the command exits"
else
  fail "run wrapper: ended '$(status_of "${slow_id%% *}")'"
fi

((fails)) && { printf '\n%d FAIL\n' "$fails"; exit 1; }
printf '\nall checks passed\n'
