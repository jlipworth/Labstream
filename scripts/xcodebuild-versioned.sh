#!/usr/bin/env bash
set -euo pipefail

# Wrapper for local/agent builds that stamps a source-derived internal Build ID
# into the generated Info.plist without mutating source/project files.
# Pass normal xcodebuild arguments after this script.

commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
commit_count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
built_at="$(date -u +%Y%m%dT%H%M%SZ)"
dirty="clean"
# Treat tracked edits/staged edits and relevant untracked sources/assets as dirty.
# File-system-synchronized Xcode groups mean a new Swift/resource file can affect
# the app build before it is tracked, so build IDs must not stamp that state as clean.
if ! git diff --quiet --ignore-submodules -- 2>/dev/null || \
   ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null || \
   [ -n "$(git ls-files --others --exclude-standard -- Labstream PMSKit 2>/dev/null | grep -E '\.(swift|metal|json|plist|strings|storyboard|xib|entitlements|xcconfig|png|jpe?g|heic|svg|pdf|mp4|mov|m4v|mp3|wav|srt|vtt|ttf|otf)$|Assets\.xcassets/' | head -1)" ]; then
  dirty="dirty"
fi

slug="${commit_count}-${commit}-${dirty}"
echo "xcodebuild-versioned: LABSTREAM_BUILD_SLUG=${slug} LABSTREAM_BUILD_DATE_UTC=${built_at}" >&2
exec xcodebuild "LABSTREAM_BUILD_SLUG=${slug}" "LABSTREAM_BUILD_DATE_UTC=${built_at}" "$@"
