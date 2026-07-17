#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode=run

usage() {
  cat <<'EOF'
Usage: scripts/ci-macos-apple-platforms.sh [--preflight]

Run unsigned visionOS and iOS/iPadOS builds plus PMSKit unit tests in isolated
build directories. --preflight checks the host toolchain without building.

Environment:
  MACOS_CI_OUTPUT_DIR       Evidence directory (default: build/ci-macos/<run>)
  MACOS_CI_ARTIFACT_ROOT    Persistent runner evidence root (Woodpecker sets it)
  MACOS_CI_RETENTION_DAYS   Delete completed runs older than this (default: 7)
  MACOS_CI_MAX_RUNS         Keep at most this many evidence runs (default: 10)
  MACOS_CI_MIN_FREE_GB      Required free space before work (default: 100)
  MACOS_CI_MAX_LOG_MB       Maximum retained bytes per log (default: 10)
  MACOS_CI_MAX_RESULT_MB    Maximum retained bytes per xcresult (default: 250)
  MACOS_CI_KEEP_BUILD_DIRS  Keep DerivedData and SwiftPM scratch paths (true/false)
EOF
}

case "${1:-}" in
  "") ;;
  --preflight) mode=preflight ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

fail() {
  printf 'ci-macos: ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

[[ "$(uname -s)" == Darwin ]] || fail "native Apple CI requires macOS"
[[ "$(uname -m)" == arm64 ]] || fail "native Apple CI requires Apple Silicon (arm64)"

for command_name in git xcode-select xcodebuild xcrun swift df awk; do
  require_command "$command_name"
done

developer_dir="$(xcode-select -p 2>/dev/null)" || fail "no active Xcode developer directory"
[[ -d "$developer_dir" ]] || fail "active developer directory does not exist: $developer_dir"

min_free_gb="${MACOS_CI_MIN_FREE_GB:-100}"
[[ "$min_free_gb" =~ ^[0-9]+$ ]] || fail "MACOS_CI_MIN_FREE_GB must be an integer"
free_kb="$(df -Pk "$repo_root" | awk 'NR == 2 {print $4}')"
[[ "$free_kb" =~ ^[0-9]+$ ]] || fail "could not determine free disk space"
free_gb=$((free_kb / 1024 / 1024))
((free_gb >= min_free_gb)) || fail "${free_gb} GB free; ${min_free_gb} GB required"

for sdk in xrsimulator iphonesimulator; do
  xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1 || fail "required SDK is unavailable: $sdk"
done

printf 'ci-macos: host=%s arch=%s free_gb=%s\n' "$(sw_vers -productVersion)" "$(uname -m)" "$free_gb"
xcodebuild -version
printf 'ci-macos: developer_dir=%s\n' "$developer_dir"
printf 'ci-macos: xrsimulator_sdk=%s\n' "$(xcrun --sdk xrsimulator --show-sdk-version)"
printf 'ci-macos: iphonesimulator_sdk=%s\n' "$(xcrun --sdk iphonesimulator --show-sdk-version)"

if [[ "$mode" == preflight ]]; then
  printf 'ci-macos: preflight passed\n'
  exit 0
fi

run_id="${CI_PIPELINE_NUMBER:-${WOODPECKER_BUILD_NUMBER:-local}}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
artifact_root="${MACOS_CI_ARTIFACT_ROOT:-}"
if [[ -n "$artifact_root" && "$artifact_root" != /* ]]; then
  fail "MACOS_CI_ARTIFACT_ROOT must be an absolute path"
fi
output_dir="${MACOS_CI_OUTPUT_DIR:-${artifact_root:-$repo_root/build/ci-macos}/$run_id}"
derived_data="$output_dir/work/DerivedData"
swift_scratch="$output_dir/work/SwiftPM"
evidence_dir="$output_dir/evidence"
mkdir -p "$derived_data" "$swift_scratch" "$evidence_dir"

prune_artifacts() {
  local root="$1"
  local retention_days="${MACOS_CI_RETENTION_DAYS:-7}"
  local max_runs="${MACOS_CI_MAX_RUNS:-10}"
  local run_dir
  local -a run_dirs=()

  [[ "$retention_days" =~ ^[0-9]+$ ]] || fail "MACOS_CI_RETENTION_DAYS must be an integer"
  [[ "$max_runs" =~ ^[1-9][0-9]*$ ]] || fail "MACOS_CI_MAX_RUNS must be a positive integer"

  # Only direct child directories of the dedicated Labstream artifact root are
  # eligible. Never follow symlinks or clean a caller-provided parent tree.
  find -P "$root" -mindepth 1 -maxdepth 1 -type d -mtime "+$retention_days" \
    -exec rm -rf -- {} +
  while IFS= read -r run_dir; do
    run_dirs+=("$run_dir")
  done < <(
    find -P "$root" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} + \
      | sort -rn | cut -d' ' -f2-
  )
  if ((${#run_dirs[@]} > max_runs)); then
    rm -rf -- "${run_dirs[@]:max_runs}"
  fi
}

if [[ -n "$artifact_root" ]]; then
  prune_artifacts "$artifact_root"
fi

cleanup() {
  local status=$?
  local child_pids
  trap - EXIT

  # The workflow does not boot simulators. Terminate only children launched by
  # this shell, then remove the isolated build state even after failure/cancel.
  child_pids="$(jobs -pr 2>/dev/null || true)"
  if [[ -n "$child_pids" ]]; then
    # shellcheck disable=SC2086 # jobs emits a whitespace-separated PID list.
    kill $child_pids 2>/dev/null || true
  fi

  if [[ "${MACOS_CI_KEEP_BUILD_DIRS:-false}" != true ]]; then
    rm -rf "$output_dir/work"
  fi
  printf 'ci-macos: evidence=%s status=%s\n' "$evidence_dir" "$status"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

bound_log() {
  local log="$1"
  local max_log_mb="${MACOS_CI_MAX_LOG_MB:-10}"
  local max_log_bytes log_bytes
  [[ "$max_log_mb" =~ ^[0-9]+$ ]] || fail "MACOS_CI_MAX_LOG_MB must be an integer"
  max_log_bytes=$((max_log_mb * 1024 * 1024))
  log_bytes="$(wc -c <"$log" | tr -d ' ')"
  if ((log_bytes > max_log_bytes)); then
    tail -c "$max_log_bytes" "$log" >"$log.tail"
    mv "$log.tail" "$log"
    printf 'ci-macos: retained the last %s MB of %s\n' "$max_log_mb" "$(basename "$log")"
  fi
}

check_result_bundle() {
  local bundle="$1"
  local max_result_mb="${MACOS_CI_MAX_RESULT_MB:-250}"
  local bundle_kb
  [[ "$max_result_mb" =~ ^[0-9]+$ ]] || fail "MACOS_CI_MAX_RESULT_MB must be an integer"
  bundle_kb="$(du -sk "$bundle" | awk '{print $1}')"
  if ((bundle_kb > max_result_mb * 1024)); then
    rm -rf "$bundle"
    fail "result bundle exceeded ${max_result_mb} MB and was removed: $(basename "$bundle")"
  fi
}

run_logged() {
  local name="$1"
  local log status
  shift
  log="$evidence_dir/$name.log"
  printf 'ci-macos: running %s\n' "$name"
  if "$@" >"$log" 2>&1; then
    bound_log "$log"
    printf 'ci-macos: passed %s\n' "$name"
  else
    status=$?
    bound_log "$log"
    printf 'ci-macos: failed %s (last 120 log lines)\n' "$name" >&2
    tail -n 120 "$log" >&2 || true
    return "$status"
  fi
}

cd "$repo_root"
{
  printf 'commit=%s\n' "$(git rev-parse HEAD)"
  printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
  printf 'developer_dir=%s\n' "$developer_dir"
  printf 'free_gb_at_start=%s\n' "$free_gb"
  xcodebuild -showsdks
} >"$evidence_dir/toolchain.txt"

run_logged visionos-build \
  scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath "$derived_data/visionos" \
  -resultBundlePath "$evidence_dir/visionos-build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  build
check_result_bundle "$evidence_dir/visionos-build.xcresult"

# LabstreamMobile is a universal iPhone/iPad target. One simulator-SDK build
# compiles the shared iOS/iPadOS product without signing or provisioning.
run_logged ios-ipados-build \
  scripts/xcodebuild-versioned.sh \
  -project Labstream.xcodeproj \
  -scheme LabstreamMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data/ios-ipados" \
  -resultBundlePath "$evidence_dir/ios-ipados-build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  build
check_result_bundle "$evidence_dir/ios-ipados-build.xcresult"

run_logged pmskit-tests \
  swift test --package-path PMSKit --scratch-path "$swift_scratch" --no-parallel

printf 'ci-macos: all native checks passed\n'
