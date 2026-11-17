#!/usr/bin/env python3
"""entity-graph-check.py — is the entity graph a graph, or only a claim?

The bundle at ~/wiki/atlas is OKF v0.2 in its frontmatter, but nothing ever
checked its link graph. Same rules as the OKF reference validator
(okf-memory/okf-agent-memory, pkg/okf/bundle.go): index.md and log.md are
navigation and not concepts, so a link INTO one is broken and a link FROM one
does not connect anything; a href carrying :// is external and ignored;
everything else must resolve to another concept in the bundle. A concept with
degree 0 is an orphan. Two departures from those rules, both because calling
something broken that resolves fine hides the links that really dangle: a
`~/...` or absolute href points into the wider corpus that atlas-site.py serves
and is counted as `outside`; a link into index.md or log.md is counted as `nav`.

Read-only. Stdlib only. No LLM, so it costs nothing to run in the gate.

usage: atlas graph-check [bundle] [--strict]
       --strict exits 1 when anything is broken, or orphaned in a collection
       that runs (MUST_LINK)
"""
import os
import re
import sys

RESERVED = ("index.md", "log.md")
# --strict gates on what runs. A repo with nothing deployed and no
# dependency in the bundle is a true leaf; linking it to the Mac its checkout
# sits on would inflate the count, not the graph.
MUST_LINK = ("jobs/", "services/", "hosts/", "mcp/", "agent-harnesses/")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)")
FENCE = re.compile(r"^\s*(```|~~~)", re.M)
REPO_FIELD = re.compile(r"^repo: *(.*)$", re.M)
FRONTMATTER = re.compile(r"\A---\n.*?\n---\n", re.S)


def strip_fences(text):
    """Drop fenced blocks: a link in a usage example is documentation, not an edge."""
    out, fenced = [], False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            out.append(line)
    return "\n".join(out)


def load(bundle):
    concepts = {}
    for dirpath, dirs, names in os.walk(bundle):
        for name in names:
            if not name.endswith(".md") or name in RESERVED:
                continue
            path = os.path.join(dirpath, name)
            concepts[os.path.relpath(path, bundle)[:-3]] = path
    return concepts


def main(argv):
    strict = "--strict" in argv
    rest = [a for a in argv if not a.startswith("--")]
    bundle = rest[0] if rest else os.path.expanduser("~/wiki/atlas")
    if not os.path.isdir(bundle):
        print(f"atlas graph: no bundle at {bundle}", file=sys.stderr)
        return 2

    concepts = load(bundle)
    # an edge is an unordered pair, counted once whichever form it
    # takes (frontmatter `repo:`, a body link, or both, or both directions).
    link_pairs, run_pairs, outside, nav, broken = set(), set(), 0, 0, []
    for cid, path in sorted(concepts.items()):
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
        # The RUNS edge lives in frontmatter, not in a markdown link, so
        # the OKF walk below cannot see it. Count it or the graph reads emptier
        # than it is.
        target = REPO_FIELD.search(raw)
        if target and target.group(1).strip() not in ("", "none"):
            target = "repos/" + os.path.basename(target.group(1).strip())
            if target in concepts and target != cid:
                run_pairs.add(frozenset((cid, target)))
        # links live in the body; a href inside a `description:` is prose the
        # README happened to carry, not an edge this bundle drew
        body = strip_fences(FRONTMATTER.sub("", raw, count=1))
        for href in LINK.findall(body):
            if "://" in href:
                continue
            href = href.split("#", 1)[0]
            if not href:
                continue
            # A `~/dev/<repo>/almanac/...` href leaves the bundle for the wider
            # corpus, which atlas-site.py resolves and OKF has no opinion on.
            # Counting those as broken buries the ones that really are.
            if href.startswith(("~/", "/")):
                outside += 1
                continue
            target = os.path.normpath(os.path.join(os.path.dirname(cid), href))
            # A link to index.md or log.md resolves — it just is not an edge:
            # those are navigation, not concepts. The reference validator calls
            # this broken; it is not, and lumping it with dangling links hides
            # the ones that really point at nothing.
            if os.path.basename(target) in RESERVED:
                nav += 1
                continue
            if target.endswith(".md"):
                target = target[:-3]
            if target in concepts:
                if target != cid:
                    link_pairs.add(frozenset((cid, target)))
            else:
                broken.append((cid, href, "target concept does not exist"))

    edges, runs = len(link_pairs), len(run_pairs - link_pairs)
    linked = set().union(*link_pairs, *run_pairs)
    orphans = sorted(set(concepts) - linked) if len(concepts) > 1 else []
    gated = [o for o in orphans if o.startswith(MUST_LINK)]
    for cid, href, why in broken[:20]:
        print(f"  broken  {cid}.md -> {href}  ({why})")
    if len(broken) > 20:
        print(f"  ... {len(broken) - 20} more broken links")
    if orphans:
        print(f"  orphans {len(orphans)}: {', '.join(orphans[:8])}"
              + (" ..." if len(orphans) > 8 else ""))
    if gated:
        print(f"  gated   {len(gated)}: {', '.join(gated)}")
    print(f"concepts={len(concepts)} links={edges} runs={runs} "
          f"outside={outside} nav={nav} broken={len(broken)} orphans={len(orphans)} gated={len(gated)}")
    return 1 if strict and (broken or gated) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
