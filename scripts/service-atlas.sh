#!/bin/bash
# service-atlas.sh — scan ~/Library/LaunchAgents + listening ports, regenerate
# ~/wiki/atlas/services/*.md (OKF frontmatter). Mirrors repo-atlas.sh's pattern.
# ponytail: flat find + overwrite-above-marker, same as repo-atlas.sh
set -euo pipefail

LA="$HOME/Library/LaunchAgents"
OUT="$HOME/wiki/atlas/services"
MARKER='<!-- manual -->'
mkdir -p "$OUT"
# Every plist here is this Mac's own LaunchAgent. The edge only exists while
# its hand-written hosts/ doc does.
host="${ATLAS_HOST:-$(hostname -s)}"
[[ -f $HOME/wiki/atlas/hosts/$host.md ]] || host=none

# Run manifest. Best-effort, same shape as repo-atlas.sh.
_rs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/atlas-run-state.sh"
_run_id="$("$_rs" begin service-atlas --kind scan --operation service-scan \
  --trigger "${ATLAS_TRIGGER:-launchd}" --pid $$ 2>/dev/null || true)"
_finish_run() {
  local rc=$?
  [[ -n $_run_id ]] || return 0
  if ((rc == 0)); then
    "$_rs" finish "$_run_id" --exit-code 0 --status succeeded >/dev/null 2>&1 || true
  else
    "$_rs" finish "$_run_id" --exit-code "$rc" --status failed --error "exit $rc" >/dev/null 2>&1 || true
  fi
}
trap _finish_run EXIT

before=()
for f in "$OUT"/*.md; do [[ -f $f ]] && before+=("$(basename "$f")"); done

ports_snapshot="$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1{print $1, $2, $9}')"

generated=()
index_entries=()
while IFS= read -r plist; do
  label="$(plutil -extract Label raw "$plist" 2>/dev/null || basename "$plist" .plist)"
  program="$(plutil -extract ProgramArguments json -o - "$plist" 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))' 2>/dev/null || true)"
  [[ -z $program ]] && program="$(plutil -extract Program raw "$plist" 2>/dev/null || true)"

  # source repo: does the program path point under ~/dev?
  repo=none
  if [[ $program == *"$HOME/dev/"* ]]; then
    rest="${program#*"$HOME/dev/"}"
    repo="${rest%% *}"
    repo="$(echo "$repo" | cut -d/ -f1-2)"
  fi

  loaded=no; pid=-
  status_line="$(launchctl list 2>/dev/null | awk -v l="$label" '$3==l{print $1, $2}')"
  if [[ -n $status_line ]]; then
    loaded=yes
    pid="$(awk '{print $1}' <<<"$status_line")"
  fi

  ports=$(awk -v p="$pid" '$2==p{print $3}' <<<"$ports_snapshot" | sed -E 's/.*:([0-9]+)$/\1/' | sort -u | paste -sd, -)

  # observed state. `loaded`/`pid` are declarations: launchd accepted the plist,
  # or a process exists right now. Neither says the job ever did its work —
  # roborev-daemon read healthy for a week while its delivery path failed ~98%
  # of the time. The declared log paths are the only on-disk evidence of an
  # actual run, so record when they last changed and let the reader judge.
  last_output=unknown; stderr_state=unknown
  sout="$(plutil -extract StandardOutPath raw "$plist" 2>/dev/null || true)"
  serr="$(plutil -extract StandardErrorPath raw "$plist" 2>/dev/null || true)"
  if [[ -n $sout ]]; then
    if [[ -f $sout ]]; then
      last_output="$(date -r "$sout" +%F) ($(( ($(date +%s) - $(stat -f %m "$sout")) / 86400 ))d ago)"
    else
      last_output=never
    fi
  fi
  if [[ -n $serr ]]; then
    if [[ -f $serr ]]; then
      _sz=$(stat -f %z "$serr")
      if (( _sz == 0 )); then stderr_state=empty
      else stderr_state="${_sz}B @ $(date -r "$serr" +%F)"; fi
    else
      stderr_state=never
    fi
  fi

  name="${label//./-}"
  f="$OUT/$name.md"
  manual=""
  [[ -f $f ]] && manual="$(sed -n "/$MARKER/,\$p" "$f")"

  {
    cat <<EOF
---
type: service
title: $label
plist: ~/Library/LaunchAgents/$(basename "$plist")
program: ${program:-unknown}
repo: $repo
host: $host
loaded: $loaded
pid: $pid
ports: ${ports:-none}
last-output: $last_output
stderr: $stderr_state
generated: { by: process:service-atlas, at: $(date -u +%FT%TZ) }
---

EOF
    # the edge rendered for OKF tools; frontmatter is the source.
    [[ $host == none ]] || printf '# Related Concepts\n\n- [%s](../hosts/%s.md): runs on this host (service-atlas)\n\n' "$host" "$host"
    echo "${manual:-$MARKER}"
  } | "$(dirname "$_rs")/write-if-changed.sh" "$f"
  generated+=("$name.md")
  index_entries+=("- [$label](services/$name.md) — repo: $repo, ports: ${ports:-none}")
done < <(find "$LA" -maxdepth 1 -name '*.plist' 2>/dev/null | sort)

# prune atlas files for removed launchd jobs
for f in "$OUT"/*.md; do
  b="$(basename "$f")"
  [[ " ${generated[*]:-} " == *" $b "* ]] || rm -f "$f"
done

# OKF v0.2 §8: index files carry no frontmatter (bundle root only).
{
  echo "# Atlas — Service Index"
  echo
  printf '%s\n' "${index_entries[@]:-}"
} > "$OUT/index.md"

echo "atlas: ${#generated[@]} services mapped"
# ponytail: reindex failure is a warning, not a scan failure. This is the last
# command, so under set -e its status becomes the script's, and the ledger then
# records the whole scan `failed` with every entity doc already written. Same
# trap when qmd is simply not installed: `command -v` returns 1 and the scan
# "fails". Report on stderr, exit on the scan's own merits.
if command -v qmd >/dev/null; then
  if qmd update >/dev/null 2>&1; then echo "qmd reindexed"; else echo "atlas: qmd update failed, index is stale" >&2; fi
else
  echo "atlas: qmd not installed, index not refreshed" >&2
fi
