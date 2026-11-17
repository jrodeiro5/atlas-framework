#!/usr/bin/env bash
# UserPromptSubmit hook — EXPERIMENT, opt-in with ATLAS_OW_INJECT=1.
#
# in 30 days no agent pulled an openwiki page. What gets used here
# (deja, gitnexus, the SessionStart entity doc) is pushed by a hook. This pushes
# the two openwiki pages of the current repo closest to the prompt, and logs
# each push so the sessions can be compared with and without it.
#
# Vector search, not BM25: prompts are Spanish, the pages English, and BM25
# matched nothing on a real prompt. Cold `qmd vsearch` takes ~12 s (model load),
# so this talks to `qmd mcp --http --daemon` (warm: ~0.3 s). No daemon → silent.
#
# What is pushed is the page's frontmatter `title` + `description` (~40 tokens),
# not a snippet, plus a `qmd get file:line:40` window for the agent to pull more.
# Pages from an interrupted run (`authoritative: false`, half the corpus and all
# of atlas today) are pushed tagged, not dropped: dropping silences whole repos.
#
# Relevance: qmd's reranker scores each hit, not a classifier judge: one
# was tried (2026-11-17), isn't calibrated for this, and didn't
# separate (0.46 relevant vs 0.48 off-topic). But `/search` with `rerank: true`
# returns a BLEND, w/rrfRank + (1-w)·rerank (qmd store.js), with the rank taken
# over every repo's pages: an atlas page ranked 1st scores ≥ 0.75 whatever the
# reranker says. So a second, cheap `rerank: false` call (~0.3 s) gives each
# page its RRF rank, the raw reranker score is solved back out, and pages are
# ordered and cut on it. Raw reranker on 5 prompts: chit-chat ≤ 0.02, relevant
# 0.46–1.0, so the default cut is 0.5. Cost: ~2.5–3.7 s per new prompt; slower
# than curl's 4 s → silent.
# ponytail: depends on qmd 2.8.3's blend weights (0.75 / 0.60 / 0.40, rank ≤3 /
# ≤10 / rest) and candidate limit (40). Upgrade: qmd returning `rerankScore`
# over HTTP (the library has `explain`, the server drops it). Cut re-derived
# from the labelled log (BACKLOG B0).
set -uo pipefail
[[ ${ATLAS_OW_INJECT:-} == 1 ]] || exit 0

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
[[ -n $cwd ]] && cd "$cwd" 2>/dev/null
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
repo="$(basename "$(dirname "$common")")"
prompt="$(jq -r '.prompt // empty' <<<"$input" | head -c 500)"
[[ -n $prompt ]] || exit 0

search() {  # $1 = rerank true|false, $2 = curl timeout; limit 40 = qmd's candidate limit, so every reranked page has a rank
  curl -sf -m "$2" -X POST "http://localhost:${QMD_HTTP_PORT:-8181}/search" -H 'content-type: application/json' \
    -d "$(jq -nc --arg q "$prompt" --argjson r "$1" \
      '{searches: [{type: "vec", query: $q}], collections: ["repo-openwiki"], limit: 40, rerank: $r}')"
}
plain="$(search false 1)" || exit 0
hits="$(search true 4 | jq -c --argjson p "$plain" --arg r "/$repo/openwiki/" '
  ($p.results | to_entries | map({key: .value.file, value: (.key + 1)}) | from_entries) as $rank
  | [.results[] | select(.file | contains($r))
     | ($rank[.file] // 40) as $k | (if $k <= 3 then 0.75 elif $k <= 10 then 0.6 else 0.4 end) as $w
     | .score = ((.score - $w / $k) / (1 - $w) * 1000 | round / 1000)]
  | sort_by(-.score)[:2]' 2>/dev/null)" || exit 0
[[ -n $hits && $hits != "[]" ]] || exit 0

out=() logged=()
while IFS=$'\t' read -r file line qtitle score; do
  # collection repo-openwiki is rooted at ~/dev
  fm="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' \
    "${OW_ROOT:-$HOME/dev}/${file#qmd://repo-openwiki/}" 2>/dev/null)"
  title="$(sed -n 's/^title: *//p' <<<"$fm")"
  desc="$(sed -n 's/^description: *//p' <<<"$fm" | head -c 300)"
  stale=""; grep -q '^authoritative: false' <<<"$fm" && stale=" [from an interrupted run, may be stale]"
  if awk -v s="$score" -v c="${ATLAS_OW_CUT:-0.5}" 'BEGIN {exit !(s < c)}'; then
    logged+=("$(jq -nc --arg f "$file" --arg s "$score" '{file: $f, score: ($s | tonumber), pushed: false}')")
    continue
  fi
  logged+=("$(jq -nc --arg f "$file" --arg s "$score" '{file: $f, score: ($s | tonumber), pushed: true}')")
  out+=("- ${title:-$qtitle}$stale — $desc" "  more: qmd get $file:$line:40")
done < <(jq -r '.[] | [.file, (.line // 1), .title, .score] | @tsv' <<<"$hits")

log="${ATLAS_STATE_DIR:-$HOME/.local/state/atlas}/prompt-context.log"
mkdir -p "$(dirname "$log")"
printf '%s\n' "${logged[@]}" | jq -sc --arg t "$(date -u +%FT%TZ)" --arg s "$(jq -r '.session_id // ""' <<<"$input")" \
  --arg r "$repo" --arg cut "${ATLAS_OW_CUT:-0.5}" '{t: $t, session: $s, repo: $r, cut: $cut, pages: .}' >> "$log"

[[ ${#out[@]} -gt 0 ]] || exit 0
echo "openwiki pages of $repo near this prompt (generated docs; the code wins if they disagree):"
printf '%s\n' "${out[@]}"
