#!/usr/bin/env bash
# Headless live PMS play-queue mutation probe (#121). Sources creds from the GITIGNORED env file
# and runs the opt-in PMSKit test that creates an ephemeral queue, adds a play-next item, and
# creates a shuffled queue. No playback/transcode is started.
#
# Setup once:
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   $EDITOR scripts/plex-live.env   # set PLEX_LIVE_PLAYQUEUE_METADATA_KEY + PLEX_LIVE_PLAYQUEUE_NEXT_METADATA_KEY
# Then:
#   ./scripts/live-playqueue-mutation-probe.sh
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
../scripts/live-test-filter.sh '^>>> PLAYQUEUE|error:|Test run' swift test --filter LivePlayQueueMutationProbe
