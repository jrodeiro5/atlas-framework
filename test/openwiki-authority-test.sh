#!/bin/bash
# openwiki-authority-test.sh — an unverified wiki says so in
# its own frontmatter, and a verified one carries no trace of having said it.
# who wrote the page is a separate dimension from whether this run was
# trustworthy, so the actor stamp stays on a clean run when the warning goes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

script="$root/scripts/openwiki-authority.sh"
repo="$sandbox/repo"
mkdir -p "$repo/openwiki/architecture"
cd "$repo"
git init -q && git config user.email t@t && git config user.name t

page="$repo/openwiki/architecture/pipeline.md"
index="$repo/openwiki/architecture/index.md"     # index pages carry no frontmatter
printf -- '---\ntype: Architecture\ntitle: Pipeline\n---\n\nbody text\n' >"$page"
printf -- '# Files\n\n- [Pipeline](pipeline.md)\n' >"$index"
manifest="$repo/openwiki/.last-update.json"

# --- 1. interrupted run: both kinds of page get stamped -----------------------
printf '{"status": "interrupted", "gitHead": "abc1234", "model": "local-model", "updatedAt": "2026-09-06T09:47:53Z"}\n' >"$manifest"
"$script" "$repo" >/dev/null
head -3 "$page" | grep -q '^authoritative: false$' || fail "page not stamped"
grep -q 'status=interrupted' "$page" || fail "stamp does not say why"
grep -q '^type: Architecture$' "$page" || fail "stamp destroyed the existing frontmatter"
grep -q '^authoritative: false$' "$index" || fail "index page (no frontmatter) not stamped"
grep -q '^# Files$' "$index" || fail "stamp destroyed the index body"
grep -q '^generated: { by: openwiki/local-model, at: 2026-09-06T09:47:53Z }$' "$page" \
  || fail "no OKF actor: a model page reads like a deterministic scan"

# --- 2. stamping twice changes nothing ----------------------------------------
before="$(cat "$page")"
"$script" "$repo" >/dev/null
[ "$before" = "$(cat "$page")" ] || fail "second run rewrote an already-stamped page"

# --- 3. a clean run clears the warning but keeps the actor --------------------
printf '{"status": "complete", "gitHead": "abc1234", "branch": "main", "model": "local-model", "updatedAt": "2026-09-06T10:00:00Z"}\n' >"$manifest"
"$script" "$repo" >/dev/null
grep -q '^authoritative:' "$page" && fail "clean run left the warning behind"
grep -q '^authority-reason:' "$page" && fail "clean run left the reason behind"
grep -q '^type: Architecture$' "$page" || fail "clean run ate the original frontmatter"
grep -q 'body text' "$page" || fail "clean run ate the body"
[ "$(grep -c '^generated: ' "$page")" = 1 ] || fail "actor stamp duplicated or dropped"
grep -q '^generated: { by: openwiki/local-model, at: 2026-09-06T09:47:53Z }$' "$page" \
  || fail "an existing actor was overwritten instead of left alone"
grep -q '^# Files$' "$index" || fail "clean run ate the index body"

# --- 3b. openwiki's own per-page actor is never overwritten -------------------
# openwiki stamps generated: itself in dist/okf/generated-provenance.js, per page
# and only where the body changed. That finalizer only runs when the run
# completes, so an interrupted run leaves the hole this script fills. Filling it
# must never turn into clobbering it: its event knows which pages the run really
# rewrote, and one run-level actor does not.
printf -- '---\ntype: Architecture\ngenerated: { by: openwiki/some-other-model, at: 2026-01-01T00:00:00Z }\n---\nbody text\n' >"$page"
"$script" "$repo" >/dev/null
grep -q '^generated: { by: openwiki/some-other-model, at: 2026-01-01T00:00:00Z }$' "$page" \
  || fail "openwiki's own per-page provenance was overwritten"
[ "$(grep -c '^generated: ' "$page")" = 1 ] || fail "a second actor was appended alongside openwiki's"

# --- 4. complete, but generated off the default branch — the wrong-head failure --
printf '{"status": "complete", "gitHead": "abc1234", "branch": "wip/experiment", "model": "local-model"}\n' >"$manifest"
"$script" "$repo" >/dev/null
grep -q "branch 'wip/experiment'" "$page" || fail "off-branch generation not flagged"

# --- 5. no receipt at all is not a pass ---------------------------------------
# back to a page with no actor of its own: this section is about the hole, and
# section 3b deliberately left one filled.
printf -- '---\ntype: Architecture\n---\nbody text\n' >"$page"
rm -f "$manifest"
"$script" "$repo" >/dev/null
grep -q '^authoritative: false$' "$page" || fail "missing .last-update.json treated as verified"
grep -q '^generated: { by: openwiki/unknown-model' "$page" \
  || fail "no receipt should still name an unknown actor, not none"

echo "PASS: openwiki authority stamp marks, clears, and is idempotent"
