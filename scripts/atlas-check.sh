#!/bin/bash
# atlas-check.sh — drift gate (drift gate). Asserts the wiring is
# intact and the bundle is fresh. Read-only: never regenerates, never fixes.
# Exit 0 = green, 1 = at least one FAIL.
#
# Built rather than adopted: the watch-list trigger ("compare loop-audit before
# building from scratch") was checked 2026-07-25 — cobusgreyling/loop-audit scores
# a project's *Loop Readiness* (does the repo have agent scaffolding), which is a
# different question from "is atlas's own wiring intact and its wiki fresh".
set -uo pipefail   # no -e: every check must run, then report together
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
WIKI="$HOME/wiki/atlas"
fails=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }
note() { printf '  note %s\n' "$*"; }

# entity-doc frontmatter scalar, with ~ expanded
field() { sed -n "s/^$1: *//p" "$2" | head -1; }

echo "== wiring"
# the CLI must be reachable by name and resolve back to this checkout
atlas_bin="$(command -v atlas || true)"
if [[ -n $atlas_bin && "$(realpath "$atlas_bin")" == "$root/bin/atlas" ]]; then
  pass "atlas on PATH → $root/bin/atlas"
else
  fail "atlas not on PATH (or resolves elsewhere): ln -sfn $root/bin/atlas ~/.local/bin/atlas"
fi

# hooks/ is core.hooksPath for every onboarded repo (one shared dir, not per-repo
# .git/hooks), so anything that writes hooks in an onboarded repo -- a tool's
# own installer, an agent scaffolding LFS support, anything not using
# --local -- lands here and kills the cascade for all of them at once, silently.
# Caught 2026-09-01: hooks/post-commit was replaced by git-lfs's stock template.
# The cascade may also live behind Entire's chain: post-commit
# calls `entire hooks` and chains post-commit.pre-entire, which holds the
# original atlas body. Either shape fires the cascade; neither shape means dead.
cascade_live=0
grep -q 'atlas-cascade.sh' "$root/hooks/post-commit" 2>/dev/null && cascade_live=1
if (( ! cascade_live )) && grep -q 'post-commit.pre-entire' "$root/hooks/post-commit" 2>/dev/null \
  && grep -q 'atlas-cascade.sh' "$root/hooks/post-commit.pre-entire" 2>/dev/null; then
  cascade_live=1
fi
if ((cascade_live)); then
  pass "hooks/post-commit still fires the atlas cascade (direct or via .pre-entire chain)"
else
  fail "hooks/post-commit has been overwritten (no atlas-cascade.sh call, direct or chained) — cascade is dead for every onboarded repo: git checkout -- hooks/post-commit"
fi

# Entire pins an absolute binary path in hooks (--absolute-git-hook-path,
# Entire), and every hook degrades to `else :` when it stops resolving — a
# brew upgrade silences capture without failing anything. Guard the pin, not PATH,
# in every repo with Entire enabled, not just the shared dir: a repo with its own
# .git/hooks is invisible from here. Caught 2026-11-17: auto-knowledge-vault's
# hooks pinned Caskroom/entire/0.13.2 after the 0.13.4 upgrade, 23 commits lost.
# A Caskroom pin resolves today and dies on the next upgrade: fail it now.
bad_pin=() root_pins=0
while IFS= read -r g; do
  r="${g%/.git}"
  [[ $r == "$root" || -f $r/.entire/settings.json ]] || continue
  hd="$(git -C "$r" config core.hooksPath 2>/dev/null)"; hd="${hd:-$r/.git/hooks}"
  while IFS= read -r pin; do
    [[ $r == "$root" ]] && root_pins=$((root_pins + 1))
    [[ -x $pin && $pin != */Caskroom/* ]] || bad_pin+=("$(basename "$r"):$pin")
  done < <(sed -n "s|^.*if \[ -x '\([^']*entire\)'.*|\1|p" "$hd"/* 2>/dev/null | sort -u)
done < <({ echo "$root/.git"; find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null; } | sort -u)
((root_pins)) || bad_pin+=("$(basename "$root"): no entire pin in hooks/")
# hooks/ serve every repo on core.hooksPath; Entire runs only where .entire/settings.json
# exists. `entire enable` rewrites the hooks without that guard: catch it here.
for h in "$root"/hooks/*; do
  if grep -q "/entire' hooks git" "$h" && ! grep -q 'if \[ ! -f .entire/settings.json \]' "$h"; then
    bad_pin+=("hooks/${h##*/} lacks the .entire/settings.json guard")
  fi
done
if ((${#bad_pin[@]})); then
  fail "entire hook pin dead or versioned — capture silently off; point it at /opt/homebrew/bin/entire: ${bad_pin[*]}"
else
  pass "entire hook pins resolve, none versioned ($(/opt/homebrew/bin/entire --version 2>/dev/null | head -1))"
fi

# The local-only policy (0 telemetry, 0 cloud) lives in .entire/settings.json,
# committed in 97688c4. A flipped flag re-arms the pre-push leak silently.
if [[ -f $root/.entire/settings.json ]]; then
  grep -q '"telemetry": *false' "$root/.entire/settings.json" \
    && grep -q '"push_sessions": *false' "$root/.entire/settings.json" \
    && pass "entire local-only policy pinned (telemetry false, push_sessions false)" \
    || fail "entire settings drifted from local-only: telemetry and push_sessions must both be false"
else
  fail "entire not enabled in this repo (.entire/settings.json missing)"
fi

# openwiki's better-sqlite3 is node-gyp-built for NODE_MODULE_VERSION 127 (Node 22)
# while qmd's is built for 147 (Node 26), so no PATH ordering satisfies both --
# each bin pins its own interpreter instead. Upstream ships
# openwiki as a `#!/usr/bin/env node` symlink, so a plain `npm i -g openwiki`
# silently un-pins it and the cascade's openwiki stage dies on dlopen -- which is
# exactly how 26 cascade runs failed unnoticed over two days. No CLI subcommand
# short of `code --update` loads better-sqlite3, so probe the module directly
# with whatever interpreter the bin resolves to.
ow_bin="$(command -v openwiki || true)"
ow_node="$(sed -n 's|^exec "\{0,1\}\([^" ]*node\)".\{0,1\}.*|\1|p' "$ow_bin" 2>/dev/null | head -1)"
ow_node="${ow_node//\$HOME/$HOME}"
ow_mod="$HOME/.local/lib/node_modules/openwiki/node_modules/better-sqlite3"
if [[ -x $ow_node ]] && "$ow_node" -e "require('$ow_mod')" 2>/dev/null; then
  pass "openwiki pinned to $("$ow_node" -v), which loads its native modules"
else
  fail "openwiki not ABI-pinned — cascade's openwiki stage will die on dlopen: ln -sfn $root/scripts/openwiki-pinned.sh ~/.local/bin/openwiki"
fi

echo "== coverage"
# every entity doc must point at a repo that still exists
orphans=()
for f in "$WIKI"/repos/*.md; do
  [[ -f $f ]] || continue
  p="$(field path "$f")"
  [[ -d "${p/#\~/$HOME}" ]] || orphans+=("$(basename "$f" .md)")
done
((${#orphans[@]})) && fail "entity docs with no repo on disk: ${orphans[*]}" \
  || pass "no orphaned entity docs"
# everything that runs links to where it runs; broken links fail too
graph="$("$root/scripts/entity-graph-check.py" "$WIKI" --strict)" \
  && pass "entity graph: no broken link, no orphan that runs" \
  || fail "entity graph (atlas graph-check): $(tail -1 <<<"$graph")"

# ...and every repo under ~/dev must have one
missing=0
  while IFS= read -r g; do
    r="${g%/.git}"
    [[ -f "$r/.atlas-ignore" ]] && continue   # opted out of scanning, see repo-atlas.sh
    [[ -f "$WIKI/repos/$(basename "$r").md" ]] || { fail "no entity doc: $r"; missing=1; }
  done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
  ((missing)) || pass "every ~/dev repo has an entity doc"

# ...and every onboarded repo must have generated narrative (openwiki/) or
# mined knowledge (almanac/) — with neither, the repo is invisible to qmd.
# Caught 2026-08-16: 8 onboarded repos (OmniZenit, personal-brand-audit, ...)
# had a last commit predating the cascade, so openwiki/ was never generated
# and the coverage checks above still passed. The cascade only fires on
# post-commit, so onboarding without a backfill run leaves a silent gap.
no_docs=()
while IFS= read -r g; do
  r="${g%/.git}"
  [[ -f "$r/.atlas-ignore" ]] && continue
  [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
  [[ -d "$r/openwiki" || -d "$r/almanac" ]] || no_docs+=("$(basename "$r")")
done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
((${#no_docs[@]})) && fail "onboarded but invisible to qmd (run: $root/scripts/atlas-cascade.sh <repo>): ${no_docs[*]}" \
  || pass "every onboarded repo has openwiki/ or almanac/"

# ...and every onboarded repo's CLAUDE.md must carry the atlas back-reference.
# Without it the wiki is invisible from inside the repo: an agent reading the
# repo cold has no way to learn `qmd get atlas/repos/<name>.md` exists.
# atlas-pointer.sh was wired into the cascade 2026-08-16; before that its only
# caller was new-folder-claude-md.sh, so the block lands repo-by-repo as each
# one commits. Expect a long list to start with — no bulk backfill.
no_pointer=()
stub=()
while IFS= read -r g; do
  r="${g%/.git}"
  [[ -f "$r/.atlas-ignore" ]] && continue
  # before the hooksPath filter: the template is written on mkdir, onboarded or not
  if grep -q 'auto-generated by atlas on mkdir' "$r/CLAUDE.md" 2>/dev/null && grep -qx 'TODO' "$r/CLAUDE.md"; then
    stub+=("$(basename "$r")")
  fi
  [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
  grep -q '<!-- atlas:start -->' "$r/CLAUDE.md" 2>/dev/null || no_pointer+=("$(basename "$r")")
done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
((${#no_pointer[@]})) && fail "no atlas pointer in CLAUDE.md (run: $root/scripts/atlas-pointer.sh <repo>): ${no_pointer[*]}" \
  || pass "every onboarded repo points back at atlas"

# ...and the pointer alone proves nothing: new-folder-claude-md.sh writes it into
# a template whose Purpose is TODO, and nothing ever fills that in.
# Such a repo carries the block above and not one instruction of its own. Not
# limited to onboarded repos: the three found on 2026-10-11 had no hooksPath.
((${#stub[@]})) && fail "CLAUDE.md is still the unfilled mkdir template (write its Purpose): ${stub[*]}" \
  || pass "no repo ships the empty mkdir template as CLAUDE.md"

# ...and the block must be a clean start/end pair, not merely present. Presence
# was the only thing checked until 2026-09-06, which is how four repos went torn
# with three of them committed -- see atlas-marker-check.sh for the mechanism.
torn="$("$root/scripts/atlas-marker-check.sh" "$root" || true)"
[[ -n $torn ]] && fail "torn marker block in CLAUDE.md (truncate at the first end marker, then re-run atlas-pointer.sh): $(printf '%s ' $torn)" \
  || pass "every marker block in CLAUDE.md is a clean pair"

echo "== agents-md-identity"
# Claude 2.1.277 falls back to AGENTS.md when CLAUDE.md is absent, so each
# harness may read a different file: two real files with different content is
# live divergence, not untidiness. A symlink (the atlas convention) or two
# identical files are both one truth and pass; only real-and-different fails.
diverged=()
while IFS= read -r g; do
  r="${g%/.git}"
  [[ -f "$r/.atlas-ignore" ]] && continue
  [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
  [[ -f "$r/CLAUDE.md" && -f "$r/AGENTS.md" ]] || continue
  [[ -L "$r/CLAUDE.md" || -L "$r/AGENTS.md" ]] && continue
  cmp -s "$r/CLAUDE.md" "$r/AGENTS.md" || diverged+=("$(basename "$r")")
done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
((${#diverged[@]})) && fail "CLAUDE.md and AGENTS.md are real files with different content (each harness reads another truth since the Claude 2.1.277 fallback): ${diverged[*]}" \
  || pass "no CLAUDE.md/AGENTS.md divergence in onboarded repos"

echo "== freshness"
# entity doc last-commit must equal the repo's HEAD date
stale=()
for f in "$WIKI"/repos/*.md; do
  [[ -f $f ]] || continue
  p="$(field path "$f")"; p="${p/#\~/$HOME}"
  [[ -d $p ]] || continue
  head_date="$(git -C "$p" log -1 --format=%cs 2>/dev/null)" || continue
  doc_date="$(field last-commit "$f")"
  [[ -n $head_date && $doc_date != "$head_date" ]] && stale+=("$(basename "$f" .md)")
done
((${#stale[@]})) && fail "stale last-commit (run: atlas scan): ${stale[*]}" \
  || pass "all entity docs match repo HEAD"

echo "== manual freshness"
# manual-reviewed (repo-atlas.sh) is a content-hash-tracked date of the
# hand-written <!-- manual --> section only — informational, not a FAIL, since
# an old manual note isn't broken, just unverified. Mirrors agent-vault's own
# threshold. The window is now the doc's own OKF v0.2 `stale_after` (repo-atlas.sh
# derives it from the repo's commit cadence), so a repo that moves weekly is held
# to weeks and a dormant one is not nagged; 30 days stays as the fallback for a
# doc written before that field existed. Skips docs with no manual content.
bare_hash="$(printf '%s' '<!-- manual -->' | shasum -a 256 | cut -d' ' -f1)"
stale_manual=()
for f in "$WIKI"/repos/*.md; do
  [[ -f $f ]] || continue
  h="$(field manual-hash "$f")"
  [[ -n $h && $h != "$bare_hash" ]] || continue
  reviewed="$(field manual-reviewed "$f")"
  [[ -n $reviewed ]] || continue
  reviewed_epoch="$(date -j -f '%Y-%m-%d' "$reviewed" +%s 2>/dev/null)" || continue
  age_days=$(((($(date +%s) - reviewed_epoch)) / 86400))
  due="$(field stale_after "$f")"
  due_epoch=""
  [[ -n $due ]] && due_epoch="$(date -j -f '%Y-%m-%d' "$due" +%s 2>/dev/null || true)"
  if [[ -n $due_epoch ]]; then
    (($(date +%s) > due_epoch)) && stale_manual+=("$(basename "$f" .md) (${age_days}d, due $due)")
  else
    ((age_days > 30)) && stale_manual+=("$(basename "$f" .md) (${age_days}d, no stale_after)")
  fi
done
((${#stale_manual[@]})) && note "manual sections past their stale_after: ${stale_manual[*]}" \
  || pass "no manual section past its stale_after"

echo "== gates"
# Every atlas-onboarded repo must actually have a staged-secret gate. hooks/pre-commit
# only runs prek when the repo declares a .pre-commit-config.yaml, so a repo without
# one silently gets no gate — which was true of 7 of 9 onboarded repos until this
# check existed. Onboard seeds the config now; this catches the ones that predate
# that, and any that lose it later.
ungated=()
while IFS= read -r g; do
  r="${g%/.git}"
  [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
  if [[ -f "$r/.pre-commit-config.yaml" ]] && grep -q gitleaks "$r/.pre-commit-config.yaml"; then
    continue
  fi
  ungated+=("$(basename "$r")")
done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
((${#ungated[@]})) && fail "onboarded but no gitleaks gate (run: atlas onboard <repo>): ${ungated[*]}" \
  || pass "every onboarded repo has a staged-secret gate"

"$root/scripts/atlas-claims-check.sh" || fails=$((fails + 1))

echo "== qmd"
# the bundle and the per-repo mined knowledge must both be indexed, and the
# CodeAlmanac manual must stay out (high-redundancy dilution — arXiv 2605.09611,
# 2604.19047; domain scoping is the measured fix — arXiv 2606.11350)
if command -v qmd >/dev/null; then
  # 'atlas' replaced 'wiki' here: the bundle got its own collection, and what is
  # left in 'wiki' is 8 unrelated files, so asserting on 'wiki' no longer proves
  # the machine map is indexed
  # 'agent-claude-skills' was renamed: skills are canonical in ~/.agents/skills
  # ('agent-skills-hub'); ~/.claude/skills is a symlink farm into it.
  for c in atlas repo-almanac repo-openwiki agent-skills-hub; do
    n="$(qmd ls "$c" 2>/dev/null | wc -l | tr -d ' ')"
    ((n > 0)) && pass "qmd collection '$c': $n files" \
      || fail "qmd collection '$c' empty or missing (see ~/.config/qmd/index.yml)"
  done
  dupes="$(qmd ls repo-almanac 2>/dev/null | grep -c '/manual/')"
  ((dupes == 0)) && pass "no almanac/manual/ duplicates indexed" \
    || fail "$dupes almanac/manual/ files indexed — restore the !(manual) pattern"
  # a doc without a vector is invisible to the semantic arm of `qmd query`, and
  # nothing in atlas runs `qmd embed`: 532 of 2714 docs on 2026-10-11
  pending="$(qmd status 2>/dev/null | sed -n 's/^ *Pending: *\([0-9][0-9]*\).*/\1/p')"
  ((${pending:-0} == 0)) && pass "every indexed doc has an embedding" \
    || fail "$pending indexed docs have no embedding; qmd query answers them from BM25 alone (run: qmd embed)"
else
  fail "qmd not installed"
fi

echo "== wiki truncation"
# The preload caps openwiki's generation (litellm-tag-inject.cjs). A capped call
# is a wiki page cut in half, and it is silent: openwiki streams, so nothing in
# the cascade sees finish_reason. The cap comment promised this counter once the
# count went nonzero -- it did on 2026-08-19 (4 pages across three repos), so
# here it is. Reads the cap from the preload so the two cannot drift.
# ponytail: queries SpendLogs directly, no psql on this box. Skips (note, not
# FAIL) when the proxy DB is unreachable -- a missing ledger is not drift.
# The verdict is the artifact on disk: an unclosed
# code fence is the only truncation signal that holds. A request row at the
# cap may have been retried with the page regenerated after, so rows are trend.
unclosed=()
while IFS= read -r md; do
  (( $(awk '/^```/{n++} END{print n%2}' "$md") )) && unclosed+=("$md")
done < <(find "$HOME/dev" -path '*/openwiki/*.md' -type f 2>/dev/null)
((${#unclosed[@]})) && fail "unclosed code fence = truncated page: ${unclosed[*]}" \
  || pass "no truncated pages on disk (all openwiki fences closed)"
cap="$(sed -n 's/^const CAP = \([0-9]*\);.*/\1/p' "$root/scripts/litellm-tag-inject.cjs" | head -1)"
if [[ -z $cap ]]; then
  fail "cannot read CAP from scripts/litellm-tag-inject.cjs"
elif ! command -v uv >/dev/null || ! command -v pass >/dev/null; then
  note "wiki truncation unchecked (uv or pass missing)"
else
  # CAP arrives on argv (a number, not a secret); the DSN never does -- python
  # pulls it from pass itself, because argv is logged.
  trunc="$(CAP="$cap" uv run --quiet --with "psycopg[binary]" python - <<'PY' 2>/dev/null
import os, subprocess, psycopg
dsn = subprocess.run(["pass","show","litellm/database-url"],
                     capture_output=True, text=True).stdout.strip()
if not dsn:
    raise SystemExit(1)
with psycopg.connect(dsn, connect_timeout=5) as c, c.cursor() as k:
    k.execute("""
      select request_tags::text, count(*)
      from "LiteLLM_SpendLogs"
      where request_tags::text like '%%tool:openwiki%%'
        and completion_tokens >= %s
        and "startTime" > now() - interval '7 days'
      group by 1
    """, (int(os.environ["CAP"]),))
    for tags, n in k.fetchall():
        repo = next((t for t in tags.split('"') if t.startswith("repo:")), "repo:?")
        print(f"{repo[5:]} {n}")
PY
)"
  if [[ $? -ne 0 ]]; then
    note "wiki truncation unchecked (LiteLLM DB unreachable)"
  elif [[ -z $trunc ]]; then
    pass "no openwiki generation hit the ${cap}-token cap in 7d"
  else
    while read -r repo n; do
      [[ -n $repo ]] && note "$repo: $n openwiki page(s) hit the ${cap}-token cap in 7d (trend only — verdict is the fence scan above)"
    done <<< "$trunc"
  fi
fi

echo
# execution health lives in its own script (different source of truth: the
# run ledger, not the bundle). Called from here so it always has a reader.
echo
"$root/scripts/atlas-runs-check.sh" || fails=$((fails + 1))

echo
if ((fails)); then
  echo "atlas check: $fails FAIL"
  exit 1
fi
echo "atlas check: green"
