#!/usr/bin/env bash
# Headless live PMS download-route probe. Sources creds from a GITIGNORED env file and
# runs the opt-in PMSKit integration test that decides whether the item should use true
# source-file "Original" download or the server optimizer.
#
# Setup once:
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   $EDITOR scripts/plex-live.env
# Then:
#   ./scripts/live-download-probe.sh
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
swift test --filter LiveDownloadProbe 2>&1 | grep -E '^>>> DL|error:|warning: .*Live|Test run'
