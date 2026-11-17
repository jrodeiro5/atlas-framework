#!/usr/bin/env python3
"""atlas-site.py — one localhost route over every doc on this machine.

Serves ~2,100 machine-generated markdown files: each repo's almanac/ (mined
decisions), openwiki/ (generated from current code) and docs/ (ADRs), plus the
~/wiki/atlas bundle of entity docs. Stdlib only.

It never writes to the corpus itself, and every structure it shows -- the
tree, the sections, the links, the backlinks -- is derived from paths and
frontmatter that already exist on disk. Since 2026-10-12 it is also the control
plane: /#/runs shows what runs in the background (launchd services, the run
ledger, the openwiki queue, logs) and can start the commands `bin/atlas`
already exposes. It starts them; the scripts do the writing. There is no nav file to maintain,
because a hand-maintained nav is a second thing that goes stale.

ARCHITECTURE (chosen by measurement, not taste):
  manifest / cargo split. The index ships metadata only (~2,100 docs = 45KB
  gzipped, 22 B/doc); bodies are fetched when a doc is opened. Embedding
  bodies would be a 7.6 MB page.

  No cache, anywhere. A stat-only walk of the whole corpus is 11ms warm and a
  full-text grep of all 7.6 MB is 33-95ms, both cheap enough to redo per
  request. That is what makes "never stale" literally true rather than "true
  within N seconds" -- these files are overwritten by scanners on every
  commit, so any cache is a staleness window. If it ever creeps, the footer
  prints the duration; fix the prune list, do not add a cache.

SECURITY. This corpus spans work/ and personal/ repos and includes incident
writeups, spend figures, credential *names* and host topology. So:
  - Only paths present in the current manifest are servable. Traversal and
    symlink escapes are not filtered, they are unrepresentable.
  - Doc HTML is built escape-first: the source is escaped, then a fixed set of
    tags is reintroduced. Nothing in a markdown file can emit markup.
  - The app's CSS and JS are served as separate files so the CSP can be
    script-src 'self' with NO 'unsafe-inline'. That is the second layer: even
    if the renderer ever leaked a <script> or an onclick=, the browser refuses
    to run it. This replaced a sandboxed iframe, which was safe but made every
    cross-reference in the corpus unclickable.
  - Only links that resolve to a doc in the manifest become anchors. External
    and unresolved targets render as inert text, never href.
  - Actions are POST-only, need a custom header (so a cross-origin page must
    preflight, and there is no OPTIONS handler to answer it) and a same-origin
    Origin. argv is built from the ACTIONS table and a repo path found on disk;
    no string from a request is ever passed to a command.
  - Host header must be a loopback literal, which defeats DNS rebinding from
    another tab. Bound to 127.0.0.1, never 0.0.0.0.
"""
import collections
import gzip
import hashlib
import html
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~")
DEV = os.path.join(HOME, "dev")
WIKI = os.path.join(HOME, "wiki", "atlas")
KINDS = ("almanac", "openwiki", "docs")
# Directories that are never documentation. If the walk ever gets slow, this
# list is the first thing to extend -- not the caching policy.
PRUNE = {"node_modules", ".venv", "venv", ".git", "dist", "target", ".next",
         "__pycache__", ".terraform", "build", ".cache", "vendor", ".gitnexus",
         "site-packages", ".pytest_cache", "coverage", ".mypy_cache"}


# ---------------------------------------------------------------- discovery

def discover():
    """Repo roots carrying a marker dir. Membership is the presence of the docs
    themselves, so there is no registry that can drift out of sync with disk --
    delete the directory and the repo leaves the site."""
    repos = []
    try:
        groups = sorted(os.scandir(DEV), key=lambda e: e.name)
    except OSError:
        return repos
    for group in groups:
        if not group.is_dir(follow_symlinks=False) or group.name in PRUNE:
            continue
        try:
            entries = sorted(os.scandir(group.path), key=lambda e: e.name)
        except OSError:
            continue
        for r in entries:
            if not r.is_dir(follow_symlinks=False):
                continue
            if any(os.path.isdir(os.path.join(r.path, k)) for k in KINDS):
                repos.append((group.name, r.name, r.path))
    return repos


def walk_md(root):
    """Stat-only scandir. Never follows symlinks: a link into ~/.ssh must not
    become servable just because someone dropped it in a docs folder."""
    out, stack = [], [root]
    while stack:
        try:
            entries = list(os.scandir(stack.pop()))
        except OSError:
            continue
        for e in entries:
            if e.name.startswith("."):
                continue
            if e.is_dir(follow_symlinks=False):
                if e.name not in PRUNE:
                    stack.append(e.path)
            elif e.name.endswith(".md") and e.is_file(follow_symlinks=False):
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                out.append((e.path, st.st_mtime, st.st_size))
    return out


def scan():
    """Full corpus scan. Returns (docs, index, elapsed_ms).

    `index` maps the public id -> absolute path and is the authorisation list:
    a body request for an id not in it is a 404, so path traversal has nothing
    to reach.

    Each doc also carries `s`, the folder path between the layer and the file
    (almanac/architecture -> "architecture"). That one field is what the whole
    sidebar tree is built from: the corpus is already organised, the previous
    build just flattened it away."""
    t0 = time.perf_counter()
    docs, index = [], {}

    def add(path, mtime, size, repo, group, kind, base):
        rel = os.path.relpath(path, HOME)
        index[rel] = path
        sect = os.path.relpath(os.path.dirname(path), base).replace(os.sep, "/")
        docs.append({"p": rel, "t": os.path.basename(path)[:-3].replace("-", " "),
                     "r": repo, "g": group, "k": kind,
                     "s": "" if sect == "." else sect,
                     "m": int(mtime), "z": size})

    for group, repo, rpath in discover():
        for kind in KINDS:
            d = os.path.join(rpath, kind)
            if os.path.isdir(d):
                for p, m, s in walk_md(d):
                    add(p, m, s, repo, group, kind, d)
    for p, m, s in walk_md(WIKI):
        sub = os.path.relpath(os.path.dirname(p), WIKI).split(os.sep)[0]
        kind = sub if sub != "." else "bundle"
        add(p, m, s, "atlas-bundle", "wiki", kind,
            WIKI if kind == "bundle" else os.path.join(WIKI, kind))

    docs.sort(key=lambda d: -d["m"])
    return docs, index, (time.perf_counter() - t0) * 1000


def repo_root(rel):
    """Repo root of a doc id, as a HOME-relative prefix. Relative links and
    `sources:` paths in the corpus are written against this."""
    parts = rel.split("/")
    if parts[0] == "dev" and len(parts) > 3:
        return "/".join(parts[:3])
    if parts[0] == "wiki":
        return "/".join(parts[:2])
    return os.path.dirname(rel)


# ------------------------------------------------------------------ content

def parse_front(raw):
    """Split OKF/YAML frontmatter. Returns (meta, sources, body).

    Flat scalars are all any generator on this machine emits, so a split on the
    first colon is exact. The one nested structure that matters is `sources:`,
    a list of {id, path} -- almanac prose cites those ids as [@source-id], so
    parsing them is what turns a citation into a link."""
    meta, sources, body = {}, {}, raw
    if not raw.startswith("---\n"):
        return meta, sources, body
    end = raw.find("\n---", 4)
    if end == -1:
        return meta, sources, body
    body = raw[end + 4:].lstrip("\n")
    cur = None
    for line in raw[4:end].split("\n"):
        if not line.strip():
            continue
        if not line.startswith((" ", "-", "\t")):
            if ":" in line:
                k, v = line.split(":", 1)
                k, v = k.strip(), v.strip().strip('"')
                if v:
                    meta[k] = v
                cur = k
            continue
        if cur != "sources":
            continue
        m = re.match(r"\s*-?\s*(id|path):\s*(.+)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip().strip('"')
        if key == "id":
            sources[val] = None
            sources["__last"] = val
        elif sources.get("__last"):
            sources[sources["__last"]] = val
    sources.pop("__last", None)
    return meta, sources, body


def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


class Resolver:
    """Turns the corpus's own cross-references into in-app links.

    The docs are already written as a hypertext -- relative links, [[slug]]
    wikilinks, [@source-id] citations -- and every one of them was dead text in
    the previous build. Resolution is closed over the manifest: a target that
    is not a doc on this machine never becomes an anchor."""

    def __init__(self, index, docs, cur, sources):
        self.index = index
        self.cur = cur
        self.root = repo_root(cur)
        self.dir = posixpath.dirname(cur)
        self.sources = sources
        self.out = {}
        self.by_base = {}
        for d in docs:
            self.by_base.setdefault(os.path.basename(d["p"])[:-3], []).append(d["p"])
            self.by_base.setdefault(slugify(d["t"]), []).append(d["p"])

    def _hit(self, rel):
        rel = posixpath.normpath(rel)
        for cand in (rel, rel + ".md", rel + "/README.md", rel + "/index.md"):
            if cand in self.index:
                return cand
        return None

    def rel(self, target):
        """A markdown link target -> doc id, or None if it leaves the corpus."""
        target = target.split("#")[0].strip()
        if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
            return None          # http:, mailto:, javascript:, file: -- all out
        if target.startswith("~/"):
            return self._hit(target[2:])
        if target.startswith("/"):
            return None
        return (self._hit(posixpath.join(self.dir, target))
                or self._hit(posixpath.join(self.root, target)))

    def wiki(self, slug):
        """[[slug]] -- prefer a hit inside the same repo, then anywhere."""
        cands = self.by_base.get(slug) or self.by_base.get(slugify(slug)) or []
        for c in cands:
            if c.startswith(self.root):
                return c
        return cands[0] if cands else None

    def cite(self, ref):
        """[@adr-0009] -> whatever the page's own `sources:` block says it is."""
        path = self.sources.get(ref)
        if not path:
            return None
        path = path.replace("~/", "").lstrip("/")
        if path.startswith(HOME.lstrip("/")):
            path = os.path.relpath("/" + path, HOME)
        return self._hit(path) or self._hit(posixpath.join(self.root, path))

    def link(self, target, text):
        """Emit an anchor for an internal doc, inert text for anything else."""
        if target and target != self.cur:
            self.out[target] = True
            return '<a href="#/d/%s">%s</a>' % (html.escape(target, True), text)
        return '<span class=x>%s</span>' % text


LI = re.compile(r"\s*(?:[-*+]|\d+[.)])\s+(.*)$")


def block(b):
    """One blank-line-delimited block -> one element.

    Block-wise, not line-wise: this corpus is hard-wrapped at ~78 columns, so a
    list item routinely spans four source lines. Matching `^- ` per line turned
    every continuation line into its own stray paragraph, which is why rendered
    almanac lists read as if sentences had been cut in half."""
    b = b.rstrip()
    if re.match(r"\s*<(h\d|blockquote|hr|pre)", b) or b.lstrip().startswith("\x00"):
        return b
    lines = b.split("\n")
    if LI.match(lines[0]):
        items, ordered = [], bool(re.match(r"\s*\d+[.)]", lines[0]))
        for ln in lines:
            m = LI.match(ln)
            if m:
                items.append(m.group(1))
            elif items:
                items[-1] += " " + ln.strip()   # wrapped continuation line
        tag = "ol" if ordered else "ul"
        # ponytail: nesting is flattened. These docs nest one level at most and
        # only in the vendored manual; add depth tracking if that changes.
        return "<%s>%s</%s>" % (tag, "".join("<li>%s</li>" % i for i in items), tag)
    if all(ln.lstrip().startswith("|") for ln in lines) and len(lines) > 1:
        rows = []
        for n, ln in enumerate(lines):
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            if n == 1 and all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                continue                        # the |---|---| separator row
            cell = "th" if n == 0 else "td"
            rows.append("<tr>" + "".join("<%s>%s</%s>" % (cell, c, cell)
                                         for c in cells) + "</tr>")
        return "<table class=md>" + "".join(rows) + "</table>"
    return "<p>%s</p>" % b


def md_to_html(src, res=None):
    """Markdown subset -> HTML, escaping first so nothing in the source can
    introduce markup. Only tags produced by this function reach the page, and
    the CSP refuses inline script even if that ever stopped being true."""
    fences, toc = [], []

    def stash(m):
        fences.append(m.group(0))
        return "\x00%d\x00" % (len(fences) - 1)

    src = re.sub(r"```[\s\S]*?```", stash, src)
    out = html.escape(src)

    def head(m):
        level, text = len(m.group(1)), m.group(2)
        hid = slugify(re.sub(r"<[^>]+>", "", text))[:60]
        if level in (2, 3):
            toc.append({"id": hid, "t": re.sub(r"[`*]", "", text), "l": level})
        return '<h%d id="%s">%s</h%d>' % (level, hid, text, level)

    out = re.sub(r"^(#{1,4}) (.*)$", head, out, flags=re.M)
    out = re.sub(r"^&gt; (.*)$", r"<blockquote>\1</blockquote>", out, flags=re.M)
    out = re.sub(r"^\s*[-*_]{3,}\s*$", "<hr>", out, flags=re.M)
    out = re.sub(r"`([^`\n]+)`", r"<code>\1</code>", out)
    # emphasis may wrap across a source line -- these docs are hard-wrapped at
    # ~78 cols, so a single-line pattern misses most of it. `\n(?!\n)` lets a
    # span cross one newline but never a blank line, so an unclosed `*` cannot
    # swallow the rest of the document. `(?!\s)` / `(?<!\s)`: a delimiter
    # padded with space is not emphasis, it is arithmetic -- "a * b * c".
    span = r"(?:[^*\n]|\n(?!\n))+?"
    out = re.sub(r"\*\*(?!\s)(" + span + r")(?<!\s)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![*\w])\*(?!\s)(" + span + r")(?<!\s)\*(?!\*)",
                 r"<em>\1</em>", out)

    if res is not None:
        out = re.sub(r"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]",
                     lambda m: res.link(res.wiki(m.group(1).strip()),
                                        m.group(2) or m.group(1)), out)
        out = re.sub(r"\[([^\]\n]+)\]\(([^)\n]+)\)",
                     lambda m: res.link(res.rel(m.group(2)), m.group(1)), out)
        # Citations keep their brackets. Rendering [@transcript-1b2a184b] as a
        # bare word drops it into the middle of a sentence as if it were prose
        # ("...into client timeouts transcript-1b2a184b. This is...").
        out = re.sub(r"\[@([\w.-]+)\]",
                     lambda m: '<span class=cite>%s</span>'
                     % res.link(res.cite(m.group(1)), m.group(1)), out)
    else:
        out = re.sub(r"\[([^\]\n]+)\]\(([^)\n]+)\)", r"\1", out)

    out = "".join(block(b) for b in re.split(r"\n{2,}", out) if b.strip())
    # A loose list (blank line between items) arrives here as one <ol> per
    # item, so every entry renumbers itself to 1. Stitch adjacent runs.
    out = re.sub(r"</(ol|ul)><\1>", "", out)
    out = re.sub(r"\x00(\d+)\x00",
                 lambda m: "<pre><code>" + html.escape(
                     re.sub(r"^```\w*\n?|```$", "", fences[int(m.group(1))])
                 ) + "</code></pre>", out)
    return out, toc


def read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def title_of(meta, body, fallback):
    """`index` and `README` are the two most common titles in the corpus (114
    and 98 of them). The filename is not an identity, so prefer what the
    document calls itself: frontmatter title, else its first H1."""
    if meta.get("title"):
        return meta["title"]
    m = re.search(r"^#\s+(.+)$", body, re.M)
    return m.group(1).strip() if m else fallback


def lead(meta, body):
    """One-line description: frontmatter summary, else the first real
    paragraph. Shown wherever a title alone would be ambiguous."""
    if meta.get("summary"):
        return re.sub(r"[`*]", "", meta["summary"])
    for para in re.split(r"\n{2,}", body):
        p = para.strip()
        if p and not p.startswith(("#", "---", "|", "-", "*", ">", "```")):
            return re.sub(r"\s+", " ", re.sub(r"[`*\[\]]", "", p))[:240]
    return ""


def targets(raw, res):
    """Every doc this one points at, by any of the corpus's three link forms."""
    out = set()
    for m in re.finditer(r"\[\[([^\]\n|]+?)(?:\|[^\]]*)?\]\]", raw):
        out.add(res.wiki(m.group(1).strip()))
    for m in re.finditer(r"\]\(([^)\n]+)\)", raw):
        out.add(res.rel(m.group(1)))
    for m in re.finditer(r"\[@([\w.-]+)\]", raw):
        out.add(res.cite(m.group(1)))
    out.discard(None)
    out.discard(res.cur)
    return out


def backlinks(target, docs, index):
    """Which docs point at this one. The corpus describes itself as a graph and
    then ships no reverse edges, so they get computed here.

    ponytail: full corpus re-read, ~90ms. A substring prefilter on the slug
    skips the body regex for ~99% of files. If it ever matters, the fix is an
    mtime-keyed index -- but that reintroduces staleness, so measure first."""
    base = os.path.basename(target)[:-3]
    hits = []
    for d in docs:
        if d["p"] == target:
            continue
        raw = read(index[d["p"]])
        if base not in raw:
            continue
        meta, sources, body = parse_front(raw)
        if target in targets(raw, Resolver(index, docs, d["p"], sources)):
            hits.append({"p": d["p"], "t": title_of(meta, body, d["t"]),
                         "r": d["r"], "k": d["k"]})
    return hits


def hubs(repo, docs, index, limit=8):
    """Rank one repo's docs by how often the rest of the repo points at them.

    The tree answers "what is in here" and the mtime sort answers "what changed".
    Neither answers "where do I start", which is the question someone opening an
    unfamiliar repo actually has. In-degree answers it from evidence the authors
    left behind rather than from an ordering someone would have to maintain:
    across atlas's 71 docs it surfaces the wiki-architecture ADR and the scanner
    page, which are in fact the two things to read first.

    Repo-scoped on purpose. Corpus-wide is the same loop over 33x the files."""
    sub = [d for d in docs if d["r"] == repo]
    deg, title = collections.Counter(), {}
    for d in sub:
        raw = read(index[d["p"]])
        meta, sources, body = parse_front(raw)
        title[d["p"]] = title_of(meta, body, d["t"])
        for t in targets(raw, Resolver(index, docs, d["p"], sources)):
            deg[t] += 1
    ranked = sorted(((deg.get(d["p"], 0), d) for d in sub),
                    key=lambda x: -x[0])
    top = [{"p": d["p"], "t": title[d["p"]], "k": d["k"], "s": d["s"], "n": n}
           for n, d in ranked[:limit] if n]
    orphans = [{"p": d["p"], "t": title[d["p"]], "k": d["k"], "s": d["s"]}
               for n, d in ranked if not n]
    return top, orphans, len(sub)


def search(q, docs, index, limit=80):
    """Content search over the whole corpus, no index. 33-95ms measured.

    The previous build filtered on title+repo+path only, which is why a junior
    engineer searching "hang" for a documented proxy hang got five irrelevant
    hits: the words are in the prose, not the filenames."""
    ql = q.lower()
    # A bare substring search for "hang" matches "change" 829 times, which is
    # how the term buries the one incident page actually about a hang. A
    # single word is searched on word boundaries; a phrase or anything with
    # punctuation is searched literally, since \b would be wrong there.
    pat = (re.compile(r"\b" + re.escape(ql) + r"\b")
           if re.fullmatch(r"[\w-]+", ql) else re.compile(re.escape(ql)))
    hits = []
    for d in docs:
        raw = read(index[d["p"]])
        low = raw.lower()
        found = [m.start() for m in pat.finditer(low)]
        n = len(found)
        in_title = bool(pat.search(d["t"].lower()))
        if not n and not in_title:
            continue
        meta, sources, body = parse_front(raw)
        i = found[0] if found else -1
        snip = ""
        if i != -1:
            a, b = max(0, i - 90), min(len(raw), i + len(q) + 110)
            # strip markdown punctuation: a snippet reading `--- title: "**x**`
            # is showing the reader the file format, not the answer
            snip = re.sub(r"[#*`>|]+", "", re.sub(r"\s+", " ", raw[a:b])).strip()
            snip = ("..." if a else "") + snip + ("..." if b < len(raw) else "")
        hits.append({"p": d["p"], "t": title_of(meta, body, d["t"]),
                     "r": d["r"], "k": d["k"], "s": d["s"], "n": n,
                     "snip": snip, "w": (100 if in_title else 0) + min(n, 20)})
    hits.sort(key=lambda h: -h["w"])
    return hits[:limit], len(hits)


# --------------------------------------------------------------------- HTTP

# --------------------------------------------------------------------- runs

RUNS = os.environ.get("ATLAS_RUNS_DIR") or os.path.join(
    HOME, ".local", "state", "atlas", "runs")


def runs_summary(runs_dir=None, days=7):
    """One row per (operation, repo) from the run ledger: is it broken
    right now, and how often over the window. Same scoring as
    atlas-runs-check.sh: 'skipped' is lock contention, out of the denominator.
    Broken-now rows sort first."""
    runs_dir = runs_dir or RUNS
    cutoff = time.time() - days * 86400
    rows = {}
    try:
        names = sorted(os.listdir(runs_dir))    # run_id leads with a UTC stamp
    except OSError:
        names = []
    # ceiling: opens every manifest per request (656 files = 13ms warm). If the
    # ledger is never pruned and this creeps, skip by the filename stamp.
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(runs_dir, n)) as f:
                d = json.load(f)
            at = datetime.fromisoformat(
                d["started_at"].replace("Z", "+00:00")).timestamp()
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
        rp = d.get("repo") or ""
        op, repo = d.get("operation") or "unknown", os.path.basename(rp)
        r = rows.setdefault((op, repo), {
            "op": op, "repo": repo, "ok": 0, "n": 0,
            "path": os.path.relpath(rp, DEV) if rp.startswith(DEV + os.sep) else ""})
        st = d.get("status") or "unknown"
        if st != "skipped":
            r.update(last=st, at=at, err=str(d.get("error") or "")[:160])
            if at >= cutoff:
                r["n"] += 1
                r["ok"] += st == "succeeded"
    out = [r for r in rows.values() if "last" in r]
    out.sort(key=lambda r: (r["last"] == "succeeded", r["op"], r["repo"]))
    return out


def unonboarded():
    """Git repos under ~/dev that carry none of the marker dirs: the complement
    of discover(), so it cannot drift from what the site shows."""
    have = {p for _, _, p in discover()}
    out = []
    try:
        groups = sorted(os.listdir(DEV))
    except OSError:
        return out
    for g in groups:
        gp = os.path.join(DEV, g)
        if g in PRUNE or not os.path.isdir(gp):
            continue
        for r in sorted(os.listdir(gp)):
            p = os.path.join(gp, r)
            if p not in have and os.path.exists(os.path.join(p, ".git")):
                out.append(g + "/" + r)
    return out


# ---------------------------------------------------------------------- ops

STATE = os.path.join(HOME, ".local", "state", "atlas")
LOGDIRS = (os.path.join(WIKI, "logs"), os.path.join(STATE, "actions"))
ATLAS = os.path.join(os.path.dirname(os.path.dirname(
    os.path.realpath(__file__))), "bin", "atlas")
# The whole write surface: `atlas <name> [repo]`. name -> (takes a repo,
# changes things).
ACTIONS = {"status": (False, False), "check": (False, False),
           "graph-check": (False, False), "friction": (False, False),
           "reads": (False, False), "upstream": (False, True),
           "scan": (False, True), "services": (False, True),
           "cascade": (True, True), "onboard": (True, True),
           "pointer": (True, True)}


def repo_paths():
    """group/name -> absolute path for every repo this site can name."""
    m = {g + "/" + n: p for g, n, p in discover()}
    m.update((r, os.path.join(DEV, r)) for r in unonboarded())
    return m


def act(name, repo=""):
    """Start `atlas <name> [repo]` detached, output to a log the page can
    tail. Returns the log's name. Double starts are the scripts' business:
    they hold their own locks and record 'skipped'."""
    if name not in ACTIONS:
        raise ValueError("unknown action")
    argv = [ATLAS, name]
    if ACTIONS[name][0]:
        path = repo_paths().get(repo)
        if not path:
            raise ValueError("unknown repo")
        argv.append(path)
    os.makedirs(LOGDIRS[1], exist_ok=True)
    log = "%s-%s.log" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), name)
    try:
        f = open(os.path.join(LOGDIRS[1], log), "xb", buffering=0)
    except FileExistsError:
        raise ValueError("already started this second")
    f.write(("$ atlas %s %s\n" % (name, repo)).encode())
    p = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True,
                         cwd=HOME)

    def reap():     # no zombie under a server that lives for weeks
        f.write(("\n[exit %d]\n" % p.wait()).encode())
        f.close()
    threading.Thread(target=reap, daemon=True).start()
    return log


def ops():
    """What runs behind the site: launchd services, runs alive right now, the
    openwiki queue, and which logs exist."""
    try:
        out = subprocess.run(["launchctl", "list"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    services = []
    for line in out.splitlines():
        pid, code, label = (line.split("\t") + ["", ""])[:3]
        if label.startswith(("com.atlas.", "com.codealmanac.")):
            services.append({"label": label, "pid": pid, "exit": code})
    running = []
    try:
        names = sorted(os.listdir(RUNS))[-100:]
    except OSError:
        names = []
    for n in names:
        try:
            with open(os.path.join(RUNS, n)) as f:
                d = json.load(f)
            if d.get("status") != "running":
                continue
            os.kill(int(d["pid"]), 0)       # a dead pid is 'abandoned', not live
        except (OSError, ValueError, KeyError, TypeError):
            continue
        running.append({"op": d.get("operation") or "unknown",
                        "repo": os.path.basename(d.get("repo") or ""),
                        "since": d.get("started_at") or ""})
    try:
        pending = sorted(os.listdir(os.path.join(STATE, "openwiki-pending")))
    except OSError:
        pending = []
    logs = []
    for d in LOGDIRS:
        try:
            for e in os.scandir(d):
                st = e.stat()
                if st.st_size:
                    logs.append({"f": e.name, "z": st.st_size, "m": int(st.st_mtime)})
        except OSError:
            pass
    logs.sort(key=lambda x: -x["m"])
    return {"services": sorted(services, key=lambda x: x["label"]),
            "running": running, "pending": pending, "logs": logs[:40],
            "actions": [{"name": k, "repo": v[0], "mut": v[1]}
                        for k, v in ACTIONS.items()]}


def log_tail(name, limit=16384):
    """Last bytes of a log, or None. Only names os.listdir returns for the two
    log dirs are openable, same rule as the docs: no path is ever joined from
    a request."""
    for d in LOGDIRS:
        try:
            if name not in os.listdir(d):
                continue
            with open(os.path.join(d, name), "rb") as f:
                f.seek(max(0, os.path.getsize(f.name) - limit))
                text = f.read().decode("utf-8", "replace")
        except OSError:
            continue
        return {"text": text,
                "live": d == LOGDIRS[1] and "\n[exit " not in text}
    return None


def gz(b):
    return gzip.compress(b, 6)


class Handler(BaseHTTPRequestHandler):
    server_version = "atlas-site"

    def _guard(self):
        """Reject anything whose Host is not a loopback literal. A browser tab
        on an attacker's page can resolve a hostname to 127.0.0.1 and reach
        this port; the Host header is what distinguishes that from the user
        typing localhost."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        if host not in ("127.0.0.1", "localhost", "::1") and not host.endswith(".localhost"):
            self.send_error(403, "bad Host")
            return False
        return True

    def _send(self, body, ctype, etag=None):
        accepts_gz = "gzip" in (self.headers.get("Accept-Encoding") or "")
        payload = gz(body) if accepts_gz and len(body) > 1024 else body
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        if payload is not body:
            self.send_header("Content-Encoding", "gzip")
        if etag:
            self.send_header("ETag", etag)
        # no-store: the whole premise is that nothing here is ever stale.
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Robots-Tag", "noindex, noarchive")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'self'; "
                         "script-src 'self'; connect-src 'self'; "
                         "img-src 'self' data:; base-uri 'none'; "
                         "form-action 'none'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, obj, etag=None):
        self._send(json.dumps(obj, separators=(",", ":")).encode(),
                   "application/json; charset=utf-8", etag)

    def do_POST(self):
        if not self._guard():
            return
        origin = self.headers.get("Origin")
        if (urlparse(self.path).path != "/api/act"
                or self.headers.get("X-Atlas") != "1"
                or self.headers.get("Sec-Fetch-Site", "same-origin") != "same-origin"
                or (origin and urlparse(origin).netloc != self.headers.get("Host"))):
            self.send_error(403, "not allowed")
            return
        try:
            body = json.loads(self.rfile.read(
                min(int(self.headers.get("Content-Length") or 0), 4096)))
            self._json({"log": act(str(body.get("action")), str(body.get("repo") or ""))})
        except (ValueError, AttributeError) as e:
            self.send_error(400, str(e)[:80])

    def do_GET(self):
        if not self._guard():
            return
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path in ("/", "/index.html"):
            self._send(SHELL.encode(), "text/html; charset=utf-8")

        elif u.path == "/app.css":
            self._send(CSS.encode(), "text/css; charset=utf-8")

        elif u.path == "/app.js":
            self._send(JS.encode(), "text/javascript; charset=utf-8")

        elif u.path == "/favicon.ico":
            # This tab stays open next to a terminal all day; it needs to be
            # findable by its icon. Inline SVG, no asset to ship.
            self._send(
                b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
                b'<rect width="16" height="16" rx="3" fill="#1b1f26"/>'
                b'<path d="M4 4h8M4 8h8M4 12h5" stroke="#6fd8de" '
                b'stroke-width="1.6" stroke-linecap="round"/></svg>',
                "image/svg+xml")

        elif u.path == "/api/index":
            docs, _, ms = scan()
            payload = json.dumps(docs, separators=(",", ":"))
            # etag over the corpus only. walk_ms and generated change every
            # request by construction, so hashing the whole body made 304
            # unreachable and shipped 47KB on every poll.
            etag = '"%s"' % hashlib.sha256(payload.encode()).hexdigest()[:16]
            if self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
                return
            body = ('{"docs":%s,"walk_ms":%s,"generated":"%s"}'
                    % (payload, round(ms, 1),
                       datetime.now().strftime("%H:%M:%S"))).encode()
            self._send(body, "application/json; charset=utf-8", etag)

        elif u.path == "/api/doc":
            rel = (q.get("p") or [""])[0]
            docs, index, _ = scan()
            if rel not in index:
                self.send_error(404, "no such doc")
                return
            t0 = time.perf_counter()
            raw = read(index[rel])
            meta, sources, body = parse_front(raw)
            res = Resolver(index, docs, rel, sources)
            # The page header already prints the title, so a leading H1 renders
            # it twice. Only the first one, and only if nothing precedes it.
            body_html, toc = md_to_html(
                re.sub(r"\A\s*#\s+.*\n+", "", body), res)
            titles = {d["p"]: d for d in docs}
            out = [{"p": p, "t": titles[p]["t"], "r": titles[p]["r"],
                    "k": titles[p]["k"]} for p in res.out if p in titles]
            ev = [{"id": k, "path": v,
                   "p": res.cite(k) or ""} for k, v in sources.items() if v]
            self._json({"path": rel, "meta": meta,
                        "title": title_of(meta, body, os.path.basename(rel)[:-3]),
                        "lead": lead(meta, body),
                        "html": body_html, "toc": toc, "out": out,
                        "sources": ev,
                        "back": backlinks(rel, docs, index),
                        "ms": round((time.perf_counter() - t0) * 1000, 1)})

        elif u.path == "/api/repo":
            name = (q.get("r") or [""])[0]
            docs, index, _ = scan()
            if not any(d["r"] == name for d in docs):
                self.send_error(404, "no such repo")
                return
            t0 = time.perf_counter()
            top, orphans, total = hubs(name, docs, index)
            self._json({"start": top, "orphans": orphans, "total": total,
                        "ms": round((time.perf_counter() - t0) * 1000, 1)})

        elif u.path == "/api/runs":
            t0 = time.perf_counter()
            self._json({"rows": runs_summary(), "missing": unonboarded(),
                        "days": 7,
                        "ms": round((time.perf_counter() - t0) * 1000, 1)})

        elif u.path == "/api/ops":
            self._json(ops())

        elif u.path == "/api/log":
            tail = log_tail((q.get("f") or [""])[0])
            if tail is None:
                self.send_error(404, "no such log")
                return
            self._json(tail)

        elif u.path == "/api/search":
            term = (q.get("q") or [""])[0].strip()
            if len(term) < 2:
                self._json({"hits": [], "total": 0, "ms": 0})
                return
            docs, index, _ = scan()
            t0 = time.perf_counter()
            hits, total = search(term, docs, index)
            self._json({"hits": hits, "total": total,
                        "ms": round((time.perf_counter() - t0) * 1000, 1)})

        else:
            self.send_error(404, "not found")

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


# ------------------------------------------------------------------ frontend

SHELL = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Atlas</title><link rel=stylesheet href="/app.css">
<link rel=icon href="/favicon.ico" type="image/svg+xml">
</head><body>
<a class=skip href="#doc">Skip to content</a>
<header>
  <button id=menu class=icon aria-label="Toggle navigation" aria-expanded=false>
    <span></span><span></span><span></span></button>
  <a class=brand href="#/">atlas</a>
  <a class=nav href="#/runs">control</a>
  <form id=sf role=search><input id=q type=search autocomplete=off
    placeholder="Search all documents..." aria-label="Search document contents">
    </form>
  <span id=stat class=stat></span>
  <button id=theme class=theme-btn aria-label="Toggle color theme"></button>
</header>
<div class=shell>
  <nav id=side aria-label="Document tree"></nav>
  <main id=doc tabindex=-1></main>
</div>
<script src="/app.js"></script>
</body></html>
"""

CSS = """
/* Read for long stretches beside a terminal, light room or dim -- follows
   system colour scheme by default, overridable via the header toggle
   (persisted in localStorage as data-theme on <html>). Restrained colour --
   tinted slate neutrals, one accent, used only for current-location and
   selection. No webfonts: the CSP forbids external origins and the machine
   is often offline. */
:root{
  --bg:oklch(0.98 0.004 250); --surface:oklch(0.965 0.006 250);
  --raised:oklch(0.925 0.008 250); --line:oklch(0.85 0.012 250);
  --ink:oklch(0.22 0.016 250); --ink2:oklch(0.42 0.016 250);
  --muted:oklch(0.50 0.014 250);
  --accent:oklch(0.46 0.15 196); --accent-dim:oklch(0.90 0.05 196);
  --warn:oklch(0.46 0.16 75);
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;
  --sans:system-ui,-apple-system,"Segoe UI",sans-serif;
  --head:56px; --side:290px; --rail:220px;
  --z-sticky:10; --z-nav:20; --z-header:30;
  /* dense scale: this is a dashboard, not a landing page */
  --s1:4px; --s2:8px; --s3:12px; --s4:16px; --s5:24px; --s6:32px;
  --ease:cubic-bezier(0.22,1,0.36,1);
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:oklch(0.17 0.012 250); --surface:oklch(0.205 0.013 250);
    --raised:oklch(0.245 0.014 250); --line:oklch(0.315 0.014 250);
    --ink:oklch(0.945 0.004 250); --ink2:oklch(0.775 0.011 250);
    --muted:oklch(0.655 0.012 250);
    --accent:oklch(0.78 0.13 196); --accent-dim:oklch(0.42 0.07 196);
    --warn:oklch(0.80 0.13 75);
  }
}
:root[data-theme="dark"]{
  --bg:oklch(0.17 0.012 250); --surface:oklch(0.205 0.013 250);
  --raised:oklch(0.245 0.014 250); --line:oklch(0.315 0.014 250);
  --ink:oklch(0.945 0.004 250); --ink2:oklch(0.775 0.011 250);
  --muted:oklch(0.655 0.012 250);
  --accent:oklch(0.78 0.13 196); --accent-dim:oklch(0.42 0.07 196);
  --warn:oklch(0.80 0.13 75);
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--sans);
  overflow-wrap:break-word}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:3px}
.skip{position:absolute;left:-999px;top:8px;z-index:100;background:var(--raised);
  padding:var(--s2) var(--s3);border-radius:6px}
.skip:focus{left:8px}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer}

header{position:fixed;inset:0 0 auto 0;height:var(--head);z-index:var(--z-header);
  display:flex;align-items:center;gap:var(--s4);padding:0 var(--s4);
  background:var(--surface);border-bottom:1px solid var(--line)}
.brand{font:600 15px/1 var(--mono);color:var(--ink);letter-spacing:-0.01em}
#sf{flex:1;max-width:560px}
#q{width:100%;height:34px;padding:0 var(--s3);border-radius:7px;
  border:1px solid var(--line);background:var(--bg);color:var(--ink);
  font:14px var(--sans);transition:border-color .15s var(--ease)}
#q::placeholder{color:var(--muted)}
#q:focus{border-color:var(--accent)}
.stat{margin-left:auto;color:var(--muted);font:11px/1 var(--mono);
  white-space:nowrap}
.icon{display:none;flex-direction:column;gap:4px;padding:var(--s2)}
.icon span{display:block;width:17px;height:1.5px;background:var(--ink2)}
.theme-btn{width:32px;height:32px;border-radius:7px;border:1px solid var(--line);
  color:var(--ink2);font-size:14px;display:flex;align-items:center;
  justify-content:center;transition:color .12s var(--ease),border-color .12s var(--ease)}
.theme-btn:hover{color:var(--ink);border-color:var(--muted)}

.shell{display:flex;padding-top:var(--head);min-height:100vh}
#side{position:fixed;top:var(--head);bottom:0;width:var(--side);overflow-y:auto;
  overscroll-behavior:contain;background:var(--surface);
  border-right:1px solid var(--line);padding:var(--s3) 0 var(--s6);
  z-index:var(--z-nav)}
#doc{flex:1;margin-left:var(--side);min-width:0;padding:var(--s5) var(--s6) 64px}

/* tree ------------------------------------------------------------------ */
.tg{padding:var(--s4) var(--s4) var(--s1);color:var(--muted);
  font:11px/1 var(--mono);letter-spacing:0.04em}
.tw{position:relative;width:100%;display:flex;align-items:center;gap:var(--s2);
  padding:5px var(--s4);text-align:left;color:var(--ink2);font-size:13.5px;
  border-left:2px solid transparent;transition:background .12s var(--ease)}
.tw:hover{background:var(--raised);color:var(--ink)}
.tw .n{margin-left:auto;color:var(--muted);font:10.5px var(--mono);
  font-variant-numeric:tabular-nums}
.tw .ar{width:9px;flex:none;color:var(--muted);transition:transform .15s var(--ease)}
.tw[aria-expanded=true] .ar{transform:rotate(90deg)}
/* depth ladder: group -> repo -> kind -> section/leaf. Weight and colour
   carry the hierarchy, not indent alone -- two rows ten pixels apart in an
   identical typeface read as the same level. */
.tw.l1{margin-top:var(--s3);font:600 11px/1 var(--mono);color:var(--muted);
  letter-spacing:0.05em;text-transform:uppercase;padding-top:var(--s2);
  padding-bottom:var(--s2)}
.tw.l1:first-child{margin-top:0}
.tw.l1:hover{color:var(--ink)}
.tw.l2{padding-left:26px;font-weight:600;color:var(--ink)}
.tw.l3{padding-left:42px;font-size:13px;font-weight:400;color:var(--ink2)}
.tw.l4{padding-left:56px;font-size:12.5px;font-weight:400;color:var(--muted)}
/* indent guide: a hairline in each row's own gutter strings together into a
   continuous rail across consecutive siblings at that depth. */
.tw.l2::before,.tw.l3::before,.tw.l4::before{content:"";position:absolute;
  top:0;bottom:0;width:1px;background:var(--line)}
.tw.l2::before{left:16px}.tw.l3::before{left:30px}.tw.l4::before{left:44px}
.tw.on{background:var(--raised);color:var(--ink);border-left-color:var(--accent)}
.tw.cur{color:var(--accent)}
.tw .dim{color:var(--muted);font-style:italic}

/* doc ------------------------------------------------------------------- */
.crumb{font:11.5px var(--mono);color:var(--muted);margin-bottom:var(--s3);
  display:flex;flex-wrap:wrap;gap:var(--s1) 6px;align-items:center}
.crumb a{color:var(--ink2)}
.crumb a:hover{color:var(--accent)}
.layout{display:grid;grid-template-columns:minmax(0,1fr) var(--rail);
  gap:var(--s6);align-items:start;max-width:1180px}
article{min-width:0;max-width:74ch;color:var(--ink2)}
h1{font-size:26px;font-weight:700;line-height:1.25;margin:0 0 var(--s2);
  letter-spacing:-0.02em;color:var(--ink);text-wrap:balance}
.lead{color:var(--ink2);font-size:15px;margin:0 0 var(--s4);max-width:70ch;
  text-wrap:pretty}
.tags{display:flex;flex-wrap:wrap;gap:var(--s2);margin-bottom:var(--s5);
  padding-bottom:var(--s4);border-bottom:1px solid var(--line)}
.tag{font:11px var(--mono);color:var(--ink2);background:var(--raised);
  border:1px solid var(--line);border-radius:5px;padding:2px 7px}
.tag b{color:var(--muted);font-weight:400}
article h2{font-size:18px;font-weight:650;margin:var(--s6) 0 var(--s3);
  letter-spacing:-0.01em;color:var(--ink);scroll-margin-top:72px;
  text-wrap:balance}
article h3{font-size:15.5px;font-weight:650;margin:var(--s5) 0 var(--s2);
  color:var(--ink);scroll-margin-top:72px}
article p{margin:0 0 var(--s4);text-wrap:pretty}
article ul{margin:0 0 var(--s4);padding-left:20px}
article li{margin:var(--s1) 0}
article code{font:12.5px var(--mono);background:var(--raised);
  padding:1px 5px;border-radius:4px;color:var(--ink)}
article pre{background:var(--surface);border:1px solid var(--line);
  border-radius:8px;padding:var(--s3) var(--s4);overflow-x:auto;
  margin:0 0 var(--s4)}
article pre code{background:none;padding:0;font-size:12.5px;line-height:1.55}
article blockquote{margin:0 0 var(--s4);padding-left:var(--s4);
  border-left:2px solid var(--line);color:var(--ink2)}
article hr{border:0;border-top:1px solid var(--line);margin:var(--s6) 0}
article .x{color:var(--ink)}   /* unresolved link: plain text, never an href */
article .cite{font:11.5px var(--mono);color:var(--muted);white-space:nowrap}
article .cite::before{content:"["}
article .cite::after{content:"]"}
article .cite a{color:var(--ink2)}
/* Wide tables scroll inside themselves; the page body never scrolls sideways */
article table.md{display:block;overflow-x:auto;width:100%;max-width:100%;
  border-collapse:collapse;font-size:13px;margin:0 0 var(--s4)}
article table.md th,article table.md td{border:1px solid var(--line);
  padding:5px var(--s3);text-align:left;vertical-align:top}
article table.md th{background:var(--surface);color:var(--ink2);
  font:11.5px var(--mono);font-weight:400;white-space:nowrap}
article ol{margin:0 0 var(--s4);padding-left:22px}

/* rail ------------------------------------------------------------------ */
.rail{position:sticky;top:calc(var(--head) + var(--s5));font-size:13px;
  display:flex;flex-direction:column;gap:var(--s5)}
.rail h4{margin:0 0 var(--s2);font:11px/1 var(--mono);color:var(--muted);
  letter-spacing:0.04em}
.rail ol,.rail ul{margin:0;padding:0;list-style:none}
.rail li{margin:0 0 5px;line-height:1.4}
.rail a{color:var(--ink2);font-size:12.5px}
.rail a:hover{color:var(--accent)}
.rail .in3{padding-left:var(--s3)}
.rail .src{color:var(--muted);font:11.5px var(--mono);word-break:break-all}

/* lists / home ---------------------------------------------------------- */
.rows{border-top:1px solid var(--line)}
.row{display:block;width:100%;text-align:left;padding:var(--s3) var(--s2);
  border-bottom:1px solid var(--line);transition:background .12s var(--ease)}
.row:hover{background:var(--surface);text-decoration:none}
.row .t{color:var(--ink);font-size:14.5px;font-weight:500}
.row .p{color:var(--muted);font:11px var(--mono);margin-top:2px}
.row .d{color:var(--ink2);font-size:13px;margin-top:3px;max-width:88ch;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;
  overflow:hidden}
.row mark{background:var(--accent-dim);color:var(--ink);border-radius:2px}
h2.sec{font-size:13px;margin:var(--s6) 0 var(--s3);color:var(--muted);
  font-family:var(--mono);font-weight:400;letter-spacing:0.04em}
h2.sec:first-child{margin-top:0}
.hint{color:var(--muted);font-size:13px;margin:var(--s5) 0}
.empty{color:var(--ink2);padding:var(--s6) 0;max-width:58ch}
.empty b{display:block;color:var(--ink);margin-bottom:var(--s2)}
table.adr{width:100%;border-collapse:collapse;font-size:13.5px}
table.adr td,table.adr th{border-bottom:1px solid var(--line);
  padding:6px var(--s3) 6px 0;text-align:left;vertical-align:top}
table.adr th{color:var(--muted);font:11px var(--mono);font-weight:400}
table.adr td.num,table.adr th.num{color:var(--muted);font:12px/1.8 var(--mono);
  white-space:nowrap;font-variant-numeric:tabular-nums}
table.adr tr:hover td{background:var(--surface)}
/* Restrained: in a table where every row is a link, colouring them all is
   noise, not signal. Ink at rest, accent on hover/focus. */
table.adr td a{font-weight:500;color:var(--ink)}
table.adr td a:hover{color:var(--accent)}
.warn{color:var(--warn)}
.nav{font:12px var(--mono);color:var(--ink2)}
table.adr td.warn{color:var(--warn);font:12px/1.8 var(--mono)}
table.adr td.err{white-space:normal;overflow-wrap:anywhere;min-width:16ch}
.act{font:12px var(--mono);color:var(--ink2);border:1px solid var(--line);
  border-radius:4px;padding:3px 9px;margin:0 6px 6px 0;min-height:24px}
.act:hover,.act:focus-visible{color:var(--accent);border-color:var(--accent)}
.act:disabled{opacity:.6;cursor:default}
pre.log{font:12px/1.5 var(--mono);background:var(--surface);
  border:1px solid var(--line);padding:12px;max-height:50vh;overflow:auto;
  white-space:pre-wrap;word-break:break-word}

@media (max-width:1080px){
  .layout{grid-template-columns:minmax(0,1fr)}
  .rail{display:none}
  /* same rule as table.md: the table scrolls, the page never does */
  table.adr{display:block;overflow-x:auto;max-width:100%}
}
@media (max-width:820px){
  .icon{display:flex}
  /* visibility, not just transform: a closed drawer must leave the tab order */
  #side{transform:translateX(-100%);visibility:hidden;
    transition:transform .2s var(--ease),visibility 0s .2s}
  #side.open{transform:none;visibility:visible;
    transition:transform .2s var(--ease);box-shadow:8px 0 40px rgb(0 0 0/.35)}
  #doc{margin-left:0;padding:var(--s4)}
  .stat{display:none}
}
@media (pointer:coarse){
  .act{min-height:44px;padding:0 14px}
  .icon{min-width:44px;min-height:44px;justify-content:center;align-items:center}
}
@media (prefers-reduced-motion:reduce){
  *{transition-duration:.01ms!important;animation-duration:.01ms!important}
}
"""

JS = r"""
'use strict';

/* ---- theme -------------------------------------------------------------
   Applied first, before the rest of boot, to keep any flash brief: a saved
   choice wins, otherwise the OS preference (handled purely in CSS) applies. */
try{
  var savedTheme = localStorage.getItem('theme');
  if (savedTheme) document.documentElement.setAttribute('data-theme', savedTheme);
}catch(e){}
function effectiveTheme(){
  var t = document.documentElement.getAttribute('data-theme');
  if (t) return t;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
var DOCS = [], BY = {}, WALK = '', GEN = '';
var side = document.getElementById('side'), main = document.getElementById('doc');
var qbox = document.getElementById('q'), stat = document.getElementById('stat');
var open = {};   // expanded tree nodes, keyed by node id

function el(t, cls, txt){ var n = document.createElement(t);
  if (cls) n.className = cls; if (txt != null) n.textContent = txt; return n; }
function kb(z){ return z < 1024 ? z + ' B' : (z/1024).toFixed(1) + ' KB'; }
function ago(m){ var d = Math.floor((Date.now()/1000 - m)/86400);
  return d <= 0 ? 'today' : d === 1 ? '1d ago' : d + 'd ago'; }

/* ---- tree ------------------------------------------------------------- */
/* Built from the path segments the scanner already emits. The corpus has four
   real levels (group > repo > layer > section) and the previous build showed
   none of them. `almanac/manual` is the vendored CodeAlmanac manual: 390 docs,
   byte-identical across 30 repos. It stays in the tree but collapsed and
   labelled, because it is 18% of the corpus and none of it is about the repo
   it sits in. */
function tree(){
  var g = {};
  DOCS.forEach(function(d){
    var G = g[d.g] || (g[d.g] = {n:0, r:{}});
    var R = G.r[d.r] || (G.r[d.r] = {n:0, k:{}});
    var K = R.k[d.k] || (R.k[d.k] = {n:0, s:{}});
    var key = d.s || '';
    (K.s[key] || (K.s[key] = {n:0, d:[]})).d.push(d);
    G.n++; R.n++; K.n++; K.s[key].n++;
  });
  return g;
}

function row(depth, id, label, count, kind){
  var b = el('button', 'tw l' + depth);
  var open_ = !!open[id];
  if (kind === 'branch'){
    b.setAttribute('aria-expanded', open_ ? 'true' : 'false');
    var ar = el('span', 'ar'); ar.textContent = '▸'; b.appendChild(ar);
  } else {
    b.appendChild(el('span', 'ar'));
  }
  var t = el('span', label === 'manual' ? 'dim' : null, label);
  b.appendChild(t);
  if (count != null) b.appendChild(el('span', 'n', String(count)));
  return b;
}

function drawTree(){
  var g = tree(), cur = location.hash.slice(2);
  side.textContent = '';
  var head = el('div', 'tg', DOCS.length.toLocaleString() + ' docs');
  side.appendChild(head);
  Object.keys(g).sort(function(a,b){ return g[b].n - g[a].n; }).forEach(function(gn){
    var gid = 'g:' + gn;
    var gb = row(1, gid, gn, g[gn].n, 'branch');
    gb.onclick = function(){ open[gid] = !open[gid]; drawTree(); };
    side.appendChild(gb);
    if (!open[gid]) return;
    var repos = g[gn].r;
    Object.keys(repos).sort().forEach(function(rn){
      var rid = gid + '/r:' + rn;
      var rb = row(2, rid, rn, repos[rn].n, 'branch');
      rb.onclick = function(ev){
        if (ev.shiftKey){ go('#/r/' + rn); return; }
        open[rid] = !open[rid]; drawTree();
        if (!location.hash.startsWith('#/d/')) go('#/r/' + rn);
      };
      side.appendChild(rb);
      if (!open[rid]) return;
      var kinds = repos[rn].k;
      Object.keys(kinds).sort().forEach(function(kn){
        var kid = rid + '/k:' + kn;
        var kbn = row(3, kid, kn, kinds[kn].n, 'branch');
        kbn.onclick = function(){ open[kid] = !open[kid]; drawTree(); };
        side.appendChild(kbn);
        if (!open[kid]) return;
        var secs = kinds[kn].s;
        Object.keys(secs).sort().forEach(function(sn){
          if (sn){
            var sid = kid + '/s:' + sn;
            var sb = row(4, sid, sn, secs[sn].n, 'branch');
            sb.onclick = function(){ open[sid] = !open[sid]; drawTree(); };
            side.appendChild(sb);
            if (!open[sid]) return;
          }
          secs[sn].d.slice().sort(function(a,b){
            return a.t < b.t ? -1 : 1;
          }).forEach(function(d){
            var lb = row(sn ? 4 : 4, 'd:' + d.p, d.t, null, 'leaf');
            lb.classList.add('l4');
            if (d.p === cur) lb.classList.add('on', 'cur');
            lb.onclick = function(){ go('#/d/' + d.p); };
            side.appendChild(lb);
          });
        });
      });
    });
  });
}

/* expand the tree down to a doc, so "where am I" is always answered */
function reveal(p){
  var d = BY[p]; if (!d) return;
  var gid = 'g:' + d.g, rid = gid + '/r:' + d.r, kid = rid + '/k:' + d.k;
  open[gid] = open[rid] = open[kid] = true;
  if (d.s) open[kid + '/s:' + d.s] = true;
}

/* ---- routing ---------------------------------------------------------- */
function go(h){ if (location.hash === h) render(); else location.hash = h; }

function render(){
  var h = location.hash || '#/';
  document.title = 'Atlas';
  side.classList.remove('open');
  document.getElementById('menu').setAttribute('aria-expanded', 'false');
  if (h.startsWith('#/d/')) return viewDoc(decodeURIComponent(h.slice(4)));
  if (h.startsWith('#/r/')) return viewRepo(decodeURIComponent(h.slice(4)));
  if (h.startsWith('#/q/')) return viewSearch(decodeURIComponent(h.slice(4)));
  if (h === '#/runs') return viewRuns();
  return viewHome();
}

function crumbs(parts){
  var c = el('div', 'crumb');
  parts.forEach(function(p, i){
    if (i) c.appendChild(el('span', null, '›'));
    if (p.h){ var a = el('a', null, p.t); a.href = p.h; c.appendChild(a); }
    else c.appendChild(el('span', null, p.t));
  });
  return c;
}

/* ---- home ------------------------------------------------------------- */
function viewHome(){
  main.textContent = '';
  var g = tree();
  main.appendChild(crumbs([{t:'all repositories'}]));
  var h = el('h1', null, 'Every document on this machine');
  main.appendChild(h);
  main.appendChild(el('p', 'lead',
    DOCS.length.toLocaleString() + ' markdown files across ' +
    Object.keys(BY_REPO()).length + ' repositories. Search reads document ' +
    'bodies, not filenames. Pick a repository to see what it documents.'));

  /* A table, not a card grid. 41 repos x 4 numbers is tabular data: aligned
     columns let you compare coverage down a column, which is the actual
     question here ("who has no ADRs?"). Cards would hide the same numbers in
     41 separate strings.

     Columns are per-group, not a global constant: a real repo has three
     layers (almanac/docs/openwiki), but the wiki bundle uses its own kinds
     (repos/services/jobs/...) -- forcing those through the repo-layer columns
     just prints dots and hides the actual counts. */
  var PRIORITY = ['almanac', 'docs', 'openwiki'];
  Object.keys(g).sort(function(a,b){ return g[b].n - g[a].n; }).forEach(function(gn){
    var kindSet = {};
    Object.keys(g[gn].r).forEach(function(rn){
      Object.keys(g[gn].r[rn].k).forEach(function(k){ kindSet[k] = true; }); });
    var cols = PRIORITY.filter(function(k){ return kindSet[k]; }).concat(
      Object.keys(kindSet).filter(function(k){ return PRIORITY.indexOf(k) === -1; }).sort());

    main.appendChild(el('h2', 'sec', gn + '  ·  ' + g[gn].n + ' docs'));
    var t = el('table', 'adr');
    var headers = ['repository'].concat(cols, ['total', 'last change']);
    var hr = el('tr');
    headers.forEach(function(h, i){
      var th = el('th', i && i < headers.length - 1 ? 'num' : null, h); th.scope = 'col'; hr.appendChild(th); });
    t.appendChild(hr);
    Object.keys(g[gn].r).sort(function(a,b){
      return g[gn].r[b].n - g[gn].r[a].n;
    }).forEach(function(rn){
      var R = g[gn].r[rn], tr = el('tr');
      var td = el('td'); var a = el('a', null, rn); a.href = '#/r/' + rn;
      td.appendChild(a); tr.appendChild(td);
      cols.forEach(function(k){
        tr.appendChild(el('td', 'num', R.k[k] ? String(R.k[k].n) : '·')); });
      tr.appendChild(el('td', 'num', String(R.n)));
      var last = 0;
      Object.keys(R.k).forEach(function(k){
        Object.keys(R.k[k].s).forEach(function(s){
          R.k[k].s[s].d.forEach(function(d){ if (d.m > last) last = d.m; }); }); });
      tr.appendChild(el('td', 'num', ago(last)));
      t.appendChild(tr);
    });
    main.appendChild(t);

    var repoNames = Object.keys(g[gn].r);
    var gaps = cols.map(function(k){
      var missing = repoNames.filter(function(rn){
        return !g[gn].r[rn].k[k];
      }).length;
      return {k: k, n: missing};
    }).filter(function(x){ return x.n > 0; })
      .map(function(x){ return x.n + ' missing ' + x.k; });
    if (gaps.length) main.appendChild(el('p', 'hint',
      gaps.join(', ') + ' (of ' + repoNames.length + ' repos).'));
  });
}
function BY_REPO(){
  var r = {}; DOCS.forEach(function(d){ (r[d.r] = r[d.r] || []).push(d); });
  return r;
}

/* ---- repo ------------------------------------------------------------- */
function viewRepo(name){
  main.textContent = '';
  var docs = DOCS.filter(function(d){ return d.r === name; });
  if (!docs.length) return notFound('No repository called "' + name + '".');
  main.appendChild(crumbs([{t:'all', h:'#/'}, {t:docs[0].g}, {t:name}]));
  main.appendChild(el('h1', null, name));
  main.appendChild(el('p', 'lead', docs.length + ' documents. ' +
    'Layers differ in authority: docs/ is human-written, almanac/ is mined ' +
    'knowledge, openwiki/ is generated from current code.'));

  /* "Where do I start" answered from the links the authors already wrote:
     how many other docs in this repo point at each one. Fetched separately
     because it costs a repo-wide read (~150-200ms) and the list below it
     should not wait on that. */
  var startBox = el('div');
  main.appendChild(startBox);
  fetch('/api/repo?r=' + encodeURIComponent(name)).then(function(r){
    return r.json();
  }).then(function(g){
    if (g.start.length){
      startBox.appendChild(el('h2', 'sec',
        'start here  ·  most referenced by the rest of this repo'));
      var t = el('table', 'adr');
      g.start.forEach(function(h){
        var tr = el('tr');
        tr.appendChild(el('td', 'num', h.n + ' refs'));
        var td = el('td'); var a = el('a', null, h.t); a.href = '#/d/' + h.p;
        td.appendChild(a); tr.appendChild(td);
        tr.appendChild(el('td', 'num', h.s ? h.k + '/' + h.s : h.k));
        t.appendChild(tr);
      });
      startBox.appendChild(t);
    }
    if (g.orphans.length){
      startBox.appendChild(el('h2', 'sec',
        g.orphans.length + ' of ' + g.total + ' documents here are referenced ' +
        'by nothing else in the repo — reachable by browsing or search only'));
      var t2 = el('table', 'adr');
      g.orphans.forEach(function(o){
        var tr = el('tr');
        var td = el('td'); var a = el('a', null, o.t); a.href = '#/d/' + o.p;
        td.appendChild(a); tr.appendChild(td);
        tr.appendChild(el('td', 'num', o.s ? o.k + '/' + o.s : o.k));
        t2.appendChild(tr);
      });
      startBox.appendChild(t2);
    }
  });

  /* almanac/manual is the vendored CodeAlmanac manual: 390 files, byte-
     identical across 30 repos, 18% of the whole corpus. None of it is about
     the repo it sits in, so it goes last under its own heading instead of
     interleaving a second "README" next to the repo's real one. Demoted in
     the view, never touched on disk. */
  var manual = docs.filter(function(d){ return /(^|\/)manual(\/|$)/.test(d.s); });
  var own = docs.filter(function(d){ return manual.indexOf(d) === -1; });
  var byKind = {};
  own.forEach(function(d){ (byKind[d.k] = byKind[d.k] || []).push(d); });
  Object.keys(byKind).sort().forEach(function(k){
    main.appendChild(el('h2', 'sec', k + '  ·  ' + byKind[k].length));
    var adr = byKind[k].filter(function(d){ return /(^|\/)adr/.test(d.s); });
    if (adr.length > 3){ main.appendChild(adrTable(adr)); }
    var rest = byKind[k].filter(function(d){ return adr.length > 3 ?
      !/(^|\/)adr/.test(d.s) : true; });
    if (rest.length) main.appendChild(rowsOf(rest));
  });
  if (manual.length){
    main.appendChild(el('h2', 'sec',
      'vendored CodeAlmanac manual  ·  ' + manual.length +
      '  ·  same files in every onboarded repo'));
    main.appendChild(rowsOf(manual));
  }
}

/* ADRs are the one place in this corpus with a real ordinal, and 141 of them
   exist across 8 repos. A table beats cards: the number IS the identity. */
function adrTable(list){
  var t = el('table', 'adr');
  var tr = el('tr');
  ['', 'decision', 'section', 'updated'].forEach(function(h){
    tr.appendChild(el('th', null, h)).scope = 'col'; });
  t.appendChild(tr);
  list.slice().sort(function(a,b){ return a.t < b.t ? -1 : 1; }).forEach(function(d){
    var m = d.t.match(/^(?:ADR[\s-]*)?(\d{3,4})\s*(.*)$/i);
    var r = el('tr');
    r.appendChild(el('td', 'num', m ? m[1] : '—'));
    var td = el('td'); var a = el('a', null, m ? m[2] : d.t);
    a.href = '#/d/' + d.p; td.appendChild(a); r.appendChild(td);
    r.appendChild(el('td', 'num', d.s || '—'));
    r.appendChild(el('td', 'num', ago(d.m)));
    t.appendChild(r);
  });
  return t;
}

function rowsOf(list){
  var wrap = el('div', 'rows');
  list.slice().sort(function(a,b){ return a.t < b.t ? -1 : 1; }).forEach(function(d){
    var a = el('a', 'row'); a.href = '#/d/' + d.p;
    a.appendChild(el('div', 't', d.t));
    a.appendChild(el('div', 'p', (d.s ? d.k + '/' + d.s : d.k) +
      '  ·  ' + kb(d.z) + '  ·  ' + ago(d.m)));
    wrap.appendChild(a);
  });
  return wrap;
}

/* ---- doc -------------------------------------------------------------- */
function viewDoc(p){
  var d = BY[p];
  main.textContent = '';
  main.appendChild(el('p', 'hint', 'Loading…'));
  fetch('/api/doc?p=' + encodeURIComponent(p)).then(function(r){
    if (!r.ok) throw new Error(r.status); return r.json();
  }).then(function(doc){
    main.textContent = '';
    reveal(p); drawTree();
    var seg = [{t:'all', h:'#/'}];
    if (d){ seg.push({t:d.g}); seg.push({t:d.r, h:'#/r/' + d.r});
      seg.push({t:d.s ? d.k + '/' + d.s : d.k}); }
    main.appendChild(crumbs(seg));

    var lay = el('div', 'layout');
    var art = el('article');
    art.appendChild(el('h1', null, doc.title));
    if (doc.lead) art.appendChild(el('p', 'lead', doc.lead));

    var tags = el('div', 'tags');
    function tag(k, v){ var s = el('span', 'tag');
      s.appendChild(el('b', null, k + ' ')); s.appendChild(el('span', null, v));
      tags.appendChild(s); }
    if (d){ tag('repo', d.r); tag('layer', d.k); if (d.s) tag('section', d.s); }
    var SKIP_META = {title: 1, summary: 1, generated: 1};
    if (doc.meta) Object.keys(doc.meta).forEach(function(k){
      if (!SKIP_META[k] && doc.meta[k]) tag(k, doc.meta[k]); });
    if (d) tag('updated', ago(d.m));
    art.appendChild(tags);

    var body = el('div');
    body.innerHTML = doc.html;   // built escape-first server-side; CSP blocks
    art.appendChild(body);       // inline script even if that ever regressed
    lay.appendChild(art);

    var rail = el('aside', 'rail');
    if (doc.toc && doc.toc.length > 1) rail.appendChild(
      list('On this page', doc.toc.map(function(t){
        return {t: t.t, h: '#' + t.id, cls: t.l === 3 ? 'in3' : ''}; })));
    if (doc.out && doc.out.length) rail.appendChild(
      list('Links out (' + doc.out.length + ')', doc.out.map(function(o){
        return {t: o.t, h: '#/d/' + o.p, sub: o.r}; })));
    if (doc.back && doc.back.length) rail.appendChild(
      list('Referenced by (' + doc.back.length + ')', doc.back.map(function(o){
        return {t: o.t, h: '#/d/' + o.p, sub: o.r}; })));
    if (doc.sources && doc.sources.length) rail.appendChild(
      list('Evidence', doc.sources.map(function(s){
        return s.p ? {t: s.path, h: '#/d/' + s.p} : {t: s.path, cls: 'src'}; })));
    lay.appendChild(rail);
    main.appendChild(lay);
    stat.textContent = DOCS.length + ' docs · scan ' + WALK +
      'ms · doc ' + doc.ms + 'ms';
    var h1 = main.querySelector('h1');
    if (h1) document.title = h1.textContent + ' · Atlas';
    main.focus();
    if (location.hash.indexOf('#', 1) === -1) window.scrollTo(0, 0);
  }).catch(function(){ notFound('That document is not in the current scan.'); });
}

function list(title, items){
  var box = el('div');
  box.appendChild(el('h4', null, title));
  var ul = el('ul');
  items.forEach(function(i){
    var li = el('li', i.cls);
    if (i.h){ var a = el('a', null, i.t); a.href = i.h; li.appendChild(a); }
    else li.appendChild(el('span', null, i.t));
    ul.appendChild(li);
  });
  box.appendChild(ul);
  return box;
}

/* ---- search ----------------------------------------------------------- */
function viewSearch(q){
  qbox.value = q;
  main.textContent = '';
  main.appendChild(crumbs([{t:'all', h:'#/'}, {t:'search'}]));
  main.appendChild(el('h1', null, '“' + q + '”'));
  var status = el('p', 'lead', 'Searching document bodies…');
  main.appendChild(status);
  fetch('/api/search?q=' + encodeURIComponent(q)).then(function(r){
    return r.json();
  }).then(function(res){
    if (!res.total){
      status.remove();
      return main.appendChild(emptyState(q));
    }
    status.textContent = res.total + ' document' + (res.total === 1 ? '' : 's') +
      ' contain this text · searched every body in ' + res.ms + 'ms' +
      (res.total > res.hits.length ? ' · showing top ' + res.hits.length : '');
    var wrap = el('div', 'rows');
    res.hits.forEach(function(h){
      var a = el('a', 'row'); a.href = '#/d/' + h.p;
      a.appendChild(el('div', 't', h.t));
      a.appendChild(el('div', 'p', h.r + '  ·  ' +
        (h.s ? h.k + '/' + h.s : h.k) + '  ·  ' + h.n + '×'));
      if (h.snip){
        var d = el('div', 'd');
        var i = h.snip.toLowerCase().indexOf(q.toLowerCase());
        if (i === -1) d.textContent = h.snip;
        else {
          d.appendChild(document.createTextNode(h.snip.slice(0, i)));
          d.appendChild(el('mark', null, h.snip.substr(i, q.length)));
          d.appendChild(document.createTextNode(h.snip.slice(i + q.length)));
        }
        a.appendChild(d);
      }
      wrap.appendChild(a);
    });
    main.appendChild(wrap);
  });
}

/* Empty states teach the interface rather than saying "nothing here". */
function emptyState(q){
  var e = el('div', 'empty');
  e.appendChild(el('b', null, 'No document contains “' + q + '”.'));
  var p = el('p', null, 'This searches the full text of every file, so a ' +
    'miss means the words really are absent. Two things that catch people ' +
    'out: some docs may be written in another language, and incident write-ups describe symptoms in their own words ' +
    '(a hang is filed as “saturation”).');
  e.appendChild(p);
  return e;
}

function notFound(msg){
  main.textContent = '';
  main.appendChild(crumbs([{t:'all', h:'#/'}]));
  var e = el('div', 'empty');
  e.appendChild(el('b', null, msg));
  var a = el('a', null, 'Back to all repositories'); a.href = '#/';
  e.appendChild(a);
  main.appendChild(e);
}

/* ---- runs ------------------------------------------------------------- */
var logTimer = 0;
function showLog(f){
  clearTimeout(logTimer);
  var pre = document.getElementById('log');
  if (!pre) return;
  fetch('/api/log?f=' + encodeURIComponent(f)).then(function(r){
    return r.json(); }).then(function(d){
    pre.textContent = f + '\n\n' + d.text;
    pre.scrollTop = pre.scrollHeight;
    if (d.live && location.hash === '#/runs')
      logTimer = setTimeout(function(){ showLog(f); }, 2000);
  }).catch(function(){
    pre.textContent = f + '\n\nCould not read this log. Reload to retry.'; });
}

/* Anything that changes state asks twice, in place: the viewer has no
   confirm() dialog to lean on and a misclick here starts a real job. */
function actBtn(label, name, repo, mut){
  var b = el('button', 'act', label);
  b.addEventListener('click', function(){
    if (mut && !b.dataset.sure){
      b.dataset.sure = '1'; b.textContent = 'confirm ' + label + '?';
      setTimeout(function(){ if (!b.disabled){ delete b.dataset.sure;
        b.textContent = label; } }, 4000);
      return;
    }
    b.disabled = true;
    fetch('/api/act', {method: 'POST',
      headers: {'Content-Type': 'application/json', 'X-Atlas': '1'},
      body: JSON.stringify({action: name, repo: repo || ''})
    }).then(function(r){
      if (!r.ok) throw new Error(r.status + ' ' + r.statusText);
      return r.json();
    }).then(function(j){ b.textContent = label + ' started'; showLog(j.log);
    }).catch(function(e){ b.disabled = false; delete b.dataset.sure;
      b.textContent = label;
      var pre = document.getElementById('log');
      if (pre) pre.textContent = label + ' did not start: ' + e.message; });
  });
  return b;
}

function table(heads){
  var t = el('table', 'adr'), tr = el('tr');
  heads.forEach(function(h){ tr.appendChild(el('th', null, h)).scope = 'col'; });
  t.appendChild(tr);
  return t;
}

function viewRuns(){
  main.textContent = '';
  main.appendChild(crumbs([{t:'all', h:'#/'}, {t:'control'}]));
  document.title = 'Control plane · Atlas';
  main.appendChild(el('h1', null, 'Control plane'));
  Promise.all(['/api/runs', '/api/ops'].map(function(u){
    return fetch(u).then(function(r){ return r.json(); }); })).then(function(x){
    if (location.hash !== '#/runs') return;
    var d = x[0], o = x[1];
    var bad = d.rows.filter(function(r){ return r.last !== 'succeeded'; }).length;
    main.appendChild(el('p', 'lead', o.running.length + ' running now, ' +
      o.pending.length + ' repos queued for openwiki tonight, ' + bad + ' of ' +
      d.rows.length + ' jobs failed their last run.'));

    main.appendChild(el('h2', 'sec', 'Services'));
    var t = table(['launchd label', 'state', 'last exit']);
    o.services.forEach(function(s){
      var r = el('tr');
      r.appendChild(el('td', null, s.label));
      r.appendChild(el('td', 'num', s.pid === '-' ? 'idle' : 'pid ' + s.pid));
      /* negative = killed by a signal; -15 is launchd's own restart */
      var sig = s.exit.charAt(0) === '-';
      r.appendChild(el('td', s.exit === '0' || s.exit === '-15' ? 'num' : 'warn',
        sig ? 'signal ' + s.exit.slice(1) : s.exit));
      t.appendChild(r);
    });
    main.appendChild(t);
    if (o.running.length){
      t = table(['running', 'repo', 'since']);
      o.running.forEach(function(s){
        var r = el('tr');
        r.appendChild(el('td', null, s.op));
        r.appendChild(el('td', 'num', s.repo || '—'));
        r.appendChild(el('td', 'num', s.since));
        t.appendChild(r);
      });
      main.appendChild(t);
    }
    if (o.pending.length) main.appendChild(el('p', 'hint',
      'Queued for openwiki: ' + o.pending.join(', ')));

    main.appendChild(el('h2', 'sec', 'Actions'));
    var bar = el('p');
    o.actions.forEach(function(a){
      if (!a.repo) bar.appendChild(actBtn(a.name, a.name, '', a.mut)); });
    main.appendChild(bar);
    var pre = el('pre', 'log', 'Output of an action or a log appears here.');
    pre.id = 'log'; pre.tabIndex = 0;
    pre.setAttribute('role', 'log'); pre.setAttribute('aria-label', 'Action output');
    main.appendChild(pre);

    main.appendChild(el('h2', 'sec', 'Jobs'));
    t = table(['operation', 'repo', 'last run', 'when', 'ok / ' + d.days + 'd',
               'error', '']);
    d.rows.forEach(function(r0){
      var r = el('tr');
      r.appendChild(el('td', null, r0.op));
      r.appendChild(el('td', 'num', r0.repo || '—'));
      r.appendChild(el('td', r0.last === 'succeeded' ? 'num' : 'warn', r0.last));
      r.appendChild(el('td', 'num', ago(r0.at)));
      r.appendChild(el('td', 'num', r0.n ? r0.ok + '/' + r0.n : '—'));
      r.appendChild(el('td', 'num err', r0.err));
      var c = el('td');
      if (r0.op === 'cascade' && r0.path)
        c.appendChild(actBtn('cascade', 'cascade', r0.path, true));
      r.appendChild(c);
      t.appendChild(r);
    });
    main.appendChild(t);

    main.appendChild(el('h2', 'sec', 'Not onboarded'));
    main.appendChild(el('p', 'hint', d.missing.length + ' git repos under ' +
      '~/dev have no almanac/, openwiki/ or docs/.'));
    t = el('table', 'adr');
    d.missing.forEach(function(p){
      var r = el('tr'), c = el('td');
      r.appendChild(el('td', 'num', p));
      c.appendChild(actBtn('onboard', 'onboard', p, true));
      r.appendChild(c);
      t.appendChild(r);
    });
    main.appendChild(t);

    main.appendChild(el('h2', 'sec', 'Logs'));
    bar = el('p');
    o.logs.forEach(function(l){
      var b = el('button', 'act', l.f + ' · ' + kb(l.z) + ' · ' + ago(l.m));
      b.addEventListener('click', function(){ showLog(l.f);
        pre.scrollIntoView({block: 'center'}); });
      bar.appendChild(b);
    });
    main.appendChild(bar);
  }).catch(function(){
    var e = el('div', 'empty');
    e.appendChild(el('b', null, 'The control plane did not load.'));
    e.appendChild(document.createTextNode(
      'The server did not answer /api/runs or /api/ops. Reload to retry.'));
    main.appendChild(e);
  });
  main.focus();
}

/* ---- boot ------------------------------------------------------------- */
document.getElementById('sf').addEventListener('submit', function(ev){
  ev.preventDefault();
  var v = qbox.value.trim();
  if (v.length > 1) go('#/q/' + encodeURIComponent(v));
});
document.getElementById('menu').addEventListener('click', function(){
  var o = side.classList.toggle('open');
  this.setAttribute('aria-expanded', o ? 'true' : 'false');
});
var themeBtn = document.getElementById('theme');
function paintThemeBtn(){
  var dark = effectiveTheme() === 'dark';
  themeBtn.textContent = dark ? '☀' : '☾';
  themeBtn.setAttribute('aria-label', dark ? 'Switch to light theme' : 'Switch to dark theme');
}
themeBtn.addEventListener('click', function(){
  var next = effectiveTheme() === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  try{ localStorage.setItem('theme', next); }catch(e){}
  paintThemeBtn();
});
paintThemeBtn();
window.addEventListener('hashchange', render);
document.addEventListener('keydown', function(ev){
  if (ev.key === '/' && document.activeElement !== qbox){
    ev.preventDefault(); qbox.focus(); qbox.select();
  }
  if (ev.key === 'Escape' && side.classList.contains('open')){
    side.classList.remove('open');
    var m = document.getElementById('menu');
    m.setAttribute('aria-expanded', 'false'); m.focus();
  }
});

fetch('/api/index').then(function(r){ return r.json(); }).then(function(d){
  DOCS = d.docs; WALK = d.walk_ms; GEN = d.generated;
  DOCS.forEach(function(x){ BY[x.p] = x; });
  stat.textContent = DOCS.length + ' docs · scan ' + WALK + 'ms · ' + GEN;
  var h = location.hash;
  if (h.startsWith('#/d/')) reveal(decodeURIComponent(h.slice(4)));
  drawTree();
  render();
});
"""


def selftest():
    """The renderer and the link resolver are the only non-trivial pure logic
    here. Run: python3 scripts/atlas-site.py selftest"""
    t = lambda s: md_to_html(s)[0]
    assert "<strong>plausible,\nnot established</strong>" in t(
        "is **plausible,\nnot established** -- no")     # emphasis wraps lines
    assert "<em>without</em>" in t("exits *without* the")
    assert "<em>" not in t("a * b * c")                 # spaced star not emphasis
    assert "<em>" not in t("2 * 3\n\nand 4 * 5")        # never crosses a blank line
    assert "<code>x*y</code>" in t("`x*y` stays")
    assert "&lt;script&gt;" in t("<script>alert(1)</script>")   # escape-first
    assert "<a " not in t("[x](javascript:alert(1))")   # no resolver, no anchors

    # a hard-wrapped list item is one <li>, not an <li> plus stray paragraphs
    assert t("1. **Explicit cap** -- chosen because\n   1024 was too tight\n"
             "2. the guard") == ("<ol><li><strong>Explicit cap</strong> -- "
                                 "chosen because 1024 was too tight</li>"
                                 "<li>the guard</li></ol>"), t(
        "1. a -- b\n   c\n2. d")
    assert t("- one\n- two").startswith("<ul><li>one</li>")
    # loose list: blank line between items must not restart numbering at 1
    assert t("1. one\n\n2. two") == "<ol><li>one</li><li>two</li></ol>", t(
        "1. one\n\n2. two")
    assert "<table class=md>" in t("| a | b |\n|---|---|\n| 1 | 2 |")
    assert "<th>a</th>" in t("| a | b |\n|---|---|\n| 1 | 2 |")
    assert "---" not in t("| a | b |\n|---|---|\n| 1 | 2 |")   # separator row gone

    meta, sources, body = parse_front(
        "---\ntitle: T\nsources:\n  - id: adr-9\n    type: file\n"
        "    path: docs/adr/0009-x.md\n---\n\nbody\n")
    assert meta["title"] == "T" and sources == {"adr-9": "docs/adr/0009-x.md"}, \
        (meta, sources)

    idx = {"dev/g/r/almanac/a.md": "/x", "dev/g/r/almanac/sub/b.md": "/y",
           "dev/g/r/docs/adr/0009-x.md": "/z"}
    docs = [{"p": k, "t": os.path.basename(k)[:-3]} for k in idx]
    r = Resolver(idx, docs, "dev/g/r/almanac/a.md", {"adr-9": "docs/adr/0009-x.md"})
    assert r.rel("./sub/b") == "dev/g/r/almanac/sub/b.md"       # relative, no ext
    assert r.rel("sub/b.md#frag") == "dev/g/r/almanac/sub/b.md"  # anchor stripped
    assert r.rel("https://example.com") is None                 # external stays out
    assert r.rel("javascript:alert(1)") is None
    assert r.rel("../../../../../../etc/passwd") is None         # not in manifest
    assert r.wiki("b") == "dev/g/r/almanac/sub/b.md"
    assert r.cite("adr-9") == "dev/g/r/docs/adr/0009-x.md"
    assert r.cite("nope") is None
    assert targets("see [[b]], [x](./sub/b.md), [@adr-9], [y](http://e.com)",
                   r) == {"dev/g/r/almanac/sub/b.md",
                          "dev/g/r/docs/adr/0009-x.md"}
    got = md_to_html("see [[b]] and [@adr-9] and [x](http://e.com)", r)[0]
    assert 'href="#/d/dev/g/r/almanac/sub/b.md"' in got, got
    assert 'href="#/d/dev/g/r/docs/adr/0009-x.md"' in got, got
    assert "<span class=x>x</span>" in got, got     # external -> inert text

    assert title_of({}, "# Real Title\n\nx", "index") == "Real Title"
    assert lead({}, "# H\n\nFirst real paragraph.\n") == "First real paragraph."
    with tempfile.TemporaryDirectory() as tmp:
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for rid, op, st, at in (("1", "cascade", "succeeded", now),
                                ("2", "cascade", "failed", now),
                                ("3", "cascade", "skipped", now),
                                ("4", "scan", "failed", "2020-01-01T00:00:00Z"),
                                ("5", "scan", "succeeded", now)):
            with open(os.path.join(tmp, rid + ".json"), "w") as f:
                json.dump({"operation": op, "status": st, "started_at": at,
                           "repo": "/x/r" if op == "cascade" else None}, f)
        with open(os.path.join(tmp, "6.json"), "w") as f:
            f.write("{truncated")                    # unreadable: skipped, no crash
        got = runs_summary(tmp)
        # latest scored run decides 'last'; skipped neither counts nor wins;
        # the 2020 failure is outside the window; broken-now sorts first
        assert [(r["op"], r["repo"], r["last"], r["ok"], r["n"]) for r in got] == [
            ("cascade", "r", "failed", 1, 2), ("scan", "", "succeeded", 1, 1)], got
    # the write surface: only table names and on-disk repos reach argv
    global ATLAS, LOGDIRS
    keep = ATLAS, LOGDIRS
    with tempfile.TemporaryDirectory() as tmp:
        ATLAS, LOGDIRS = "/bin/echo", (tmp, os.path.join(tmp, "actions"))
        try:
            for bad in (("rm", ""), ("status; id", ""), ("cascade", "../../etc"),
                        ("cascade", "")):
                try:
                    act(*bad)
                    raise AssertionError("accepted %r" % (bad,))
                except ValueError:
                    pass
            name = act("status")
            for _ in range(100):
                tail = log_tail(name)
                if not tail["live"]:
                    break
                time.sleep(0.02)
            assert "$ atlas status" in tail["text"] and "[exit 0]" in tail["text"], tail
            assert log_tail("../" + os.path.basename(tmp)) is None
            assert log_tail("nope.log") is None
        finally:
            ATLAS, LOGDIRS = keep
    print("atlas-site: selftest ok")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        return selftest()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    docs, _, ms = scan()
    print("atlas: %d docs, %d repos, scanned in %.0fms"
          % (len(docs), len(set(d["r"] for d in docs)), ms))
    print("atlas: http://127.0.0.1:%d  (ctrl-c to stop)" % port)
    try:
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
    except OSError as e:
        sys.exit("atlas-site: cannot bind %d: %s" % (port, e))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
