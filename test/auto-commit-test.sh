#!/bin/bash
# auto-commit-test.sh — the cascade commits its generated openwiki output only
# where a push cannot publish it, and must not re-fire on its own commit.
#
# Public remote: a silent commit plus a later push would publish unreviewed LLM
# prose, so the human review stays. Private/unknown: nothing can be published, so
# the tree is committed instead of left dirty for the next agent session.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
# Repo names carry the sandbox suffix because the cascade's spinlock lives in
# /tmp, machine-wide: a fixed name would collide with a leaked lock from an
# earlier run, and the test would pass or fail on history instead of on the code.
uniq="$(basename "$sandbox")"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT
mkdir -p "$sandbox/bin" "$sandbox/home/wiki/atlas"

cat >"$sandbox/bin/openwiki" <<'STUB'
#!/bin/bash
[[ "${1:-}" == code ]] || exit 0
mkdir -p openwiki/architecture
printf '# generated %s\n' "$(git rev-parse --short HEAD)" >openwiki/architecture/overview.md
printf '{"command":"update","gitHead":"%s","model":"stub","status":"complete"}\n' "$(git rev-parse HEAD)" >openwiki/.last-update.json
STUB
for stub in gitnexus qmd gitleaks; do printf '#!/bin/bash\nexit 0\n' >"$sandbox/bin/$stub"; done
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

gh_says() {
  printf '#!/bin/bash\nprintf %s\n' "$1" >"$sandbox/bin/gh"
  chmod +x "$sandbox/bin/gh"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# demo\n\nprose\n' >"$repo/CLAUDE.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
}

run_cascade() {
  local repo="$1"
  ( cd "$repo" \
    && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
       ATLAS_SKIP_ROBOREV=1 PROXY_UP=yes SANDBOX="$sandbox" \
       ATLAS_WIKI_LOCK="$sandbox/wiki-gen.lock" \
       "$root/scripts/atlas-cascade.sh" "$repo" ) >/dev/null 2>&1 || true
}

# --- 1. private remote: the generated output is committed ---------------------
gh_says true
repo="$sandbox/priv-$uniq"
make_repo "$repo"
run_cascade "$repo"
# Two commits now: openwiki, then the CLAUDE.md block. Assert on the log, not on
# HEAD, or the second one hides the first.
check "private: the generated output is committed" \
  "yes" "$(git -C "$repo" log --format=%s -3 | grep -qx 'chore(atlas): openwiki regenerated' && echo yes || echo no)"
check "private: the commit carries the anti-loop trailer" \
  "yes" "$(git -C "$repo" log --format=%B -3 | grep -q '^Atlas-Cascade: openwiki$' && echo yes || echo no)"
check "private: the working tree is left clean" \
  "" "$(git -C "$repo" status --porcelain -- openwiki)"

# --- 1b. the cascade's own CLAUDE.md block is committed too -------------------
# The cascade writes the atlas block into CLAUDE.md and used to refuse to commit
# it, so the block lived in no commit in any repo (2026-09-19: a corrected warning
# reached nine repos, committed in none). A block-only change must now be
# committed; a change outside the markers must not be.
gh_says true
repo="$sandbox/md-$uniq"
make_repo "$repo"
cat >"$repo/CLAUDE.md" <<'EOF'
# demo

Human prose.

<!-- atlas:start -->
old block
<!-- atlas:end -->
EOF
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "add block"
perl -i -pe 's/old block/new block/' "$repo/CLAUDE.md"
run_cascade "$repo"
check "private: a block-only CLAUDE.md change is committed" \
  "chore(atlas): generated block in CLAUDE.md" "$(git -C "$repo" log -1 --format=%s)"
check "private: that commit carries its own anti-loop trailer" \
  "yes" "$(git -C "$repo" log -1 --format=%B | grep -q '^Atlas-Cascade: claude-md$' && echo yes || echo no)"

# A human's edit outside the markers is never swept into the bot commit.
perl -i -pe 's/Human prose\./Human prose, edited./' "$repo/CLAUDE.md"
perl -i -pe 's/new block/newer block/' "$repo/CLAUDE.md"
run_cascade "$repo"
check "private: prose outside the markers is left for a human" \
  "yes" "$(git -C "$repo" status --porcelain -- CLAUDE.md | grep -q . && echo yes || echo no)"
check "private: and the bot committed only the openwiki it regenerated" \
  "chore(atlas): openwiki regenerated" "$(git -C "$repo" log -1 --format=%s)"
check "private: no bot commit ever carries the human's prose" \
  "0" "$(git -C "$repo" log --format=%B -5 | grep -c 'Human prose, edited' || true)"

# --- 1c. work the user staged meanwhile stays staged, out of the bot commits --
# Both bot commits used to run `git commit` without a pathspec: anything staged
# while the cascade ran was committed as atlas-cascade.
gh_says true
repo="$sandbox/staged-$uniq"
make_repo "$repo"
printf 'wip\n' >"$repo/user.txt"
git -C "$repo" add user.txt
cat >>"$repo/CLAUDE.md" <<'EOF'
<!-- atlas:start -->
block
<!-- atlas:end -->
EOF
run_cascade "$repo"
check "staged: the user's file is in no bot commit" \
  "0" "$(git -C "$repo" log --format=%H --author=atlas-cascade | while read -r c; do git -C "$repo" show --name-only --format= "$c"; done | grep -c '^user.txt$' || true)"
check "staged: the user's file is still staged" \
  "A  user.txt" "$(git -C "$repo" status --porcelain -- user.txt)"
check "staged: openwiki was still committed" \
  "yes" "$(git -C "$repo" log --format=%s | grep -qx 'chore(atlas): openwiki regenerated' && echo yes || echo no)"

# --- 2. public remote: never commits, leaves the diff for a human -------------
gh_says false
repo="$sandbox/pub-$uniq"
make_repo "$repo"
run_cascade "$repo"
check "public: nothing is committed" \
  "init" "$(git -C "$repo" log -1 --format=%s)"
check "public: the generated output stays dirty for review" \
  "yes" "$(git -C "$repo" status --porcelain -- openwiki | grep -q . && echo yes || echo no)"

# --- 3. the trailer guard -----------------------------------------------------
# Asserted on the hook's own decision, not on a backgrounded cascade: the hook
# fires `nohup caffeinate -i atlas-cascade.sh &`, so stubbing caffeinate makes
# "did it fire?" observable instantly, with no sleep to race against.
gh_says true
repo="$sandbox/loop-$uniq"
make_repo "$repo"
calls="$sandbox/caffeinate.calls"
: >"$calls"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$calls" >"$sandbox/bin/caffeinate"
chmod +x "$sandbox/bin/caffeinate"
fire_hook() {
  ( cd "$repo" && PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" ATLAS_SKIP_ROBOREV=1 \
    bash "$root/hooks/post-commit.pre-entire" ) >/dev/null 2>&1 || true
}
# Control first: without it, a hook that never fires anything would pass.
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "plain"
# The hook backgrounds the call (`nohup ... &`), so a fire is observable only
# once the stub has actually run: poll for it instead of assuming a sleep is long
# enough. Reading too early is the flake this replaces.
fire_hook
fired=no
for _ in $(seq 1 50); do
  grep -q 'atlas-cascade.sh' "$calls" 2>/dev/null && { fired=yes; break; }
  sleep 0.1
done
check "control: a plain commit does fire the cascade" "yes" "$fired"

before="$(grep -c 'atlas-cascade.sh' "$calls" 2>/dev/null)"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty \
  -m "chore(atlas): openwiki regenerated" -m "Atlas-Cascade: openwiki"
fire_hook
# A negative assertion needs a bounded wait, and the control above is what makes
# it mean something: it proves the fire lands well inside this window.
sleep 2
after="$(grep -c 'atlas-cascade.sh' "$calls" 2>/dev/null)"
check "trailer: the cascade does not re-fire on its own commit" "$before" "$after"

if (( fails )); then
  printf '\n%d check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall checks passed\n'
