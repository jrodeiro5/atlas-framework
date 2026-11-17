# Third-party software

atlas **vendors no third-party code**. It calls the tools below as separate
programs you install yourself; each keeps its own license, and nothing here
relicenses them.

| Tool | License | Used for | Required |
|---|---|---|---|
| [GitNexus](https://github.com/abhigyanpatwari/GitNexus) | **PolyForm Noncommercial 1.0.0** | code graph (`gitnexus analyze`) | for the cascade |
| [OpenWiki](https://github.com/langchain-ai/openwiki) | MIT | narrative wiki per repo | for the cascade |
| [CodeAlmanac](https://github.com/AlmanacCode/codealmanac) | Apache-2.0 | transcript mining into `almanac/` | optional |
| [qmd](https://github.com/tobi/qmd) | MIT | search index | yes |
| [GitHub CLI](https://github.com/cli/cli) | MIT | repo visibility | yes |
| [jq](https://github.com/jqlang/jq) | MIT (docs CC-BY-3.0) | JSON in scans | yes |
| [LiteLLM](https://github.com/BerriAI/litellm) | MIT (enterprise dir under a separate license) | LLM proxy | for OpenWiki |
| [pass](https://www.passwordstore.org) | GPL-2.0-or-later | secrets lookup | recommended |
| [gitleaks](https://github.com/gitleaks/gitleaks) | MIT | pre-commit secret scan | recommended |
| [prek](https://github.com/j178/prek) | MIT | pre-commit runner | recommended |
| [skill-check](https://github.com/thedaviddias/skill-check) | MIT | pre-commit, agent skill validation | recommended |
| [Entire](https://github.com/entireio/cli) | MIT | session checkpoints (opt-in per repo) | optional |
| [deja](https://github.com/Giammarco-Ferranti/deja) | MIT | `atlas friction` | optional |
| [uv](https://github.com/astral-sh/uv) | Apache-2.0 / MIT | Python tooling | optional |
| [Node.js](https://github.com/nodejs/node) | MIT | runs OpenWiki | for OpenWiki |

## GitNexus is noncommercial

GitNexus's PolyForm Noncommercial license forbids commercial use. atlas's own
MIT license does not change that. If you use atlas commercially, either get a
commercial GitNexus license or drop the `gitnexus analyze` step (the cascade
skips it when `gitnexus` is not on `PATH`).

## Ideas, not code

The design borrows from Karpathy's
[LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f),
Backstage's entity model, and Google Goods ("crawl, don't register"). No code
is copied from them.
