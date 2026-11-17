#!/bin/bash
# claims-check-test.sh — the claims section of atlas check.
#
# The block it guards replaced one that grepped `source_paths:` in page
# frontmatter, a key openwiki never writes (the real one is `sources:`). It
# printed "ok atlas: 1/47 pages carry grounded claims" while 32 sidecars held
# 282 claims -- a green light nobody had ever seen go red. So the test that
# matters here is not "does it print something", it is: does each of the four
# Verdicts come out of real hashes.
#
# Five sandbox repos, one run of the checker, five expected lines.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# mkrepo runs in $( ), so it cannot append to an array -- the caller list below
# is the single source of which repos the checker is handed.
mkrepo() {
  local d="$sandbox/$1"
  mkdir -p "$d/openwiki/.claims"
  printf '%s' "$d"
}
repos=("$sandbox/supported" "$sandbox/stale" "$sandbox/hallucinated" \
       "$sandbox/moved" "$sandbox/unverified")

# sidecar for page.md citing src.txt, hashed however $2 says
# $1 repo  $2 whole|lines|gone  ($3 line range for lines)
write_claims() {
  python3 - "$1" "$2" <<'PY'
import hashlib, json, os, sys
repo, mode = sys.argv[1], sys.argv[2]
sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
page = os.path.join(repo, "openwiki", "page.md")
raw = open(os.path.join(repo, "src.txt"), "rb").read() if mode != "gone" else b""
if mode == "lines":
    body = ("\n".join(raw.decode().split("\n")[2:5]) + "\n").encode()
    ev = {"resource": "repo://src.txt#L3-L5", "version": "repo-lines-v1:" + sha(body) + ":e30"}
else:
    ev = {"resource": "repo://src.txt", "version": "repo-file-v1:" + sha(raw)}
doc = {"schemaVersion": 1, "pageVersion": sha(open(page, "rb").read()),
       "claims": [{"statement": "it does the thing", "evidence": [ev]}]}
json.dump(doc, open(os.path.join(repo, "openwiki", ".claims", "page.json"), "w"))
PY
}

src=$'zero\none\ntwo\nthree\nfour\nfive\n'

# 1. evidence unchanged -> supported
r="$(mkrepo supported)"; printf 'page\n' >"$r/openwiki/page.md"; printf '%s' "$src" >"$r/src.txt"
write_claims "$r" whole

# 2. evidence file edited -> stale
r="$(mkrepo stale)"; printf 'page\n' >"$r/openwiki/page.md"; printf '%s' "$src" >"$r/src.txt"
write_claims "$r" whole
printf 'edited after the claim was verified\n' >>"$r/src.txt"

# 3. evidence file deleted -> hallucinated (always FAIL)
r="$(mkrepo hallucinated)"; printf 'page\n' >"$r/openwiki/page.md"; printf '%s' "$src" >"$r/src.txt"
write_claims "$r" whole
rm "$r/src.txt"

# 4. cited lines pushed down the file -> moved, not stale. This is the case a
#    line-number diff would call drift and the content hash correctly does not.
r="$(mkrepo moved)"; printf 'page\n' >"$r/openwiki/page.md"; printf '%s' "$src" >"$r/src.txt"
write_claims "$r" lines
printf '%s' $'header\nheader\n' | cat - "$r/src.txt" >"$r/src.txt.new" && mv "$r/src.txt.new" "$r/src.txt"

# 5. no sidecars at all -> unverified, never a FAIL
r="$(mkrepo unverified)"; printf 'page\n' >"$r/openwiki/page.md"

out="$(bash "$root/scripts/atlas-claims-check.sh" "${repos[@]}" 2>&1)"

expect() {  # $1 repo name  $2 verdict word  $3 line regexp
  local line; line="$(grep -E "^  [a-zA-Z]+ +$1:" <<<"$out")"
  if [[ $line =~ $3 ]]; then pass "$1: $2"; else fail "$1: $2 — got: ${line:-<no line>}"; fi
}
expect supported    "all supported, green"      '^  ok .*1 claims.*1 supported, 0 stale \(0%\), 0 hallucinated'
expect stale        "changed source is stale"   '^  FAIL .*0 supported, 1 stale \(100%\).*wrong head'
expect hallucinated "missing evidence FAILs"    '^  FAIL .*1 hallucinated'
expect moved        "shifted lines are moved"   '^  ok .*0 stale \(0%\), 0 hallucinated \(1 moved\)'
expect unverified   "no sidecars is a note"     '^  note .*no claims sidecars'

# ...and stays a note under the ceiling. A few stale claims are the normal gap
# between a commit and the cascade that reconciles it; what MAX_STALE_PCT is there
# to catch is the wrong-head signature, a whole claim set going stale at once.
# no pipe into grep -q: set -o pipefail turns its early exit into a failed
# pipeline even on a match.
lenient="$(MAX_STALE_PCT=100 bash "$root/scripts/atlas-claims-check.sh" "${repos[@]}" 2>&1)"
if grep -qE '^  note stale:.*1 stale \(100%\)' <<<"$lenient"; then
  pass "stale: stays a note under MAX_STALE_PCT"
else
  fail "stale: MAX_STALE_PCT=100 still turned the stale repo red"
fi

((fails)) && { printf '\nclaims-check: %d FAIL\n' "$fails"; exit 1; }
printf '\nclaims-check: all passed\n'
