#!/usr/bin/env bash
# atlas-generated-only.sh — the gate that decides whether the cascade may commit a
# mixed file. Three verdicts, and the two that matter are "no" and "cannot tell".
#
# It exists because the cascade writes the atlas block into CLAUDE.md and then
# refuses to commit it (auto-commit only stages openwiki/), so the block lives in
# no commit anywhere. On 2026-09-19 a corrected warning reached nine repos and was
# committed in none.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/atlas-generated-only.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox" 2>/dev/null || true' EXIT

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

mk_repo() {
  git -C "$sandbox/$1" init -q 2>/dev/null || { mkdir -p "$sandbox/$1"; git -C "$sandbox/$1" init -q; }
}

# --- 1. only the marker block moved: commit ----------------------------------
mk_repo gen
cat >"$sandbox/gen/CLAUDE.md" <<'EOF'
# Demo

Hand-written prose the human owns.

<!-- atlas:start -->
## Atlas
old generated text
<!-- atlas:end -->

Tail prose.
EOF
git -C "$sandbox/gen" add -A
git -C "$sandbox/gen" -c user.email=t@t -c user.name=t commit -qm init
perl -i -pe 's/old generated text/new generated text/' "$sandbox/gen/CLAUDE.md"
"$script" "$sandbox/gen" CLAUDE.md; check "a block-only change is committable" "0" "$?"

# --- 2. a human edited outside the markers: refuse ---------------------------
perl -i -pe 's/Tail prose\./Tail prose, now edited by a human./' "$sandbox/gen/CLAUDE.md"
"$script" "$sandbox/gen" CLAUDE.md; check "prose outside the markers refuses" "1" "$?"

# --- 3. blank-line churn from stripping is not an edit -----------------------
mk_repo blank
printf '# Demo\n\n<!-- atlas:start -->\nx\n<!-- atlas:end -->\n\n\n\n' >"$sandbox/blank/CLAUDE.md"
git -C "$sandbox/blank" add -A
git -C "$sandbox/blank" -c user.email=t@t -c user.name=t commit -qm init
printf '# Demo\n\n<!-- atlas:start -->\ny\n<!-- atlas:end -->\n' >"$sandbox/blank/CLAUDE.md"
"$script" "$sandbox/blank" CLAUDE.md; check "whitespace-only difference is committable" "0" "$?"

# --- 4. an unbalanced block is never "clean" (it would eat the tail) ---------
mk_repo torn
printf '# Demo\n\n<!-- atlas:start -->\nx\n' >"$sandbox/torn/CLAUDE.md"
git -C "$sandbox/torn" add -A
git -C "$sandbox/torn" -c user.email=t@t -c user.name=t commit -qm init
printf '# Demo\n\n<!-- atlas:start -->\nx\n<!-- atlas:end -->\ntail\n' >"$sandbox/torn/CLAUDE.md"
"$script" "$sandbox/torn" CLAUDE.md; check "a torn block refuses" "1" "$?"

# --- 5. no HEAD version: cannot tell, which is not a yes ---------------------
mk_repo fresh
printf '# Demo\n' >"$sandbox/fresh/CLAUDE.md"
"$script" "$sandbox/fresh" CLAUDE.md; check "an untracked file is exit 2" "2" "$?"

if (( fails )); then
  printf '\n%d check(s) failed\n' "$fails"
  exit 1
fi
printf '\nall checks passed\n'
