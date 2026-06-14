#!/usr/bin/env bash
# Headless live PMS PTS-CONTINUITY probe (#33 proxy-owned playlist). Sources creds from the
# GITIGNORED env file and runs the opt-in PMSKit test, which primes two transcode sessions a fixed
# gap apart and parses the first video PTS out of each session's first real segment. The
# >>> PTS VERDICT line says whether PMS stamps ABSOLUTE PTS (segment PTS tracks the prime offset →
# a re-primed segment splices into AVKit's timeline with no reload → the proxy-owned full-timeline
# playlist is viable) or RESET PTS (each prime restarts the clock → the no-reload splice is
# impossible without a playlist reload + EXT-X-DISCONTINUITY). No secrets are committed: the env
# file is gitignored.
#
# Setup once (shared with the decision/segment probes):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token/key
# Then:
#   ./scripts/live-pts-probe.sh
# Tunables (env): PLEX_LIVE_OFFSET_SECONDS (first prime; default 3300),
#                 PLEX_LIVE_PTS_GAP_SECONDS (gap to the second prime; default 600),
#                 PLEX_LIVE_MAX_KBPS (default 3000).
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
swift test --filter LivePTSProbe 2>&1 | grep -E '^>>> PTS|error:|Test run' || true
