#!/usr/bin/env bash
set -euo pipefail

# Deterministic validation for issue #228's native macOS pass.
# This intentionally avoids real-auth/server/manual UI checks. It covers the checks that agents can
# run without user involvement and writes build logs under build/validation/macos-228/.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/build/validation/macos-228"
mkdir -p "$LOG_DIR"
cd "$ROOT"

log_step() { printf '\n==> %s\n' "$*"; }
run_logged() {
  local name="$1"; shift
  local log="$LOG_DIR/$name.log"
  printf 'log: %s\n' "$log"
  "$@" 2>&1 | tee "$log"
}

log_step "git diff whitespace check"
git diff --check

log_step "conflict-marker scan"
if rg -n '^(<<<<<<<|=======|>>>>>>>)' Labstream PMSKit scripts docs Config . --glob '!build/**' --glob '!*.xcuserstate'; then
  echo "conflict markers found" >&2
  exit 1
fi

log_step "macOS host build"
run_logged macos-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme LabstreamMac \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug \
    build

log_step "visionOS simulator build"
VSIM="$(scripts/worktree-sim.sh --platform visionos id)"
run_logged visionos-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme Labstream \
    -destination "platform=visionOS Simulator,id=$VSIM" \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO

log_step "iOS simulator build"
ISIM="$(scripts/worktree-sim.sh --platform iphone id)"
run_logged ios-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme LabstreamMobile \
    -destination "platform=iOS Simulator,id=$ISIM" \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO

log_step "PMSKit diagnostics/redaction tests"
run_logged pmskit-diagnostic-tests \
  swift test --package-path PMSKit --filter DiagnosticLoggingTests

log_step "summary"
printf 'Validation logs: %s\n' "$LOG_DIR"
printf 'macOS #228 deterministic validation passed. Manual real-server/UI checks remain in docs/MACOS-228-VALIDATION.md.\n'
