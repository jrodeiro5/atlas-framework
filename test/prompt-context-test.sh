#!/bin/bash
# prompt-context-test.sh — the UserPromptSubmit experiment stays silent unless
# opted in, pushes only the current repo's pages (frontmatter, not body), logs each
# push with the raw reranker score (not qmd's rank blend), drops below ATLAS_OW_CUT, and exits 0
# silently when the qmd daemon is down: it runs on every prompt of every session.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
hook="$root/scripts/atlas-prompt-context.sh"

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

export ATLAS_STATE_DIR="$tmp/state"
mkdir -p "$tmp/bin" "$tmp/known"
git init -q "$tmp/known"
# stub daemon. rerank:false → RRF order; rerank:true → qmd's blend w/rank +
# (1-w)·rerank. Raw reranker: a.md 0.6, b.md 0.9 (b blends lower, at rank 3),
# c.md 0, other-repo x.md 0.9. CURL_TOP=1: a.md ranked 1st, reranker 0.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
[[ -n ${CURL_DOWN:-} ]] && exit 7
o=qmd://repo-openwiki/g/known-public/openwiki/x.md k=qmd://repo-openwiki/g/known/openwiki
if [[ $* =~ \"rerank\":false ]]; then
  [[ -n ${CURL_TOP:-} ]] && { echo "{\"results\":[{\"file\":\"$k/a.md\",\"score\":1}]}"; exit; }
  echo "{\"results\":[{\"file\":\"$o\",\"score\":1},{\"file\":\"$k/a.md\",\"score\":0.9},{\"file\":\"$k/b.md\",\"score\":0.8},{\"file\":\"$k/c.md\",\"score\":0.7}]}"
  exit
fi
[[ -n ${CURL_TOP:-} ]] && { echo "{\"results\":[{\"file\":\"$k/a.md\",\"line\":7,\"score\":0.75,\"title\":\"MARKER\"}]}"; exit; }
echo "{\"results\":[
 {\"file\":\"$o\",\"line\":1,\"score\":0.975,\"title\":\"OTHER\"},
 {\"file\":\"$k/a.md\",\"line\":7,\"score\":0.525,\"title\":\"MARKER\"},
 {\"file\":\"$k/b.md\",\"line\":1,\"score\":0.475,\"title\":\"SECOND\"},
 {\"file\":\"$k/c.md\",\"line\":1,\"score\":0.15,\"title\":\"THIRD\"}]}"
EOF
export OW_ROOT="$tmp/dev"
mkdir -p "$OW_ROOT/g/known/openwiki"
printf -- '---\nauthoritative: false\ntitle: MARKER\ndescription: DESC line\n---\nBODY\n' > "$OW_ROOT/g/known/openwiki/a.md"
printf -- '---\ntitle: SECOND\n---\n' > "$OW_ROOT/g/known/openwiki/b.md"
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
in="{\"prompt\":\"why\",\"cwd\":\"$tmp/known\",\"session_id\":\"s1\"}"

# --- 1. not opted in → silent ----------------------------------------------
out="$(ATLAS_OW_INJECT='' "$hook" <<<"$in" 2>&1)"
[[ -z $out ]] && pass "silent without ATLAS_OW_INJECT" || fail "printed without opt-in: $out"

# --- 2-4. opted in → this repo's page only, and a log line ------------------
out="$(ATLAS_OW_INJECT=1 "$hook" <<<"$in" 2>&1)"
grep -q MARKER <<<"$out" && pass "pushes the repo's page" || fail "no page: $out"
grep -q OTHER <<<"$out" && fail "pushed another repo's page" || pass "other repo filtered out"
grep -q '"session":"s1"' "$ATLAS_STATE_DIR/prompt-context.log" 2>/dev/null \
  && pass "push logged" || fail "no log line"
grep -q 'DESC line' <<<"$out" && pass "pushes the frontmatter description" || fail "no description: $out"
grep -q BODY <<<"$out" && fail "pushed the page body" || pass "page body not pushed"
grep -q 'interrupted run' <<<"$out" && pass "stale page tagged" || fail "stale page untagged: $out"
grep -q 'qmd get qmd://repo-openwiki/g/known/openwiki/a.md:7:40' <<<"$out" && pass "points at a 40-line window" || fail "no window: $out"
tail -1 "$ATLAS_STATE_DIR/prompt-context.log" | grep -q '"score":0.6,' && pass "raw reranker score logged, not the blend" || fail "no raw score in log"
[[ $(grep -n SECOND <<<"$out" | cut -d: -f1) -lt $(grep -n MARKER <<<"$out" | cut -d: -f1) ]] \
  && pass "ordered by reranker, not by blend" || fail "blend order: $out"
grep -q THIRD <<<"$out" && fail "pushed a third page" || pass "two pages at most"

# --- ranked 1st but irrelevant: blend 0.75, reranker 0 → silent ---------------
out="$(CURL_TOP=1 ATLAS_OW_INJECT=1 "$hook" <<<"$in" 2>&1)"
[[ -z $out ]] && pass "top rank alone does not pass the cut" || fail "pushed on rank alone: $out"

# --- gate: score below ATLAS_OW_CUT → silent, logged as not pushed ----------
out="$(ATLAS_OW_CUT=0.7 ATLAS_OW_INJECT=1 "$hook" <<<"$in" 2>&1)"
grep -q MARKER <<<"$out" && fail "pushed below the cut: $out" || pass "cut drops a low-scored page"
tail -1 "$ATLAS_STATE_DIR/prompt-context.log" | grep -q '"pushed":false' && pass "drop logged" || fail "drop not logged"


# --- 5. daemon down → silent, exit 0 ----------------------------------------
out="$(CURL_DOWN=1 ATLAS_OW_INJECT=1 "$hook" <<<"$in" 2>&1)"; rc=$?
[[ $rc -eq 0 && -z $out ]] && pass "silent when daemon is down" || fail "rc=$rc out=$out"

[[ $fails -eq 0 ]] && echo "prompt-context: all passed" || { echo "prompt-context: $fails failed"; exit 1; }
