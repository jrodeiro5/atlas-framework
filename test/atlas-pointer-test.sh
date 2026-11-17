#!/bin/bash
# atlas-pointer-test.sh — the pointer must never delete prose it did not write.
#
# The awk that swaps the block sets skip=1 at <!-- atlas:start --> and only clears
# it at <!-- atlas:end -->. Against a file missing the end marker that is a silent
# truncation to EOF. Not hypothetical: atlas's own CLAUDE.md was committed on
# 2026-08-16 carrying one start and two ends (fallout of the AGENTS.md symlink
# tear), and the pointer rewrote it into a clean block followed by an orphaned
# half-sentence tail. Checks 3-5 are the guard; 1-2 pin the happy paths.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
pointer="$root/scripts/atlas-pointer.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# a repo whose CLAUDE.md is exactly $1
mkrepo() {
  local d="$tmp/$1"; mkdir -p "$d"; shift
  printf '%s' "$1" > "$d/CLAUDE.md"
  printf '%s' "$d"
}

# --- 1. no block yet → appended, surrounding prose untouched -----------------
r="$(mkrepo append $'# Repo\n\nkeep me\n')"
if "$pointer" "$r" >/dev/null 2>&1 \
   && grep -q '<!-- atlas:start -->' "$r/CLAUDE.md" \
   && grep -q '<!-- atlas:end -->' "$r/CLAUDE.md" \
   && grep -q '^keep me$' "$r/CLAUDE.md"; then
  pass "no block: appends one clean pair and keeps existing prose"
else
  fail "no block: append path damaged the file"
fi

# --- 2. clean pair → replaced in place, idempotent ---------------------------
# Second run must leave the file byte-identical, or every cascade dirties the
# repo it just refreshed.
before="$(md5 -q "$r/CLAUDE.md")"
"$pointer" "$r" >/dev/null 2>&1
if [[ "$(md5 -q "$r/CLAUDE.md")" == "$before" ]]; then
  pass "clean pair: re-running is byte-identical (idempotent)"
else
  fail "clean pair: re-run changed the file"
fi

# --- 3. start with no end → refuse, change nothing ---------------------------
# This is the truncation case. The tail below is what a silent awk run eats.
torn=$'# Repo\n\n<!-- atlas:start -->\nold block\n\nIMPORTANT TAIL PROSE\n'
r="$(mkrepo torn "$torn")"
md5_before="$(md5 -q "$r/CLAUDE.md")"
"$pointer" "$r" >/dev/null 2>&1
rc=$?
if (( rc != 0 )) && [[ "$(md5 -q "$r/CLAUDE.md")" == "$md5_before" ]]; then
  pass "start without end: refuses and leaves the file untouched"
else
  fail "start without end: rc=$rc, tail prose present=$(grep -c 'IMPORTANT TAIL PROSE' "$r/CLAUDE.md")"
fi

# --- 4. one start, two ends → refuse (atlas's own real damage) ---------------
dup=$'# Repo\n\n<!-- atlas:start -->\nblock\n<!-- atlas:end -->\northaned half-sentence\n<!-- atlas:end -->\n'
r="$(mkrepo dup "$dup")"
md5_before="$(md5 -q "$r/CLAUDE.md")"
"$pointer" "$r" >/dev/null 2>&1
rc=$?
if (( rc != 0 )) && [[ "$(md5 -q "$r/CLAUDE.md")" == "$md5_before" ]]; then
  pass "duplicate end marker: refuses and leaves the file untouched"
else
  fail "duplicate end marker: rc=$rc, file was rewritten"
fi

# --- 5. end with no start → refuse ------------------------------------------
# The append path would happily add a second end here, compounding the damage.
stray=$'# Repo\n\nprose\n<!-- atlas:end -->\n'
r="$(mkrepo stray "$stray")"
md5_before="$(md5 -q "$r/CLAUDE.md")"
"$pointer" "$r" >/dev/null 2>&1
rc=$?
if (( rc != 0 )) && [[ "$(md5 -q "$r/CLAUDE.md")" == "$md5_before" ]]; then
  pass "stray end marker: refuses and leaves the file untouched"
else
  fail "stray end marker: rc=$rc, file was rewritten"
fi

# --- 6. no CLAUDE.md at all → creates one plus the AGENTS.md symlink ----------
r="$tmp/fresh"; mkdir -p "$r"
"$pointer" "$r" >/dev/null 2>&1
if [[ -f "$r/CLAUDE.md" ]] && grep -q '<!-- atlas:start -->' "$r/CLAUDE.md" \
   && [[ -L "$r/AGENTS.md" && "$(readlink "$r/AGENTS.md")" == CLAUDE.md ]]; then
  pass "bare repo: creates CLAUDE.md and the AGENTS.md symlink"
else
  fail "bare repo: scaffold incomplete"
fi

# --- 7. the inode survives, so an AGENTS.md symlink stays wired --------------
# atlas-pointer writes with `cat >` for exactly this reason; an mv would swap the
# inode and quietly orphan every hardlink and symlink pointing at the old one.
ino_before="$(stat -f %i "$r/CLAUDE.md")"
"$pointer" "$r" >/dev/null 2>&1
if [[ "$(stat -f %i "$r/CLAUDE.md")" == "$ino_before" ]]; then
  pass "rewrite preserves the CLAUDE.md inode"
else
  fail "rewrite replaced the inode — AGENTS.md symlinks would break"
fi

# --- 8. a lossless AGENTS.md is adopted even when the tree is dirty ----------
# The cascade swaps a symlinked AGENTS.md for a real copy of CLAUDE.md and only
# restores it at the end of its own run, so a run killed before that leaves a
# tracked, modified, lossless copy behind. Requiring a clean tree left those
# repos divergent forever (2026-09-18: 21 of 34). Losing content still refuses.
r="$tmp/dirty"; mkdir -p "$r"
"$pointer" "$r" >/dev/null 2>&1
git -C "$r" init -q
printf '# extra agent note\n' > "$r/AGENTS.md"
git -C "$r" add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
rm -f "$r/AGENTS.md" && cp "$r/CLAUDE.md" "$r/AGENTS.md"   # the swap's leftover
git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm copy
printf '\nhand-written only in AGENTS.md\n' >> "$r/AGENTS.md"
"$pointer" "$r" >/dev/null 2>&1
if [[ -L "$r/AGENTS.md" ]]; then
  fail "dirty lossless: adopted despite the unique line it now carries"
else
  pass "dirty lossless: unique line still refuses the conversion"
fi
sed -i '' '$d' "$r/AGENTS.md"
"$pointer" "$r" >/dev/null 2>&1
if [[ -L "$r/AGENTS.md" && "$(readlink "$r/AGENTS.md")" == CLAUDE.md ]]; then
  pass "dirty lossless: adopted once nothing is unique"
else
  fail "dirty lossless: a modified tracked copy was not adopted"
fi

# --- 8b. a newer OPENWIKI block in AGENTS.md alone does not block adoption ----
# openwiki rewrites its block in AGENTS.md only; the wording drifts from the
# copy in CLAUDE.md and is regenerated anyway. A line outside the block still
# refuses, and so does a block CLAUDE.md has no copy of.
r="$tmp/owblock"; mkdir -p "$r"
"$pointer" "$r" >/dev/null 2>&1
git -C "$r" init -q
printf '<!-- OPENWIKI:START -->\nold wording\n<!-- OPENWIKI:END -->\n' >> "$r/CLAUDE.md"
rm -f "$r/AGENTS.md"
printf '<!-- OPENWIKI:START -->\nnew wording\n<!-- OPENWIKI:END -->\nhuman note\n' > "$r/AGENTS.md"
git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
"$pointer" "$r" >/dev/null 2>&1
[[ -L "$r/AGENTS.md" ]] && fail "openwiki block: adopted despite a unique line outside the block" \
  || pass "openwiki block: a unique line outside the block still refuses"
sed -i '' '$d' "$r/AGENTS.md"
"$pointer" "$r" >/dev/null 2>&1
[[ -L "$r/AGENTS.md" && "$(readlink "$r/AGENTS.md")" == CLAUDE.md ]] \
  && pass "openwiki block: newer block wording alone is adopted" \
  || fail "openwiki block: newer block wording blocked the adoption"
r="$tmp/owonly"; mkdir -p "$r"
"$pointer" "$r" >/dev/null 2>&1
git -C "$r" init -q
rm -f "$r/AGENTS.md"
printf '<!-- OPENWIKI:START -->\nnew wording\n<!-- OPENWIKI:END -->\n' > "$r/AGENTS.md"
git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
"$pointer" "$r" >/dev/null 2>&1
[[ -L "$r/AGENTS.md" ]] && fail "openwiki block: adopted though CLAUDE.md has no block of its own" \
  || pass "openwiki block: kept when CLAUDE.md has no block of its own"

# --- 9. inverted convention: CLAUDE.md -> AGENTS.md is left alone -------------
# Both paths then read the same bytes, so a loss check alone says "adopt", and
# adopting points AGENTS.md back at CLAUDE.md: a symlink loop (media-tools,
# 2026-09-18, "too many levels of symbolic links").
r="$tmp/inverted"; mkdir -p "$r"
printf '# agents\n\nReal content.\n' > "$r/AGENTS.md"
ln -s AGENTS.md "$r/CLAUDE.md"
git -C "$r" init -q && git -C "$r" add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm init
"$pointer" "$r" >/dev/null 2>&1
if [[ ! -L "$r/AGENTS.md" ]] && [[ -r "$r/CLAUDE.md" ]] && grep -q 'Real content' "$r/CLAUDE.md"; then
  pass "inverted convention: no symlink loop created"
else
  fail "inverted convention: AGENTS.md was pointed back at CLAUDE.md"
fi

((fails)) && { printf '\n%d FAIL\n' "$fails"; exit 1; }
printf '\nall checks passed\n'
