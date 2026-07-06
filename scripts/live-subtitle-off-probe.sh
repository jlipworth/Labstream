#!/usr/bin/env bash
# Headless live PMS SUBTITLE-OFF probe. Answers "why do subtitles show while the picker says
# Off": dumps the probed item's part-level subtitle selection (account-sticky, shared across
# Plex clients) and the legible renditions of the app's real `subtitles=auto` HLS master, on
# both the copy and capped lanes. With PLEX_LIVE_SUBTITLE_OFF_MUTATE=1 it additionally proves
# causation by deselecting the part subtitle, re-probing, and RESTORING the original selection.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env    # fill in server/token
# Then:
#   PLEX_LIVE_SUBTITLE_OFF_QUERY="<title>" ./scripts/live-subtitle-off-probe.sh
# Tunables (env): PLEX_LIVE_SUBTITLE_OFF_QUERY (required — search title; for a show the most
#                 recently viewed episode is probed), PLEX_LIVE_SUBTITLE_OFF_KBPS (capped-lane
#                 bitrate, default 3000), PLEX_LIVE_SUBTITLE_OFF_MUTATE=1 (deselect/restore leg).
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

if [[ -z "${PLEX_LIVE_SUBTITLE_OFF_QUERY:-}" ]]; then
  echo "ERROR: set PLEX_LIVE_SUBTITLE_OFF_QUERY=\"<title>\" (kept out of the repo — it's a media title)." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd PMSKit
../scripts/live-test-filter.sh '^>>> SUBOFF|error:|Test run' swift test --filter LiveSubtitleOffProbe
