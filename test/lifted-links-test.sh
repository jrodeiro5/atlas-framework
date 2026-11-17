#!/bin/bash
# lifted-links-test.sh — prose lifted from a README keeps the README's links,
# and those resolve to nothing once they are in the bundle. `./SECURITY.md` was
# five of the six broken links `atlas graph-check` found. Relative targets get
# flattened to text; `~/...` and http(s) ones must survive, because those two do
# resolve (atlas-site.py serves the first, a browser the second).
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

d="$tmp/dev/experiments/r"; mkdir -p "$d"
git -C "$d" init -q .
git -C "$d" config user.email t@t; git -C "$d" config user.name t
cat > "$d/README.md" <<'MD'
# r

Scanner see [`CHANGELOG.md`](CHANGELOG.md) and [posture](./SECURITY.md), plus
see [home](~/dev/r/notes.md) and [site](https://example.com/p).
MD
git -C "$d" add -A; git -C "$d" commit -qm init

export ATLAS_SCAN_LOCK="$tmp/scan.lock.d" ATLAS_RUNS_DIR="$tmp/runs"
mkdir -p "$ATLAS_RUNS_DIR"
HOME="$tmp" "$root/scripts/repo-atlas.sh" >/dev/null 2>&1

doc="$tmp/wiki/atlas/repos/r.md"
[[ -f $doc ]] || { fail "no entity doc generated"; exit 1; }

grep -q '(CHANGELOG.md)' "$doc" && fail "a README-relative link survived into the bundle" \
  || pass "a README-relative link is flattened"
grep -q '(./SECURITY.md)' "$doc" && fail "./SECURITY.md survived — the exact broken link" \
  || pass "./SECURITY.md is flattened"
grep -q 'CHANGELOG.md' "$doc" && pass "the text is kept, only the link is dropped" \
  || fail "flattening ate the words too"
grep -q '(~/dev/r/notes.md)' "$doc" && pass "a ~/ link survives: it resolves in the site" \
  || fail "a ~/ link was flattened"
grep -q '(https://example.com/p)' "$doc" && pass "an http(s) link survives" \
  || fail "an external link was flattened"

out="$("$root/scripts/entity-graph-check.py" "$tmp/wiki/atlas")"
[[ $out == *"broken=0"* ]] && pass "the bundle has no broken links ($out)" \
  || fail "still broken: $out"

(( fails == 0 )) || exit 1
