#!/usr/bin/env bash
# Headless live PMS SEGMENT probe (media-plane isolation, issue #25/#33). Sources creds from
# the GITIGNORED env file and runs the opt-in PMSKit segment test, which sends the EXACT failing
# wire shape (start.m3u8 + HLS segments at a deep offset, directPlay=0 directStream=1, Safari)
# through URLSession from the Mac — bypassing the simulator's AVFoundation. The >>> SEG VERDICT
# line says whether the server serves the primed deep-offset segments (→ sim artifact) or not
# (→ PMS priming bottleneck). No secrets are committed: the env file is gitignored.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token/key
# Then:
#   ./scripts/live-segment-probe.sh
# Tunables (env): PLEX_LIVE_OFFSET_SECONDS (default 3300), PLEX_LIVE_MAX_KBPS (default 3000),
#                 PLEX_LIVE_SEGMENTS (default 3).
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${PLEX_LIVE_ENV:-scripts/plex-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: $env_file not found. Copy scripts/plex-live.env.example to it and fill in creds." >&2
  exit 1
fi

# Refuse to run if the creds file is somehow tracked — it must never be committed.
if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: $env_file is TRACKED by git — it holds secrets and must be gitignored." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd PMSKit
../scripts/live-test-filter.sh '^>>> SEG|error:|Test run' swift test --filter LiveSegmentProbe
