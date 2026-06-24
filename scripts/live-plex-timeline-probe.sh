#!/usr/bin/env bash
# Headless live Plex TIMELINE/progress + session-stop probe (issue #75). Sources creds from the
# GITIGNORED env file and runs the opt-in PMSKit timeline test, which (a) POSTs a /:/timeline
# progress update via the real TimelineRequest builder and reads the resume point back, and
# (b) starts a transcode session and stops it via the real TranscodeRequest.stop builder — the
# exact wire shapes the app produces — asserting progress round-trips and the session ends cleanly
# with no orphaned transcode. No secrets are committed: the env file is gitignored.
#
# ⚠️  This probe WRITES a resume point — run it ONLY against a DEDICATED TEST ACCOUNT, never a real
#     user's. See the "Cleanup / reset" section of docs/TESTING-LIVE-REQUIREMENTS.md.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token/metadata key
# Then:
#   ./scripts/live-plex-timeline-probe.sh
# Tunables (env): PLEX_LIVE_TIMELINE_OFFSET_SECONDS (offset to report; default 120).
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
swift test --filter LivePlexTimelineProbe 2>&1 | grep -E '^>>> TIMELINE|error:|Test run' || true
