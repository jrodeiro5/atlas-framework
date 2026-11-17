#!/bin/bash
# friction-test.sh — the gap between what the sessions hit and what the pages say.
#
# The report must not claim a failure is documented because a word of it happens
# to appear somewhere.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
script="$root/scripts/atlas-friction.py"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

mkdir -p "$tmp/bin" "$tmp/wiki/atlas/repos" "$tmp/dev/r"
cat > "$tmp/bin/deja" <<'SH'
#!/bin/sh
cat <<'JSON'
{ "rows": [
  { "error": "ModuleNotFoundError: No module named 'httpx'", "sessions": 14 },
  { "error": "gtimeout flavour rejected", "sessions": 9 } ] }
JSON
SH
chmod +x "$tmp/bin/deja"

printf 'the gtimeout flavour is rejected on this machine\n' > "$tmp/wiki/atlas/repos/a.md"

out="$(HOME="$tmp" PATH="$tmp/bin:$PATH" "$script" 2>&1)"; rc=$?

(( rc == 0 )) && pass "exits 0: this reports, it does not gate" || fail "exit was $rc"
grep -q "^GAP .*ModuleNotFoundError" <<<"$out" && pass "an undocumented error is a GAP" \
  || fail "no GAP for the undocumented error: $out"
grep -q "gap-or-weak=1" <<<"$out" && pass "one gap reported" \
  || fail "wrong gap count: $out"
grep -q "word(s) appear somewhere, best page .*repos/a.md" <<<"$out" \
  && pass "a covered error names the page instead of asserting a verdict" \
  || fail "page not named: $out"

only="$(HOME="$tmp" PATH="$tmp/bin:$PATH" "$script" --undocumented 2>&1)"
grep -q "gtimeout" <<<"$only" && fail "--undocumented still printed a covered row" \
  || pass "--undocumented drops the covered rows"

HOME="$tmp" PATH="$tmp/empty:/usr/bin:/bin" "$script" >/dev/null 2>&1
(( $? == 2 )) && pass "no deja on PATH exits 2, not a silent empty report" \
  || fail "missing deja did not exit 2"

(( fails == 0 )) || exit 1
