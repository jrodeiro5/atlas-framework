#!/bin/bash
# atlas-claims-check.sh - the claims section of `atlas check`, split out
# the way atlas-runs-check.sh is: `atlas check` calls it with no arguments and it
# finds the onboarded repos itself; pass repo paths to check just those (that is
# what test/claims-check-test.sh does, so the test needs no fake HOME).
# Exit 0 = green, 1 = at least one FAIL.
#
# It consumes openwiki's claims runtime instead of guessing. Every generated page
# has a sidecar in openwiki/.claims/**.json whose evidence carries a content hash
# of the source it cites -- repo-file-v1 (whole file) or repo-lines-v1 (a line
# range, hashed as the joined lines plus a trailing newline). Re-hashing here
# reproduces the runtime's own verdict with no model call, in the ADR's
# vocabulary: supported (hash matches where cited), moved (those lines live
# elsewhere in the file now -- the citation drifted, the claim holds), stale (the
# cited source changed), hallucinated (the cited file is gone).
#
# The predecessor grepped page frontmatter for `source_paths:`, a key openwiki
# never writes (it writes `sources:`), and so reported "ok atlas: 1/47 pages carry
# grounded claims" while 32 sidecars held 282 claims: a gate nobody had seen go
# red. The truncation probe stays, demoted to fallback.
#
# ceiling: stale only FAILs past MAX_STALE_PCT. A few stale claims are the normal
# gap between a commit and the cascade that reconciles it; a wiki generated from
# the wrong head turns most of the set stale at once. Per-claim
# freshness is openwiki's job, not the gate's. Published baseline: 0.5% stale.
set -uo pipefail
root="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
MAX_STALE_PCT="${MAX_STALE_PCT:-20}"

# no args: every onboarded repo carrying an openwiki. With args: just those.
repos=()
n=0
if (($# > 0)); then
  for r in "$@"; do repos+=("$r"); n=$((n + 1)); done
else
  while IFS= read -r g; do
    r="${g%/.git}"
    [[ -f "$r/.atlas-ignore" ]] && continue
    [[ -d "$r/openwiki" ]] || continue
    [[ "$(git -C "$r" config core.hooksPath 2>/dev/null)" == "$root/hooks" ]] || continue
    repos+=("$r")
    n=$((n + 1))
  done < <(find "$HOME/dev" -maxdepth 3 -name .git -type d 2>/dev/null)
fi

echo "== claims"
if ((n == 0)); then
  echo "  ok   no onboarded repos with openwiki to claim-check"
  exit 0
fi

python3 - "$MAX_STALE_PCT" "${repos[@]}" <<'EOPY'
import glob, hashlib, json, os, sys

max_stale_pct, repos = int(sys.argv[1]), sys.argv[2:]
bad_repos = 0
sha = lambda b: hashlib.sha256(b).hexdigest()
_cache = {}


def read(path):
    if path not in _cache:
        try:
            with open(path, "rb") as fh:
                _cache[path] = fh.read()
        except OSError:
            _cache[path] = None
    return _cache[path]


def verdict(repo, ev):
    """One evidence entry -> supported | moved | stale | hallucinated | None."""
    res, ver = ev.get("resource", ""), ev.get("version", "")
    if not res.startswith("repo://"):
        return None
    raw = read(os.path.join(repo, res[len("repo://"):].split("#", 1)[0]))
    if raw is None:
        return "hallucinated"
    kind, _, rest = ver.partition(":sha256:")
    want = rest.split(":", 1)[0]          # repo-lines-v1 appends a base64 locator
    if kind == "repo-file-v1":
        return "supported" if sha(raw) == want else "stale"
    if kind != "repo-lines-v1" or "#L" not in res:
        return None
    first, _, last = res.split("#L", 1)[1].partition("-L")
    try:
        first, last = int(first), int(last or first)
    except ValueError:
        return None
    lines = raw.decode("utf-8", "replace").split("\n")
    slice_hash = lambda i, n: sha(("\n".join(lines[i:i + n]) + "\n").encode())
    n = last - first + 1
    if slice_hash(first - 1, n) == want:
        return "supported"
    return "moved" if any(slice_hash(i, n) == want for i in range(len(lines) - n + 1)) \
        else "stale"


for repo in repos:
    name, wiki = os.path.basename(repo), os.path.join(repo, "openwiki")
    pages = glob.glob(os.path.join(wiki, "**", "*.md"), recursive=True)
    cars = glob.glob(os.path.join(wiki, ".claims", "**", "*.json"), recursive=True)
    if not cars:
        print(f"  note {name}: {len(pages)} pages, no claims sidecars "
              f"(pre-0.4 wiki -- unverified, not wrong)")
        continue
    tally = {"supported": 0, "moved": 0, "stale": 0, "hallucinated": 0}
    edited = 0
    for car in cars:
        try:
            with open(car) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            print(f"  FAIL {name}: unreadable claims sidecar {os.path.relpath(car, repo)}")
            bad_repos += 1
            continue
        page = os.path.join(wiki, os.path.relpath(car, os.path.join(wiki, ".claims")))
        body = read(page[:-len(".json")] + ".md")
        pv = doc.get("pageVersion", "")
        if pv.startswith("sha256:") and (body is None or sha(body) != pv[len("sha256:"):]):
            edited += 1
        for claim in doc.get("claims", []):
            for ev in claim.get("evidence", []):
                v = verdict(repo, ev)
                if v:
                    tally[v] += 1
    total = sum(tally.values())
    stale_pct = 100.0 * tally["stale"] / total if total else 0.0
    aside = [f"{tally['moved']} moved"] if tally["moved"] else []
    if edited:
        aside.append(f"{edited} generated page(s) hand-edited since verification")
    if len(pages) > len(cars):
        aside.append(f"{len(pages) - len(cars)} page(s) unverified")
    aside = f" ({', '.join(aside)})" if aside else ""
    body = (f"{name}: {total} claims over {len(cars)} pages -- {tally['supported']} supported, "
            f"{tally['stale']} stale ({stale_pct:.0f}%), {tally['hallucinated']} hallucinated{aside}")
    if tally["hallucinated"] or stale_pct > max_stale_pct:
        print(f"  FAIL {body} -- rerun the cascade; if it persists the wiki was built "
              f"from the wrong head")
        bad_repos += 1
    elif tally["stale"] or edited:
        print(f"  note {body}")
    else:
        print(f"  ok   {body}")

sys.exit(1 if bad_repos else 0)
EOPY
