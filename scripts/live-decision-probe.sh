#!/usr/bin/env bash
# Headless live PMS decision probe (issue #7). Sources creds from a GITIGNORED env file
# and runs the opt-in PMSKit integration test, which sends the real TranscodeRequest through
# URLSession.shared — the exact wire shape the app's PlexClient.send produces — and dumps the
# raw decision JSON. No secrets are committed: the env file is gitignored, this script is not.
#
# Setup once:
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   # edit scripts/plex-live.env with your server / token / metadata key
# Then:
#   ./scripts/live-decision-probe.sh
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
# --filter matches the test type; -q keeps output focused on the >>> LIVE dump lines.
swift test --filter LiveDecisionProbe 2>&1 | grep -E '^>>> LIVE|error:|warning: .*Live|Test run' || true
