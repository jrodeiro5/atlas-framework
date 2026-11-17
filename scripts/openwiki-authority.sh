#!/bin/bash
# openwiki-authority.sh <repo-path> — a wiki that was not
# verified says so in its own frontmatter, so an agent that reads one page knows
# what it is holding without going to look for the run receipt.
#
# The receipt is openwiki/.last-update.json, never the exit code (the wrong-head failure, and
# the cascade comment above the same check). A wiki is unverified when:
#   - there is no receipt at all;
#   - status is anything but "complete" — "interrupted" leaves the wiki half old
#     and half new, which reads exactly like a finished one;
#   - it was generated off the default branch, which is the failure this was
#     written about: a run from the wrong head produces a plausible, false wiki.
#
# Every page also gets OKF's `generated: { by, at }`. Without it an openwiki page
# and an entity doc are indistinguishable to a cold reader, though one is model
# prose and the other is a deterministic scan — `process:repo-atlas` versus
# `openwiki/<model>`. Keeping that as an actor string rather than a new
# trust field is deliberate: state admission (`authoritative:`), temporal
# validity (`stale_after:`) and evidential support (who derived it) are
# orthogonal dimensions, and collapsing them is what inflates trust.
#
# Stamping is idempotent and reversible: a later clean run strips both keys. The
# pages are generated, so the stamp does not survive regeneration on its own —
# that is why the cascade re-runs this after every openwiki stage, pass or fail.
set -uo pipefail

repo="${1:-.}"
wiki="$repo/openwiki"
[[ -d $wiki ]] || { echo "openwiki-authority: no openwiki/ in $repo" >&2; exit 0; }

manifest="$wiki/.last-update.json"
reason=""
model=""
at=""
if [[ ! -f $manifest ]]; then
  reason="openwiki left no .last-update.json — nothing recorded this run"
else
  model="$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  at="$(grep -o '"updatedAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  status="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  branch="$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  default="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [[ -n $default ]] || default=main
  if [[ $status != complete ]]; then
    reason="openwiki run ended status=${status:-unknown}, so these pages are part old and part new"
  elif [[ -n $branch && $branch != "$default" ]]; then
    reason="generated from branch '$branch', not '$default'"
  fi
fi

REASON="$reason" ACTOR="openwiki/${model:-unknown-model}" AT="$at" python3 - "$wiki" <<'PY'
import os, pathlib, sys

reason = os.environ["REASON"]
# OKF v0.2 actor: a producer/version pair, never `process:` — a model wrote this
stamp = "generated: { by: %s, at: %s }\n" % (os.environ["ACTOR"], os.environ["AT"] or "unknown")
marked = changed = 0
for path in sorted(pathlib.Path(sys.argv[1]).rglob("*.md")):
    text = path.read_text()
    end = text.find("\n---\n", 3) if text.startswith("---\n") else -1
    # the section index pages carry no frontmatter at all, and they are the pages
    # an agent lands on first — give them a block of their own rather than skip
    # the warning where it is most likely to be read
    if end != -1:
        head, rest = text[4:end + 1], text[end + 1:]   # rest starts with the closing ---
    else:
        head, rest = "", "---\n" + text               # invent the block, delimiter and all
    kept = [l for l in head.splitlines(True)
            if not l.startswith(("authoritative:", "authority-reason:"))]
    # The actor is stamped on every page, verified or not: who wrote it does not
    # depend on whether this run finished. But openwiki stamps `generated:`
    # itself, per page and only where the body changed this run
    # (dist/okf/generated-provenance.js, a finalizer that an interrupted run
    # never reaches). Fill the hole it leaves; never overwrite it. Its event
    # knows which pages this run actually rewrote and a run-level actor does not.
    if not any(l.startswith("generated:") for l in kept):
        kept.append(stamp)
    if reason:
        # first, not last: an agent that reads only the top of a page still sees it
        kept.insert(0, "authoritative: false\nauthority-reason: %s\n" % reason)
        marked += 1
    # a block that was only ever ours goes away whole, closing delimiter included
    new = "---\n" + "".join(kept) + rest
    if new != text:
        path.write_text(new)
        changed += 1
print("openwiki-authority: %s (%d pages marked, %d rewritten)"
      % (reason or "verified", marked, changed))
PY
