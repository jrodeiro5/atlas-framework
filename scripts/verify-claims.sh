#!/usr/bin/env bash
# verify-claims.sh <repo> — checks factual claims in generated prose
# against the repo they describe.
#
# Two writers produce unverified prose: `openwiki code --update` and
# CodeAlmanac's garden job. Neither re-reads the repo to confirm what it wrote.
# Proof this is not hypothetical: openwiki's own template asserted "a scheduled
# GitHub Actions workflow refreshes the wiki", false for every atlas-onboarded
# repo, and nothing caught it.
#
# ponytail: path claims only — claim type 1. Binary, exact, no LLM.
# Type 2 (behavior) lives in verify-claims-behavior.py, judged by the local
# Strands model instead of by grep. Type 3 (counts) is still not built.
#
# Reports, never blocks. Exit 0 even with findings, so a cascade
# stage that calls this cannot kill the run.
set -uo pipefail

repo="${1:?usage: verify-claims.sh <repo> [--markers]}"
mode="${2:-}"
[[ -d $repo ]] || { echo "no such repo: $repo" >&2; exit 1; }



# A backticked token is a checkable claim only if it names a path inside THIS
# repo. Absolute paths, ~/ paths and $vars point outside it; github.com/user/repo
# and bare `package.json` are illustrative, not claims. Excluding them is what
# makes the finding count readable — names wording false positives as
# the main risk, and out-of-repo paths were 90% of them on the first run.
is_path_claim() {
  local t=$1
  [[ $t == *' '* || $t == *'*'* || $t == http*://* ]] && return 1
  [[ $t == ~* || $t == /* || $t == *'$'* || $t == *'@'* ]] && return 1
  [[ $t == github.com/* || $t == *:[0-9]* ]] && return 1
  # slash AND a file extension: `almanac/decisions/foo.md` is a claim, while
  # `architecture/repo-atlas-scanner` (a wiki slug), `langchain-ai/openwiki`
  # (an org/repo) and `litellm/atlas-key` (a pass entry) are not paths at all.
  [[ $t == */* && $t =~ \.(sh|py|ts|js|cjs|mjs|json|yaml|yml|toml|md|plist|sql)$ ]]
}

found=0
while IFS= read -r f; do
  rel="${f#"$repo"/}"
  # backtick-quoted tokens, one per line
  while IFS= read -r tok; do
    is_path_claim "$tok" || continue
    [[ -e "$repo/${tok#./}" ]] && continue
    # a bare basename may legitimately live anywhere in the repo
    [[ $tok != */* ]] && find "$repo" -name "$(basename "$tok")" -print -quit 2>/dev/null | grep -q . && continue
    found=$((found + 1))
    if [[ $mode == --markers ]]; then
      printf '<!-- atlas:unverified claim="%s" in="%s" -->\n' "$tok" "$rel"
    else
      printf '%s: %s\n' "$rel" "$tok"
    fi
  done < <(grep -oE '`[^`]+`' "$f" 2>/dev/null | tr -d '`')
done < <(find "$repo/openwiki" "$repo/almanac" -name '*.md' 2>/dev/null)

[[ $mode == --markers ]] || echo "unverified path claims: $found"
exit 0
