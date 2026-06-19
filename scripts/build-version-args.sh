#!/usr/bin/env bash
set -euo pipefail

# Prints xcodebuild arguments that stamp the app with a source-derived internal
# Build ID without rewriting project/source files on every build.
# Usage from bash:
#   mapfile -t args < <(./scripts/build-version-args.sh)
#   xcodebuild "${args[@]}" ...
# Prefer scripts/xcodebuild-versioned.sh for normal local use.

commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
commit_count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
built_at="$(date -u +%Y%m%dT%H%M%SZ)"
dirty="clean"
if ! git diff --quiet --ignore-submodules -- 2>/dev/null || \
   ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  dirty="dirty"
fi

printf 'VISIONPLAY_BUILD_SLUG=%s-%s-%s\n' "$commit_count" "$commit" "$dirty"
printf 'VISIONPLAY_BUILD_DATE_UTC=%s\n' "$built_at"
