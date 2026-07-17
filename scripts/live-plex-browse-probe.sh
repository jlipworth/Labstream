#!/usr/bin/env bash
# Headless live Plex BROWSE + TV-hierarchy probe (issue #75). Sources creds from the GITIGNORED
# env file and runs the opt-in PMSKit browse test, which sends the real Plex browse requests
# (/library/sections, /library/sections/{key}/all, and the ChildrenRequest /children traversal)
# through URLSession — the exact wire shape the app produces — and asserts the PMSKit decoders
# (SectionsResponse, MetadataResponse) parse the live bodies and that the TV hierarchy
# (show -> season -> episode) ids chain coherently. No secrets are committed: the env file is
# gitignored. Tokens / scheme+host are REDACTED in all output.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token and set
#                                                              # PLEX_LIVE_SECTION_KEY + PLEX_LIVE_SHOW_METADATA_KEY
# Then:
#   ./scripts/live-plex-browse-probe.sh
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${PLEX_LIVE_ENV:-scripts/plex-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo ">>> BROWSE VERDICT: SKIP — $env_file is absent; copy scripts/plex-live.env.example and fill in the browse values."
  exit 0
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

if [[ -z "${PLEX_LIVE_SERVER:-}" || -z "${PLEX_LIVE_TOKEN:-}" ||
      -z "${PLEX_LIVE_SECTION_KEY:-}" || -z "${PLEX_LIVE_SHOW_METADATA_KEY:-}" ]]; then
  echo ">>> BROWSE VERDICT: SKIP — PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_SECTION_KEY / PLEX_LIVE_SHOW_METADATA_KEY are required."
  exit 0
fi

cd PMSKit
../scripts/live-test-filter.sh '^>>> BROWSE|error:|Test run' swift test --filter LivePlexBrowseProbe
