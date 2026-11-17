#!/bin/bash
# entity-graph.sh — query relationships between ~/wiki/atlas/ entity docs.
# No graph engine: grep over existing frontmatter/links.
set -uo pipefail
WIKI="$HOME/wiki/atlas"

usage() {
  cat <<EOF
usage: entity-graph.sh runs <repo-title>     # services whose repo: field matches
       entity-graph.sh links <entity-doc>    # markdown links found in a doc
EOF
  exit 1
}

field() { sed -n "s/^$1: *//p" "$2" | head -1; }

cmd_runs() {
  local repo="${1:?repo title required}"
  grep -l "^repo: .*${repo}\$" "$WIKI"/services/*.md 2>/dev/null | while read -r f; do
    echo "$(field title "$f")  ($f)"
  done
}

cmd_links() {
  local doc="${1:?entity doc path required}"
  [[ -f "$doc" ]] || doc="$WIKI/$doc"
  [[ -f "$doc" ]] || { echo "not found: $1" >&2; exit 1; }
  grep -oE '\[[^]]+\]\([^)]+\)' "$doc"
}

case "${1:-}" in
  runs)  shift; cmd_runs "$@" ;;
  links) shift; cmd_links "$@" ;;
  *) usage ;;
esac
