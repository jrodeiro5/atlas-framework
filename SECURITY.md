# Security

## Reporting

Report vulnerabilities privately through GitHub:
**Security → Report a vulnerability** on this repository. Please don't open a
public issue for them.

## What atlas sends off the machine

- **GitHub API** (`gh`): repo visibility and recent Actions runs, with your own `gh` login.
- **LLM proxy** (`ATLAS_LLM_URL`, default `localhost:4000`): repository source and
  docs, sent by OpenWiki for narrative generation. Where the proxy forwards them is
  your proxy's configuration.
- **Cloud fallback** (`ATLAS_FALLBACK_*`): only for **public** repos, only when the
  proxy is down, and only if you set all three variables. Private and
  unknown-visibility repos never use it; with the proxy down they are refused.

Nothing else: apart from those `gh` calls, the scans, the run ledger, `atlas check`
and the test suite make no network calls.

## Secrets

atlas reads keys from the environment (export them from `pass` or a similar
store) and never writes them to disk. The pre-commit gate runs gitleaks. For
repos with a public remote, the cascade never auto-commits generated output.
