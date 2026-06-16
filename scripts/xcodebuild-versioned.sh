#!/usr/bin/env bash
set -euo pipefail

# Wrapper for local/agent builds that stamps a source-derived internal Build ID
# into the generated Info.plist without mutating source/project files.
# Pass normal xcodebuild arguments after this script.

commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
commit_count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
built_at="$(date -u +%Y%m%dT%H%M%SZ)"
dirty="clean"
if ! git diff --quiet --ignore-submodules -- 2>/dev/null || \
   ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  dirty="dirty"
fi

slug="${commit_count}-${commit}-${dirty}"
echo "xcodebuild-versioned: VISIONPLEX_BUILD_SLUG=${slug} VISIONPLEX_BUILD_DATE_UTC=${built_at}" >&2
exec xcodebuild "VISIONPLEX_BUILD_SLUG=${slug}" "VISIONPLEX_BUILD_DATE_UTC=${built_at}" "$@"
