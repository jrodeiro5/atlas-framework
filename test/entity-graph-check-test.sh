#!/bin/bash
# entity-graph-check-test.sh — the counts must distinguish a real edge from a
# link that only looks like one. A doc pointing at ~/dev/... is broken, not
# connected; a link inside a fence is an example, not an edge; RUNS lives in
# frontmatter where the markdown walk cannot see it.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
checker="$root/scripts/entity-graph-check.py"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

b="$tmp/wiki/atlas"; mkdir -p "$b/repos" "$b/services"
printf -- '---\nokf_version: "0.2"\n---\n- [a](repos/a.md)\n' > "$b/index.md"
printf -- '---\ntype: repo\n---\nsee [b](b.md), [out](~/dev/x/almanac/d.md) and [gone](./nope.md)\n' > "$b/repos/a.md"
printf -- '---\ntype: repo\n---\nplain, see [nav](../index.md)\n' > "$b/repos/b.md"
printf -- '---\ntype: repo\n---\n```\n[fake](repos/nope.md)\n```\n' > "$b/repos/c.md"
printf -- '---\ntype: service\nrepo: infra/a\n---\nruns\n' > "$b/services/s.md"
printf -- '---\ntype: service\nrepo: none\n---\nnothing\n' > "$b/services/t.md"
mkdir -p "$b/jobs"; printf -- '---\ntype: job\nrepo: a\n---\n- [a](../repos/a.md): runs code\n' > "$b/jobs/j.md"

out="$("$checker" "$b")"; rc=$?

(( rc == 0 )) && pass "exits 0 without --strict" || fail "exit was $rc, expected 0"
[[ $out == *"concepts=6"* ]] && pass "index.md and log.md are not concepts" \
  || fail "wrong concept count: $out"
[[ $out == *"links=2"* ]] && pass "counts the one resolvable markdown link" \
  || fail "wrong link count: $out"
[[ $out == *"runs=1"* ]] && pass "repo: counted, repo: none is not, and repo: + link to the same repo is one edge" \
  || fail "wrong runs count: $out"
[[ $out == *"outside=1"* ]] && pass "a ~/dev href leaves the bundle, it is not broken" \
  || fail "wrong outside count: $out"
[[ $out == *"broken=1"* ]] && pass "an unresolvable sibling is broken, a fenced link is not a link" \
  || fail "wrong broken count: $out"
[[ $out == *"nav=1"* ]] && pass "a link into index.md resolves: navigation, not broken" \
  || fail "wrong nav count: $out"
# a, b (link), s, a (runs) are connected; c and t are not
[[ $out == *"orphans=2"* ]] && pass "orphans are the unconnected concepts" \
  || fail "wrong orphan count: $out"

"$checker" "$b" --strict >/dev/null 2>&1
(( $? == 1 )) && pass "--strict exits 1 when anything is broken" \
  || fail "--strict did not exit 1"

# --strict gates on what runs: a lone repo is a leaf, a lone service is not
g="$tmp/gate"; mkdir -p "$g/repos" "$g/services"
printf -- '---\ntype: repo\n---\nleaf\n' > "$g/repos/x.md"
printf -- '---\ntype: repo\n---\nleaf\n' > "$g/repos/y.md"
"$checker" "$g" --strict >/dev/null 2>&1
(( $? == 0 )) && pass "--strict lets orphan repos through" || fail "--strict failed on repo leaves"
printf -- '---\ntype: service\nrepo: none\n---\nalone\n' > "$g/services/z.md"
"$checker" "$g" --strict >/dev/null 2>&1
(( $? == 1 )) && pass "--strict fails on an orphan service" || fail "--strict let an orphan service through"

"$checker" "$tmp/nowhere" >/dev/null 2>&1
(( $? == 2 )) && pass "missing bundle exits 2, not 0" || fail "missing bundle did not exit 2"

(( fails == 0 )) || exit 1
