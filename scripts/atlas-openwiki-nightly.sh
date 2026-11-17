#!/bin/bash
# atlas-openwiki-nightly.sh — generate openwiki for the repos that
# post-commit marked pending, one at a time, in the night window. Runs the full
# cascade per repo, so the verdict, splice, auto-commit and wiki lock are the
# same code path as before; only the trigger moved. Launched by launchd
# (com.atlas.openwiki-nightly, nix-darwin); `atlas cascade <repo>` stays the
# on-demand path.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pending="${ATLAS_STATE_DIR:-$HOME/.local/state/atlas}/openwiki-pending"
# No new run starts at or after this hour. ponytail: a run started just before
# it can still spill past it (~34 min of engine time on average);
# upgrade path is to skip when the repo's last run took longer than what is left.
end_hour="${ATLAS_OPENWIKI_WINDOW_END:-7}"

# launchd does not source ~/.zshrc, where the virtual key is exported from pass.
export ATLAS_LITELLM_KEY="${ATLAS_LITELLM_KEY:-$(pass show litellm/atlas-key 2>/dev/null)}"

for marker in "$pending"/*; do
  [[ -f $marker ]] || continue
  if (( 10#$(date +%H) >= end_hour )); then
    echo "$(date +%FT%T) nightly: window closed at ${end_hour}h, left for tomorrow: $(cd "$pending" && echo *)"
    break
  fi
  repo="$(cat "$marker")"
  # Before the run, so a commit landing during it re-marks the repo for tomorrow.
  rm -f "$marker"
  [[ -d $repo ]] || continue
  ATLAS_CASCADE_TRIGGER=nightly caffeinate -i "$root/scripts/atlas-cascade.sh" "$repo" \
    >>"$HOME/wiki/atlas/cascade.log" 2>&1
done
