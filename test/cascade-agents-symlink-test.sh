#!/bin/bash
# atlas-cascade.sh must not let openwiki shred CLAUDE.md in repos where
# AGENTS.md is a symlink to it (the atlas convention, see atlas-pointer.sh).
#
# openwiki writes AGENTS.md and CLAUDE.md with two different snippets and does
# it concurrently (dist/ingestion/code-mode.js:129-130). One symlink means one
# inode and two racing truncating writes; one repo came back on 2026-08-16
# with a beheaded sentence and two OPENWIKI:END markers. The cascade now hides
# the symlink for the duration of the stage and splices the real block back into
# CLAUDE.md, which is canonical here.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT

mkdir -p "$sandbox/bin" "$sandbox/home/wiki/atlas"

# The stub writes exactly what openwiki writes: the full instructions into
# AGENTS.md, a bare "see AGENTS.md" pointer into CLAUDE.md. Sequential rather
# than concurrent — the race is not what we assert on, the shared inode is, and
# sequential writes make the failure deterministic instead of flaky.
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
# The cascade breaks the shared inode before calling us. Assert from in here —
# the only place that can see mid-stage state — that it left a readable regular
# file behind rather than a hole, and that the two paths really are distinct.
[[ -f AGENTS.md && ! -L AGENTS.md ]] || touch "$SANDBOX/BROKEN-agents-missing-midstage"
[[ "$(stat -f %i AGENTS.md 2>/dev/null)" != "$(stat -f %i CLAUDE.md 2>/dev/null)" ]] \
  || touch "$SANDBOX/BROKEN-same-inode-midstage"
refuses_torn() {
  # Real openwiki validates markers per file and refuses one with an unbalanced
  # pair rather than rewriting it. Mirror that PER FILE, not globally: a global
  # refusal leaves AGENTS.md unwritten, the extracted block empty, and the
  # cascade's `-s $blk` test short-circuits before the marker guard is ever
  # reached — which makes the torn-marker case pass whether the guard exists or
  # not. Per-file refusal is what puts a good block in AGENTS.md and a torn
  # CLAUDE.md in front of the splice, so the guard is the only thing protecting
  # the tail prose.
  local f="$1" s e
  [[ -f "$f" ]] || return 1
  s=$(grep -c '<!-- OPENWIKI:START -->' "$f"); e=$(grep -c '<!-- OPENWIKI:END -->' "$f")
  [[ "$s" != "$e" ]]
}
write_block() {
  local f="$1" body="$2" tmp blk
  # Only CLAUDE.md, deliberately. After the swap AGENTS.md is a copy of the torn
  # CLAUDE.md, so a symmetric refusal would skip both and empty the block again.
  # Today's openwiki does refuse both, which is exactly why the guard is
  # currently unreachable in production — the guard defends against that
  # validation changing in a dependency we do not control. This stub models that
  # future: a good block in AGENTS.md, a torn CLAUDE.md, splice about to run.
  [[ "$f" == CLAUDE.md ]] && refuses_torn "$f" && return 0
  tmp="$(mktemp)"; blk="$(mktemp)"
  # Body goes through a file, never `awk -v`: BSD awk (the macOS default)
  # rejects a newline inside a -v assignment, and these bodies are multi-line.
  # Same reason atlas-pointer.sh:37-38 does it this way.
  printf '<!-- OPENWIKI:START -->\n\n## OpenWiki\n\n%s\n\n<!-- OPENWIKI:END -->\n' "$body" > "$blk"
  if grep -q '<!-- OPENWIKI:START -->' "$f" 2>/dev/null; then
    awk -v bf="$blk" '
      /<!-- OPENWIKI:START -->/ { while ((getline l < bf) > 0) print l; close(bf); skip = 1; next }
      /<!-- OPENWIKI:END -->/   { skip = 0; next }
      !skip
    ' "$f" > "$tmp"
  else
    { cat "$f" 2>/dev/null; printf '\n'; cat "$blk"; } > "$tmp"
  fi
  cat "$tmp" > "$f"
  rm -f "$tmp" "$blk"
}
write_block AGENTS.md 'This repository has a generated `openwiki/` evidence index. It is optional just-in-time context, not required startup reading.

The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki. Do not hand-edit generated OpenWiki pages unless explicitly asked; prefer updating source code/docs and letting OpenWiki regenerate.'
write_block CLAUDE.md '@AGENTS.md'
mkdir -p .github/workflows && touch .github/workflows/openwiki-update.yml
# The cascade now reads this receipt instead of trusting the exit code, so a
# stub that writes pages but no manifest is no longer a successful run.
mkdir -p openwiki
printf '{"updatedAt":"2026-01-01T00:00:00.000Z","command":"update","gitHead":"%s","model":"stub","status":"complete"}\n' \
  "$(git rev-parse HEAD)" >openwiki/.last-update.json
STUB

# Everything else the cascade shells out to. gitnexus and repo-atlas are not
# under test; gh reports a private repo so the public-leak scan stays quiet.
# osascript too: run standalone, the failure cases raised 15 real desktop
# banners per run.
for stub in gitnexus qmd gitleaks osascript; do
  printf '#!/bin/bash\nexit 0\n' >"$sandbox/bin/$stub"
done
printf '#!/bin/bash\nprintf true\n' >"$sandbox/bin/gh"
printf '#!/bin/bash\nexit 0\n' >"$sandbox/bin/curl"
printf '#!/bin/bash\nprintf fake-key\n' >"$sandbox/bin/pass"
chmod +x "$sandbox/bin"/*

fails=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
    fails=$((fails + 1))
  fi
}

make_repo() {
  local repo="$1" agents_mode="$2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# demo\n\nHand-written prose that must survive.\n\n<!-- OPENWIKI:START -->\n\n## OpenWiki\n\nold\n\n<!-- OPENWIKI:END -->\n' > "$repo/CLAUDE.md"
  if [[ "$agents_mode" == symlink ]]; then
    ln -s CLAUDE.md "$repo/AGENTS.md"
  else
    printf '# demo agents\n' > "$repo/AGENTS.md"
  fi
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
}

run_cascade() {
  local repo="$1"
  # ATLAS_SKIP_ROBOREV: roborev hands the commit to a launchd daemon holding the
  # real HOME and PATH, which no sandbox can contain.
  ( cd "$repo" \
    && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
       ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
       ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
       "$root/scripts/atlas-cascade.sh" "$repo" ) >/dev/null 2>&1 || true
}

# --- case 1: AGENTS.md is a symlink to CLAUDE.md (the tear) ---
repo="$sandbox/symlinked"
make_repo "$repo" symlink
run_cascade "$repo"

check "symlink repo: AGENTS.md is still a symlink" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo MISSING)"
check "symlink repo: exactly one OPENWIKI:END" \
  "1" "$(grep -c '<!-- OPENWIKI:END -->' "$repo/CLAUDE.md")"
check "symlink repo: exactly one OPENWIKI:START" \
  "1" "$(grep -c '<!-- OPENWIKI:START -->' "$repo/CLAUDE.md")"
check "symlink repo: CLAUDE.md carries the real block, not the self-pointer" \
  "yes" "$(grep -q 'generated .openwiki/. evidence index' "$repo/CLAUDE.md" && echo yes || echo no)"
check "symlink repo: no pointer aimed back at itself" \
  "no" "$(grep -qE 'See \[AGENTS[.]md\]|@AGENTS[.]md' "$repo/CLAUDE.md" && echo yes || echo no)"
check "symlink repo: GHA sentence corrected to the atlas cascade" \
  "yes" "$(grep -q 'local atlas post-commit cascade' "$repo/CLAUDE.md" && echo yes || echo no)"
check "symlink repo: prose outside the markers survived" \
  "yes" "$(grep -q 'Hand-written prose that must survive' "$repo/CLAUDE.md" && echo yes || echo no)"
check "symlink repo: scaffolded GHA workflow deleted" \
  "no" "$([[ -f "$repo/.github/workflows/openwiki-update.yml" ]] && echo yes || echo no)"
check "symlink repo: AGENTS.md readable throughout the openwiki stage" \
  "no" "$([[ -f "$sandbox/BROKEN-agents-missing-midstage" ]] && echo yes || echo no)"
check "symlink repo: AGENTS.md and CLAUDE.md were distinct inodes mid-stage" \
  "no" "$([[ -f "$sandbox/BROKEN-same-inode-midstage" ]] && echo yes || echo no)"

# --- case 2: AGENTS.md is a real file — openwiki's own layout, left alone ---
repo="$sandbox/regular"
make_repo "$repo" regular
run_cascade "$repo"

check "regular repo: AGENTS.md is not a symlink" \
  "no" "$([[ -L "$repo/AGENTS.md" ]] && echo yes || echo no)"
check "regular repo: AGENTS.md keeps the real block" \
  "yes" "$(grep -q 'generated .openwiki/. evidence index' "$repo/AGENTS.md" && echo yes || echo no)"
check "regular repo: CLAUDE.md keeps openwiki's legitimate @AGENTS.md include" \
  "yes" "$(grep -q '@AGENTS[.]md' "$repo/CLAUDE.md" && echo yes || echo no)"

# --- case 3: CLAUDE.md already has a torn marker pair (START, no END) ---
# The splice awk skips from START to END; with no END it would eat the rest of
# the file. The cascade must refuse to splice and leave the file alone.
repo="$sandbox/torn"
make_repo "$repo" symlink
printf '# demo\n\nHand-written prose that must survive.\n\n<!-- OPENWIKI:START -->\n\n## OpenWiki\n\nold\n\nTail prose after a missing END.\n' > "$repo/CLAUDE.md"
run_cascade "$repo"

check "torn repo: tail prose after the missing END survived" \
  "yes" "$(grep -q 'Tail prose after a missing END' "$repo/CLAUDE.md" && echo yes || echo no)"
check "torn repo: leading prose survived" \
  "yes" "$(grep -q 'Hand-written prose that must survive' "$repo/CLAUDE.md" && echo yes || echo no)"
check "torn repo: AGENTS.md symlink restored" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo MISSING)"

# --- case 4: openwiki fails mid-stage — the symlink must come back anyway ---
repo="$sandbox/failing"
make_repo "$repo" symlink
printf '#!/bin/bash\nmkdir -p .github/workflows && touch .github/workflows/openwiki-update.yml\nexit 1\n' >"$sandbox/bin/openwiki"
chmod +x "$sandbox/bin/openwiki"
run_cascade "$repo"

check "failed openwiki: AGENTS.md symlink restored" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo MISSING)"
# openwiki scaffolds the workflow before it fails, so a success-only delete
# left it to be committed and run in the cloud (hp_laptop_ops 90c0a39).
check "failed openwiki: scaffolded GHA workflow deleted anyway" \
  "no" "$([[ -f "$repo/.github/workflows/openwiki-update.yml" ]] && echo yes || echo no)"

# --- case 4b: openwiki rewrites CLAUDE.md's block, then fails ---
# The gap the 2026-09-18 atlas cascade fell into: the splice that replaces
# CLAUDE.md's block runs only on success, so a failure left openwiki's bare
# `@AGENTS.md` include in a file the restored symlink points back at.
repo="$sandbox/failing-selfpointer"
make_repo "$repo" symlink
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
perl -i -pe 's/^old$/\@AGENTS.md/' CLAUDE.md
exit 1
STUB
chmod +x "$sandbox/bin/openwiki"
run_cascade "$repo"

check "failed after self-pointer: AGENTS.md symlink restored" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo MISSING)"
check "failed after self-pointer: no self-include left in CLAUDE.md" \
  "no" "$(grep -q '@AGENTS[.]md' "$repo/CLAUDE.md" && echo yes || echo no)"
check "failed after self-pointer: prose outside the markers survived" \
  "yes" "$(grep -q 'Hand-written prose that must survive' "$repo/CLAUDE.md" && echo yes || echo no)"
check "failed after self-pointer: markers still a clean pair" \
  "1" "$(grep -c '<!-- OPENWIKI:START -->' "$repo/CLAUDE.md")"

# --- case 4c: openwiki writes both blocks at setup, then fails ---
# Real openwiki writes AGENTS.md's instructions and CLAUDE.md's `@AGENTS.md`
# before the first model call. Dropping the pointer without splicing left an
# empty block in 13 repos (atlas 9fe56e7, 2026-11-11).
repo="$sandbox/failing-after-setup"
make_repo "$repo" symlink
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
perl -0pi -e 's/<!-- OPENWIKI:START -->.*?<!-- OPENWIKI:END -->/<!-- OPENWIKI:START -->\nUse openwiki_search.\n<!-- OPENWIKI:END -->/s' AGENTS.md
perl -i -pe 's/^old$/\@AGENTS.md/' CLAUDE.md
exit 1
STUB
chmod +x "$sandbox/bin/openwiki"
run_cascade "$repo"

check "failed after setup: real block spliced into CLAUDE.md" \
  "yes" "$(grep -q 'Use openwiki_search' "$repo/CLAUDE.md" && echo yes || echo no)"
check "failed after setup: no self-include left in CLAUDE.md" \
  "no" "$(grep -q '@AGENTS[.]md' "$repo/CLAUDE.md" && echo yes || echo no)"

# --- case 5: openwiki exits 0 without writing anything ---
# A real failure (one repo, 2026-07-27..08-22): .openwikiignore listed
# openwiki/, so the agent could neither read nor write its own output directory,
# refused the run, and exited 0. The cascade logged "openwiki: ok" for 26 days.
# A stage that reports success must have the receipt to back it.
repo="$sandbox/silent-noop"
make_repo "$repo" regular
printf '#!/bin/bash\nexit 0\n' >"$sandbox/bin/openwiki"
chmod +x "$sandbox/bin/openwiki"
silent_log="$sandbox/silent.log"
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$silent_log" 2>&1 || true

check "silent no-op: not reported as ok" \
  "no" "$(grep -q 'openwiki: ok' "$silent_log" && echo yes || echo no)"
check "silent no-op: reported as writing nothing" \
  "yes" "$(grep -q 'openwiki: exited 0 but wrote no' "$silent_log" && echo yes || echo no)"

# --- case 6: openwiki writes a manifest, but for an older commit ---
# A run can leave a stale receipt behind (an interrupted earlier pass, a wiki
# restored from git). Matching the head this cascade started from is what proves
# the stage did work for *this* commit.
repo="$sandbox/stale-head"
make_repo "$repo" regular
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
mkdir -p openwiki
printf '{"gitHead":"0000000000000000000000000000000000000000","status":"complete"}
'   >openwiki/.last-update.json
STUB
chmod +x "$sandbox/bin/openwiki"
stale_log="$sandbox/stale.log"
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$stale_log" 2>&1 || true

check "stale head: not reported as ok" \
  "no" "$(grep -q 'openwiki: ok' "$stale_log" && echo yes || echo no)"
check "stale head: reported as writing nothing" \
  "yes" "$(grep -q 'openwiki: exited 0 but wrote nothing' "$stale_log" && echo yes || echo no)"

# --- case 6a: same stale receipt, but openwiki said it skipped a page ---
# One page worker ending without submit_page stamps the run interrupted at the
# old head. The run still regenerated the other pages; say which one it lost.
repo="$sandbox/skipped-page"
make_repo "$repo" regular
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
mkdir -p openwiki
printf '{"gitHead":"0000000000000000000000000000000000000000","status":"interrupted"}
'   >openwiki/.last-update.json
echo "/openwiki/a/b.md was restored after its worker exited without submitting. It was skipped for this update and will be reconsidered on the next update."
STUB
chmod +x "$sandbox/bin/openwiki"
skip_log="$sandbox/skip.log"
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$skip_log" 2>&1 || true

check "skipped page: named, not reported as writing nothing" \
  "yes" "$(grep -q 'partial run, page worker(s) ended without submit_page, skipped: /openwiki/a/b.md' "$skip_log" && echo yes || echo no)"
check "skipped page: still not ok" \
  "no" "$(grep -qE 'openwiki: ok|wrote nothing' "$skip_log" && echo yes || echo no)"

# --- case 6b: HEAD moved while the run waited for the machine-wide wiki lock ---
# The queue is hours deep -- atlas waited 11070s on 2026-09-06 -- so commits land
# between the cascade snapshotting HEAD and openwiki actually running. Judging
# the receipt against that pre-wait snapshot failed every such run for doing
# exactly the right thing, which is how the cascade success rate reached 0/28.
# The receipt has to be judged on whether the wiki moved to a real commit.
repo="$sandbox/head-moved"
make_repo "$repo" regular
mkdir -p "$repo/openwiki"
printf '{"gitHead":"%s","status":"complete"}\n' "$(git -C "$repo" rev-parse HEAD)" \
  >"$repo/openwiki/.last-update.json"
# A commit lands during the stage, and openwiki records the head it really saw.
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
printf 'landed mid-stage
' >> README.md
git add -A && git -c user.email=t@t -c user.name=t commit -qm "during the wait"
mkdir -p openwiki
printf '{"gitHead":"%s","status":"complete"}
' "$(git rev-parse HEAD)"   >openwiki/.last-update.json
STUB
chmod +x "$sandbox/bin/openwiki"
moved_log="$sandbox/moved.log"
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$moved_log" 2>&1 || true

check "head moved during the wait: reported as ok" \
  "yes" "$(grep -q 'openwiki: ok' "$moved_log" && echo yes || echo no)"
check "head moved during the wait: not reported as writing nothing" \
  "no" "$(grep -q 'openwiki: exited 0 but wrote nothing' "$moved_log" && echo yes || echo no)"

# --- case 7: openwiki writes the false GHA sentence, then fails ---
# A real repo, 2026-09-05: openwiki rewrote AGENTS.md and only then died
# ("Cannot advance page coverage ..."). The correction used to live in the
# success branch, so the false sentence stayed in a real (non-symlinked)
# AGENTS.md, which nothing restores, and every later commit re-dirtied the tree.
repo="$sandbox/failing-after-write"
make_repo "$repo" regular
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
printf '\nThe scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki.\n' >> AGENTS.md
exit 1
STUB
chmod +x "$sandbox/bin/openwiki"
run_cascade "$repo"

check "failed after write: false GHA sentence corrected in real AGENTS.md" \
  "no" "$(grep -q 'scheduled OpenWiki GitHub Actions workflow' "$repo/AGENTS.md" && echo yes || echo no)"
check "failed after write: corrected to the atlas cascade" \
  "yes" "$(grep -q 'local atlas post-commit cascade' "$repo/AGENTS.md" && echo yes || echo no)"

# --- case 8: the swap waits for the lock ------------------------------------
# The lock test proves the mechanism; this proves the cascade is wired to it. A
# repo queued behind the machine-wide lock must keep its AGENTS.md a symlink:
# the runs that die while waiting are exactly the ones that used to be left
# holding a real copy, which is what manufactured the divergence.
repo="$sandbox/queued"
make_repo "$repo" symlink
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
# Sees the swapped state: mid-stage the stand-in must be a real file, and this
# case would otherwise pass whether the swap ran under the lock or not at all.
[[ -f AGENTS.md && ! -L AGENTS.md ]] || touch "$SANDBOX/BROKEN-not-swapped-midstage"
mkdir -p openwiki
printf '{"gitHead":"%s","status":"complete"}\n' "$(git rev-parse HEAD)" >openwiki/.last-update.json
STUB
chmod +x "$sandbox/bin/openwiki"

( exec 9>"$sandbox/wiki-gen.lock"; python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'; sleep 6 ) &
holder=$!
sleep 1
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$sandbox/queued.log" 2>&1 &
cascade_pid=$!
sleep 2

check "queued repo: AGENTS.md is still a symlink while it waits" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo NOT-A-SYMLINK)"

wait "$holder" 2>/dev/null || true
wait "$cascade_pid" 2>/dev/null || true

check "queued repo: the swap happened inside the stage, not before it" \
  "no" "$([[ -f "$sandbox/BROKEN-not-swapped-midstage" ]] && echo yes || echo no)"
check "queued repo: AGENTS.md symlink restored at the end" \
  "CLAUDE.md" "$(readlink "$repo/AGENTS.md" 2>/dev/null || echo MISSING)"
# The stage clock starts before the lock call, so a queued run's total is mostly
# queue. Both numbers, and a non-zero wait, are the point: without them a queued
# run and a slow one are the same line in the log.
check "queued repo: the stage log separates the wait from the generation" \
  "yes" "$(grep -qE 'openwiki: stage [0-9]+s \(waited [1-9][0-9]*s, generated [0-9]+s' "$sandbox/queued.log" && echo yes || echo no)"

# --- case: a failing openwiki records its exit status ------------------------
# Most openwiki failures leave stderr empty, so the FAILED line is often the only
# evidence there is. Without the status it is a guess: a run killed by a signal
# (143) reads identically to one that exited 1 having written nothing.
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
exit 7
STUB
chmod +x "$sandbox/bin/openwiki"
repo="$sandbox/exitcode"
make_repo "$repo" symlink
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$sandbox/exitcode.log" 2>&1 || true

check "failing openwiki: the FAILED line carries its exit status" \
  "yes" "$(grep -q 'openwiki: FAILED (env or generation), exit 7' "$sandbox/exitcode.log" && echo yes || echo no)"

# --- case: the submit_plan flake gets one retry, other failures none ----------
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
echo x >>"$SANDBOX/ow-calls"
[[ -n ${OW_FLAKE:-} ]] && echo 'Repository planning worker exited without submit_plan.' >&2
exit 1
STUB
chmod +x "$sandbox/bin/openwiki"
repo="$sandbox/flake"
make_repo "$repo" symlink
rm -f "$sandbox/ow-calls"; OW_FLAKE=1 run_cascade "$repo"
check "submit_plan flake: openwiki retried once" "2" "$(wc -l <"$sandbox/ow-calls" | tr -d ' ')"
rm -f "$sandbox/ow-calls"; run_cascade "$repo"
check "other failure: openwiki not retried" "1" "$(wc -l <"$sandbox/ow-calls" | tr -d ' ')"

# --- case: an interrupted --init is resumed as --init --------------------------
# openwiki refuses an --update while an init run is persisted, so a cascade that
# always passed --update failed that repo forever (hp_laptop_ops, 2026-09-22).
cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] && printf '%s\n' "$2" >"$SANDBOX/ow-mode"
exit 0
STUB
chmod +x "$sandbox/bin/openwiki"
repo="$sandbox/initrun"
make_repo "$repo" symlink
mkdir -p "$repo/openwiki" && printf '{"mode": "init", "phase": "generating"}\n' >"$repo/openwiki/.run.json"
run_cascade "$repo"
check "interrupted init: cascade resumes with --init" "--init" "$(cat "$sandbox/ow-mode" 2>/dev/null)"
rm -f "$repo/openwiki/.run.json"
run_cascade "$repo"
check "no persisted init: cascade runs --update" "--update" "$(cat "$sandbox/ow-mode" 2>/dev/null)"

# --- case: a branch refusal is a skipped run, not a failed one ----------------
repo="$sandbox/offbranch"
make_repo "$repo" symlink
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$repo" switch -q -c feature
# The ledger verdict needs every other stage clean. repo-atlas cannot scan a fake
# HOME, so hold its lock with a live pid and it skips (exit 0) deterministically.
mkdir -p "$sandbox/scan.lock.d" && echo $$ >"$sandbox/scan.lock.d/pid"
runs="$sandbox/home/.local/state/atlas/runs"
rm -rf "$runs"; export ATLAS_RUNS_DIR="$runs"  # the suite exports its own
( cd "$repo" \
  && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
     ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes \
     ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" SANDBOX="$sandbox" \
     ATLAS_SCAN_LOCK="$sandbox/scan.lock.d" \
     "$root/scripts/atlas-cascade.sh" "$repo" ) >"$sandbox/offbranch.log" 2>&1 || true
check "off-branch repo: logged as skipped" \
  "yes" "$(grep -q 'openwiki: skipped, repo off its default branch' "$sandbox/offbranch.log" && echo yes || echo no)"
check "off-branch repo: ledger records skipped, not failed" \
  "skipped" "$(python3 -c 'import json,glob,sys; print(*sorted({json.load(open(f))["status"] for f in glob.glob(sys.argv[1]+"/*.json") if json.load(open(f)).get("operation")=="cascade"}))' "$runs")"

if (( fails )); then
  [[ -f $sandbox/offbranch.log ]] && sed -n '1,40p' "$sandbox/offbranch.log"
  printf '\n%d check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall checks passed\n'
