#!/bin/bash
# mcp-entity-test.sh — an MCP server is a concept, not a string in a field.
#
# `mcp-servers: deja, fff` drew no edge (measured links=0 over the whole
# bundle). The relation now has to exist in both directions, opencode's JSONC has
# to parse at all, and a command line must never carry its args into a committed
# file.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
scan="$root/scripts/repo-atlas.sh"

tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp" || true; exit $rc' EXIT
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

mkdir -p "$tmp/.claude" "$tmp/.config/opencode" "$tmp/dev/experiments/r"
# one repo, only so the scan reaches the harness phase: its prune step fails
# under set -e when ~/dev holds nothing at all
d="$tmp/dev/experiments/r"
git -C "$d" init -q .
git -C "$d" config user.email t@t; git -C "$d" config user.name t
printf 'summary line\n' > "$d/README.md"
git -C "$d" add -A; git -C "$d" commit -qm init
cat > "$tmp/.claude.json" <<'JSON'
{ "mcpServers": {
    "deja":     { "type": "stdio", "command": "/opt/homebrew/bin/deja", "args": ["mcp"] },
    "gitnexus": { "command": "/opt/homebrew/bin/gitnexus", "args": ["mcp"] } } }
JSON
# comments on their own lines, and a `//` inside two strings that must survive
cat > "$tmp/.config/opencode/opencode.jsonc" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    // deja is shared with claude-code
    "deja": { "command": ["/opt/homebrew/bin/deja", "mcp"] },
    "headroom": { "command": ["/usr/local/bin/headroom", "mcp", "--url", "http://127.0.0.1:8788"] }
  }
}
JSON

export ATLAS_SCAN_LOCK="$tmp/scan.lock.d" ATLAS_RUNS_DIR="$tmp/runs"
mkdir -p "$ATLAS_RUNS_DIR" "$tmp/wiki/atlas/mcp"
printf -- '---\ntype: mcp-server\n---\ngone\n' > "$tmp/wiki/atlas/mcp/removed.md"
HOME="$tmp" "$scan" >/dev/null 2>&1

b="$tmp/wiki/atlas"
field() { sed -n "s/^$1: *//p" "$2" | head -1; }

[[ -f $b/mcp/deja.md ]] && pass "a server loaded by two harnesses is one concept" \
  || fail "mcp/deja.md not generated"
[[ "$(field harnesses "$b/mcp/deja.md")" == *claude-code*opencode* ]] \
  && pass "the concept names every harness that loads it" \
  || fail "harnesses field wrong: $(field harnesses "$b/mcp/deja.md")"
grep -q '\[claude-code\](../agent-harnesses/claude-code.md)' "$b/mcp/deja.md" \
  && pass "server -> harness is a link" || fail "no link back to the harness"
grep -q '\[deja\](../mcp/deja.md)' "$b/agent-harnesses/claude-code.md" \
  && pass "harness -> server is a link" || fail "no link from the harness"

[[ "$(field mcp-servers "$b/agent-harnesses/opencode.md")" == *headroom* ]] \
  && pass "JSONC parses: opencode's servers are not 'none'" \
  || fail "opencode mcp-servers: $(field mcp-servers "$b/agent-harnesses/opencode.md")"

cmd="$(field command "$b/mcp/headroom.md")"
[[ $cmd == /usr/local/bin/headroom ]] && pass "the command is the executable, without its args ($cmd)" \
  || fail "command carried args or is wrong: $cmd"

[[ -f $b/mcp/removed.md ]] && fail "a server no longer configured was not pruned" \
  || pass "a server no longer configured is pruned"
grep -q '\[deja\](deja.md)' "$b/mcp/index.md" && pass "the index links each server" \
  || fail "mcp/index.md does not link deja"

# the point of all of it: these are edges the graph checker can count
out="$("$root/scripts/entity-graph-check.py" "$b" 2>/dev/null)"
links="$(sed -n 's/.*links=\([0-9]*\).*/\1/p' <<<"$out")"
# server<->harness in both directions is one pair each
(( links >= 4 )) && pass "graph-check counts the new edges (links=$links)" \
  || fail "checker sees links=$links, expected >= 4: $out"

(( fails == 0 )) || exit 1
