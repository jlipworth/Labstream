#!/usr/bin/env bash
# Simulator-only Emby download probe.
#
# Launches the DEBUG app in this worktree's simulator and uses the simulator's signed-in app state.
# It does not read or print Emby tokens. The app-side probe exercises DownloadManager's real Emby
# route negotiation / convert reuse / download lifecycle and deletes the row after observation unless
# --keep-record is passed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/probe-emby-download.sh --query TEXT [options]

Required selector (or env):
  --query TEXT                      Resolve an Emby item by search/title.
  VISIONPLAY_PROBE_QUERY            Env alternative for --query.

Options:
  --dry-run                         Resolve and log route only.
  --start-download                  Start the original/download route.
  --start-optimize                  Start the optimize/convert route (default).
  --refresh-existing                Request item refresh and poll for API-visible converted files.
  --preset NAME                     Preset for --start-optimize (default: env or 1080p 8 Mbps).
  --drop-after-bytes N              Enable DEBUG range-drop URLProtocol for static range downloads.
  --observe-seconds N               Observation window inside the app (default: env or 30).
  --keep-record                     Leave the probe download row in the app.
  --keep-app-running                Do not terminate VisionPlay after the observation window.
  --skip-build                      Reuse the existing DerivedData app.
  --no-install                      Reuse the already installed app.
  -h, --help                        Show this help.

The target simulator defaults to scripts/worktree-sim.sh id (or SIMID if set).
Output logs are written under build/probes/emby-download/<timestamp>/.
USAGE
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

query=${VISIONPLAY_PROBE_QUERY:-}
observe_seconds=${VISIONPLAY_PROBE_OBSERVE_SECONDS:-30}
preset=${VISIONPLAY_PROBE_PRESET:-1080p 8 Mbps}
mode=optimize
drop_after=${VISIONPLAY_PROBE_DROP_AFTER_BYTES:-}
keep_record=${VISIONPLAY_PROBE_KEEP_RECORD:-0}
keep_app_running=${VISIONPLAY_PROBE_KEEP_APP_RUNNING:-0}
skip_build=0
no_install=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query) [[ $# -ge 2 ]] || { echo "ERROR: --query needs a value" >&2; exit 2; }; query=$2; shift 2 ;;
    --observe-seconds) [[ $# -ge 2 ]] || { echo "ERROR: --observe-seconds needs a value" >&2; exit 2; }; observe_seconds=$2; shift 2 ;;
    --preset) [[ $# -ge 2 ]] || { echo "ERROR: --preset needs a value" >&2; exit 2; }; preset=$2; shift 2 ;;
    --dry-run) mode=dry; shift ;;
    --start-download) mode=download; shift ;;
    --start-optimize) mode=optimize; shift ;;
    --refresh-existing) mode=refresh; shift ;;
    --drop-after-bytes) [[ $# -ge 2 ]] || { echo "ERROR: --drop-after-bytes needs a value" >&2; exit 2; }; drop_after=$2; shift 2 ;;
    --keep-record) keep_record=1; shift ;;
    --keep-app-running) keep_app_running=1; shift ;;
    --skip-build) skip_build=1; shift ;;
    --no-install) no_install=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_positive_int() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }
if [[ -z "$query" ]]; then
  echo "ERROR: provide --query or VISIONPLAY_PROBE_QUERY." >&2
  exit 2
fi
if ! is_positive_int "$observe_seconds"; then
  echo "ERROR: observe-seconds must be a positive integer (got '$observe_seconds')." >&2
  exit 2
fi
if [[ -n "$drop_after" ]] && ! is_positive_int "$drop_after"; then
  echo "ERROR: drop-after-bytes must be a positive integer (got '$drop_after')." >&2
  exit 2
fi

simid=${SIMID:-$(scripts/worktree-sim.sh id)}
derived_data=${VISIONPLAY_PROBE_DERIVED_DATA:-build/DerivedData/EmbyDownloadProbe}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir=${VISIONPLAY_PROBE_OUTPUT_DIR:-build/probes/emby-download/$timestamp}
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)

log_file="$out_dir/unified.log"
stdout_file="$out_dir/stdout.log"
stderr_file="$out_dir/stderr.log"
build_log="$out_dir/xcodebuild.log"
summary_file="$out_dir/summary.txt"

cat > "$summary_file" <<SUMMARY
simulator: $simid
query_set: yes
mode: $mode
observe_seconds: $observe_seconds
preset_set: $([[ -n "$preset" ]] && echo yes || echo no)
drop_after_bytes: ${drop_after:-none}
keep_record: $keep_record
keep_app_running: $keep_app_running
SUMMARY

printf '==> Using simulator %s\n' "$simid"
xcrun simctl boot "$simid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simid" -b >/dev/null

if [[ $skip_build -eq 0 ]]; then
  printf '==> Building VisionPlay (log: %s)\n' "$build_log"
  scripts/xcodebuild-versioned.sh \
    -project VisionPlay.xcodeproj \
    -scheme VisionPlay \
    -configuration Debug \
    -destination "platform=visionOS Simulator,id=$simid" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$build_log" 2>&1
fi

app_path="$derived_data/Build/Products/Debug-xrsimulator/VisionPlay.app"
if [[ ! -d "$app_path" ]]; then
  app_path=$(find "$derived_data/Build/Products" -path '*/VisionPlay.app' -type d -print -quit 2>/dev/null || true)
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  echo "ERROR: could not find built VisionPlay.app under $derived_data" >&2
  exit 1
fi

if [[ $no_install -eq 0 ]]; then
  printf '==> Installing %s\n' "$app_path"
  xcrun simctl install "$simid" "$app_path"
fi

probe_args=(
  --vp-probe-backend emby
  --vp-probe-emby-download
  --vp-probe-query "$query"
  --vp-probe-observe-seconds "$observe_seconds"
)
case "$mode" in
  dry) ;;
  download) probe_args+=(--vp-probe-start-download) ;;
  optimize) probe_args+=(--vp-probe-start-optimize --vp-probe-download-preset "$preset") ;;
  refresh) probe_args+=(--vp-probe-refresh-existing) ;;
  *) echo "ERROR: invalid mode $mode" >&2; exit 2 ;;
esac
[[ -n "$drop_after" ]] && probe_args+=(--vp-probe-range-drop-after-bytes "$drop_after")
if [[ $keep_record == "1" || $keep_record == "true" || $keep_record == "yes" ]]; then
  probe_args+=(--vp-probe-keep-record)
fi

timeout_seconds=${VISIONPLAY_PROBE_TIMEOUT_SECONDS:-$((observe_seconds + 90))}
printf '==> Capturing app logs for ~%ss (unified: %s)\n' "$timeout_seconds" "$log_file"
predicate='subsystem == "com.jlipworth.VisionPlay" AND (category == "EmbyDownloadProbe" OR category == "Downloads")'
xcrun simctl spawn "$simid" log stream --style compact --level debug --predicate "$predicate" >"$log_file" 2>&1 &
log_pid=$!
cleanup() {
  if kill -0 "$log_pid" >/dev/null 2>&1; then
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf '==> Launching probe (stdout: %s, stderr: %s)\n' "$stdout_file" "$stderr_file"
xcrun simctl launch --terminate-running-process --stdout="$stdout_file" --stderr="$stderr_file" \
  "$simid" com.jlipworth.VisionPlay "${probe_args[@]}"

sleep "$timeout_seconds"
if [[ $keep_app_running == "1" || $keep_app_running == "true" || $keep_app_running == "yes" ]]; then
  printf '==> Leaving VisionPlay running in simulator %s\n' "$simid"
else
  xcrun simctl terminate "$simid" com.jlipworth.VisionPlay >/dev/null 2>&1 || true
fi
cleanup
trap - EXIT

probe_status=0
if grep -Eq 'probe\.emby_download\.fail|probe\.fail' "$log_file"; then
  echo "ERROR: probe logged a failure; inspect $log_file" >&2
  probe_status=1
fi
if ! grep -Eq 'probe\.emby_download\.(route|pass|observe|resume_check|existing_sources)|downloads\.(enqueue|start|range_start|range_retry|range_checkpoint|range_chunk_appended)' "$log_file"; then
  echo "ERROR: probe did not reach route/download observation; inspect $log_file" >&2
  probe_status=1
fi

printf '==> Probe complete. Key outputs:\n'
printf '    %s\n' "$summary_file" "$build_log" "$log_file" "$stdout_file" "$stderr_file"
printf '\n==> Recent probe lines:\n'
grep -E 'probe\.|range-drop|retry|failed|complete|downloads\.(enqueue|start|range_)' "$log_file" | tail -100 || true
exit "$probe_status"
