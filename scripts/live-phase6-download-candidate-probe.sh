#!/usr/bin/env bash
# Find a large original/static Plex item suitable for the Phase-6 range fault harness.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${PLEX_LIVE_ENV:-scripts/plex-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: $env_file not found. Copy scripts/plex-live.env.example and fill in credentials." >&2
  exit 1
fi
if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: $env_file is tracked; the live credential file must remain gitignored." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd PMSKit
swift test --filter LivePhase6DownloadCandidateProbe 2>&1 \
  | grep -E '^>>> PHASE6|error:|warning: .*Live|Test run'
