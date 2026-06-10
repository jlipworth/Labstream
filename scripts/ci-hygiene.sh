#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { printf 'ERROR: not inside a git repository\n' >&2; exit 1; }
cd "$repo_root"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "required file is missing: $path"
}

tracked_file() {
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

require_file README.md
require_file docs/DEVELOPMENT.md
require_file Signing.xcconfig

printf '== git whitespace check ==\n'
has_unstaged_changes=false
has_staged_changes=false

if ! git diff --quiet; then
  has_unstaged_changes=true
fi

if ! git diff --cached --quiet; then
  has_staged_changes=true
fi

if [[ "$has_unstaged_changes" == true || "$has_staged_changes" == true ]]; then
  if [[ "$has_unstaged_changes" == true ]]; then
    printf 'Working tree has unstaged changes; checking whitespace in unstaged diff.\n'
    git diff --check
  fi

  if [[ "$has_staged_changes" == true ]]; then
    printf 'Index has staged changes; checking whitespace in staged diff.\n'
    git diff --cached --check
  fi
elif git rev-parse --verify HEAD^ >/dev/null 2>&1; then
  printf 'No local staged or unstaged changes; checking whitespace in HEAD against parent.\n'
  git diff --check HEAD^ HEAD
else
  printf 'No parent commit available; checking default git diff whitespace.\n'
  git diff --check
fi


# The shared signing template is intentionally committed. Local overrides and
# credential/profile material must never be tracked.
if tracked_file Signing.local.xcconfig; then
  fail "Signing.local.xcconfig must not be tracked"
fi

while IFS= read -r -d '' path; do
  case "$path" in
    Signing.xcconfig)
      ;;
    *.local.xcconfig|Signing.*.xcconfig|*.mobileprovision|*.p12|*.cer)
      fail "tracked signing credential/profile artifact: $path"
      ;;
  esac
done < <(git ls-files -z)

stale_paths=()
while IFS= read -r -d '' path; do
  case "$path" in
    # Historical/planning docs may intentionally reference the old bundle ID.
    docs/superpowers/*)
      ;;
    *)
      stale_paths+=("$path")
      ;;
  esac
done < <(git ls-files -z)

old_bundle_id="$(printf '%s%s' 'com.personal.' 'PlexAVPApp')"
if ((${#stale_paths[@]} > 0)) && git grep -n -I -F -- "$old_bundle_id" -- "${stale_paths[@]}"; then
  fail "stale bundle identifier $old_bundle_id found"
fi

scan_paths=()
while IFS= read -r -d '' path; do
  case "$path" in
    # Intentional guardrail/historical mentions are allowed in these files.
    .gitignore|scripts/ci-hygiene.sh|docs/superpowers/*)
      ;;
    *)
      scan_paths+=("$path")
      ;;
  esac
done < <(git ls-files -z)

for forbidden in \
  "X-Plex-Token:" \
  "PLEX_TOKEN=" \
  "plex.example.internal" \
  "192.0.2.10"
do
  if ((${#scan_paths[@]} > 0)) && git grep -n -I -F -- "$forbidden" -- "${scan_paths[@]}"; then
    fail "forbidden Plex token/server string found: $forbidden"
  fi
done

echo "ci-hygiene: ok"
