#!/usr/bin/env bash
# Headless live PMS SUBTITLE-BURN probe (issue #75 — representative end-to-end nuance). Sources
# creds from the GITIGNORED env file and runs the opt-in PMSKit subtitle test, which loads real
# item metadata, picks an embedded (image-based) subtitle stream, and sends subtitles=burn through
# URLSession — the exact wire shape the app's TranscodeRequest produces. The >>> SUBBURN VERDICT
# line says whether PMS actually re-encodes the video to apply the burned subtitle (→ subtitle
# would render) or silently ignores the burn (→ the "subtitles not applying" regression). No
# secrets are committed: the env file is gitignored.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token, and set
#                                                              # PLEX_LIVE_SUBTITLE_METADATA_KEY
# Then:
#   ./scripts/live-subtitle-burn-probe.sh
# Tunables (env): PLEX_LIVE_SUBTITLE_METADATA_KEY (item with an embedded subtitle track; falls back
#                 to PLEX_LIVE_METADATA_KEY), PLEX_LIVE_SUBTITLE_STREAM_ID (pin a specific stream).
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
../scripts/live-test-filter.sh '^>>> SUBBURN|error:|Test run' swift test --filter LiveSubtitleBurnProbe
