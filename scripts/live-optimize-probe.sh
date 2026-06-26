#!/usr/bin/env bash
# Phase 0 — live Media Optimizer DISCOVERY probe (offline-download redesign). Sources creds
# from the gitignored scripts/plex-live.env and runs the opt-in PMSKit discovery test, which
# logs the server-specific optimize contract (background-processing key, target tag IDs, the
# POST grammar PMS accepts, the rendered Part, static-part Content-Length). No secrets are
# committed: the env file is gitignored; this script is not.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   # edit scripts/plex-live.env with your server / token / metadata key
# Then:
#   ./scripts/live-optimize-probe.sh
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
# Print the full body lines too (not just >>> LIVE) so the discovered JSON is visible.
../scripts/live-test-filter.sh '^>>> LIVE|^\{|error:|Test run' swift test --filter LiveOptimizeProbe
