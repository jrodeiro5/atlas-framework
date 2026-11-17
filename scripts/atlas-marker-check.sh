#!/bin/bash
# atlas-marker-check.sh [root] — print every onboarded repo whose CLAUDE.md has a
# marker block that is not a clean start/end pair, one "<repo>:<block>=<n>/<m>"
# per line. Exit 1 if any, 0 if none. Read-only.
#
# Why pairing and not presence: openwiki writes AGENTS.md and CLAUDE.md
# concurrently from a single pre-read (dist/ingestion/code-mode.js:129-130).
# Where AGENTS.md is a symlink to CLAUDE.md — the atlas convention — both writes
# land on one inode, the shorter content covers the head of the longer, and the
# longer one's tail survives: a beheaded sentence plus one extra end marker.
# The surviving tail is a constant 523 bytes (the fixed size gap between the two
# snippets openwiki generates), measured identical in atlas and media-tools,
# files of different lengths — which is what rules out a random interleaving.
#
# Four repos were found torn on 2026-09-06, three of them already committed:
# atlas:start 1/3 (byte-identical across commits), atlas:start 1/6,
# and OPENWIKI 1/2 twice (2026-08-16). None of them ever
# failed a gate: atlas-check.sh only grepped for the presence of atlas:start,
# and atlas-pointer.sh's refusal to touch a torn file goes to cascade.log.
# The refusal is also permanent, so a torn block never refreshes again —
# media-tools accumulated five tails that way.
set -uo pipefail
root="${1:-$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)}"
torn=()

while IFS= read -r g; do
  r="${g%/.git}"
  [[ -f "$r/.atlas-ignore" ]] && continue
  [[ -f "$r/CLAUDE.md" ]] || continue
  [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
  for m in atlas OPENWIKI gitnexus; do
    case $m in
      atlas)    a='<!-- atlas:start -->';    b='<!-- atlas:end -->' ;;
      OPENWIKI) a='<!-- OPENWIKI:START -->'; b='<!-- OPENWIKI:END -->' ;;
      gitnexus) a='<!-- gitnexus:start -->'; b='<!-- gitnexus:end -->' ;;
    esac
    cs="$(grep -c "$a" "$r/CLAUDE.md" || true)"
    ce="$(grep -c "$b" "$r/CLAUDE.md" || true)"
    (( cs == ce )) || torn+=("$(basename "$r"):$m=$cs/$ce")
  done
done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)

((${#torn[@]})) || exit 0
printf '%s\n' "${torn[@]}"
exit 1
