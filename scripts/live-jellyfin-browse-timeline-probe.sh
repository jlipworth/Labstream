#!/usr/bin/env bash
# Secret-gated Jellyfin browse + playback-progress proof for remediation Phases 4A and 3D.
# The optional timeline offset writes a resume point on a TEST ACCOUNT and restores it.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${JELLYFIN_LIVE_ENV:-scripts/jellyfin-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo ">>> JELLYFIN VERDICT: SKIP — $env_file is absent; copy scripts/jellyfin-live.env.example and fill in the required values."
  exit 0
fi
if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: $env_file is TRACKED by git — it holds secrets and must stay ignored." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

if [[ -z "${JELLYFIN_SERVER_URL:-}" || -z "${JELLYFIN_ACCESS_TOKEN:-}" ||
      -z "${JELLYFIN_USER_ID:-}" || -z "${JELLYFIN_LIVE_ITEM_ID:-}" ]]; then
  echo ">>> JELLYFIN VERDICT: SKIP — JELLYFIN_SERVER_URL / JELLYFIN_ACCESS_TOKEN / JELLYFIN_USER_ID / JELLYFIN_LIVE_ITEM_ID are required."
  exit 0
fi

cd PMSKit
../scripts/live-test-filter.sh '^>>> JELLYFIN|error:|warning: .*Live|Test run' \
  swift test --filter LiveJellyfinBrowseTimelineProbe
