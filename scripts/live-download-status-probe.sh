#!/usr/bin/env bash
# Read-only live PMS download/optimizer status probe. Sources creds from gitignored
# scripts/plex-live.env and prints server-side queue/progress state for PLEX_LIVE_METADATA_KEY.
# Does not create, reorder, delete, or download jobs.
#
# Optional:
#   PLEX_LIVE_POLLS=12 PLEX_LIVE_POLL_INTERVAL_SECONDS=5 ./scripts/live-download-status-probe.sh
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${PLEX_LIVE_ENV:-scripts/plex-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: $env_file not found. Copy scripts/plex-live.env.example to it and fill in creds." >&2
  exit 1
fi

if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: $env_file is TRACKED by git — it holds secrets and must be gitignored." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd PMSKit
swift test --filter LiveDownloadStatusProbe 2>&1 | grep -E '^>>> DLSTAT|error:|warning: .*Live|Test run'
