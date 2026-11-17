#!/bin/bash
# retrofit-openwikiignore.sh — backfill. atlas-onboard.sh's seed-once
# policy means the ~2026-08-22 sensitive-pattern additions only land on newly
# onboarded repos. This adds the missing patterns to existing .openwikiignore
# files, never touching lines already there (a repo may have deliberately
# removed a seed pattern). Dry-run by default; --apply writes.
set -euo pipefail

NEW_PATTERNS=(
  "secrets/"
  "credentials/"
  "private/"
  "*.pem"
  "*.key"
  ".ssh/"
  "id_rsa"
  "id_ed25519"
)

apply=false
[[ "${1:-}" == "--apply" ]] && apply=true

find "$HOME/dev" -name .openwikiignore -not -path '*/node_modules/*' 2>/dev/null | while read -r f; do
  missing=()
  for p in "${NEW_PATTERNS[@]}"; do
    grep -qxF "$p" "$f" || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && continue

  repo="$(dirname "$f")"
  echo "$repo: missing ${missing[*]}"
  if $apply; then
    printf '%s\n' "${missing[@]}" >> "$f"
  fi
done

$apply || echo "(dry-run — rerun with --apply to write)"
