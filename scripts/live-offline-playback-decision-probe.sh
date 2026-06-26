#!/usr/bin/env bash
# Headless live fixture probe for offline playback routing (#120). Sources creds from the
# GITIGNORED env file, verifies a real PMS item fixture, then asserts a completed local-file row
# routes to offline playback instead of the remote/server stream branch.
#
# Setup once:
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   $EDITOR scripts/plex-live.env   # set PLEX_LIVE_OFFLINE_METADATA_KEY + PLEX_LIVE_OFFLINE_FILE
# Then:
#   ./scripts/live-offline-playback-decision-probe.sh
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
swift test --filter LiveOfflinePlaybackDecisionProbe 2>&1 | grep -E '^>>> OFFLINEPLAY|error:|Test run' || true
