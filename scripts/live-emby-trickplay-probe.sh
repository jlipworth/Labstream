#!/usr/bin/env bash
# Privacy-safe, GET-only Emby ThumbnailSet / Thumbnail / index.bif probe for #238.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"
env_file="${EMBY_LIVE_ENV:-scripts/emby-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo ">>> EMBY-TRICKPLAY VERDICT: SKIP — ignored Emby live env file is absent."
  exit 0
fi
if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: Emby live env file is tracked; refusing to load secrets." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
cd PMSKit
../scripts/live-test-filter.sh '^>>> EMBY-TRICKPLAY|error:|warning: .*Live|Test run' \
  swift test --filter LiveEmbyTrickPlayProbeTests
