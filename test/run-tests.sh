#!/bin/bash
# run-tests.sh — end-to-end check of onboard + hooks + cascade with stubbed tools.
# Sandbox: fake HOME + stub gitnexus/openwiki/codealmanac/qmd/prek logging every call.
# No LLM, no network, no touching the real ~/wiki.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
# rc=$? / exit $rc, not a bare rm. Measured on /bin/bash 3.2: a trap's own exit
# status is discarded UNLESS set -e fires inside the trap — errexit then exits
# from the trap itself, and that exit sets the status. This script has set -e, so
# a cleanup that cannot delete the sandbox aborts the trap at the failing rm and
# turns a green run into exit 1 — printing "ALL TESTS PASSED" and then failing.
# Hence both halves: `|| true` so errexit never fires, and `exit $rc` so the real
# verdict is what the shell returns. The rm's error still reaches stderr. Seen
# once on 2026-08-24 and not reproducible in 18 further runs, so the cleanup no
# longer decides the verdict.
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- sandbox ---
export HOME="$sandbox/home"
export ATLAS_RUNS_DIR="$sandbox/runs"
# without this the onboard scan collides with whatever real scan holds the
# global /tmp lock and the suite fails for a reason unrelated to the code
export ATLAS_SCAN_LOCK="$sandbox/scan.lock.d"
# own lock, or the suite blocks on the real machine-wide one held by a live openwiki
export ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock"
name="testrepo-$$"
repo="$HOME/dev/$name"
calls="$sandbox/calls.log"
mkdir -p "$repo" "$HOME/wiki" "$HOME/.claude" "$HOME/.config/opencode" "$HOME/.pi/agent" "$sandbox/stubs"
: >"$calls"
for tool in gitnexus openwiki codealmanac qmd prek osascript curl pass gh; do
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$tool" "$calls" >"$sandbox/stubs/$tool"
  chmod +x "$sandbox/stubs/$tool"
done
printf '#!/bin/bash\nprintf "true\\n"\n' >"$sandbox/stubs/gh"
chmod +x "$sandbox/stubs/gh"
# openwiki gets more than a call log: the cascade verifies the stage by reading
# openwiki/.last-update.json, so the stub has to leave the same receipt a real
# run does. Without it every cascade in this suite logs "openwiki: exited 0 but
# wrote nothing" -- which is the point of the check, and wrong here.
cat >"$sandbox/stubs/openwiki" <<STUB
#!/bin/bash
echo "openwiki \$*" >>"$calls"
[[ "\${1:-}" == code ]] || exit 0
mkdir -p openwiki
printf '{"updatedAt":"2026-01-01T00:00:00.000Z","command":"update","gitHead":"%s","model":"stub","status":"complete"}\n' \
  "\$(git rev-parse HEAD)" >openwiki/.last-update.json
STUB
chmod +x "$sandbox/stubs/openwiki"
# entire is stubbed because it must never run for real here: onboard calls it and
# a real binary would rewrite $root/hooks, the shared hooksPath. The stub writes
# settings that reflect exactly the flags it was handed, so an onboard that drops
# --skip-push-sessions or --telemetry=false leaves a settings.json its own
# verification rejects.
cat >"$sandbox/stubs/entire" <<STUB
#!/bin/bash
echo "entire \$*" >>"$calls"
mkdir -p .entire
{
  printf '{"enabled":true'
  case " \$* " in *" --skip-push-sessions "*) printf ',"strategy_options":{"push_sessions":false}' ;; esac
  case " \$* " in *" --telemetry=false "*) printf ',"telemetry":false' ;; esac
  printf ',"checkpoints":{"primary":{"type":"git-refs"}}}\n'
} >.entire/settings.json
STUB
chmod +x "$sandbox/stubs/entire"
export PATH="$sandbox/stubs:$PATH"
export ATLAS_LITELLM_KEY=test
export GIT_CONFIG_NOSYSTEM=1
# The suite commits for real, and post-commit hands the commit to the roborev
# launchd daemon — which runs outside this sandbox with the real HOME/PATH and
# spawns agents that read production secrets. Stubs cannot reach it; only this can.
export ATLAS_SKIP_ROBOREV=1

cd "$repo"
git init -q
git config user.email t@t && git config user.name t
echo "# $name" >README.md
echo "test repo purpose line." >>README.md
git add . && git commit -qm init --no-verify

# --- 1. onboard ---
"$root/bin/atlas" onboard "$repo" >"$sandbox/onboard.log" 2>&1 || { cat "$sandbox/onboard.log"; fail "onboard exited non-zero"; }
[[ "$(git config core.hooksPath)" == "$root/hooks" ]] || fail "hooksPath not set"
grep -q "gitnexus analyze" "$calls" || fail "onboard did not run gitnexus analyze"
grep -q "openwiki code --init" "$calls" || fail "onboard did not run openwiki --init"
grep -q "codealmanac init" "$calls" || fail "onboard did not run codealmanac init"
entity="$HOME/wiki/atlas/repos/$name.md"
[[ -f $entity ]] || fail "no entity doc"
grep -q "last-commit: $(git log -1 --format=%cs)" "$entity" || fail "entity doc stale"
# entire: armed local-only, never with the defaults (telemetry true, push on)
grep -q "entire enable" "$calls" || fail "onboard did not enable entire in a private repo"
grep -q -- "--skip-push-sessions" "$calls" || fail "entire enabled without --skip-push-sessions — session logs would push"
grep -q -- "--telemetry=false" "$calls" || fail "entire enabled without --telemetry=false — telemetry defaults true"
echo "ok: onboard"

# --- 2. onboard idempotent ---
mkdir -p almanac
"$root/bin/atlas" onboard "$repo" >/dev/null 2>&1 || fail "second onboard not idempotent"
echo "ok: onboard idempotent"

# --- 2c. entire is gated on visibility ---
# Checkpoints are session transcripts. 11 of 46 repos are public, so enabling
# entire there would publish prompts, paths and any secret a session touched.
rm -rf "$repo/.entire"
printf '#!/bin/bash\nprintf "false\\n"\n' >"$sandbox/stubs/gh"
"$root/bin/atlas" onboard "$repo" >/dev/null 2>&1 || fail "onboard (public) exited non-zero"
[[ ! -e "$repo/.entire" ]] || fail "entire enabled in a public repo — checkpoints are session transcripts"
printf '#!/bin/bash\nprintf "true\\n"\n' >"$sandbox/stubs/gh"
echo "ok: entire gated on visibility"

# --- 2b. onboard leaves a terminal onboard/bootstrap manifest ---
# Registration is best-effort by design, so a broken begin/trap pair fails
# silently in production; this is the only thing that would notice.
ob_manifest="$(ls "$ATLAS_RUNS_DIR"/*-atlas-onboard-*.json 2>/dev/null | head -1 || true)"
[[ -n $ob_manifest ]] || fail "no onboard manifest under ATLAS_RUNS_DIR"
grep -q '"kind": "onboard"' "$ob_manifest" || fail "onboard manifest kind != onboard"
grep -q '"operation": "bootstrap"' "$ob_manifest" || fail "onboard manifest operation != bootstrap"
grep -q '"status": "succeeded"' "$ob_manifest" || fail "onboard manifest not succeeded"
echo "ok: onboard manifest"

# --- 3. post-commit cascade fires in background ---
upd_before="$(grep -c "openwiki code --update" "$calls" || true)"
echo x >>README.md
git add . && git commit -qm "trigger cascade"
cascade_log="$HOME/wiki/atlas/cascade.log"
for _ in $(seq 1 50); do
  grep -q " $name done" "$cascade_log" 2>/dev/null && break
  sleep 0.2
done
grep -q " $name done" "$cascade_log" || fail "cascade never finished (see $cascade_log)"
# post-commit defers openwiki and marks the repo; the nightly drain runs it.
[[ "$(grep -c "openwiki code --update" "$calls" || true)" == "$upd_before" ]] || fail "post-commit ran openwiki in the day"
marker="$HOME/.local/state/atlas/openwiki-pending/$name"
[[ -f $marker ]] || fail "post-commit did not mark the repo pending"
ATLAS_LITELLM_KEY=test ATLAS_OPENWIKI_WINDOW_END=0 "$root/scripts/atlas-openwiki-nightly.sh" >/dev/null 2>&1
[[ -f $marker ]] || fail "nightly drain ran outside its window"
ATLAS_LITELLM_KEY=test ATLAS_OPENWIKI_WINDOW_END=24 "$root/scripts/atlas-openwiki-nightly.sh" >/dev/null 2>&1
(( $(grep -c "openwiki code --update" "$calls") > upd_before )) || fail "nightly drain did not run openwiki --update"
[[ ! -f $marker ]] || fail "nightly drain left the marker behind"
[[ -f $entity ]] || fail "cascade lost entity doc"
echo "ok: cascade"

# --- 3b. cascade run leaves a terminal openwiki/cascade manifest ---
manifest=""
for _ in $(seq 1 50); do
  manifest="$(ls "$ATLAS_RUNS_DIR"/*-cascade-*.json 2>/dev/null | head -1 || true)"
  [[ -n $manifest ]] && grep -q '"status": "succeeded"' "$manifest" 2>/dev/null && break
  sleep 0.1
done
[[ -n $manifest ]] || fail "no cascade manifest under ATLAS_RUNS_DIR"
grep -q '"status": "succeeded"' "$manifest" || fail "cascade manifest not succeeded"
grep -q '"exit_code": 0' "$manifest" || fail "cascade manifest exit_code != 0"
grep -q '"kind": "openwiki"' "$manifest" || fail "cascade manifest kind != openwiki"
grep -q '"operation": "cascade"' "$manifest" || fail "cascade manifest operation != cascade"
grep -q '"trigger": "post-commit"' "$manifest" || fail "cascade manifest trigger != post-commit"
echo "ok: cascade manifest"

# --- 3c. stale lock (dead holder) is taken over; the old run is closed abandoned ---
runs="$ATLAS_RUNS_DIR"
# Forge the dead holder's ledger entry: a running openwiki/cascade run whose pid
# (the dead cascade) can never be alive. reconcile at the next cascade's start
# closes it abandoned.
old_rid="20260101T000000Z-cascade-dead-9999999"
python3 - "$runs/$old_rid.json" "$repo" <<'PY' || fail "could not forge old run manifest"
import json, sys
path, repo = sys.argv[1], sys.argv[2]
m = {
  "schema_version": 1, "run_id": "20260101T000000Z-cascade-dead-9999999",
  "kind": "openwiki", "operation": "cascade", "repo": repo, "trigger": "post-commit",
  "status": "running", "pid": 9999999, "started_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z", "finished_at": None, "exit_code": None, "error": None,
}
with open(path, "w") as f: json.dump(m, f, sort_keys=True); f.write("\n")
PY
stale_lock="/tmp/atlas-cascade-$name.lock.d"
mkdir -p "$stale_lock"
echo "9999999" >"$stale_lock/pid"          # a pid that can never be alive
echo "$old_rid" >"$stale_lock/run_id"
echo s >>README.md
git add . && git commit -qm "stale takeover" 2>/dev/null
for _ in $(seq 1 50); do
  grep -q "taking over" "$cascade_log" 2>/dev/null && break
  sleep 0.2
done
grep -q "taking over" "$cascade_log" || fail "cascade did not take over the stale lock"
for _ in $(seq 1 50); do
  grep -q '"status": "abandoned"' "$runs/$old_rid.json" 2>/dev/null && break
  sleep 0.1
done
python3 - "$runs/$old_rid.json" <<'PY' || fail "old run not closed abandoned"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["status"] == "abandoned", m
assert m["pid"] is None, m
assert m["finished_at"] is not None and m["finished_at"].endswith("Z"), m
PY
fresh_manifest=""
for _ in $(seq 1 50); do
  fresh_manifest="$(ls -t "$runs"/*-cascade-*.json | head -1 || true)"
  [[ -n $fresh_manifest && "$fresh_manifest" != "$runs/$old_rid.json" ]] \
    && grep -q '"status": "succeeded"' "$fresh_manifest" 2>/dev/null && break
  sleep 0.1
done
[[ -n $fresh_manifest && "$fresh_manifest" != "$runs/$old_rid.json" ]] \
  || fail "stale takeover produced no new terminal manifest"
grep -q '"exit_code": 0' "$fresh_manifest" || fail "takeover run exit_code != 0"
[[ ! -e "$stale_lock" ]] || fail "stale lock not cleaned up after takeover"
echo "ok: stale lock takeover"

# --- 3d. live lock (alive holder) is skipped, never stolen ---
live_lock="/tmp/atlas-cascade-$name.lock.d"
mkdir -p "$live_lock"
echo "$$" >"$live_lock/pid"          # this test shell is alive during the commit
echo "live-holder" >"$live_lock/run_id"
before_count="$(ls "$ATLAS_RUNS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ' || true)"
echo z >>README.md
git add . && git commit -qm "live lock" 2>/dev/null
for _ in $(seq 1 50); do
  grep -q "already running" "$cascade_log" 2>/dev/null && break
  sleep 0.2
done
grep -q "already running" "$cascade_log" || fail "cascade did not skip a live lock"
[[ -e "$live_lock" ]] || fail "live lock was removed (must never be stolen)"
[[ "$(cat "$live_lock/pid")" == "$$" ]] || fail "live lock pid was modified"
after_count="$(ls "$ATLAS_RUNS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ' || true)"
[[ "$after_count" == "$before_count" ]] || fail "live-lock skip created a manifest"
rm -rf "$live_lock"
echo "ok: live lock skip"

# --- 4. pre-commit shim runs prek when config exists ---
printf '# test hook\n' >>.pre-commit-config.yaml
git add . && git commit -qm "with prek config"
grep -q "prek run" "$calls" || fail "shim did not run prek"
echo "ok: prek shim"

# --- 5. failing pre-commit gate blocks the commit ---
printf '#!/bin/bash\nexit 1\n' >"$sandbox/stubs/prek"
echo y >>README.md
git add .
if git commit -qm "should be blocked" 2>/dev/null; then
  fail "commit passed despite failing prek"
fi
echo "ok: failing gate blocks commit"

# --- 6. repo's own .git/hooks/pre-commit is chained (takes precedence) ---
printf '#!/bin/bash\necho "own-hook" >>"%s"\n' "$calls" >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
git commit -qm "own hook run"
grep -q "own-hook" "$calls" || fail "own .git/hooks/pre-commit not chained"
echo "ok: own pre-commit chained"

# --- 7. onboard --undo detaches the repo ---
"$root/bin/atlas" onboard "$repo" --undo >/dev/null 2>&1 || fail "undo exited non-zero"
[[ -z "$(git config core.hooksPath || true)" ]] || fail "undo left hooksPath set"
echo "ok: onboard undo"

# --- 8. almanac-fold: folds decisions, skips CodeAlmanac's own manual/ ---
fold_repo="$sandbox/foldrepo"
mkdir -p "$fold_repo/almanac/decisions" "$fold_repo/almanac/manual"
printf -- '---\ntitle: "Chose X over Y"\nsummary: "Because Z."\n---\n\nbody\n' \
  >"$fold_repo/almanac/decisions/d.md"
printf -- '---\ntitle: "How To Write"\n---\n\nmanual noise\n' \
  >"$fold_repo/almanac/manual/noise.md"
out="$("$root/scripts/almanac-fold.sh" "$fold_repo")"
grep -q "Chose X over Y" <<<"$out" || fail "fold dropped the decision"
grep -q "Because Z." <<<"$out" || fail "fold dropped the summary"
grep -q "How To Write" <<<"$out" && fail "fold leaked almanac/manual/ content"
[[ -z "$("$root/scripts/almanac-fold.sh" "$sandbox")" ]] || fail "fold not silent without almanac/"
echo "ok: almanac-fold"

# the tag preload is the one piece of the cascade written in JS. Any node with
# global fetch runs it -- unlike openwiki it loads no native module, so this
# deliberately does not use the ABI-pinned interpreter ($HOME is a sandbox here).
# Talks to a throwaway server, so it needs neither the proxy nor a token.
node "$root/test/tag-inject-check.cjs" || fail "tag-inject check"

# The standalone tests. Each stands up its own fake $HOME, so they cannot share
# this file's fixture — but CLAUDE.md calls this script "the full suite", and
# until 2026-09-06 nine of these ran only if someone remembered them by name.
# One had been failing for a month by then (a prune fixture pinned to a date
# that aged past the 30-day window) with nobody looking.
for t in marker-check atlas-pointer atlas-run-state cascade-agents-symlink \
         auto-commit \
         claims-check openwiki-llm-env repo-scan-lock run-state-pid \
         openwiki-authority \
         entity-graph-check stale-after mcp-entity friction lifted-links \
         wiki-lock-cap generated-only \
         session-context prompt-context new-folder-claude-md byte-stable-docs; do
  bash "$root/test/$t-test.sh" >/dev/null 2>&1 || fail "$t-test.sh (re-run it directly for the output)"
  echo "ok: $t"
done

echo "ALL TESTS PASSED"
