#!/bin/bash
# atlas-run-state-test.sh — focused contract test for scripts/atlas-run-state.sh.
# Sandboxed via a temp HOME + custom ATLAS_RUNS_DIR; no network, no real state dir.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT
export HOME="$sandbox/home"
export ATLAS_RUNS_DIR="$sandbox/state/atlas/runs"
mkdir -p "$HOME" "$ATLAS_RUNS_DIR"
state="$ATLAS_RUNS_DIR"
script="$root/scripts/atlas-run-state.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. kind/operation validation: every supported pair succeeds, garbage fails ---
for k in openwiki codealmanac; do
  for o in cascade sync garden; do
    out="$("$script" begin "test-$k-$o" --kind "$k" --operation "$o" --repo foo --trigger test)"
    rid="${out##*$'\n'}"   # last line: run_id
    [[ "$rid" == 20*"-test-$k-$o-"* ]] || fail "begin $k/$o did not print run_id (got: $out)"
    [[ -f "$state/$rid.json" ]] || fail "manifest file missing for $k/$o"
  done
done
# The non-cascade workflows added 2026-08-11. Not a cross product: scan pairs
# only with the two scan operations.
for pair in "scan:repo-scan" "scan:service-scan" "onboard:bootstrap"; do
  k="${pair%%:*}" o="${pair##*:}"
  out="$("$script" begin "test-$k-$o" --kind "$k" --operation "$o" --repo foo --trigger test)"
  rid="${out##*$'\n'}"
  [[ "$rid" == 20*"-test-$k-$o-"* ]] || fail "begin $k/$o did not print run_id (got: $out)"
  [[ -f "$state/$rid.json" ]] || fail "manifest file missing for $k/$o"
done
[[ "$(ls "$state" | wc -l | tr -d ' ')" == 9 ]] || fail "expected 9 manifests, got $(ls "$state" | wc -l)"

if "$script" begin x --kind bogus --operation cascade >/dev/null 2>&1; then
  fail "begin accepted invalid kind 'bogus'"
fi
if "$script" begin x --kind openwiki --operation bogus >/dev/null 2>&1; then
  fail "begin accepted invalid operation 'bogus'"
fi
if "$script" begin >/dev/null 2>&1; then
  fail "begin accepted missing --kind/--operation"
fi
echo "ok: validation accepts every supported kind/operation pair, rejects others"

# --- 2. schema: every required field present with correct types ---
# The `2>/dev/null` is deliberate and load-bearing: it is the shape all six real
# callers use, and it is not equivalent to the bare `$( ... )` this test used
# until 2026-08-16. With a redirect bash forks a subshell for the substitution
# and only then execs, so the child's $PPID is that throwaway subshell; without
# one bash execs directly and $PPID is the caller. begin used to read $PPID, so
# this test was green under the bare shape while every production caller wrote a
# pid that was dead on arrival. Call it the way production calls it.
rid="$("$script" begin schema-check --kind openwiki --operation cascade --repo atlas --trigger post-commit --pid $$ 2>/dev/null)"
manifest="$state/$rid.json"
[[ -f "$manifest" ]] || fail "schema manifest missing"

py_check="$(python3 - "$manifest" <<'PY'
import json, sys
with open(sys.argv[1]) as f: m = json.load(f)
required = {
    "schema_version": int, "run_id": str, "kind": str, "operation": str,
    "repo": (str, type(None)), "trigger": str, "status": str, "pid": (int, type(None)),
    "started_at": str, "updated_at": str, "finished_at": (str, type(None)),
    "exit_code": (int, type(None)), "error": (str, type(None)),
}
bad = [k for k, t in required.items() if k not in m or not isinstance(m[k], t)]
if bad: print("missing/bad:", bad); raise SystemExit(1)
if m["schema_version"] != 1: print("schema_version", m["schema_version"]); raise SystemExit(1)
if m["status"] != "running": print("status", m["status"]); raise SystemExit(1)
if not isinstance(m["pid"], int) or m["pid"] <= 0: print("pid", m["pid"]); raise SystemExit(1)
if not m["started_at"].endswith("Z") or "T" not in m["started_at"]:
    print("started_at shape", m["started_at"]); raise SystemExit(1)
if m["finished_at"] is not None or m["exit_code"] is not None or m["error"] is not None:
    print("running manifest has terminal fields"); raise SystemExit(1)
PY
)" || fail "schema check failed: $py_check"
echo "ok: schema v1 complete with correct types and RFC3339 UTC timestamps"

# --- 3. begin prints run_id to stdout exactly, manifest to filesystem ---
out="$("$script" begin stdout-check --kind codealmanac --operation sync)"
[[ -n "$out" && "$out" != *$'\n'* ]] || fail "begin printed unexpected output: $(printf '%q' "$out")"
rid="$out"
[[ -f "$state/$rid.json" ]] || fail "printed run_id has no manifest"
echo "ok: begin emits exactly one run_id line"

# --- 4. finish transitions running → succeeded and writes terminal fields ---
out="$("$script" begin finish-ok --kind openwiki --operation cascade)"
rid="$out"
"$script" finish "$rid" --exit-code 0 --status succeeded
python3 - "$state/$rid.json" "$rid" <<'PY' || { echo FAIL; exit 1; }
import json, sys
path, expected_id = sys.argv[1], sys.argv[2]
m = json.load(open(path))
assert m["status"] == "succeeded", m
assert m["exit_code"] == 0, m
assert m["error"] is None, m
assert m["finished_at"] is not None and m["finished_at"].endswith("Z"), m
assert m["pid"] is None, m
assert m["run_id"] == expected_id, m
PY
echo "ok: finish → succeeded with terminal fields"

# --- 4b. finish → failed records exit_code and error ---
out="$("$script" begin finish-fail --kind codealmanac --operation garden)"
rid="$out"
"$script" finish "$rid" --exit-code 7 --status failed --error "boom" >/dev/null
python3 - "$state/$rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "failed" and m["exit_code"] == 7 and m["error"] == "boom", m
PY
echo "ok: finish → failed records exit_code and error"

# --- 4c. finish → abandoned records exit_code and error, terminal state, atomic ---
out="$("$script" begin finish-abandon --kind openwiki --operation cascade)"
rid="$out"
"$script" finish "$rid" --exit-code 1 --status abandoned --error "stale-lock takeover" >/dev/null
python3 - "$state/$rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "abandoned", m
assert m["exit_code"] == 1, m
assert m["error"] == "stale-lock takeover", m
assert m["finished_at"] is not None and m["finished_at"].endswith("Z"), m
assert m["pid"] is None, m
PY
abandon_leftovers="$(find "$state" -name '.*.tmp' -o -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$abandon_leftovers" == 0 ]] || fail "abandoned finish left temp files behind"
echo "ok: finish --status abandoned writes terminal state atomically"

# --- 4d. begin sanitizes the user-supplied name into a safe slug for the filename ---
unsafe_name='My Run/../evil:name!'
out="$("$script" begin "$unsafe_name" --kind openwiki --operation sync)"
rid="$out"
[[ "$rid" != */* ]] || fail "run_id contains '/' (path escape): $rid"
[[ -f "$state/$rid.json" ]] || fail "sanitized run_id has no manifest: $rid"
[[ "$rid" == *"-my-run-evil-name-"* ]] || fail "name not sanitized to slug (got: $rid)"
name_seg="${rid#20??????T??????Z-}"
name_seg="${name_seg%-*}"
[[ "$name_seg" =~ ^[a-z0-9_-]+$ ]] || fail "run_id name segment has unsafe chars: $name_seg"
echo "ok: begin sanitizes name to a safe slug in the run_id"

# --- 5. finish is idempotent: re-finishing a terminal manifest is a no-op ---
out="$("$script" begin idempotent --kind openwiki --operation sync)"
rid="$out"
"$script" finish "$rid" --exit-code 0 --status succeeded >/dev/null
mtime1="$(stat -f %m "$state/$rid.json")"
sleep 1
"$script" finish "$rid" --exit-code 99 --status failed --error "x" >/dev/null
mtime2="$(stat -f %m "$state/$rid.json")"
python3 - "$state/$rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "succeeded" and m["exit_code"] == 0 and m["error"] is None, m
PY
[[ "$mtime1" == "$mtime2" ]] || fail "idempotent finish rewrote the file (mtime changed)"
echo "ok: finish on terminal manifest is a no-op"

# --- 5b. abandoned is terminal: re-finishing it is a no-op ---
out="$("$script" begin idempotent-abandon --kind openwiki --operation sync)"
rid="$out"
"$script" finish "$rid" --exit-code 1 --status abandoned --error "first" >/dev/null
mtime1="$(stat -f %m "$state/$rid.json")"
sleep 1
"$script" finish "$rid" --exit-code 0 --status succeeded --error "second" >/dev/null
mtime2="$(stat -f %m "$state/$rid.json")"
python3 - "$state/$rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "abandoned" and m["exit_code"] == 1 and m["error"] == "first", m
PY
[[ "$mtime1" == "$mtime2" ]] || fail "re-finish rewrote the abandoned manifest (mtime changed)"
echo "ok: re-finish on abandoned manifest is a no-op"

# --- 6. reconcile: live pid stays running, dead pid → abandoned ---
# live: a fresh begin records the pid we hand it ($$) — must be alive
out="$("$script" begin live --kind openwiki --operation cascade --pid $$ 2>/dev/null)"
live_rid="$out"
# dead: forge a manifest with an obviously dead pid
dead_rid="20260101T000000Z-dead-9999999"
python3 - "$state/$dead_rid.json" "$dead_rid" <<'PY' || { echo FAIL; exit 1; }
import json, os, sys
path, rid = sys.argv[1], sys.argv[2]
m = {
  "schema_version": 1, "run_id": rid, "kind": "openwiki", "operation": "cascade",
  "repo": "atlas", "trigger": "post-commit", "status": "running", "pid": 9999999,
  "started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
  "finished_at": None, "exit_code": None, "error": None,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f: json.dump(m, f, sort_keys=True); f.write("\n")
PY
out="$("$script" reconcile)"
grep -q "abandoned=1" <<<"$out" || fail "reconcile should report abandoned=1 (got: $out)"
python3 - "$state/$live_rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "running" and m["pid"] is not None, m
PY
python3 - "$state/$dead_rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "abandoned" and m["pid"] is None, m
assert m["finished_at"] is not None and m["finished_at"].endswith("Z"), m
PY
# clean up live manifest
"$script" finish "$live_rid" --exit-code 0 --status succeeded >/dev/null
echo "ok: reconcile marks dead-pid as abandoned, preserves live-pid"

# --- 7. prune: removes terminal manifests older than 30 days, never running ---
# old terminal (finished_at 40 days ago)
old_rid="20260101T000000Z-old-terminal-9999998"
python3 - "$state/$old_rid.json" "$old_rid" <<'PY' || { echo FAIL; exit 1; }
import json, sys
path, rid = sys.argv[1], sys.argv[2]
m = {
  "schema_version": 1, "run_id": rid, "kind": "codealmanac", "operation": "sync",
  "repo": "atlas", "trigger": "launchd", "status": "succeeded", "pid": None,
  "started_at": "2026-06-01T00:00:00Z", "updated_at": "2026-06-29T12:00:00Z",
  "finished_at": "2026-06-29T12:00:00Z", "exit_code": 0, "error": None,
}
with open(path, "w") as f: json.dump(m, f, sort_keys=True); f.write("\n")
PY
# recent terminal (yesterday) — must NOT be pruned.
# Computed, not hardcoded: this was a fixed 2026-08-07 and the test went red on
# its own on 2026-09-06, thirty days later, with prune working correctly.
recent_ts="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
recent_rid="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=1)).strftime("%Y%m%dT%H%M%SZ"))')-recent-terminal-9999997"
python3 - "$state/$recent_rid.json" "$recent_rid" "$recent_ts" <<'PY' || { echo FAIL; exit 1; }
import json, sys
path, rid, ts = sys.argv[1], sys.argv[2], sys.argv[3]
m = {
  "schema_version": 1, "run_id": rid, "kind": "openwiki", "operation": "cascade",
  "repo": "atlas", "trigger": "manual", "status": "succeeded", "pid": None,
  "started_at": ts, "updated_at": ts,
  "finished_at": ts, "exit_code": 0, "error": None,
}
with open(path, "w") as f: json.dump(m, f, sort_keys=True); f.write("\n")
PY
# old-but-still-running — must NOT be pruned
stale_rid="20260101T000000Z-stale-running-9999996"
python3 - "$state/$stale_rid.json" "$stale_rid" <<'PY' || { echo FAIL; exit 1; }
import json, sys
path, rid = sys.argv[1], sys.argv[2]
m = {
  "schema_version": 1, "run_id": rid, "kind": "openwiki", "operation": "sync",
  "repo": "atlas", "trigger": "launchd", "status": "running", "pid": 9999996,
  "started_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
  "finished_at": None, "exit_code": None, "error": None,
}
with open(path, "w") as f: json.dump(m, f, sort_keys=True); f.write("\n")
PY
out="$("$script" prune)"
grep -q "pruned=1" <<<"$out" || fail "prune should report pruned=1 (got: $out)"
[[ ! -f "$state/$old_rid.json" ]] || fail "prune left an old terminal manifest behind"
[[   -f "$state/$recent_rid.json" ]] || fail "prune removed a recent terminal manifest"
[[   -f "$state/$stale_rid.json" ]] || fail "prune removed a running manifest (must never touch running)"
echo "ok: prune removes >30d terminals, keeps recent terminals, never touches running"

# --- 8. run: success path records succeeded and returns 0 ---
"$script" run success-case --kind openwiki --operation cascade --repo atlas --trigger manual -- /usr/bin/true >/dev/null
run_rc=$?
[[ "$run_rc" == 0 ]] || fail "run did not return 0 on success (got $run_rc)"
run_rid="$(ls -t "$state" | grep '^20.*-success-case-' | head -1 | sed 's/\.json$//')"
[[ -n "$run_rid" ]] || fail "run did not create a manifest for success-case"
python3 - "$state/$run_rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "succeeded" and m["exit_code"] == 0, m
assert m["kind"] == "openwiki" and m["operation"] == "cascade", m
assert m["repo"] == "atlas" and m["trigger"] == "manual", m
assert m["error"] is None and m["finished_at"] is not None, m
PY
echo "ok: run records succeeded on /bin/true and returns 0"

# --- 8b. run: failure path records failed, returns the command's exit code ---
set +e
"$script" run fail-case --kind codealmanac --operation garden --repo atlas -- /bin/sh -c 'exit 42' >/dev/null 2>&1
run_rc=$?
set -e
[[ "$run_rc" == 42 ]] || fail "run did not return 42 on /bin/sh -c 'exit 42' (got $run_rc)"
fail_rid="$(ls -t "$state" | grep '^20.*-fail-case-' | head -1 | sed 's/\.json$//')"
[[ -n "$fail_rid" ]] || fail "run did not create a manifest for fail-case"
python3 - "$state/$fail_rid.json" <<'PY' || { echo FAIL; exit 1; }
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "failed" and m["exit_code"] == 42, m
assert m["kind"] == "codealmanac" and m["operation"] == "garden", m
assert m["error"] and "42" in m["error"], m
PY
echo "ok: run records failed with command's exit code, returns that code"

# --- 9. run: stdout from wrapped command is NOT persisted, no credentials leaked ---
SECRET="sentinel-credential-$$-$(date +%s%N)"
SECRET="$SECRET" "$script" run leak-check --kind openwiki --operation sync -- /bin/sh -c 'printf "%s\n" "$SECRET"' >/dev/null
if grep -rFl -- "$SECRET" "$state" >/dev/null 2>&1; then
  fail "run persisted command output (credential sentinel leaked into $state)"
fi
leak_rid="$(ls -t "$state" | grep '^20.*-leak-check-' | head -1 | sed 's/\.json$//')"
[[ -n "$leak_rid" ]] || fail "run did not create a manifest for leak-check"
python3 - "$state/$leak_rid.json" "$SECRET" <<'PY' || { echo FAIL; exit 1; }
import json, sys
path, secret = sys.argv[1], sys.argv[2]
m = json.load(open(path))
raw = open(path).read()
assert secret not in raw, "secret leaked into manifest body"
for k in ("stdout", "stderr", "output", "command_output"):
    assert k not in m, f"manifest carries unexpected field {k!r}"
PY
echo "ok: run does not persist command output or stdout/stderr fields"

# --- 10. atomic write: no .tmp leftovers after a clean begin ---
"$script" begin atomic-check --kind openwiki --operation sync >/dev/null
leftovers="$(find "$state" -name '.*.tmp' -o -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$leftovers" == 0 ]] || fail "atomic write left temp files behind: $(find "$state" -name '*.tmp')"
echo "ok: atomic writes leave no .tmp leftovers"

# --- 11. ATLAS_RUNS_DIR override is respected (state never touches $HOME/.local) ---
[[ ! -d "$HOME/.local/state/atlas/runs" ]] || fail "default $HOME/.local/state/atlas/runs was created"
[[ -d "$ATLAS_RUNS_DIR" ]] || fail "ATLAS_RUNS_DIR not created"
echo "ok: ATLAS_RUNS_DIR override is respected, no default path used"

echo "ALL TESTS PASSED"
