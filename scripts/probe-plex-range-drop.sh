#!/usr/bin/env bash
# Simulator-only Plex download recoverability probe.
#
# Launches the DEBUG app in this worktree's simulator with the in-process
# range-drop URLProtocol enabled. It uses the simulator's signed-in app state;
# it does not read or print Plex tokens.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/probe-plex-range-drop.sh (--query TEXT | --rating-key KEY) [options]

Required selector (or env):
  --query TEXT                      Resolve a Plex item by title or "Show S01E02" syntax.
  --rating-key KEY                  Resolve a Plex item by Plex ratingKey.
  LABSTREAM_PROBE_QUERY            Env alternative for --query.
  LABSTREAM_PROBE_RATING_KEY       Env alternative for --rating-key.

Options:
  --drop-after-bytes N              Simulated network-loss threshold (default: env or 2097152).
  --observe-seconds N               Probe post-start observation window (default: env or 90).
  --pause-after-seconds N           Delay before pause in --pause-resume mode (default: env or 8).
  --pause-resume                    Also exercise pause -> retry/resume after starting.
  --existing-version                Download an existing server-generated Plex Version.
  --media-index N                   Media/version index to probe (default: env or 0).
  --part-index N                    Part index to probe (default: env or 0).
  --list-versions                   Log available media/version choices before starting.
  --preset NAME                     Plex optimize preset if original is not eligible.
  --delete-existing                 Delete any existing probe record and exit.
  --delete-after                    Delete the probe record after observation.
  --keep-app-running                Do not terminate Labstream after the observation window.
  --skip-build                      Reuse the existing DerivedData app.
  --no-install                      Reuse the already installed app.
  -h, --help                        Show this help.

The target simulator defaults to scripts/worktree-sim.sh --platform visionos id (or SIMID if set).
Output logs are written under build/probes/plex-range-drop/<timestamp>/.
USAGE
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

query=${LABSTREAM_PROBE_QUERY:-}
rating_key=${LABSTREAM_PROBE_RATING_KEY:-}
drop_after=${LABSTREAM_PROBE_DROP_AFTER_BYTES:-2097152}
observe_seconds=${LABSTREAM_PROBE_OBSERVE_SECONDS:-90}
pause_after_seconds=${LABSTREAM_PROBE_PAUSE_AFTER_SECONDS:-8}
preset=${LABSTREAM_PROBE_PRESET:-}
media_index=${LABSTREAM_PROBE_MEDIA_INDEX:-0}
part_index=${LABSTREAM_PROBE_PART_INDEX:-0}
pause_resume=0
existing_version=${LABSTREAM_PROBE_EXISTING_VERSION:-0}
list_versions=${LABSTREAM_PROBE_LIST_VERSIONS:-0}
delete_existing=${LABSTREAM_PROBE_DELETE_EXISTING:-0}
delete_after=${LABSTREAM_PROBE_DELETE_AFTER:-0}
keep_app_running=${LABSTREAM_PROBE_KEEP_APP_RUNNING:-0}
skip_build=0
no_install=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)
      [[ $# -ge 2 ]] || { echo "ERROR: --query needs a value" >&2; exit 2; }
      query=$2; shift 2 ;;
    --rating-key)
      [[ $# -ge 2 ]] || { echo "ERROR: --rating-key needs a value" >&2; exit 2; }
      rating_key=$2; shift 2 ;;
    --drop-after-bytes)
      [[ $# -ge 2 ]] || { echo "ERROR: --drop-after-bytes needs a value" >&2; exit 2; }
      drop_after=$2; shift 2 ;;
    --observe-seconds)
      [[ $# -ge 2 ]] || { echo "ERROR: --observe-seconds needs a value" >&2; exit 2; }
      observe_seconds=$2; shift 2 ;;
    --pause-after-seconds)
      [[ $# -ge 2 ]] || { echo "ERROR: --pause-after-seconds needs a value" >&2; exit 2; }
      pause_after_seconds=$2; shift 2 ;;
    --preset)
      [[ $# -ge 2 ]] || { echo "ERROR: --preset needs a value" >&2; exit 2; }
      preset=$2; shift 2 ;;
    --media-index)
      [[ $# -ge 2 ]] || { echo "ERROR: --media-index needs a value" >&2; exit 2; }
      media_index=$2; shift 2 ;;
    --part-index)
      [[ $# -ge 2 ]] || { echo "ERROR: --part-index needs a value" >&2; exit 2; }
      part_index=$2; shift 2 ;;
    --pause-resume) pause_resume=1; shift ;;
    --existing-version) existing_version=1; shift ;;
    --list-versions) list_versions=1; shift ;;
    --delete-existing) delete_existing=1; shift ;;
    --delete-after) delete_after=1; shift ;;
    --keep-app-running) keep_app_running=1; shift ;;
    --skip-build) skip_build=1; shift ;;
    --no-install) no_install=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_positive_int() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }

if [[ -z "$query" && -z "$rating_key" ]]; then
  echo "ERROR: provide --query/--rating-key or LABSTREAM_PROBE_QUERY/LABSTREAM_PROBE_RATING_KEY." >&2
  echo "       The script intentionally has no built-in media id." >&2
  exit 2
fi
if ! is_positive_int "$drop_after"; then
  echo "ERROR: drop-after-bytes must be a positive integer (got '$drop_after')." >&2
  exit 2
fi
if [[ ! ${media_index:-} =~ ^[0-9]+$ || ! ${part_index:-} =~ ^[0-9]+$ ]]; then
  echo "ERROR: media-index and part-index must be non-negative integers." >&2
  exit 2
fi
if ! is_positive_int "$observe_seconds" || ! is_positive_int "$pause_after_seconds"; then
  echo "ERROR: observe-seconds and pause-after-seconds must be positive integers." >&2
  exit 2
fi

simid=${SIMID:-$(scripts/worktree-sim.sh --platform visionos id)}
derived_data=${LABSTREAM_PROBE_DERIVED_DATA:-build/DerivedData/PlexRangeDropProbe}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
out_dir=${LABSTREAM_PROBE_OUTPUT_DIR:-build/probes/plex-range-drop/$timestamp}
mkdir -p "$out_dir"
# `simctl launch --stdout/--stderr` is fragile with relative host paths on visionOS
# simulators (it can report a misleading SFBSystemService NotFound launch error).
# Keep the user-facing path under the repo by default, but pass absolute file paths to simctl.
out_dir=$(cd "$out_dir" && pwd -P)

log_file="$out_dir/unified.log"
stdout_file="$out_dir/stdout.log"
stderr_file="$out_dir/stderr.log"
build_log="$out_dir/xcodebuild.log"
summary_file="$out_dir/summary.txt"

cat > "$summary_file" <<SUMMARY
simulator: $simid
query_set: $([[ -n "$query" ]] && echo yes || echo no)
rating_key_set: $([[ -n "$rating_key" ]] && echo yes || echo no)
drop_after_bytes: $drop_after
observe_seconds: $observe_seconds
pause_resume: $pause_resume
pause_after_seconds: $pause_after_seconds
existing_version: $existing_version
media_index: $media_index
part_index: $part_index
list_versions: $list_versions
preset_set: $([[ -n "$preset" ]] && echo yes || echo no)
delete_existing: $delete_existing
delete_after: $delete_after
keep_app_running: $keep_app_running
SUMMARY

printf '==> Using simulator %s\n' "$simid"
xcrun simctl boot "$simid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simid" -b >/dev/null

if [[ $skip_build -eq 0 ]]; then
  printf '==> Building Labstream (log: %s)\n' "$build_log"
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme Labstream \
    -configuration Debug \
    -destination "platform=visionOS Simulator,id=$simid" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$build_log" 2>&1
fi

app_path="$derived_data/Build/Products/Debug-xrsimulator/Labstream.app"
if [[ ! -d "$app_path" ]]; then
  app_path=$(find "$derived_data/Build/Products" -path '*/Labstream.app' -type d -print -quit 2>/dev/null || true)
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  echo "ERROR: could not find built Labstream.app under $derived_data" >&2
  exit 1
fi

if [[ $no_install -eq 0 ]]; then
  printf '==> Installing %s\n' "$app_path"
  xcrun simctl install "$simid" "$app_path"
fi

probe_args=(
  --vp-probe-backend plex
  --vp-probe-plex-download
  --vp-probe-start-download
  --vp-probe-range-check
  --vp-probe-range-drop-after-bytes "$drop_after"
  --vp-probe-observe-seconds "$observe_seconds"
  --vp-probe-media-index "$media_index"
  --vp-probe-part-index "$part_index"
)
[[ -n "$rating_key" ]] && probe_args+=(--vp-probe-rating-key "$rating_key")
[[ -n "$query" ]] && probe_args+=(--vp-probe-query "$query")
[[ -n "$preset" ]] && probe_args+=(--vp-probe-download-preset "$preset")
if [[ $existing_version == "1" || $existing_version == "true" || $existing_version == "yes" ]]; then
  probe_args+=(--vp-probe-existing-version)
fi
if [[ $list_versions == "1" || $list_versions == "true" || $list_versions == "yes" ]]; then
  probe_args+=(--vp-probe-list-versions)
fi
if [[ $delete_existing == "1" || $delete_existing == "true" || $delete_existing == "yes" ]]; then
  probe_args+=(--vp-probe-delete-existing)
fi
if [[ $pause_resume -eq 1 ]]; then
  probe_args+=(--vp-probe-pause-resume --vp-probe-pause-after-seconds "$pause_after_seconds")
fi
if [[ $delete_after == "1" || $delete_after == "true" || $delete_after == "yes" ]]; then
  probe_args+=(--vp-probe-delete-after-observe)
fi

timeout_seconds=${LABSTREAM_PROBE_TIMEOUT_SECONDS:-$((observe_seconds + pause_after_seconds + 70))}
printf '==> Capturing app logs for ~%ss (unified: %s)\n' "$timeout_seconds" "$log_file"

predicate='subsystem == "com.jlipworth.Labstream" AND (category == "DownloadProbe" OR category == "Downloads")'
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
  "$simid" com.jlipworth.Labstream "${probe_args[@]}"

sleep "$timeout_seconds"
if [[ $keep_app_running == "1" || $keep_app_running == "true" || $keep_app_running == "yes" ]]; then
  printf '==> Leaving Labstream running in simulator %s\n' "$simid"
else
  xcrun simctl terminate "$simid" com.jlipworth.Labstream >/dev/null 2>&1 || true
fi
cleanup
trap - EXIT

probe_status=0
if grep -Eq 'probe\.plex_download\.fail|probe\.fail' "$log_file"; then
  echo "ERROR: probe logged a failure; inspect $log_file" >&2
  probe_status=1
fi
if [[ $delete_existing != "1" && $delete_existing != "true" && $delete_existing != "yes" ]]; then
  # A route-only log is inconclusive for the recovery harness: it proves item resolution, but not
  # that the app actually entered the transfer/observation path. Fail visibly so callers don't cite
  # a no-op as network-drop evidence.
  if ! grep -Eq 'probe\.plex_download\.(observe|done|resume_check|deleted)|downloads\.(enqueue|start|start_failed|range_start|range_retry|range_failed|range_checkpoint)' "$log_file"; then
    echo "ERROR: probe did not reach transfer observation/start; inspect $log_file" >&2
    probe_status=1
  fi
fi

printf '==> Probe complete. Key outputs:\n'
printf '    %s\n' "$summary_file" "$build_log" "$log_file" "$stdout_file" "$stderr_file"
printf '\n==> Recent probe lines:\n'
grep -E 'probe\.|range-drop|Range|retry|failed|complete|downloads\.(enqueue|start|range_)' "$log_file" | tail -80 || true
exit "$probe_status"
