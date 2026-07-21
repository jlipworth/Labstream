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

check_pbxproj_churn() {
  local label="$1"
  shift
  local diff_output
  diff_output=$(git diff --unified=0 "$@" -- Labstream.xcodeproj/project.pbxproj)
  [[ -n "$diff_output" ]] || return 0

  # New Swift/resources under the synchronized Labstream root are discovered by
  # Xcode without PBXFileReference/PBXBuildFile churn. Keep allowing project
  # build-setting/version edits, but stop accidental file-reference/build-phase
  # noise before it reaches CI or review.
  #
  # SDK framework linkage cannot be inferred from a synchronized group, so allow the
  # specific frameworks the project intentionally links (AVKit for the tvOS target) the
  # same way PMSKit's local-package link is allowed. Keep this an explicit list — a
  # blanket *.framework exemption would let unrelated framework churn through the guard.
  local pbx_churn
  pbx_churn=$(printf '%s\n' "$diff_output" \
    | grep -E '^[+-].*(isa = PBX(BuildFile|FileReference)|/\* (Begin|End) PBX(BuildFile|FileReference) section \*/|/\* .* in (Sources|Resources) \*/)' \
    | grep -Ev 'Labstream(Mobile|TV)?\.app|Labstream(Mac|TV)?(UI)?Tests\.xctest|PMSKit in Frameworks|AVKit\.framework in Frameworks|AVKit\.framework \*/ = \{isa = PBXFileReference' || true)
  if [[ -n "$pbx_churn" ]]; then
    printf '%s\n' "$pbx_churn" >&2
    fail "unexpected project.pbxproj file-reference/build-file churn in $label; synchronized groups should pick up new Swift/resource files without pbxproj edits"
  fi
}

printf '== Xcode project churn guard ==\n'
if [[ "$has_unstaged_changes" == true ]]; then
  check_pbxproj_churn "unstaged diff"
fi
if [[ "$has_staged_changes" == true ]]; then
  check_pbxproj_churn "staged diff" --cached
elif [[ "$has_unstaged_changes" != true ]] && git rev-parse --verify HEAD^ >/dev/null 2>&1; then
  check_pbxproj_churn "HEAD against parent" HEAD^ HEAD
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
    # Historical docs may intentionally reference the old bundle ID.
    docs/archive/*)
      ;;
    *)
      stale_paths+=("$path")
      ;;
  esac
done < <(git ls-files -z)

old_bundle_id="$(printf '%s%s' 'com.personal.' 'Labstream')"
if ((${#stale_paths[@]} > 0)) && git grep -n -I -F -- "$old_bundle_id" -- "${stale_paths[@]}"; then
  fail "stale bundle identifier $old_bundle_id found"
fi

scan_paths=()
while IFS= read -r -d '' path; do
  case "$path" in
    # Intentional guardrail/historical mentions are allowed in these files.
    .gitignore|scripts/ci-hygiene.sh|docs/archive/*)
      ;;
    *)
      scan_paths+=("$path")
      ;;
  esac
done < <(git ls-files -z)

# Generic token markers — these are patterns, not secrets.
forbidden_strings=(
  "X-Plex-Token:"
  "PLEX_TOKEN="
)

# Extra forbidden strings (the actual sensitive values) are NEVER hardcoded
# here. They are injected at runtime from sources that are not tracked by git:
#
#   1. scripts/ci-hygiene.local — an untracked, gitignored local file.
#      One string per line; blank lines and lines starting with '#' are ignored.
#   2. CI_EXTRA_FORBIDDEN_FILE — env var holding a path to a file with the same
#      format as (1). Intended for a future CI system to materialize from a
#      secret store (CI is not set up yet; this is just the hook).
#   3. CI_EXTRA_FORBIDDEN — env var holding newline-separated strings directly
#      (same comment/blank-line rules), for CI secrets injected as variables.
#
# All extras join the same scan loop as the built-in markers above.
local_forbidden_file="scripts/ci-hygiene.local"

# Defense in depth: the local extras file must never be committable silently.
if tracked_file "$local_forbidden_file"; then
  fail "$local_forbidden_file is tracked by git — it must stay untracked (it may contain sensitive strings)"
fi

append_forbidden_lines() {
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    forbidden_strings+=("$line")
  done
}

if [[ -f "$local_forbidden_file" ]]; then
  append_forbidden_lines < "$local_forbidden_file"
fi

if [[ -n "${CI_EXTRA_FORBIDDEN_FILE:-}" ]]; then
  [[ -f "$CI_EXTRA_FORBIDDEN_FILE" ]] || fail "CI_EXTRA_FORBIDDEN_FILE points to a missing file: $CI_EXTRA_FORBIDDEN_FILE"
  append_forbidden_lines < "$CI_EXTRA_FORBIDDEN_FILE"
fi

if [[ -n "${CI_EXTRA_FORBIDDEN:-}" ]]; then
  append_forbidden_lines <<< "$CI_EXTRA_FORBIDDEN"
fi

# Extras may be sensitive — report matches by file path only, never echo the
# matched string or line content for them.
builtin_forbidden_count=2
idx=0
for forbidden in "${forbidden_strings[@]}"; do
  if ((idx < builtin_forbidden_count)); then
    if ((${#scan_paths[@]} > 0)) && git grep -n -I -F -- "$forbidden" -- "${scan_paths[@]}"; then
      fail "forbidden string found: $forbidden"
    fi
  else
    if ((${#scan_paths[@]} > 0)) && git grep -l -I -F -- "$forbidden" -- "${scan_paths[@]}"; then
      fail "extra forbidden string #$((idx - builtin_forbidden_count + 1)) found (value redacted; offending files listed above)"
    fi
  fi
  idx=$((idx + 1))
done

# Scrubbed server identity — fingerprint guard.
# The owner's real PMS hostname and LAN IP were purged from the working tree AND
# from git history. They survive here ONLY as one-way SHA-256 fingerprints: the
# plaintext exists nowhere in this repo, yet any tracked file that reintroduces
# the exact hostname or IP will hash to a listed digest and fail the build.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

forbidden_digests='
ab73d7c622719b37d8ea581bff9feccc782de51f8dcc39552d61de82a55e026d
0ce6409dfa31d2f8f686f103b17c0174774da6d763e7f83dc26462fd1b6f2574
'

host_ip_re='([a-z0-9-]+\.)+[a-z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3}'
if ((${#scan_paths[@]} > 0)); then
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    digest="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sha256_hex)"
    if printf '%s\n' "$forbidden_digests" | grep -qxF "$digest"; then
      fail "reintroduced a scrubbed server hostname/IP (matched a forbidden fingerprint)"
    fi
  done < <(
    git grep -I -hE -- "$host_ip_re" -- "${scan_paths[@]}" 2>/dev/null \
      | grep -oiE "$host_ip_re" | sort -u
  )
fi

# Scrubbed signing identity — fingerprint guard (Apple Team ID OU + cert id).
# Same one-way model as the host/IP guard above: the plaintext 10-char ids exist
# nowhere in this repo, but any tracked file that reintroduces one hashes to a
# listed digest and fails the build. The host/IP regex never matches a bare id,
# so these need their own extraction pass.
forbidden_id_digests='
e8ca5e1278c94c76b351af689f194cd28094ecd15bbb8ea4d055a4579bfa2dfe
047834168b9826ba6e2c297e12de4082820a8126ca50e15bb29f1c1e3543bc86
'
signing_id_re='[A-Za-z0-9]{10}'
if ((${#scan_paths[@]} > 0)); then
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    digest="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sha256_hex)"
    if printf '%s\n' "$forbidden_id_digests" | grep -qxF "$digest"; then
      fail "reintroduced a scrubbed Apple Team ID / signing cert id (matched a forbidden fingerprint)"
    fi
  done < <(
    git grep -I -hE -- "$signing_id_re" -- "${scan_paths[@]}" 2>/dev/null \
      | grep -oE "$signing_id_re" | sort -u
  )
fi

# Archive docs are historical, so they are allowed to mention retired decisions and
# synthetic examples, but they are still part of the public repo. Keep obviously
# machine-local paths and private-LAN examples out of committed archives.
archive_paths=()
while IFS= read -r -d '' path; do
  case "$path" in
    docs/archive/*)
      archive_paths+=("$path")
      ;;
  esac
done < <(git ls-files -z)

if ((${#archive_paths[@]} > 0)); then
  if git grep -n -I -E -- '/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|/path/to/temp|\\b10\.([0-9]{1,3}\.){2}[0-9]{1,3}\b|\\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b|\\b172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}\b' -- "${archive_paths[@]}" | grep -v '/Users/AuthenticateByName'; then
    fail "public archive docs contain machine-local paths or private-LAN IP examples; scrub to placeholders such as /path/to/labstream or 192.0.2.10"
  fi
fi


if [[ -f pyproject.toml ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    fail "uv is required for repo Python tooling; install uv or run outside this hygiene gate"
  fi
  printf '== Python tooling tests ==\n'
  uv run python -m unittest discover -s scripts/tests -v
fi

# Gated on mkdocs.yml so the tooling tests' minimal sandbox repos (which exercise the
# earlier guards' success paths) don't fail here; the real repo always has it.
if [[ -f mkdocs.yml ]]; then
  printf '== Published documentation ==\n'
  [[ -f requirements.txt ]] || fail "mkdocs.yml present but requirements.txt missing; docs build cannot run"
  uv run --with-requirements requirements.txt mkdocs build --strict
  uv run python scripts/check-docs-mermaid.py
fi

echo "ci-hygiene: ok"
