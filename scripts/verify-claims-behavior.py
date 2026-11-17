#!/usr/bin/env python3
"""verify-claims-behavior.py <repo> [N] — type 2 (behavior claims).

verify-claims.sh covers type 1 (paths, exact, no LLM). This covers sentences in
openwiki/ and almanac/ that name a backticked non-path token: code finds the
claim and its evidence, the local judge (Strands, via the classifier-judge
skill's judge.py) only answers "do these lines establish this claim".

claims() and evidence() are copied verbatim from the extractor the judge's
0.64 cut was calibrated on (an external calibration run,
2026-09-21). Changing either invalidates that cut — recalibrate first.

A flag means "this evidence does not establish the claim", not "the claim is
false": on the 200-claim holdout 155 were unsupported. Read it as a worklist.

Reports, never blocks: exit 0 even with flags.
"""
import json, re, subprocess, sys, tempfile
from pathlib import Path

JUDGE = Path.home() / ".claude/skills/classifier-judge/judge.py"
TOK = re.compile(r"`([^`]+)`")


def is_path(t):  # mirrors verify-claims.sh is_path_claim (type 1 is already covered)
    return "/" in t and re.search(r"\.(sh|py|ts|js|cjs|mjs|json|yaml|yml|toml|md|plist|sql)$", t)


def evidence(repo, claim, toks):
    """The file a claim names, or the definition site of a symbol — not lines
    that merely mention the name. Lines near the claim's words, capped."""
    words = {w.lower() for w in re.findall(r"[A-Za-z_][\w.-]{3,}", claim)} | {t.lower() for t in toks}
    files = subprocess.run(["git", "ls-files"], cwd=repo, capture_output=True, text=True).stdout.splitlines()
    files = [f for f in files if not f.startswith(("openwiki/", "almanac/", ".almanac/"))]
    ev = []
    for tok in toks:
        hit = next((f for f in files if f == tok.lstrip("./") or f.rsplit("/", 1)[-1] == tok), None)
        if hit:
            lines = (repo / hit).read_text(errors="ignore").splitlines()
            keep = sorted({j for i, l in enumerate(lines) if any(w in l.lower() for w in words - {tok.lower()})
                           for j in range(max(0, i - 2), min(len(lines), i + 3))})[:30] or range(min(30, len(lines)))
            ev += [f"{hit}:{j+1}: {lines[j][:200]}" for j in keep]
        else:
            r = subprocess.run(["git", "grep", "-n", "-F", "-C2", "-e", tok, "--", ".", ":!openwiki", ":!almanac", ":!.almanac"],
                               cwd=repo, capture_output=True, text=True)
            ev += [l[:200] for l in r.stdout.splitlines()[:20]]
    return ev[:60]


def claims(repo):
    out = []
    for f in sorted([*repo.glob("openwiki/**/*.md"), *repo.glob("almanac/**/*.md"), *repo.glob(".almanac/**/*.md")]):
        for s in re.split(r"(?<=[.!?])\s+|\n\s*\n", f.read_text(errors="ignore")):
            s = " ".join(s.split())
            toks = [t for t in TOK.findall(s) if " " not in t and len(t) > 2 and not is_path(t)]
            if toks and 40 < len(s) < 600 and not s.startswith(("|", "#", "-", "```")):
                out.append((str(f.relative_to(repo)), s, toks))
    return out


def selftest():
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / "openwiki").mkdir()
        (repo / "openwiki/a.md").write_text(
            "The cascade calls `run_stage` once per repo before it writes the entity doc.\n\n"
            "Configuration for the scanner lives in `scripts/foo.sh` and nowhere else at all.\n\n"
            "- A list item naming `run_stage` is skipped because it is not prose at all.\n")
        got = claims(repo)
        assert [(doc, toks) for doc, _, toks in got] == [("openwiki/a.md", ["run_stage"])], got
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest(); sys.exit()
    if not sys.argv[1:]:
        sys.exit("usage: verify-claims-behavior.py <repo> [N]")
    repo = Path(sys.argv[1]).resolve()
    # ponytail: first N claims in file order (as calibrated), not a census —
    # ~0.5 s per claim on Strands. Pass a bigger N, or sample, for full coverage.
    todo = claims(repo)[:int(sys.argv[2]) if len(sys.argv) > 2 else 30]
    stdin = "".join(json.dumps({"doc": doc, "claim": s, "evidence": evidence(repo, s, toks)}) + "\n"
                    for doc, s, toks in todo)
    # --judge strands: the only judge with a measured cut for this extractor, and
    # generated prose about a repo stays on the Mac whether or not it is public.
    r = subprocess.run([sys.executable, str(JUDGE), "--repo", str(repo), "--judge", "strands"],
                       input=stdin, capture_output=True, text=True)
    if r.returncode:
        print(f"judge failed: {r.stderr.strip()[-300:]}", file=sys.stderr)
    rows = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
    flags = sorted((x for x in rows if x["verdict"] == "flag"), key=lambda x: x["p"])
    for x in flags:
        print(f'{x["p"]:.2f}  {x["doc"]}: {x["claim"][:160]}')
    print(f"unsupported behavior claims: {len(flags)} of {len(rows)} judged")
