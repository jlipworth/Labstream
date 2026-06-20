#!/usr/bin/env bash
# Headless live Emby wire-shape probe (Emby backend lane). Sources creds from a GITIGNORED
# env file and runs the opt-in PMSKit integration test, which sends the real Emby request
# builders through URLSession.shared — the exact wire shape the app's Emby client produces —
# and confirms the PMSKit Emby decoders parse the live bodies. No secrets are committed: the
# env file is gitignored, this script is not. Tokens / api_key are REDACTED in all output.
#
# Setup once:
#   # edit scripts/emby-live.env with your server / token / user id / item id
# Then:
#   ./scripts/live-emby-probe.sh
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${EMBY_LIVE_ENV:-scripts/emby-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: $env_file not found. Fill it in with your Emby server / token / user id / item id." >&2
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
# --filter matches the test type; grep keeps output focused on the >>> LIVE dump lines.
swift test --filter LiveEmbyProbe 2>&1 | grep -E '^>>> LIVE|error:|warning: .*Live|Test run' || true
