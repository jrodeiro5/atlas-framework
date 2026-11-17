# AGENTS.md — atlas

Machine-wide self-documenting wiki system. Every repo and config dir on the machine
documents itself well enough that an agent or human works in it cold. The human writes
zero docs; hooks and launchd loops update everything.

## Project structure

- `bin/atlas` — single entry point, a pure dispatcher over `scripts/`. New capability = new script + one `case` line.
- `scripts/` — the actual work: `repo-atlas.sh` (scanner), `atlas-cascade.sh` (post-commit chain), `atlas-check.sh` (drift gate), `atlas-site.py` (viewer).
- `test/` — bash tests against stubbed tools in a fake `$HOME`.
- `hooks/`, `launchd/` — what triggers the cascade.
- `~/wiki/atlas/` — the output bundle: OKF entity docs, searchable via `qmd`.

## Verification

```bash
test/run-tests.sh              # full suite: stubbed tools, fake HOME, no network, no LLM
test/<name>-test.sh            # single test closest to the change
atlas check                    # drift gate: wiring, staleness, qmd coverage
atlas status                   # entity doc count + repos missing a gitnexus index
prek run --all-files           # pre-commit: skill-check + gitleaks
```

- Run the full suite before committing. Tests stub every external tool — they must not touch the real `~/wiki`.
- `atlas check` exits per-repo, and a pipe swallows that exit code. Don't pipe when you need it. `${PIPESTATUS[0]}` is bash-only — in zsh it is `${pipestatus[1]}` and 1-indexed.
- Do not claim an interrupted or timed-out run passed.

## Boundaries

- `~/wiki/atlas/**` is generated. Hand-edits go below the `<!-- manual -->` marker only; everything above is overwritten on the next scan.
- Same for generated `openwiki/` pages and the `<!-- atlas:start -->` block atlas writes into each repo's `CLAUDE.md`. Fix the source, let it regenerate.
- Never write a literal key, token, or password. Export from `pass`: `export FOO=$(pass ns/foo)`.
- Bash 3.2 is `/bin/bash` on macOS. No `mapfile`; `${arr[@]}` on an empty array trips `set -u`.

## Known traps

- **openwiki is pinned to node 22** at `~/.local/bin/node` (`scripts/openwiki-pinned.sh`). Its native `better-sqlite3` build is ABI-bound to the node that installed it; don't "fix" the pin by pointing it at whatever node is on `PATH`.
- **`atlas check` truncation detection is heuristic.** An unclosed code fence is the only signal that reliably holds.
- **Non-login shells may lack the Homebrew `PATH`**, and `pass` can then spin instead of failing. Launchd jobs set `PATH` explicitly — keep it that way.
- **The cost is prefill, not generation.** Trimming prose from generated pages barely moves the bill. Cut the number of pages read, not their wording.
- **`stream: false` makes orphaned requests undetectable** — the LLM proxy cannot see the client disconnect.
