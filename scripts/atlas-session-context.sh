#!/usr/bin/env bash
# SessionStart hook: print the entity doc of the repo the session opened in.
#
# A probe scored 2/5 on README + ls-files and 5/5 with the entity doc (run of
# 2026-08-24), but the CLAUDE.md pointer only suggests fetching it: on 2026-10-03,
# 21 of 446 Claude Code transcripts from the previous 30 days ran a qmd lookup.
# This delivers the doc instead of suggesting it. Silent outside a scanned repo —
# a hook that errors blocks nothing but prints noise into every session.
set -euo pipefail

wiki="${ATLAS_WIKI:-$HOME/wiki/atlas}"
# the common dir, not --show-toplevel: a linked worktree's toplevel is the
# worktree folder, whose basename is not the repo's
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
doc="$wiki/repos/$(basename "$(dirname "$common")").md"
[[ -f $doc ]] || exit 0
echo "Atlas entity doc for this repo ($doc), generated from scans:"
# ponytail: 8 KB cap (~2k tokens); on 2026-10-03 the mean doc is 1.2 KB and the
# largest (long manual section) 4.3 KB. Send a shorter abstract layer
# instead if docs outgrow it
head -c 8192 "$doc"
