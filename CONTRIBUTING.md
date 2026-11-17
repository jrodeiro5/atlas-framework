# Contributing

1. Open an issue first for anything bigger than a bug fix.
2. Keep changes small: one new capability is one script in `scripts/` plus one
   `case` line in `bin/atlas`.
3. Add or update the test closest to the change in `test/`, and run the suite:

   ```bash
   test/run-tests.sh
   ```

   Tests stub every external tool and use a fake `$HOME`; they must never touch
   your real `~/wiki`.
4. Scripts with `#!/bin/bash` must run on macOS bash 3.2: no `mapfile`, no
   associative arrays, and watch `${arr[@]}` under `set -u`. Only `repo-atlas.sh`
   (`#!/usr/bin/env bash`) may use bash 4+.
5. Never commit a literal key, token or password.

See [CLAUDE.md](CLAUDE.md) for the project rules agents follow; they apply to humans too.
