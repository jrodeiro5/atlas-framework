#!/usr/bin/env bash
# repo-atlas.sh — scan ~/dev for git repos, regenerate ~/wiki/atlas/repos/*.md (OKF frontmatter)
# ponytail: flat find + overwrite-above-marker; parallel scan when repo count hurts
set -euo pipefail

DEV="$HOME/dev"
OUT="$HOME/wiki/atlas/repos"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER='<!-- manual -->'
mkdir -p "$OUT"

# Run manifest. Best-effort: bookkeeping must never block a scan, so
# every helper call is `|| true` and an empty run_id disables the finish hook.
_rs="$HERE/atlas-run-state.sh"
_run_id="$("$_rs" begin repo-atlas --kind scan --operation repo-scan \
  --trigger "${ATLAS_TRIGGER:-launchd}" --pid $$ 2>/dev/null || true)"
_lock=""   # set only once this process owns it, so the skip path never frees someone else's
_finish_run() {
  local rc=$?
  # `[[ ]] && rm` as a bare statement returns 1 when _lock is empty, and under
  # set -e that aborts this function before it ever records the run. if, not &&.
  if [[ -n $_lock ]]; then rm -rf "$_lock"; fi
  [[ -n $_run_id ]] || return 0
  if ((rc == 0)); then
    "$_rs" finish "$_run_id" --exit-code 0 --status succeeded >/dev/null 2>&1 || true
  else
    "$_rs" finish "$_run_id" --exit-code "$rc" --status failed --error "exit $rc" >/dev/null 2>&1 || true
  fi
}
trap _finish_run EXIT

# ponytail: mkdir spinlock, one scan at a time. A second concurrent scan is pure
# duplicate work — this is a full regenerate, not an incremental one — and the two
# collide on the `qmd update` at the end, where SQLite refuses the second writer
# and the script exits 1 with the scan itself already finished ("44 repos mapped",
# no "qmd reindexed"). Reproduced 2026-08-16 on the first try by starting two
# scans at once; 5 of the 10 recorded repo-scan failures overlapped another scan.
# Every cascade ends by calling this, so three commits in a minute is three scans.
#
# Liveness-checked like the cascade's lock: a holder killed without running its
# trap would otherwise wedge every later scan forever.
# ponytail: this only serializes repo-atlas against itself. service-atlas.sh
# ends in its own `qmd update` and can still collide with this one
# — not yet observed (service-scan is 4/4). Shared lock around qmd update if it
# ever shows up in the ledger.
# ponytail: env override so the test can exercise the lock without touching (or
# deleting) the lock a real scan may be holding right now.
_lockdir="${ATLAS_SCAN_LOCK:-/tmp/atlas-repo-scan.lock.d}"
if ! mkdir "$_lockdir" 2>/dev/null; then
  _holder="$(cat "$_lockdir/pid" 2>/dev/null || true)"
  if [[ -n $_holder ]] && kill -0 "$_holder" 2>/dev/null; then
    echo "atlas: scan already running (pid $_holder), skipped"
    if [[ -n $_run_id ]]; then
      "$_rs" finish "$_run_id" --exit-code 0 --status skipped >/dev/null 2>&1 || true
      _run_id=""   # already terminal; the EXIT trap must not finish it again
    fi
    exit 0
  fi
  rm -rf "$_lockdir"
  mkdir "$_lockdir" 2>/dev/null || { echo "atlas: lost the race for a stale lock, skipped"; exit 0; }
fi
_lock="$_lockdir"
echo $$ > "$_lockdir/pid"

stack_of() { # detect stack from marker files, root + one level of subdirs (monorepo services)
  local r="$1" d has_node= has_python= has_rust= has_go= has_swift= s=()
  for d in "$r" "$r"/*/; do
    [[ -d $d ]] || continue
    [[ -f $d/package.json ]] && has_node=1
    { [[ -f $d/pyproject.toml ]] || [[ -f $d/requirements.txt ]]; } && has_python=1
    [[ -f $d/Cargo.toml ]] && has_rust=1
    [[ -f $d/go.mod ]] && has_go=1
    [[ -f $d/Package.swift ]] && has_swift=1
  done
  [[ -n $has_node ]] && s+=(node)
  [[ -n $has_python ]] && s+=(python)
  [[ -n $has_rust ]] && s+=(rust)
  [[ -n $has_go ]] && s+=(go)
  [[ -n $has_swift ]] && s+=(swift)
  echo "${s[*]:-unknown}"
}

flatten_links() { # a markdown link to a relative target is prose here, not an edge
  sed -E 's@\[([^]]*)\]\(([.a-zA-Z0-9_][^):]*)\)@\1@g'
}

# ponytail: surfaces scheduled CI + consecutive-failure count so a cold agent sees
# dead crons; one gh call per remote repo, weekly job so latency is fine. Silent
# on gh failure — atlas scan must never break on network.
wf_table() {
  local rem="$1"
  [[ -z $rem ]] && return
  # event=="dynamic" drops Dependabot's per-PR runs — one-shot, uniquely named,
  # they'd swamp the table with a row each and hide the real scheduled workflows.
  gh run list -R "$rem" --limit 60 --json name,conclusion,createdAt,event 2>/dev/null | jq -r '
    map(select(.event != "dynamic"))
    | group_by(.name)[]
    | sort_by(.createdAt) | reverse
    | {n: (.[0].name | if length > 45 then .[0:44] + "…" else . end),
       c: (.[0].conclusion // "running"),
       d: (.[0].createdAt | split("T")[0]),
       f: ([.[] | .conclusion] | index("success") // length)}
    | "| \(.n) | \(.d) | \(.c) | \(.f) |"' 2>/dev/null || true
}

# witr: one lsof snapshot of all live cwd->pid mappings, so we don't shell out
# per repo. Repo with no live process just gets no ## Running section.
declare -A REPO_PID
if command -v witr >/dev/null && command -v lsof >/dev/null; then
  while read -r pid path; do
    [[ -n ${REPO_PID[$path]:-} ]] || REPO_PID["$path"]="$pid"
  done < <(lsof -d cwd -a -Fpn 2>/dev/null | awk '/^p/{pid=substr($0,2)} /^n/{print pid, substr($0,2)}')
fi

# Which launchd services run out of each repo. One pass over the service scan,
# same shape as the witr map above. service-atlas.sh writes `repo: <category>/<name>`,
# which is exactly $rel below, so this is an exact match and not a suffix guess.
declare -A REPO_SVC
SVC_DIR="$HOME/wiki/atlas/services"
if [[ -d $SVC_DIR ]]; then
  for s in "$SVC_DIR"/*.md; do
    [[ -f $s ]] || continue
    svc_repo="$(sed -n 's/^repo: *//p' "$s" | head -1)"
    [[ -n $svc_repo && $svc_repo != none ]] || continue
    svc_title="$(sed -n 's/^title: *//p' "$s" | head -1)"
    svc_loaded="$(sed -n 's/^loaded: *//p' "$s" | head -1)"
    # a real markdown link, not backticked text: repo -> service is the one
    # edge the entity graph can draw inside the bundle, and `atlas graph-check` counts it
    REPO_SVC["$svc_repo"]+="- [${svc_title:-$(basename "$s" .md)}](../services/$(basename "$s")) — loaded: ${svc_loaded:-unknown}"$'\n'
  done
fi

before=()
for f in "$OUT"/*.md; do [[ -f $f ]] && before+=("$(basename "$f")"); done

generated=()
index_entries=()
while IFS= read -r gitdir; do
  repo="${gitdir%/.git}"
  # ponytail: opt-out marker in the repo itself, not a central list here — a
  # list in atlas drifts the moment a repo is renamed or moved. A scanned repo
  # is not necessarily an onboarded one (this find is flat over ~/dev), so this
  # is the only place some repos can say "not me".
  [[ -f "$repo/.atlas-ignore" ]] && continue
  name="$(basename "$repo")"
  rel="${repo#"$DEV"/}"
  category="${rel%%/*}"; [[ $category == "$rel" ]] && category=root
  remote="$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#(git@|https://)##; s#\.git$##' || true)"
  last="$(git -C "$repo" log -1 --format=%cs 2>/dev/null || echo unknown)"
  branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  dirty=no; [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && dirty=yes
  unpushed="$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo -)"  # "-" = no upstream
  indexed=no; [[ -d $repo/.gitnexus ]] && indexed=yes
  ktx=no; [[ -d $repo/ktx || -d $repo/_ktx ]] && ktx=yes
  # A README's own links (CHANGELOG.md, ./SECURITY.md) mean nothing once the
  # prose is lifted into the bundle: nothing resolves there and the checker
  # counts them broken. `~/...` and `http(s)://` targets do resolve, so the
  # pattern flattens only relative ones — a target starting with a word char or
  # a dot and carrying no `:`.
  purpose="$(awk '
    NR==1 && /^---$/ {fm=1; next}
    fm && /^---$/ {fm=0; next}
    fm {next}
    /^```/ {cb=!cb; next}
    cb {next}
    /^[#!\[<]/ {next}
    started && !NF {exit}
    NF {print; started=1}
  ' "$repo/README.md" 2>/dev/null | tr '\n' ' ' | head -c 300 | flatten_links || true)"
  # OKF v0.2 carries the summary in frontmatter; the body copy is what the index
  # listing is compared against, so both must come from this one string.
  desc="$(printf '%s' "${purpose:-No summary.}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  # fold top almanac decisions/pitfalls into the
  # entity doc. Empty for repos with no almanac/ — never fails the scan.
  fold="$("$HERE/almanac-fold.sh" "$repo" 2>/dev/null || true)"

  wf="$(wf_table "$remote")"
  [[ -n $wf ]] && wf=$'## Workflows\n\n| workflow | last run | status | consecutive failures |\n|---|---|---|---|\n'"$wf"

  services=""
  [[ -n ${REPO_SVC[$rel]:-} ]] && services=$'## Services\n\n'"${REPO_SVC[$rel]}"

  running=""
  pid="${REPO_PID[$repo]:-}"
  if [[ -n $pid ]]; then
    note="$(witr --pid "$pid" --short --no-color 2>/dev/null || true)"
    [[ -n $note ]] && running=$'## Running\n\n```\n'"$note"$'\n```'
  fi

  f="$OUT/$name.md"
  manual=""
  old_hash=""
  old_reviewed=""
  if [[ -f $f ]]; then
    manual="$(sed -n "/$MARKER/,\$p" "$f")"
    old_hash="$(sed -n 's/^manual-hash: *//p' "$f" | head -1)"
    old_reviewed="$(sed -n 's/^manual-reviewed: *//p' "$f" | head -1)"
  fi
  manual_body="${manual:-$MARKER}"
  # manual-reviewed tracks the hand-written section only (below $MARKER), via
  # content hash — the auto-generated part above it is already covered by
  # last-commit/timestamp and changes every scan, so git-log on the whole file
  # can't distinguish "regenerated" from "a human actually edited the manual note".
  new_hash="$(printf '%s' "$manual_body" | shasum -a 256 | cut -d' ' -f1)"
  if [[ $new_hash == "$old_hash" && -n $old_reviewed ]]; then
    manual_reviewed="$old_reviewed"
  else
    manual_reviewed="$(date +%F)"
  fi

  # OKF v0.2 `stale_after`: when this doc stops being trustworthy, said by the
  # doc instead of by a constant in the gate. Derived from the repo's own recent
  # cadence (span of its last 10 commits), so a repo that moves weekly goes
  # stale in weeks and a dormant one does not nag. Clamped to [7, 365] days:
  # a burst of 10 commits in an hour must not expire the doc tomorrow.
  # || true: a repo with no commits yet makes git exit 128, and under pipefail
  # that killed the whole scan (2026-10-11, every run, one empty repo)
  oldest="$(git -C "$repo" log -10 --format=%cs 2>/dev/null | tail -1 || true)"
  cadence=30
  if [[ -n $oldest && $last != unknown ]]; then
    o="$(date -j -f '%Y-%m-%d' "$oldest" +%s 2>/dev/null || true)"
    n="$(date -j -f '%Y-%m-%d' "$last" +%s 2>/dev/null || true)"
    [[ -n $o && -n $n ]] && cadence=$(( (n - o) / 86400 ))
  fi
  ((cadence < 7)) && cadence=7
  ((cadence > 365)) && cadence=365
  stale_after="$(date -j -v+${cadence}d -f '%Y-%m-%d' "$manual_reviewed" +%F 2>/dev/null || echo "$manual_reviewed")"

  {
    cat <<EOF
---
type: repo
title: $name
description: "$desc"
path: ~/dev/$rel
remote: ${remote:-none}
category: $category
stack: $(stack_of "$repo")
last-commit: $last
branch: ${branch:-none}
dirty: $dirty
unpushed: $unpushed
gitnexus-indexed: $indexed
ktx: $ktx
generated: { by: process:repo-atlas, at: $(date -u +%FT%TZ) }
manual-reviewed: $manual_reviewed
stale_after: $stale_after
manual-hash: $new_hash
---

${purpose:-No README summary.}

$fold
$wf
$services
$running
EOF
    echo "$manual_body"
  } | "$HERE/write-if-changed.sh" "$f"
  generated+=("$name.md")
  index_entries+=("- [$name](repos/$name.md) - ${purpose:-No summary.}")
done < <(find "$DEV" -maxdepth 3 -name .git -type d 2>/dev/null | sort)

# prune atlas files for deleted repos
for f in "$OUT"/*.md; do
  b="$(basename "$f")"
  [[ " ${generated[*]:-} " == *" $b "* ]] || rm "$f"
done

# F3: agent-harness entities — non-git config dirs (~/.claude, opencode, pi).
# Fixed list, not a filesystem crawl: these three are the harnesses the design
# names explicitly; no signal to auto-discover more without false positives.
ENV_OUT="$HOME/wiki/atlas/agent-harnesses"
mkdir -p "$ENV_OUT"

env_generated=()
env_index_entries=()

# One concept per MCP server (F3b). Bash 3.2 has no associative arrays, so the
# registry is three parallel arrays keyed by index.
mcp_names=(); mcp_users=(); mcp_cmds=()

mcp_register() { # server harness mcp_file mcp_key
  local s="$1" h="$2" file="$3" key="$4" i cmd
  # the executable, never its args: a command line is a plausible place for a
  # token and this bundle is committed
  cmd="$(sed 's|^[[:space:]]*//.*||' "$file" \
    | jq -r "$key[\"$s\"].command | if type == \"array\" then .[0] else . end" 2>/dev/null || true)"
  for ((i = 0; i < ${#mcp_names[@]}; i++)); do
    if [[ ${mcp_names[$i]} == "$s" ]]; then mcp_users[$i]="${mcp_users[$i]}, $h"; return; fi
  done
  mcp_names+=("$s"); mcp_users+=("$h"); mcp_cmds+=("${cmd:-unknown}")
}

mcp_links() { # "a, b" -> "[a](../mcp/a.md), [b](../mcp/b.md)"
  local s out=""
  for s in ${1//,/ }; do out+="${out:+, }[$s](../mcp/$s.md)"; done
  printf '%s' "$out"
}

harness_entity() { # name hdir settings mcp_file mcp_key agents_dir skills_dir purpose
  local name="$1" hdir="$2" settings="$3" mcp_file="$4" mcp_key="$5" agents_dir="$6" skills_dir="$7" purpose="$8"
  # `return` alone carries the test's status, and under set -e a harness that
  # simply is not installed on this machine aborted the whole scan
  [[ -d $hdir ]] || return 0

  local mcp_servers=""
  # opencode's config is JSONC and jq chokes on it, so every one of its servers
  # silently read as `none`. Only whole-line comments are stripped: a `//` inside
  # a string (the $schema URL, a http:// proxy arg) has to survive.
  # ceiling: a trailing comment after code on the same line is not handled.
  [[ -f $mcp_file ]] && mcp_servers="$(sed 's|^[[:space:]]*//.*||' "$mcp_file" \
    | jq -r "$mcp_key // {} | keys | join(\", \")" 2>/dev/null || true)"

  local s
  for s in ${mcp_servers//,/ }; do mcp_register "$s" "$name" "$mcp_file" "$mcp_key"; done

  local agents_n=0
  [[ -n $agents_dir && -d $agents_dir ]] && agents_n=$(find "$agents_dir" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

  local skills_n=0
  [[ -n $skills_dir && -d $skills_dir ]] && skills_n=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

  local f="$ENV_OUT/$name.md"
  local manual=""
  [[ -f $f ]] && manual="$(sed -n "/$MARKER/,\$p" "$f")"

  {
    cat <<EOF
---
type: agent-harness
title: $name
path: $hdir
settings: ${settings:-none}
mcp-servers: ${mcp_servers:-none}
agents: $agents_n
skills: $skills_n
generated: { by: process:repo-atlas, at: $(date -u +%FT%TZ) }
---

$purpose

EOF
    # the frontmatter field is a string; this is the edge
    [[ -n $mcp_servers ]] && { echo "MCP servers: $(mcp_links "$mcp_servers")"; echo; }
    echo "${manual:-$MARKER}"
  } | "$HERE/write-if-changed.sh" "$f"
  env_generated+=("$name.md")
  env_index_entries+=("- [$name]($name.md) — mcp: ${mcp_servers:-none}, agents: $agents_n, skills: $skills_n")
}

harness_entity claude-code "$HOME/.claude" "~/.claude/settings.json" "$HOME/.claude.json" ".mcpServers" "$HOME/.claude/agents" "$HOME/.claude/skills" \
  "Claude Code agent harness config: settings, custom subagents (agents/), skills (skills/), MCP servers. MCPs live in the sibling ~/.claude.json, not this dir."
harness_entity opencode "$HOME/.config/opencode" "~/.config/opencode/opencode.jsonc" "$HOME/.config/opencode/opencode.jsonc" ".mcp" "" "$HOME/.config/opencode/skills" \
  "opencode agent harness config: opencode.jsonc (MCPs, LiteLLM provider/models), oh-my-openagent.json plugin (agent-to-model routing), skills/."
harness_entity pi "$HOME/.pi/agent" "~/.pi/agent/settings.json" "$HOME/.pi/agent/mcp.json" ".mcpServers" "" "" \
  "pi agent harness config: settings.json, mcp.json (MCP servers), litellm-models.json."

for f in "$ENV_OUT"/*.md; do
  b="$(basename "$f")"
  [[ $b == index.md ]] && continue
  [[ " ${env_generated[*]:-} " == *" $b "* ]] || rm -f "$f"
done

# OKF v0.2 §8: index files carry no frontmatter. Only the bundle-root index.md
# may, and only for okf_version.
{
  echo "# Atlas — Agent Harness Index"
  echo
  printf '%s\n' "${env_index_entries[@]:-}"
} > "$ENV_OUT/index.md"

echo "atlas: ${#env_generated[@]} agent harnesses mapped"

# F3b: the MCP servers the harnesses load, one concept each. They were already
# known — as a comma-separated string in one frontmatter field, which draws no
# edge. A doc per server makes the relation a link
# in both directions. No summary line: nothing in the config says what a server
# does, and inventing one is worse than leaving it blank (same call as
# `description:` on services/).
MCP_OUT="$HOME/wiki/atlas/mcp"
mkdir -p "$MCP_OUT"
mcp_generated=(); mcp_index_entries=()
for ((i = 0; i < ${#mcp_names[@]}; i++)); do
  mname="${mcp_names[$i]}"; musers="${mcp_users[$i]}"; mcmd="${mcp_cmds[$i]}"
  f="$MCP_OUT/$mname.md"
  manual=""
  [[ -f $f ]] && manual="$(sed -n "/$MARKER/,\$p" "$f")"
  hlinks=""
  for h in ${musers//,/ }; do hlinks+="${hlinks:+, }[$h](../agent-harnesses/$h.md)"; done
  {
    cat <<EOF
---
type: mcp-server
title: $mname
command: $mcmd
harnesses: $musers
generated: { by: process:repo-atlas, at: $(date -u +%FT%TZ) }
---

Loaded by: $hlinks

EOF
    echo "${manual:-$MARKER}"
  } | "$HERE/write-if-changed.sh" "$f"
  mcp_generated+=("$mname.md")
  mcp_index_entries+=("- [$mname]($mname.md) — $mcmd, loaded by: $musers")
done

for f in "$MCP_OUT"/*.md; do
  b="$(basename "$f")"
  [[ $b == index.md ]] && continue
  [[ " ${mcp_generated[*]:-} " == *" $b "* ]] || rm -f "$f"
done

{
  echo "# Atlas — MCP Server Index"
  echo
  printf '%s\n' "${mcp_index_entries[@]:-}"
} > "$MCP_OUT/index.md"

echo "atlas: ${#mcp_generated[@]} MCP servers mapped"

# OKF v0.2 bundle root index.md (§8) — fully regenerated, no manual section
# (pure listing). The one place in the bundle where an index may carry
# frontmatter, and only to declare the version (§12).
{
  echo "---"
  echo 'okf_version: "0.2"'
  echo "---"
  echo
  echo "# Atlas — Repo Index"
  echo
  printf '%s\n' "${index_entries[@]:-}"
} > "$HOME/wiki/atlas/index.md"

# OKF v0.2 bundle root log.md (§9) — only log runs that actually added/removed a repo
added=(); removed=()
for f in "${generated[@]:-}"; do [[ " ${before[*]:-} " == *" $f "* ]] || added+=("${f%.md}"); done
for f in "${before[@]:-}"; do [[ " ${generated[*]:-} " == *" $f "* ]] || removed+=("${f%.md}"); done
if ((${#added[@]} || ${#removed[@]})); then
  log="$HOME/wiki/atlas/log.md"
  # ponytail: prepends a fresh "## date" heading per run, even same-day reruns —
  # duplicate date headings are spec-legal, not worth merging for a weekly job
  {
    echo "# Atlas Repo Log"
    echo
    echo "## $(date +%F)"
    for r in "${added[@]:-}"; do echo "* **Creation**: Added [$r](repos/$r.md)."; done
    for r in "${removed[@]:-}"; do echo "* **Deprecation**: Removed $r (no longer under ~/dev)."; done
    echo
    [[ -f $log ]] && tail -n +2 "$log"
  } > "$log.tmp"
  mv "$log.tmp" "$log"
fi

echo "atlas: ${#generated[@]} repos mapped"
# ponytail: reindex failure is a warning, not a scan failure. This is the last
# command, so under set -e its status becomes the script's, and the ledger then
# records the whole scan `failed` with every entity doc already written. Same
# trap when qmd is simply not installed: `command -v` returns 1 and the scan
# "fails". Report on stderr, exit on the scan's own merits.
if command -v qmd >/dev/null; then
  if qmd update >/dev/null 2>&1; then echo "qmd reindexed"; else echo "atlas: qmd update failed, index is stale" >&2; fi
  # Only here, not in service-atlas: this scan runs nightly and after every
  # cascade, and embed covers every collection. Measured 2026-10-11: 532 docs in
  # 140 s; with byte-stable docs a normal scan leaves a handful. Never fatal.
  qmd embed >/dev/null 2>&1 || echo "atlas: qmd embed failed, new docs answer from BM25 only" >&2
else
  echo "atlas: qmd not installed, index not refreshed" >&2
fi
