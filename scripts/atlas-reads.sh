#!/usr/bin/env bash
# Which wiki pages does anything actually read?
#
# The design calls the wiki "a cache over expensive context re-derivation" and says
# to judge it by cache-hit quality — but nothing measured hits. This does, from
# the outside: atime > mtime means the page was opened after it was written.
#
# ponytail: atime, not a query wrapper. No PATH change, no launchd, no hook, no
# daemon. The cost is precision — grep, Spotlight and Time Machine also bump
# atime, so a read here is only evidence that *something* opened the file.
# A page never read since generation is the reliable signal, and it is the one
# that matters: that page is pure cost. Upgrade to a `qmd query` wrapper logging
# returned paths only if the never-read list gets small enough to argue about.
#
# Every `atlas scan` rewrites the entity docs and resets mtime, so this measures
# reads *since the last generation*, not all time. Baseline 2026-07-25, right
# after a scan-free week: 81 pages, 33 read, 48 never. Run it before a scan, not
# after, and the weekly cadence is the sampling window.
set -euo pipefail

wiki="${ATLAS_WIKI:-$HOME/wiki/atlas}"
[[ -d $wiki ]] || { echo "no wiki at $wiki" >&2; exit 1; }

total=0 read_n=0
cold=()

while IFS= read -r f; do
  total=$((total + 1))
  # %a = atime epoch, %m = mtime epoch
  read -r a m <<<"$(stat -f '%a %m' "$f")"
  if ((a > m)); then read_n=$((read_n + 1)); else cold+=("${f#"$wiki"/}"); fi
done < <(find "$wiki" -name '*.md')

echo "wiki pages: $total | read since written: $read_n | never read: $((total - read_n))"

if ((${#cold[@]})); then
  echo
  echo "never read since generated:"
  printf '  %s\n' "${cold[@]}" | sort
fi
