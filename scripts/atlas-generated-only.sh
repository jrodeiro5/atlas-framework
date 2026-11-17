#!/usr/bin/env bash
# atlas-generated-only.sh <repo> <path> — is every change in <path> inside a
# generated marker block?
#
#   0  yes: only generated content moved. Safe to commit as bot output.
#   1  no: something outside the markers changed. A human wrote it, or a block is
#      torn. Refuse.
#   2  cannot tell: the file is untracked, absent, or has no HEAD version.
#
# Why this exists. The cascade writes the atlas block into CLAUDE.md, then its
# auto-commit gate (`index holds changes outside openwiki/`) refuses to commit it.
# So the block lives in the working tree and in no commit, in every repo. On
# 2026-09-19 the corrected AGENTS.md warning was propagated to nine repos and
# committed in none of them — the next agent to read CLAUDE.md anywhere still read
# the false one.
#
# It is a script and not an inline grep because of the same day's lesson: a check
# with no name cannot be run before the write, and one that always exits 0 stops
# nothing. This one has a name, runs standalone, and fails.
#
# A CLAUDE.md is a mixed file: hand-written prose (the litellm traps, the port
# notes) beside four generated blocks. Committing it blind would sweep a human's
# edit into a bot commit. So compare the file to its HEAD version with every
# generated block removed from both sides; if what remains is identical, the diff
# was all generated.
set -uo pipefail

repo="${1:?usage: atlas-generated-only.sh <repo> <path>}"
rel="${2:?usage: atlas-generated-only.sh <repo> <path>}"

[[ -f "$repo/$rel" ]] || exit 2
git -C "$repo" cat-file -e "HEAD:$rel" 2>/dev/null || exit 2

# Markers seen in the wild: atlas, gitnexus, OPENWIKI (upper), codealmanac.
starts=$(grep -cE '<!--[[:space:]]*(atlas|gitnexus|openwiki|codealmanac):(start|begin)[[:space:]]*-->' "$repo/$rel" 2>/dev/null || true)
ends=$(grep -cE '<!--[[:space:]]*(atlas|gitnexus|openwiki|codealmanac):end[[:space:]]*-->' "$repo/$rel" 2>/dev/null || true)
# An unbalanced block would let the stripper eat the tail on both sides and call a
# torn file clean. Refuse instead: atlas-marker-check.sh names the repo.
[[ "$starts" == "$ends" ]] || exit 1

strip() {
  perl -ne '
    if (/<!--[[:space:]]*(?:atlas|gitnexus|openwiki|codealmanac):(?:start|begin)[[:space:]]*-->/i) { $in = 1; next }
    if (/<!--[[:space:]]*(?:atlas|gitnexus|openwiki|codealmanac):end[[:space:]]*-->/i) { $in = 0; next }
    print unless $in;
  '
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" show "HEAD:$rel" 2>/dev/null | strip >"$tmp/head"
strip <"$repo/$rel" >"$tmp/work"

# -B, not cmp: stripping a block leaves blank lines behind, and rudel and
# gcp-gws-control differ from HEAD by whitespace alone. Only non-blank is an edit.
diff -qB "$tmp/head" "$tmp/work" >/dev/null && exit 0 || exit 1
