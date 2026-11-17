#!/bin/bash
# atlas-onboard.sh <repo> — idempotent bootstrap:
#   CLAUDE.md/AGENTS.md symlink → hooksPath → gitnexus analyze →
#   openwiki init/update → codealmanac init → repo-atlas.sh (ends in
#   qmd update) → verify freshness.
# Safe to re-run; each step is a no-op when already done.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "${1:?usage: atlas-onboard.sh <repo>}" && pwd)"
name="$(basename "$repo")"

git -C "$repo" rev-parse --show-toplevel >/dev/null  # must be a git repo

# --undo: detach the repo from atlas (verified reversal before
# any rollout wave). Generated artifacts (entity doc, openwiki/, almanac/) stay —
# they're inert without the hook; delete by hand if truly unwanted.
if [[ "${2:-}" == "--undo" ]]; then
  current="$(git -C "$repo" config core.hooksPath || true)"
  if [[ $current == "$root/hooks" ]]; then
    git -C "$repo" config --unset core.hooksPath
    echo "onboard-undo: hooksPath unset — cascade will no longer fire for $name"
  else
    echo "onboard-undo: hooksPath is '${current:-<unset>}', not atlas — nothing to undo"
  fi
  echo "onboard-undo: kept: ~/wiki/atlas/repos/$name.md, $repo/openwiki/, $repo/almanac/"
  exit 0
fi

# Run manifest. Below the --undo block on purpose: undo is a one-line
# config unset that reports its own result, while the path that follows is the
# long multi-step one (gitnexus analyze, openwiki update) that can die partway
# and leave a repo half-onboarded. Best-effort, same shape as repo-atlas.sh.
_rs="$root/scripts/atlas-run-state.sh"
_run_id="$("$_rs" begin atlas-onboard --kind onboard --operation bootstrap \
  --repo "$name" --trigger "${ATLAS_TRIGGER:-manual}" --pid $$ 2>/dev/null || true)"
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

# 0. canonical CLAUDE.md, AGENTS.md as symlink (2026-07-20: Claude Code reads
# CLAUDE.md natively; AGENTS.md is the cross-tool standard name — symlink beats
# a Claude-only @import since it resolves at the OS level for any reader).
if [[ -L "$repo/AGENTS.md" ]]; then
  : # already a symlink, no-op
elif [[ -f "$repo/CLAUDE.md" && -f "$repo/AGENTS.md" ]]; then
  echo "onboard: WARNING both CLAUDE.md and real AGENTS.md exist, not touching (resolve manually)" >&2
elif [[ -f "$repo/AGENTS.md" ]]; then
  mv "$repo/AGENTS.md" "$repo/CLAUDE.md"
  ln -s CLAUDE.md "$repo/AGENTS.md"
  echo "onboard: AGENTS.md content moved to CLAUDE.md, symlink created"
elif [[ -f "$repo/CLAUDE.md" ]]; then
  ln -s CLAUDE.md "$repo/AGENTS.md"
  echo "onboard: AGENTS.md -> CLAUDE.md symlink created"
fi

# 0b. atlas back-reference. Without this a repo's CLAUDE.md never tells an agent
# the machine-wide wiki exists, so the entity doc gets written and never read.
# Marker-delimited and idempotent; AGENTS.md mirrors it via the symlink above.
"$root/scripts/atlas-pointer.sh" "$repo"

# 1. hooks — warn instead of silently clobbering a foreign hooksPath
current="$(git -C "$repo" config core.hooksPath || true)"
if [[ -n $current && $current != "$root/hooks" ]]; then
  echo "onboard: WARNING repo has core.hooksPath=$current, overwriting with $root/hooks" >&2
fi
git -C "$repo" config core.hooksPath "$root/hooks"
if [[ -x "$repo/.git/hooks/pre-commit" ]]; then
  echo "onboard: note: existing .git/hooks/pre-commit will be chained by the atlas pre-commit shim"
fi
echo "onboard: hooksPath -> $root/hooks"

# 1b. staged-secret gate. hooks/pre-commit only runs prek when the repo declares
# a config, so a repo without one silently gets no gate at all — true of every
# onboarded repo but the five that already had a config. Seed the minimum;
# never overwrite a config the repo already has.
if [[ ! -f "$repo/.pre-commit-config.yaml" ]] && command -v gitleaks >/dev/null; then
  cat > "$repo/.pre-commit-config.yaml" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: gitleaks
        name: gitleaks (scan staged changes for secrets)
        entry: gitleaks protect --staged --verbose
        language: system
YAML
  echo "onboard: seeded .pre-commit-config.yaml (gitleaks staged-secret gate)"
elif [[ -f "$repo/.pre-commit-config.yaml" ]]; then
  grep -q gitleaks "$repo/.pre-commit-config.yaml" \
    || echo "onboard: WARNING .pre-commit-config.yaml exists without a gitleaks hook — no staged-secret gate" >&2
fi

# 1c. CLI version pin + drift warning (fork/vendor rejected,
# pin-and-gate chosen instead — prometheus changelog monitors *notify*, this
# *gates*). First onboard pins whatever's installed; later runs compare and
# warn instead of silently trusting a tool whose output shape may have changed.
mkdir -p "$root/.tool-pins"
for tool in gitnexus openwiki codealmanac; do
  if [[ "$tool" == openwiki ]]; then
    # openwiki has no --version flag; read the pinned install.
    installed="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$HOME/.local/lib/node_modules/openwiki/package.json" 2>/dev/null || true)"
    installed="${installed:-unknown}"
  else
    installed="$("$tool" --version 2>/dev/null || echo unknown)"
  fi
  pinfile="$root/.tool-pins/$tool"
  if [[ ! -f "$pinfile" ]]; then
    echo "$installed" > "$pinfile"
    echo "onboard: pinned $tool@$installed"
  elif [[ "$(cat "$pinfile")" != "$installed" ]]; then
    echo "onboard: WARNING $tool version drift: pinned=$(cat "$pinfile") installed=$installed — verify output shape before trusting, then update $pinfile" >&2
  fi
done

# 1d. Entire session capture. `entire enable` writes hooks into the
# SHARED hooksPath — the same class of write that kills the cascade for all 41
# repos at once, which is what the hooks/post-commit check in atlas-check.sh
# exists to catch. Gated three ways:
#   visibility: checkpoints are session transcripts. A sweep measured 11 of 46
#     repos public, and there a push publishes prompts, paths and any secret the
#     session touched. Private only; unknown counts as public.
#   flags: --telemetry defaults true and push_sessions defaults on, so a bare
#     `entire enable` arms that leak. One repo is the proof: enabled
#     without --skip-push-sessions, its settings.json has no strategy_options at
#     all, and 182 checkpoints now sit in its remote.
#   re-run: measured 2026-09-19 in a scratch repo — a second enable prints
#     "already installed", leaves post-commit byte-identical, does not nest
#     post-commit.pre-entire, and leaves an existing pre-commit alone (so the
#     prek shim survives). So it is idempotent and re-running only repairs
#     settings that lack the flags.
if command -v entire >/dev/null; then
  ent_settings="$repo/.entire/settings.json"
  if ! /usr/bin/grep -q '"push_sessions": *false' "$ent_settings" 2>/dev/null \
    || ! /usr/bin/grep -q '"telemetry": *false' "$ent_settings" 2>/dev/null; then
    is_private="$(cd "$repo" && gh repo view --json isPrivate -q .isPrivate 2>/dev/null || true)"
    if [[ "$is_private" != "true" ]]; then
      echo "onboard: entire skipped — repo is not private (checkpoints are session transcripts)"
    else
      # ponytail: claude-code is the fallback, not the rule — wire the agents the
      # repo already has; add a case here when a new one shows up.
      ent_agents=""
      for probe in claude-code:.claude opencode:.opencode pi:.pi; do
        if [[ -d "$repo/${probe#*:}" ]]; then ent_agents="$ent_agents ${probe%%:*}"; fi
      done
      [[ -n "$ent_agents" ]] || ent_agents=" claude-code"
      for agent in $ent_agents; do
        # The env vars are not redundant with the flags. --telemetry writes the
        # setting but the 24h update check has NO settings key at all (verified
        # 2026-09-19: strings has ENTIRE_NO_AUTO_UPDATE, docs.entire.io documents
        # neither it nor the check), so the env is the only way to close it. And
        # -y is never passed: it "accepts telemetry" by design, which would undo
        # --telemetry=false.
        (cd "$repo" && ENTIRE_TELEMETRY_OPTOUT=1 ENTIRE_NO_AUTO_UPDATE=1 \
          entire enable --agent "$agent" --absolute-git-hook-path \
          --skip-push-sessions --telemetry=false) >/dev/null 2>&1 || true
      done
      if /usr/bin/grep -q '"push_sessions": *false' "$ent_settings" 2>/dev/null \
        && /usr/bin/grep -q '"telemetry": *false' "$ent_settings" 2>/dev/null; then
        echo "onboard: entire enabled (${ent_agents# }, local-only)"
      else
        echo "onboard: WARNING entire settings lack the local-only flags — session logs may be pushed" >&2
      fi
    fi
  fi
else
  echo "onboard: entire not installed"
fi

# 2. code graph
if command -v gitnexus >/dev/null; then
  (cd "$repo" && gitnexus analyze) >/dev/null && echo "onboard: gitnexus ok" \
    || echo "onboard: WARNING gitnexus analyze failed" >&2
else
  echo "onboard: WARNING gitnexus not installed" >&2
fi

# 2b. .openwikiignore (OpenWiki 0.2.5+) — every onboarded repo grows the same
# atlas-added noise dirs (almanac/, .gitnexus/); seed once, never overwrite a
# repo's own choice.
#
# openwiki/ is deliberately NOT in this list, however much it looks like it
# belongs. openwiki enforces this file as a hard read *and* write filesystem
# gate, not as a context-selection hint, so excluding the generator's own output
# directory leaves it unable to read the wiki it is updating or write the result.
# It refuses the run, explains itself on stdout, and exits 0. This seed shipped
# openwiki/ on line 10 and froze the wiki in all nine onboarded repos for three
# to five weeks -- see fix(cascade) 49d6c98, which makes the cascade verify the
# stage instead of trusting that exit code.
if [[ ! -f "$repo/.openwikiignore" ]]; then
  cat > "$repo/.openwikiignore" <<'IGNORE'
node_modules/
__pycache__/
.venv/
venv/
dist/
build/
vendor/
.ruff_cache/
.gitnexus/
almanac/
.git/
*.lock
package-lock.json
pnpm-lock.yaml
uv.lock
.env*
coverage/
.next/
.turbo/
.cache/
secrets/
credentials/
private/
*.pem
*.key
.ssh/
id_rsa
id_ed25519
IGNORE
  echo "onboard: seeded .openwikiignore"
fi

# 3. wiki generation — needs the LLM proxy; failure is a warning, not fatal:
#    the entity doc (step 5) is the onboard exit criterion, the wiki catches up
#    on the next commit's cascade.
if command -v openwiki >/dev/null; then
  mode=--init; [[ -d "$repo/openwiki" ]] && mode=--update
  if (source "$root/scripts/openwiki-llm-env.sh" "$repo" \
      && cd "$repo" \
      && "$root/scripts/with-wiki-lock.sh" openwiki code "$mode"); then
    echo "onboard: openwiki $mode ok"
  else
    echo "onboard: WARNING openwiki $mode failed (LLM down?), cascade will retry" >&2
  fi
  rm -f "$repo/.github/workflows/openwiki-update.yml"  # ponytail: openwiki init scaffolds a cloud workflow (openrouter/glm-5.2) that bypasses openwiki-llm-env.sh policy; atlas-cascade covers this locally. Outside the if: it is scaffolded even when the run fails
else
  echo "onboard: WARNING openwiki not installed" >&2
fi

# 4. decision mining
if command -v codealmanac >/dev/null; then
  if [[ -d "$repo/almanac" ]]; then
    echo "onboard: almanac/ already present"
  else
    (cd "$repo" && codealmanac init) && echo "onboard: codealmanac init ok" \
      || echo "onboard: WARNING codealmanac init failed" >&2
  fi
else
  echo "onboard: WARNING codealmanac not installed" >&2
fi

# 5. entity doc + qmd
"$root/scripts/repo-atlas.sh"

# 6. verify (ADR freshness criterion: entity last-commit == repo HEAD)
f="$HOME/wiki/atlas/repos/$name.md"
if [[ ! -f $f ]]; then
  echo "onboard: FAIL no entity doc at $f (repo outside ~/dev? repo-atlas.sh only scans there)" >&2
  exit 1
fi
head_date="$(git -C "$repo" log -1 --format=%cs 2>/dev/null || echo unknown)"  # empty repo: matches repo-atlas's "unknown"
doc_date="$(awk -F': ' '/^last-commit:/{print $2; exit}' "$f")"
if [[ $doc_date != "$head_date" ]]; then
  echo "onboard: FAIL entity doc last-commit=$doc_date != HEAD $head_date" >&2
  exit 1
fi
echo "onboard: OK — $name self-documents from now on (entity doc fresh: $doc_date)"
