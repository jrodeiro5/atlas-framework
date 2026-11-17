#!/bin/bash
# openwiki-llm-env.sh <repo> — export OPENAI_COMPATIBLE_* for `openwiki`.
# Routing is decided by repo visibility first, proxy health second:
#   public  → $ATLAS_MODEL_PUBLIC via the local OpenAI-compatible proxy
#             (LiteLLM by default). If the proxy itself is down, an optional
#             cloud fallback ($ATLAS_FALLBACK_URL/_KEY/_MODEL) is used when all
#             three are set; otherwise generation is refused.
#   private → $ATLAS_MODEL_PRIVATE via the same proxy, or nothing.
# Private/unknown is deny-by-default: if `gh` can't confirm the repo is public,
# treat it as private, and proxy-down means refuse. No cloud path for private.
# Keep private model groups local in the proxy config too: no global fallback
# there, or private code can leave the machine behind this script's back.
#
# Environment:
#   ATLAS_LLM_URL        proxy root (default http://localhost:4000); needs
#                        /health/liveliness and /v1 (LiteLLM's shape)
#   ATLAS_LITELLM_KEY    scoped virtual key for the proxy (never the admin key)
#   ATLAS_MODEL_PUBLIC   model id for public repos  (default atlas-public)
#   ATLAS_MODEL_PRIVATE  model id for private repos (default atlas-private)
#   ATLAS_FALLBACK_URL / ATLAS_FALLBACK_KEY / ATLAS_FALLBACK_MODEL
#                        optional cloud route for PUBLIC repos when the proxy is down
set -euo pipefail
repo="${1:?usage: source openwiki-llm-env.sh <repo>}"
# openwiki 0.9 sends usage telemetry unless told not to; ~/.openwiki/.env says
# so too, this keeps it off if that file is lost or rewritten by `openwiki setup`.
export OPENWIKI_TELEMETRY_DISABLED=1
llm_url="${ATLAS_LLM_URL:-http://localhost:4000}"
llm_url="${llm_url%/}"

# Refuse generation off the default branch: a wiki written from a feature
# branch documents code that main does not have.
default_branch="$(cd "$repo" && git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
current_branch="$(cd "$repo" && git branch --show-current 2>/dev/null || true)"
is_worktree="no"
if (cd "$repo" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
  gitdir="$(cd "$repo" && git rev-parse --git-dir 2>/dev/null || true)"
  commondir="$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null || true)"
  [[ "$gitdir" != "$commondir" ]] && is_worktree="yes"
fi
export ATLAS_GIT_BRANCH="${current_branch:-unknown}"
export ATLAS_GIT_WORKTREE="$is_worktree"

# Fail-open: no origin/HEAD means we cannot judge; never block on unknown.
if [[ "${OPENWIKI_ALLOW_BRANCH:-0}" != "1" && -n "$default_branch" && -n "$current_branch" && "$current_branch" != "$default_branch" ]]; then
  echo "$(date +%FT%T) REFUSED: repo on branch $current_branch (default $default_branch), worktree=$is_worktree, repo=$repo" >> "$HOME/wiki/atlas/fallback.log"
  osascript -e "display notification \"OpenWiki: repo on branch $current_branch (default $default_branch), generation refused\" with title \"atlas: generation refused\"" 2>/dev/null || true
  echo "openwiki-llm-env: repo on branch '$current_branch' (default '$default_branch') — refusing; OPENWIKI_ALLOW_BRANCH=1 to override" >&2
  exit 3  # not 1: refused by design, the cascade records it as skipped, not failed
fi

is_private="$(cd "$repo" && gh repo view --json isPrivate -q .isPrivate 2>/dev/null)"

proxy_up() { curl -sf --max-time 2 "$llm_url/health/liveliness" >/dev/null 2>&1; }
log() { echo "$(date +%FT%T) $*" >> "$HOME/wiki/atlas/fallback.log"; }

if [[ "$is_private" == "false" ]]; then
  if proxy_up; then
    export OPENAI_COMPATIBLE_BASE_URL="$llm_url/v1"
    export OPENAI_COMPATIBLE_API_KEY="${ATLAS_LITELLM_KEY:?ATLAS_LITELLM_KEY not set (scoped key, never the admin key)}"
    export OPENWIKI_MODEL_ID="${ATLAS_MODEL_PUBLIC:-atlas-public}"
    echo "openwiki-llm-env: public repo — $OPENWIKI_MODEL_ID via proxy"
    log "public: $OPENWIKI_MODEL_ID via proxy repo=$repo"
  elif [[ -n "${ATLAS_FALLBACK_URL:-}" && -n "${ATLAS_FALLBACK_KEY:-}" && -n "${ATLAS_FALLBACK_MODEL:-}" ]]; then
    export OPENAI_COMPATIBLE_BASE_URL="$ATLAS_FALLBACK_URL"
    export OPENAI_COMPATIBLE_API_KEY="$ATLAS_FALLBACK_KEY"
    export OPENWIKI_MODEL_ID="$ATLAS_FALLBACK_MODEL"
    echo "openwiki-llm-env: public repo — proxy unavailable, using cloud fallback $OPENWIKI_MODEL_ID"
    log "public, proxy-down: cloud fallback $OPENWIKI_MODEL_ID repo=$repo"
  else
    log "REFUSED: public repo, proxy down, no fallback configured, repo=$repo"
    echo "openwiki-llm-env: proxy unreachable and no ATLAS_FALLBACK_* configured — refusing" >&2
    exit 1
  fi
elif proxy_up; then
  export OPENAI_COMPATIBLE_BASE_URL="$llm_url/v1"
  # One scoped virtual key for all atlas traffic: the proxy's spend log can
  # attribute it, and the admin key never leaves the shell that runs the proxy.
  export OPENAI_COMPATIBLE_API_KEY="${ATLAS_LITELLM_KEY:?ATLAS_LITELLM_KEY not set (scoped key, never the admin key)}"
  export OPENWIKI_MODEL_ID="${ATLAS_MODEL_PRIVATE:-atlas-private}"
  echo "openwiki-llm-env: private repo — $OPENWIKI_MODEL_ID via proxy"
else
  # Loud refusal: the cascade swallows stdout, so a skipped generation must
  # leave a persistent trace and a user notification.
  log "REFUSED: private/unknown repo, proxy down, repo=$repo"
  osascript -e 'display notification "OpenWiki: proxy down, private repo, generation refused" with title "atlas: generation refused"' 2>/dev/null || true
  echo "openwiki-llm-env: proxy unreachable and repo is private/unknown — refusing, no cloud path for private code" >&2
  exit 1
fi
export OPENWIKI_PROVIDER="openai-compatible"
# openwiki >=0.6 can run page workers in parallel. The local engine is one
# thread by design: N workers only queue N requests, and
# concurrency >1 silently raises retries 3 -> 5. Pin both; process env wins
# over ~/.openwiki/.env. Guard 400s are retried by litellm-tag-inject.cjs.
export OPENWIKI_PAGE_CONCURRENCY=1
export OPENWIKI_PROVIDER_RETRY_ATTEMPTS=3

# Per-repo attribution (litellm-tag-inject.cjs, preloaded by openwiki-pinned.sh).
# atlas drives every repo through one virtual key, so the proxy's spend log could
# not say which repo spent what. The tag header fixes that without a key per repo.
# Only set on the proxy route -- a cloud fallback has no tag ledger, and the
# preload tags whatever OPENAI_COMPATIBLE_BASE_URL points at.
case "$OPENAI_COMPATIBLE_BASE_URL" in
  "$llm_url"/*) export ATLAS_TAG_REPO="$(basename "$repo")" ;;
esac
