#!/bin/bash
# atlas-cascade.sh <repo> — post-commit refresh chain:
#   gitnexus analyze → openwiki code --update (wiki-locked) → repo-atlas.sh (ends in qmd update)
# Runs in background from hooks/post-commit. No set -e: one failed stage must not
# kill the rest — every stage logs and the chain continues.
set -uo pipefail

# Bash reads a script by byte offset and re-reads it as it goes, so editing this
# file while a cascade is running makes the running shell resume at a stale
# offset and execute garbage. Observed 2026-09-05: three cascades started
# 16:45-18:45 were still in their openwiki stage when this file was committed
# and all three died with `line 232: e: command not found` / `syntax error near
# unexpected token 'else'`. The atlas stage never reached restore_agents_symlink,
# openwiki ran with AGENTS.md still a symlink to CLAUDE.md, and its two
# concurrent writeFile calls tore the file (see the swap below). The whole body
# therefore lives in a function: bash parses a function definition to its closing
# brace before running a single line of it, so a mid-run edit cannot reach it.
# Body deliberately left unindented -- reindenting 280 lines would bury the fix.
main() {
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${1:?usage: atlas-cascade.sh <repo>}"
name="$(basename "$repo")"
log() { printf '%s %s %s\n' "$(date +%FT%T)" "$name" "$*"; }
fails=0
logfail() { fails=$((fails + 1)); log "$@"; }
helper="$root/scripts/atlas-run-state.sh"
run_id=""

# Opportunistic run-manifest maintenance: reconcile marks runs whose
# owner died as abandoned, prune drops 30-day-old terminal manifests. Best-effort
# only — bookkeeping must never block a cascade.
"$helper" reconcile >/dev/null 2>&1 || true
"$helper" prune >/dev/null 2>&1 || true

# ponytail: mkdir spinlock, one cascade per repo; queueing adds nothing — the next
# commit re-fires it anyway
lock="/tmp/atlas-cascade-$name.lock.d"
if ! mkdir "$lock" 2>/dev/null; then
  # A holder that dies without running its EXIT trap (killed, reboot, session
  # teardown) leaves the lock behind forever, and every later commit logs
  # "already running" and does nothing — the cascade is silently dead for that
  # repo. Observed 2026-07-26: a run started 17:45 never finished, and ~6h of
  # commits refreshed nothing. Liveness-check the holder instead of trusting
  # the directory's existence.
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null; then
    log "skip: cascade already running (pid $holder)"
    exit 0
  fi
  log "WARN: stale lock (pid ${holder:-unknown} gone), taking over"
  # The dead holder's run (if any) never finished — close it as abandoned so the
  # ledger is terminal instead of lingering as "running" until reconcile finds it.
  old_run_id="$(cat "$lock/run_id" 2>/dev/null || true)"
  if [[ -n $old_run_id ]]; then
    "$helper" finish "$old_run_id" --status abandoned --exit-code 1 --error 'cascade owner PID gone' >/dev/null 2>&1 || true
  fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || { log "skip: lost the race for a stale lock"; exit 0; }
fi
echo $$ > "$lock/pid"
# Track this cascade as an openwiki/cascade run manifest; the run_id in
# the lock ties the spinlock to the ledger. Bookkeeping failure never blocks the
# cascade — run_id stays empty and the run goes untracked.
run_id="$( "$helper" begin "cascade-$name" --kind openwiki --operation cascade --repo "$repo" --trigger "${ATLAS_CASCADE_TRIGGER:-post-commit}" --pid $$ 2>/dev/null )" || true
echo "$run_id" > "$lock/run_id"

# EXIT trap cleans the spinlock AND finishes the manifest, preserving the final
# status/exit code: failed (exit 1) when any stage failed, else succeeded.
# openwiki prepares snippets for AGENTS.md and CLAUDE.md from one pre-read of
# each file, then writes both concurrently (dist/ingestion/code-mode.js:129-130).
# Where AGENTS.md is a symlink to CLAUDE.md — the atlas convention, see
# atlas-pointer.sh — those two writeFile calls truncate the same inode and race.
# The shorter CLAUDE snippet lands on the head of the longer AGENTS one and the
# file comes back torn: a beheaded sentence plus two OPENWIKI:END markers.
# Observed 2026-08-16. Swap the symlink for a real copy for the
# duration of the openwiki stage so it sees two distinct files, then put the
# symlink back.
#
# ponytail: restore does not wait for openwiki to be gone. A cascade killed
# mid-stage fires this trap immediately, but its openwiki grandchild is orphaned,
# not killed (verified: an EXIT-only trap runs ~instantly on TERM while the shell
# blocks on a child, and the child survives). That orphan then writes AGENTS.md
# with the symlink back in place — the same race, re-armed. Ceiling accepted: the
# precondition is an operator killing a cascade mid-openwiki, and recovery is one
# `git checkout CLAUDE.md`. Upgrade path if it ever bites: run the stage with its
# own process group and kill the group here before restoring.
agents_link=""
restore_agents_symlink() {
  [[ -n $agents_link ]] || return 0
  rm -f "$repo/AGENTS.md"
  ln -s "$agents_link" "$repo/AGENTS.md"
  agents_link=""
}

cleanup() {
  local rc=$?
  # Before anything else: a cascade killed mid-openwiki must not leave the repo
  # without its AGENTS.md.
  restore_agents_symlink
  rm -rf "$lock"
  if [[ -n $run_id ]]; then
    if (( fails )); then
      "$helper" finish "$run_id" --status failed --exit-code 1 --error "$name: $fails stage(s) failed" >/dev/null 2>&1 || true
      rc=1
    elif (( ${ow_skipped:-0} )); then
      "$helper" finish "$run_id" --status skipped --exit-code 0 >/dev/null 2>&1 || true
    else
      "$helper" finish "$run_id" --status succeeded --exit-code 0 >/dev/null 2>&1 || true
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

log "start"

if command -v gitnexus >/dev/null; then
  (cd "$repo" && gitnexus analyze) >/dev/null 2>&1 && log "gitnexus: ok" || logfail "gitnexus: FAILED"
else
  log "gitnexus: not installed, skipped"
fi

if [[ ${ATLAS_OPENWIKI_DEFER:-} == 1 ]]; then
  # post-commit marked the repo pending; atlas-openwiki-nightly.sh runs this stage
  log "openwiki: deferred to the nightly window"
elif command -v openwiki >/dev/null; then
  # stderr to a file, not /dev/null: "FAILED (env or generation)" cannot tell a
  # 401 from a 422, a 429 or a native-module ABI crash, so every failure became
  # a guess -- 2026-08-16 three of five suspected causes turned out not to exist.
  # Surfaced only when the stage fails; a healthy run stays as quiet as before.
  err="$(mktemp -t atlas-openwiki)"
  # stdout too: it is where openwiki names a page it skipped (see the verdict below)
  out="$(mktemp -t atlas-openwiki-out)"
  # Persistent, timestamped copy of the same stderr. $err is thrown away at the
  # end of the stage and only its last 5 lines are ever logged, which is enough
  # to name a failure but not to explain a run that burns 7h and writes nothing
  # (2026-09-04/05: two runs of 7.9h and 7.4h, 1119 engine calls, gitHead never
  # moved). What that needs is *when* each line arrived, kept for both verdicts.
  owlog="$HOME/wiki/atlas/openwiki-$name.log"
  # Bounded: keep the last ~2000 lines rather than growing without limit.
  if [[ -f $owlog ]] && [[ $(wc -c <"$owlog") -gt 5242880 ]]; then
    tail -2000 "$owlog" >"$owlog.tmp" && mv "$owlog.tmp" "$owlog"
  fi
  printf '=== %s %s start (HEAD %s, pid %s) ===\n' "$(date +%FT%T)" "$name" \
    "$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo none)" $$ >>"$owlog"
  ow_start=$SECONDS
  # Only record where the symlink points. The swap waits for the lock and
  # with-wiki-lock.sh --repo performs it once it holds one: swapping here put a
  # real AGENTS.md in every repo that was merely queued, for hours, so a cascade
  # killed while waiting left the divergence behind instead of an empty wait.
  agents_link=""
  if [[ -L "$repo/AGENTS.md" ]]; then
    agents_link="$(readlink "$repo/AGENTS.md")"
  fi
  # Snapshot HEAD before the stage: openwiki stamps the head it saw into
  # .last-update.json, and a commit landing mid-run would otherwise make a good
  # run look stale. wiki_head_expected is what a successful run must record.
  wiki_head_expected="$(cd "$repo" && git rev-parse HEAD 2>/dev/null || true)"
  # ...but this snapshot is taken before with-wiki-lock.sh queues, and the queue
  # is hours deep: atlas waited 11070s on 2026-09-06 while five commits landed.
  # A run that then generated correctly against the newer HEAD was still logged
  # "wrote nothing", which is how the cascade success rate reached 0/28. Keep
  # the pre-run head too, so the verdict can ask the question that survives a
  # long wait -- did the wiki move? -- instead of one that cannot.
  wiki_head_before="$(grep -o '"gitHead"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' \
    "$repo/openwiki/.last-update.json" 2>/dev/null | grep -o '[0-9a-f]\{7,\}' || true)"
  # openwiki only resumes an interrupted run in its own mode (repository-run.js
  # resumeRepositoryRun); a stranded --init failed every --update after it
  # (hp_laptop_ops, 6/6 since 2026-09-22). Resume what is there.
  ow_mode=--update
  grep -q '"mode"[[:space:]]*:[[:space:]]*"init"' "$repo/openwiki/.run.json" 2>/dev/null && ow_mode=--init
  # subshell isolates the env script's exports and its set -euo pipefail
  for ow_try in 1 2; do
    ow_rc=0
    (source "$root/scripts/openwiki-llm-env.sh" "$repo" \
      && cd "$repo" \
      && "$root/scripts/with-wiki-lock.sh" --repo "$repo" openwiki code "$ow_mode") 2>&1 >"$out" \
      | perl -MPOSIX -pe 'BEGIN{$|=1} $_ = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ ", gmtime) . $_' \
      | tee -a "$owlog" >"$err" || ow_rc=$?
    # A planner that ends its turn without calling submit_plan is a model flake,
    # not a verdict on the repo: traces showed one model emitting its tool calls
    # as XML text in `content`, and another looping on one sentence until
    # max_tokens. openwiki resumes the persisted run, so one more pass is cheap.
    # ponytail: one retry; the model-side fix (parse XML tool calls in the proxy)
    # belongs to the LLM proxy.
    # Same for a page worker that ends without submit_page (B7): the page is
    # restored and skipped, the run is sealed `interrupted` and exits 0, and the
    # skipped page is named only on stdout. Same resume, same single retry.
    (( ow_try == 1 )) || break
    if (( ow_rc != 0 )) && grep -q 'exited without submit_plan' "$err"; then
      log "openwiki: planner ended without submit_plan, retrying once"
    elif (( ow_rc == 0 )) && grep -q 'was restored after its worker exited without submitting' "$out"; then
      log "openwiki: page worker ended without submit_page, retrying once"
    else
      break
    fi
  done
  # openwiki re-scaffolds its GitHub Actions workflow on every --update, not
  # only on init, so deleting it once at onboard never held. That workflow
  # generates in the cloud on openwiki's vendor default model, bypassing
  # openwiki-llm-env.sh entirely — which is how private repos would leave the
  # machine. Delete it every run, failed ones included: it is scaffolded before
  # the LLM is ever called (hp_laptop_ops committed it in 90c0a39).
  rm -f "$repo/.github/workflows/openwiki-update.yml"
  if (( ow_rc == 0 )); then
    # `2>&1 >"$out"` in that order: stderr to the pipe, then stdout to its
    # file. pipefail (set at the top) is what keeps openwiki's exit status as the
    # verdict here -- perl and tee do not fail, so the `if` still tests the run.
    # openwiki's AGENTS snippet is an unconditional template literal
    # (dist/code-mode.js:101) claiming a scheduled GitHub Actions workflow
    # refreshes the wiki. atlas deletes that workflow at onboard and refreshes
    # locally, so the sentence is false for every atlas repo and gets rewritten
    # on every commit. Correct it here rather than patching node_modules, which
    # an openwiki upgrade would silently revert.

    # Exit 0 is not a success signal for this stage. openwiki refuses a run it
    # cannot perform -- e.g. .openwikiignore listing openwiki/, which gates its
    # own output directory read-and-write -- explains itself on stdout, and exits
    # 0 anyway. One repo logged "openwiki: ok" over a wiki frozen at the same
    # gitHead from 2026-07-27 to 2026-08-22 because nothing checked. The receipt
    # openwiki leaves is .last-update.json; read it rather than the exit code.
    wiki_manifest="$repo/openwiki/.last-update.json"
    if [[ ! -f $wiki_manifest ]]; then
      logfail "openwiki: exited 0 but wrote no openwiki/.last-update.json"
    else
      # grep, not jq: jq is not a dependency anywhere else in this cascade.
      wiki_head="$(grep -o '"gitHead"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$wiki_manifest" | grep -o '[0-9a-f]\{7,\}' || true)"
      wiki_status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$wiki_manifest" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
      # Two ways to pass, because HEAD may have moved while this run waited for
      # the machine-wide lock. The wiki is current if it records the head that
      # is checked out now; failing that, it did real work if its head advanced
      # from where the run found it. Only a wiki that is neither current nor
      # moved is the frozen no-op this check exists for (one repo sat at
      # one gitHead from 2026-07-27 to 2026-08-22 while the stage logged "ok").
      # Both ways require the recorded head to be a commit reachable from HEAD:
      # without that, any garbage in the receipt reads as movement.
      head_now="$(cd "$repo" && git rev-parse HEAD 2>/dev/null || true)"
      wiki_fresh=0
      if [[ -z $head_now ]]; then
        # No head to compare against: judging would be guessing, so do not.
        wiki_fresh=1
      elif [[ -n $wiki_head ]] \
        && (cd "$repo" && git merge-base --is-ancestor "$wiki_head" HEAD) 2>/dev/null \
        && [[ $wiki_head == "$head_now" || $wiki_head != "$wiki_head_before" ]]; then
        wiki_fresh=1
      fi
      # A page worker that ends its turn without submit_page gets its page
      # restored and skipped, and one skipped page makes openwiki stamp the whole
      # run `interrupted` at the head it started from and exit 0
      # (repository-run.js finishRepositoryRun). That read as "wrote nothing"
      # while the run had regenerated every other page: 13 of 14 in addocu-pro,
      # 8 of 9 in rudel (2026-10-10/11). The only place it says so is stdout.
      ow_skipped="$(sed -n 's/ was restored after its worker exited without submitting.*//p' "$out" | tr '\n' ' ')"
      if (( ! wiki_fresh )) && [[ -n $ow_skipped ]]; then
        logfail "openwiki: partial run, page worker(s) ended without submit_page, skipped: $ow_skipped"
      elif (( ! wiki_fresh )); then
        logfail "openwiki: exited 0 but wrote nothing (last-update gitHead=${wiki_head:-none}, unmoved from ${wiki_head_before:-none}, HEAD $head_now)"
      elif [[ $wiki_status == "interrupted" ]]; then
        # A partial pass: some pages written, the plan not finished. Worth a
        # loud line -- the wiki is now half old and half new -- but the run did
        # real work, so it is not the silent no-op above.
        logfail "openwiki: partial run (status=interrupted at $wiki_head_expected)${ow_skipped:+, skipped: $ow_skipped}"
      else
        # env-script exports die with the subshell; re-derive.
        ow_branch="$(cd "$repo" && git branch --show-current 2>/dev/null || true)"
        # `! $(grep -q ...)` was the test here until 2026-09-06: grep -q prints
        # nothing, so it expanded to `! ""`, which is always true, and the branch
        # got re-stamped on every pass.
        if [[ -n $ow_branch ]] && ! grep -q '"branch"' "$wiki_manifest"; then
          sed -i '' "/\"gitHead\"/a\\
  \"branch\": \"$ow_branch\",\\
  \"worktree\": \"$([[ -f "$repo/.git" ]] && echo true || echo false)\"," "$wiki_manifest" 2>/dev/null || true
        fi
        log "openwiki: ok"
      fi
    fi
  else
    # ow_rc is captured in the loop above, straight off the pipeline. Without it
    # this line is a guess — 45% of historical failures left stderr empty and
    # read the same as a clean exit.
    if (( ow_rc == 3 )); then
      # openwiki-llm-env.sh refused a non-default branch: by design, not a failure
      ow_skipped=1
      log "openwiki: skipped, repo off its default branch"
    else
      logfail "openwiki: FAILED (env or generation), exit $ow_rc, skipped"
    fi
    # ponytail: last 5 lines. The cause is in the tail (HTTP status, dlopen
    # error); the head is the banner. Raise it if a real failure gets truncated.
    [[ -s $err ]] && tail -5 "$err" | while IFS= read -r l; do log "openwiki: | $l"; done
  fi
  stage_total=$((SECONDS - ow_start))
  # Split the clock. It starts before the lock call, so on a busy machine the
  # total is mostly queue -- 2026-09-07 acquired after 26367s -- and a queued run
  # was indistinguishable from a slow one.
  waited="$(sed -n 's/.*with-wiki-lock: acquired after \([0-9]\{1,\}\)s.*/\1/p' "$owlog" 2>/dev/null | tail -1)" || true
  log "openwiki: stage ${stage_total}s (waited ${waited:-0}s, generated $((stage_total - ${waited:-0}))s, stderr: $owlog)"
  printf '=== %s %s end after %ss ===\n' "$(date +%FT%T)" "$name" "$((SECONDS - ow_start))" >>"$owlog"
  # With the symlink out of the way openwiki writes its real instructions to
  # AGENTS.md and leaves CLAUDE.md a "See AGENTS.md" pointer — the opposite of
  # the atlas convention, where CLAUDE.md is canonical and the pointer would
  # aim the reader back at the same file. Splice the real block over it.
  # Outside the success branch: openwiki writes both blocks at setup, before
  # the first model call (code-mode.js ensureCodeModeRepoSetup), so a failed run
  # leaves them too. Splicing only on success, and dropping the pointer below on
  # failure, emptied the block in 13 repos by 2026-11-15 (atlas in 9fe56e7).
  if [[ -n $agents_link ]]; then
    blk="$(mktemp)"
    awk '/<!-- OPENWIKI:START -->/,/<!-- OPENWIKI:END -->/' "$repo/AGENTS.md" > "$blk"
    # Both markers, exactly once each, before touching the file. The awk below
    # sets skip=1 at START and only clears it at END, so a CLAUDE.md carrying a
    # START with no END would silently truncate everything after it. openwiki's
    # own validation happens to make that unreachable today, but that is a
    # guarantee living in someone else's node_modules — check it here instead.
    c_start="$(grep -c '<!-- OPENWIKI:START -->' "$repo/CLAUDE.md" || true)"
    c_end="$(grep -c '<!-- OPENWIKI:END -->' "$repo/CLAUDE.md" || true)"
    # Three outcomes, not two. An empty $blk means openwiki produced no AGENTS
    # block for this repo — nothing to splice, and nothing wrong. Folding that
    # into the else made every such run log a failed stage and finish the whole
    # cascade as 'failed'; run-tests.sh has failed on exactly this since the
    # splice landed, because its openwiki stub writes nothing by design.
    # Only a real torn CLAUDE.md — a block to splice but markers that are not a
    # clean pair — is a failure.
    if [[ ! -s $blk ]]; then
      log "openwiki: no AGENTS block emitted, nothing to splice"
    elif [[ "$c_start" == 1 && "$c_end" == 1 ]]; then
      tmp="$(mktemp)"
      awk -v bf="$blk" '
        /<!-- OPENWIKI:START -->/ { while ((getline l < bf) > 0) print l; close(bf); skip = 1; next }
        /<!-- OPENWIKI:END -->/   { skip = 0; next }
        !skip
      ' "$repo/CLAUDE.md" > "$tmp"
      cat "$tmp" > "$repo/CLAUDE.md"
      rm -f "$tmp"
      log "openwiki: spliced AGENTS block into canonical CLAUDE.md"
    else
      logfail "openwiki: CLAUDE.md markers not a clean pair (start=$c_start end=$c_end), left as written"
    fi
    rm -f "$blk"
  fi

  # Outside the success branch on purpose. openwiki rewrites AGENTS.md before it
  # can fail (a mid-run "Cannot advance page coverage" left a repo dirty
  # on 2026-09-05), and the false sentence it leaves behind outlives the failure:
  # a symlinked AGENTS.md is discarded by restore below, a real one is not, and
  # every later commit re-dirties the tree. Correcting it always costs one perl
  # pass over two files that are usually already correct.
  for f in "$repo/CLAUDE.md" "$repo/AGENTS.md"; do
    [[ -f $f && ! -L $f ]] || continue
    perl -i -pe 's/^The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki\./The local atlas post-commit cascade (see atlas ARCHITECTURE.md) refreshes the repository wiki./' "$f"
  done
  # openwiki points CLAUDE.md at its instructions with a bare `@AGENTS.md`
  # include — right for its own layout, where AGENTS.md is a real file
  # (some repos), wrong here: restore below points AGENTS.md back at
  # CLAUDE.md, so the file includes itself. The splice covers the success path;
  # a failed run reaches this instead, which is how two repos came
  # back carrying it. Gated on $agents_link so the regular layout keeps its
  # legitimate pointer.
  if [[ -n $agents_link && -f $repo/CLAUDE.md && ! -L $repo/CLAUDE.md ]] \
     && grep -qE '^[[:space:]]*@AGENTS[.]md[[:space:]]*$' "$repo/CLAUDE.md"; then
    perl -i -ne 'print unless /^[[:space:]]*\@AGENTS[.]md[[:space:]]*$/' "$repo/CLAUDE.md"
    log "openwiki: dropped the @AGENTS.md self-include from CLAUDE.md (AGENTS.md points at it)"
  fi

  restore_agents_symlink
  rm -f "$err" "$out"

  # Outside every verdict branch above on purpose: a wiki that was
  # not verified has to say so on its own pages, and the runs that most need the
  # stamp are exactly the ones that took a failure branch and would have skipped
  # it. Cheap (a frontmatter rewrite), idempotent, and self-clearing on the next
  # clean run.
  if [[ -x $root/scripts/openwiki-authority.sh ]]; then
    log "$("$root/scripts/openwiki-authority.sh" "$repo" 2>&1 | tail -1)"
  fi
else
  log "openwiki: not installed, skipped"
fi

# The atlas back-reference block: without it a repo's CLAUDE.md never tells a
# cold agent that the machine-wide wiki exists. atlas-pointer.sh was only ever
# called by new-folder-claude-md.sh, so 2 of 41 onboarded repos carried it.
# Runs after openwiki restored the symlink, never during the swap: the pointer
# rewrites CLAUDE.md in place (cat >, inode preserved) and a stand-in AGENTS.md
# would be left holding a stale copy. Idempotent — only the region between
# <!-- atlas:start --> and <!-- atlas:end --> is ever touched, so an unchanged
# block leaves the file byte-identical and the repo undirtied.
if [[ -f "$repo/.atlas-ignore" ]]; then
  log "atlas-pointer: .atlas-ignore present, skipped"
else
  # Keep stderr: the pointer refuses to rewrite a CLAUDE.md whose atlas markers
  # are not a clean pair, and that refusal is the only warning a torn file gets.
  # Swallowing it turns a diagnosis into a bare "FAILED".
  if pointer_err="$("$root/scripts/atlas-pointer.sh" "$repo" 2>&1 >/dev/null)"; then
    log "atlas-pointer: ok"
  else
    logfail "atlas-pointer: FAILED"
    [[ -n $pointer_err ]] && printf '%s\n' "$pointer_err" | while IFS= read -r l; do log "atlas-pointer: | $l"; done
  fi
fi

"$root/scripts/repo-atlas.sh" >/dev/null 2>&1 && log "repo-atlas+qmd: ok" || logfail "repo-atlas: FAILED"

# Public remote: never auto-commit — a silent commit plus a later push would
# publish unreviewed LLM prose, and this is the only place a human sees it
# first. Private/unknown (deny-by-default, as openwiki-llm-env.sh picks the
# model): a push cannot publish, so commit instead of leaving the tree dirty.
if command -v gh >/dev/null; then
  is_private="$(cd "$repo" && gh repo view --json isPrivate -q .isPrivate 2>/dev/null)"
  if [[ "$is_private" == "false" ]]; then
    for d in openwiki almanac; do
      [[ -d "$repo/$d" ]] || continue
      if command -v gitleaks >/dev/null && ! gitleaks detect --no-git --source "$repo/$d" >/dev/null 2>&1; then
        log "WARN: gitleaks found possible secrets in $d/ — review before committing (public remote)"
      fi
      if grep -rlqF "$HOME" "$repo/$d" 2>/dev/null; then
        log "WARN: $d/ contains local path ($HOME) — review before committing (public remote)"
      fi
    done
  else
    # Only openwiki/ — that is what this process writes. almanac/ belongs to
    # CodeAlmanac on its own schedule, and staging it here would sweep another
    # tool's work in progress.
    if [[ -d "$repo/openwiki" ]]; then
      git -C "$repo" add -- openwiki 2>/dev/null || true
      # Commit with a pathspec: only openwiki/ goes in, whatever the user has
      # staged in the meantime stays staged and out of this commit.
      if ! git -C "$repo" diff --cached --quiet -- openwiki 2>/dev/null; then
        # Trailer contract: hooks/post-commit.pre-entire skips a commit carrying
        # it, so the cascade does not fire again on its own output.
        if git -C "$repo" -c user.name=atlas-cascade -c user.email=atlas-cascade@localhost \
             commit -q -m "chore(atlas): openwiki regenerated" \
             -m "Atlas-Cascade: openwiki" -- openwiki 2>/dev/null; then
          log "auto-commit: openwiki regenerated (private/unknown)"
        else
          log "auto-commit: git commit failed, tree left dirty"
        fi
      fi
    fi

    # This process also writes the atlas block into CLAUDE.md, and used to refuse
    # to commit it: the block lived in no commit, anywhere. A corrected warning
    # reached nine repos on 2026-09-19 and was committed in none. CLAUDE.md is
    # mixed, so commit only when nothing outside the markers moved.
    if [[ -f "$repo/CLAUDE.md" ]] && ! git -C "$repo" diff --quiet -- CLAUDE.md 2>/dev/null; then
      if "$root/scripts/atlas-generated-only.sh" "$repo" CLAUDE.md; then
        git -C "$repo" add -- CLAUDE.md 2>/dev/null || true
        if ! git -C "$repo" diff --cached --quiet -- CLAUDE.md 2>/dev/null; then
          if git -C "$repo" -c user.name=atlas-cascade -c user.email=atlas-cascade@localhost \
               commit -q -m "chore(atlas): generated block in CLAUDE.md" \
               -m "Atlas-Cascade: claude-md" -- CLAUDE.md 2>/dev/null; then
            log "auto-commit: CLAUDE.md (generated blocks only)"
          else
            log "auto-commit: CLAUDE.md commit failed, left dirty"
          fi
        fi
      else
        log "auto-commit: CLAUDE.md skipped, changes outside the markers"
      fi
    fi
  fi
fi

# loud failure (mirrors the cloud-fallback rule): background chain must not fail silently
if ((fails)); then
  osascript -e "display notification \"$name: $fails stage(s) FAILED — see ~/wiki/atlas/cascade.log\" with title \"atlas cascade\"" 2>/dev/null || true
fi

log "done (${SECONDS}s)"
}

# `; exit $?` on the same line, not the next one: bash reads the whole list before
# running it, so once main returns there is no further read from a file that may
# have changed underneath. A bare `main "$@"` still leaves that one read exposed.
main "$@"; exit $?
