#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rc=$?; rm -rf "$sandbox" || true; exit $rc' EXIT

repo="$sandbox/repo"
mkdir -p "$repo" "$sandbox/home/wiki/atlas" "$sandbox/bin"

cat >"$sandbox/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${GH_IS_PRIVATE:-false}"
EOF
cat >"$sandbox/bin/curl" <<'EOF'
#!/bin/bash
[[ "${PROXY_UP:-no}" == yes ]]
EOF
cat >"$sandbox/bin/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$sandbox/bin"/*

run_env() {
  env -i HOME="$sandbox/home" PATH="$sandbox/bin:/usr/bin:/bin" \
    GH_IS_PRIVATE="${GH_IS_PRIVATE:-false}" PROXY_UP="${PROXY_UP:-no}" \
    ATLAS_LITELLM_KEY=local-test-key ATLAS_MODEL_PUBLIC=pub-model ATLAS_MODEL_PRIVATE=priv-model \
    ${FALLBACK:+ATLAS_FALLBACK_URL=https://cloud.example/v1 ATLAS_FALLBACK_KEY=fake-cloud-key ATLAS_FALLBACK_MODEL=cloud-model} \
    bash -c 'source "$1/scripts/openwiki-llm-env.sh" "$2" >/dev/null; printf "%s\n%s\n%s\n" "$OPENAI_COMPATIBLE_BASE_URL" "$OPENWIKI_MODEL_ID" "$OPENAI_COMPATIBLE_API_KEY"' _ "$root" "$repo"
}

values="$(GH_IS_PRIVATE=false PROXY_UP=yes run_env)"
values="${values//$'\n'/ }"
read -r base model key <<<"$values"
[[ "$base" == http://localhost:4000/v1 ]]
[[ "$model" == pub-model ]]
[[ "$key" == local-test-key ]]

# single-threaded engine — page concurrency and retries stay pinned,
# even when ~/.openwiki/.env or the caller's env asks for more.
pinned="$(env -i HOME="$sandbox/home" PATH="$sandbox/bin:/usr/bin:/bin" \
  GH_IS_PRIVATE=true PROXY_UP=yes ATLAS_LITELLM_KEY=local-test-key \
  OPENWIKI_PAGE_CONCURRENCY=8 OPENWIKI_PROVIDER_RETRY_ATTEMPTS=5 \
  bash -c 'source "$1/scripts/openwiki-llm-env.sh" "$2" >/dev/null; printf "%s %s" "$OPENWIKI_PAGE_CONCURRENCY" "$OPENWIKI_PROVIDER_RETRY_ATTEMPTS"' _ "$root" "$repo")"
[[ "$pinned" == "1 3" ]] || { printf 'concurrency/retry pin broken: %s\n' "$pinned" >&2; exit 1; }

values="$(FALLBACK=1 GH_IS_PRIVATE=false PROXY_UP=no run_env)"
values="${values//$'\n'/ }"
read -r base model key <<<"$values"
[[ "$base" == https://cloud.example/v1 ]]
[[ "$model" == cloud-model ]]
[[ "$key" == fake-cloud-key ]]

# public, proxy down, no fallback configured: refuse
if GH_IS_PRIVATE=false PROXY_UP=no run_env >/dev/null 2>&1; then
  printf '%s\n' 'public proxy-down without fallback unexpectedly succeeded' >&2
  exit 1
fi

values="$(GH_IS_PRIVATE=true PROXY_UP=yes run_env)"
values="${values//$'\n'/ }"
read -r base model key <<<"$values"
[[ "$base" == http://localhost:4000/v1 ]]
[[ "$model" == priv-model ]]
[[ "$key" == local-test-key ]]

if FALLBACK=1 GH_IS_PRIVATE=true PROXY_UP=no run_env >/dev/null 2>&1; then
  printf '%s\n' 'private proxy-down path unexpectedly succeeded' >&2
  exit 1
fi

# Branch guard: a repo on a non-default branch must refuse
# generation unless OPENWIKI_ALLOW_BRANCH=1; a repo on the default branch
# must pass. The bare-dir sandbox above cannot trigger the guard (no origin),
# so build a real git repo.
gt="$sandbox/gt"
git -C "$sandbox" init -q -b main "$gt" 2>/dev/null || git init -q -b main "$gt"
git -C "$gt" config user.email t@t.t && git -C "$gt" config user.name t
echo x > "$gt/f" && git -C "$gt" add f && git -C "$gt" commit -qm init
git -C "$gt" remote add origin "$gt"
git -C "$gt" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$gt" switch -q -c feature

run_env_gt() {
  env -i HOME="$sandbox/home" PATH="$sandbox/bin:/usr/bin:/bin" \
    GH_IS_PRIVATE=true PROXY_UP=yes ATLAS_LITELLM_KEY=local-test-key \
    ${1:+OPENWIKI_ALLOW_BRANCH=$1} \
    bash -c 'source "$1/scripts/openwiki-llm-env.sh" "$2" >/dev/null' _ "$root" "$gt"
}
run_env_gt >/dev/null 2>&1 && gt_rc=0 || gt_rc=$?
if [[ $gt_rc != 3 ]]; then
  printf 'guard: feature-branch refusal exited %s, want 3 (cascade reads 3 as skipped)\n' "$gt_rc" >&2
  exit 1
fi
run_env_gt 1 >/dev/null 2>&1 || { printf '%s\n' 'guard: --allow-branch override failed' >&2; exit 1; }

git -C "$gt" switch -q -c main 2>/dev/null || git -C "$gt" switch -q main
run_env_gt >/dev/null 2>&1 || { printf '%s\n' 'guard: default-branch generation refused' >&2; exit 1; }

tel="$(env -i HOME="$sandbox/home" PATH="$sandbox/bin:/usr/bin:/bin" PROXY_UP=yes ATLAS_LITELLM_KEY=k \
  bash -c 'source "$1/scripts/openwiki-llm-env.sh" "$2" >/dev/null; printf "%s" "${OPENWIKI_TELEMETRY_DISABLED:-}"' _ "$root" "$repo")"
[[ "$tel" == 1 ]] || { printf '%s\n' 'openwiki telemetry not disabled' >&2; exit 1; }

printf '%s\n' 'openwiki-llm-env: routing contract passed'
