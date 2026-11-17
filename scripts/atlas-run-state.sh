#!/bin/bash
# atlas-run-state.sh — run-manifest helper.
#
# Subcommands (all use Python stdlib for JSON; no jq, no extra deps):
#   begin <name> --kind K --operation O [--repo R] [--trigger T] [--pid P]
#     Write a schema v1 running manifest under ${ATLAS_RUNS_DIR:-$HOME/.local/state/atlas/runs}.
#     Prints run_id to stdout. --pid is the long-running owner's pid, and callers
#     must pass their own $$ — this script cannot infer it (see cmd_begin).
#     Without it the run is recorded with pid null and reconcile leaves it alone.
#   finish <run_id> --exit-code N [--error E] [--status succeeded|failed|skipped|abandoned]
#     Atomically transition a running manifest to a terminal state.
#   reconcile
#     Mark every running manifest whose pid is dead as abandoned; preserve live pids.
#   prune
#     Delete terminal manifests whose finished_at is older than 30 days; never touch running.
#   run <name> --kind K --operation O [--repo R] [--trigger T] -- cmd [args...]
#     Wrap cmd: begin → exec → finish with cmd's exit code, return cmd's exit code.
#     Command stdout/stderr is NOT captured.
set -euo pipefail

RUNS_DIR="${ATLAS_RUNS_DIR:-$HOME/.local/state/atlas/runs}"
# The ledger shipped with only the two cascade-stage kinds, which left 8 of atlas's
# 9 workflows outside the ledger — "what is atlas doing right now" was answerable
# only by grepping ps (2026-08-11). scan added so the periodic scans register
# too.
#
# onboard/bootstrap added 2026-08-12. The remaining four workflows are
# deliberately NOT registered: atlas-pointer.sh and almanac-fold.sh are children
# of already-registered parents (atlas-onboard.sh and repo-atlas.sh), so a
# manifest each would double-count the same work; atlas-check.sh and
# atlas-reads.sh are read-only reports that print their verdict to the terminal
# they were run from, and a ledger entry answers nothing their output does not.
ALLOWED_KINDS=(openwiki codealmanac scan onboard)
ALLOWED_OPS=(cascade sync garden repo-scan service-scan bootstrap)

err() { printf 'atlas-run-state: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
usage: atlas-run-state.sh <command> [args]

  begin    <name> --kind K --operation O [--repo R] [--trigger T] [--pid P]
  finish   <run_id> --exit-code N [--error E] [--status succeeded|failed|skipped|abandoned]
  reconcile
  prune
  run      <name> --kind K --operation O [--repo R] [--trigger T] -- cmd [args...]

State directory: ${ATLAS_RUNS_DIR:-$HOME/.local/state/atlas/runs}
EOF
}

# Validate kind/operation membership. Echoes nothing on success, error to stderr + non-zero on fail.
validate_kind_op() {
  local k ok=0
  for k in "${ALLOWED_KINDS[@]}"; do [[ "$1" == "$k" ]] && ok=1 && break; done
  ((ok)) || { err "invalid kind '$1' (allowed: ${ALLOWED_KINDS[*]})"; return 2; }
  ok=0
  for k in "${ALLOWED_OPS[@]}"; do [[ "$2" == "$k" ]] && ok=1 && break; done
  ((ok)) || { err "invalid operation '$2' (allowed: ${ALLOWED_OPS[*]})"; return 2; }
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Sanitize a user-supplied name into a safe slug: lowercase, keep [a-z0-9_],
# collapse every other run to '-', trim edge '-'. Never empty (falls back to "run").
slug() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:-run}"
}

new_run_id() { printf '%s-%s-%d' "$(date -u +%Y%m%dT%H%M%SZ)" "$(slug "$1")" "$$"; }

cmd_begin() {
  local name="" kind="" operation="" repo="" trigger="manual" pid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)      kind="${2:-}"; shift 2 ;;
      --operation) operation="${2:-}"; shift 2 ;;
      --repo)      repo="${2:-}"; shift 2 ;;
      --trigger)   trigger="${2:-}"; shift 2 ;;
      --pid)       pid="${2:-}"; shift 2 ;;
      -*) err "unknown flag '$1'"; return 2 ;;
      *)  [[ -z "$name" ]] && { name="$1"; shift; } || { err "unexpected extra arg '$1'"; return 2; } ;;
    esac
  done
  [[ -n "$name" ]]      || { err "begin requires <name>"; return 2; }
  [[ -n "$kind" ]]      || { err "begin requires --kind"; return 2; }
  [[ -n "$operation" ]] || { err "begin requires --operation"; return 2; }
  validate_kind_op "$kind" "$operation" || return 2

  local run_id started_at target
  run_id="$(new_run_id "$name")"
  started_at="$(now_utc)"
  target="$RUNS_DIR/$run_id.json"

  # pid = the long-running owner, and ONLY the caller knows it. $PPID was used here
  # until 2026-08-16 and was always wrong: every caller invokes this script as
  # `$( helper begin ... )`, and bash forks a subshell for the command substitution
  # before exec'ing us, so $PPID is that subshell — a process that exits within
  # milliseconds. Every manifest therefore recorded an already-dead pid, and the
  # next reconcile marked the still-running owner "abandoned". That is the whole of
  # the 31%-abandoned reading: 59/59 abandoned runs carried error "pid dead", and
  # cascade.log shows those same runs going on to log "done". Callers now pass $$.
  #
  # No --pid means no pid: reconcile skips a null and leaves the run 'running'
  # rather than guessing. A run stuck 'running' is a visible loose end; a run
  # falsely 'abandoned' is a fabricated incident, and this ledger exists to be
  # trusted. Untracked-but-honest beats tracked-and-lying.
  python3 - "$target" "$run_id" "$kind" "$operation" "${repo:-}" "$trigger" "${pid:-}" "$started_at" <<'PY'
import json, os, sys, tempfile
target, run_id, kind, operation, repo, trigger, pid, started_at = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "run_id": run_id,
    "kind": kind,
    "operation": operation,
    "repo": repo or None,
    "trigger": trigger,
    "status": "running",
    "pid": int(pid) if pid else None,
    "started_at": started_at,
    "updated_at": started_at,
    "finished_at": None,
    "exit_code": None,
    "error": None,
}
os.makedirs(os.path.dirname(target), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target),
                          prefix=f".{os.path.basename(target)}.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(manifest, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, target)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
print(run_id)
PY
}

cmd_finish() {
  local run_id="" exit_code="" error="" status="succeeded"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exit-code) exit_code="${2:-}"; shift 2 ;;
      --error)     error="${2:-}"; shift 2 ;;
      --status)    status="${2:-}"; shift 2 ;;
      -*) err "unknown flag '$1'"; return 2 ;;
      *)  [[ -z "$run_id" ]] && { run_id="$1"; shift; } || { err "unexpected extra arg '$1'"; return 2; } ;;
    esac
  done
  [[ -n "$run_id" ]]    || { err "finish requires <run_id>"; return 2; }
  [[ -n "$exit_code" ]] || { err "finish requires --exit-code"; return 2; }
  case "$status" in
    succeeded|failed|skipped|abandoned) ;;
    *) err "invalid --status '$status' (succeeded|failed|skipped|abandoned)"; return 2 ;;
  esac
  local target="$RUNS_DIR/$run_id.json"
  [[ -f "$target" ]] || { err "manifest not found: $target"; return 1; }

  python3 - "$target" "$status" "$exit_code" "$error" "$(now_utc)" <<'PY'
import json, os, sys, tempfile
target, status, exit_code, error, now = sys.argv[1:]
with open(target) as f: m = json.load(f)
if m.get("status") in ("succeeded", "failed", "skipped", "abandoned"):
    sys.exit(0)  # terminal: idempotent no-op
m["status"]      = status
m["exit_code"]   = int(exit_code)
m["error"]       = error or None
m["finished_at"] = now
m["updated_at"]  = now
m["pid"]         = None
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target),
                          prefix=f".{os.path.basename(target)}.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, target)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
}

cmd_reconcile() {
  python3 - "$RUNS_DIR" "$(now_utc)" <<'PY'
import json, os, sys, tempfile
runs_dir, now = sys.argv[1], sys.argv[2]
if not os.path.isdir(runs_dir): sys.exit(0)
abandoned = 0
for name in sorted(os.listdir(runs_dir)):
    if not name.endswith(".json") or name.startswith("."): continue
    path = os.path.join(runs_dir, name)
    try:
        with open(path) as f: m = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    if m.get("status") != "running": continue
    pid = m.get("pid")
    if pid is None: continue
    alive = False
    try:
        os.kill(pid, 0); alive = True
    except ProcessLookupError:
        alive = False
    except PermissionError:
        alive = True  # exists, but we lack permission to signal
    if alive: continue
    m["status"]      = "abandoned"
    m["finished_at"] = now
    m["updated_at"]  = now
    m["pid"]         = None
    m["error"]       = m.get("error") or "pid dead"
    fd, tmp = tempfile.mkstemp(dir=runs_dir, prefix=f".{name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(m, f, sort_keys=True); f.write("\n")
        os.replace(tmp, path)
        abandoned += 1
    except BaseException:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
        raise
print(f"abandoned={abandoned}")
PY
}

cmd_prune() {
  python3 - "$RUNS_DIR" <<'PY'
import json, os, sys
from datetime import datetime, timezone
runs_dir = sys.argv[1]
if not os.path.isdir(runs_dir): sys.exit(0)
threshold = datetime.now(timezone.utc).timestamp() - 30 * 86400
removed = 0
for name in sorted(os.listdir(runs_dir)):
    if not name.endswith(".json") or name.startswith("."): continue
    path = os.path.join(runs_dir, name)
    try:
        with open(path) as f: m = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    if m.get("status") == "running": continue  # never touch active
    finished = m.get("finished_at") or m.get("updated_at") or m.get("started_at")
    if not finished: continue
    try:
        ts = datetime.fromisoformat(finished.replace("Z", "+00:00")).timestamp()
    except ValueError:
        continue
    if ts < threshold:
        os.unlink(path); removed += 1
print(f"pruned={removed}")
PY
}

cmd_run() {
  local name="" kind="" operation="" repo="" trigger="manual"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; break ;;
      --kind)      kind="${2:-}"; shift 2 ;;
      --operation) operation="${2:-}"; shift 2 ;;
      --repo)      repo="${2:-}"; shift 2 ;;
      --trigger)   trigger="${2:-}"; shift 2 ;;
      -*) err "unknown flag '$1'"; return 2 ;;
      *)  [[ -z "$name" ]] && { name="$1"; shift; } || { err "unexpected extra arg '$1'"; return 2; } ;;
    esac
  done
  [[ -n "$name" ]]      || { err "run requires <name>"; return 2; }
  [[ -n "$kind" ]]      || { err "run requires --kind"; return 2; }
  [[ -n "$operation" ]] || { err "run requires --operation"; return 2; }
  [[ $# -gt 0 ]]        || { err "run requires -- cmd [args...]"; return 2; }
  validate_kind_op "$kind" "$operation" || return 2

  local run_id
  # $$ is right here: under `run` this script IS the long-running owner. (Inside
  # the $( ) subshell $$ still expands to the parent shell's pid, by design.)
  if ! run_id="$(cmd_begin "$name" --kind "$kind" --operation "$operation" \
                            ${repo:+--repo "$repo"} --trigger "$trigger" --pid $$)"; then
    return 1
  fi

  set +e
  "$@"
  local rc=$?
  set -e
  if ((rc == 0)); then
    cmd_finish "$run_id" --exit-code 0 --status succeeded >/dev/null
  else
    cmd_finish "$run_id" --exit-code "$rc" --status failed --error "exit $rc" >/dev/null
  fi
  return $rc
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    begin)     cmd_begin "$@" ;;
    finish)    cmd_finish "$@" ;;
    reconcile) cmd_reconcile ;;
    prune)     cmd_prune ;;
    run)       cmd_run "$@" ;;
    help|-h|--help) usage ;;
    *) err "unknown command '$cmd'"; usage >&2; return 2 ;;
  esac
}

main "$@"
