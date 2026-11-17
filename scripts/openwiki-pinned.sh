#!/bin/sh
# ABI pin for openwiki. Installed as ~/.local/bin/openwiki, replacing
# upstream's `#!/usr/bin/env node` symlink.
#
# openwiki's better-sqlite3 12.11.1 is node-gyp-built for NODE_MODULE_VERSION 127
# (Node 22); qmd's is built for 147 (Node 26). One PATH cannot serve both, and
# a newer Node first in a non-interactive PATH hands the cascade an interpreter
# that cannot dlopen this module. Name the interpreter here instead of hoping
# PATH is ordered right.
#
# Install:  ln -sfn "$PWD/scripts/openwiki-pinned.sh" ~/.local/bin/openwiki
# Verified by: atlas check ("openwiki pinned to ...").
# --require adds x-litellm-tags to openwiki's proxy calls so LiteLLM_SpendLogs
# attributes tokens per repo (see litellm-tag-inject.cjs). No-op unless
# ATLAS_TAG_REPO is set, which only openwiki-llm-env.sh does.
# Self-locating: the symlink in ~/.local/bin resolves back to this checkout.
self="$0"; while [ -L "$self" ]; do l="$(readlink "$self")"; case "$l" in /*) self="$l" ;; *) self="$(dirname "$self")/$l" ;; esac; done
here="$(cd "$(dirname "$self")" && pwd)"
exec "$HOME/.local/bin/node" \
  --require "$here/litellm-tag-inject.cjs" \
  "$HOME/.local/lib/node_modules/openwiki/dist/cli/cli.js" "$@"
