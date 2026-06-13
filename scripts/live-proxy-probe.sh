#!/usr/bin/env bash
# Headless live PROXY probe (media-session proxy, issue #33). Sources creds from the GITIGNORED
# env file and runs the opt-in PMSKit proxy test, which fronts the LIVE PMS server through the
# app-owned loopback origin and pulls start.m3u8 + the variant playlist + the primed deep-offset
# segment THROUGH the proxy. The >>> PROXY VERDICT line says whether the proxy is a correct
# transparent forwarder against the real server. No secrets are committed: the env file is
# gitignored.
#
# Setup once (shared with the decision/segment probes):
#   cp scripts/plex-live.env.example scripts/plex-live.env   # then fill in server/token/key
# Then:
#   ./scripts/live-proxy-probe.sh
# Tunables (env): PLEX_LIVE_OFFSET_SECONDS (default 3300), PLEX_LIVE_MAX_KBPS (default 3000).
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
swift test --filter LiveProxyProbe 2>&1 | grep -E '^>>> PROXY|error:|Test run' || true
