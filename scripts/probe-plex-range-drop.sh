#!/usr/bin/env bash
# Simulator-only Plex download transport fault probe.
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
  --fault NAME                      connection-drop (default), validator-flip, 401-mid-train,
                                    held-body-pause (requires --pause-resume), or
                                    double-connection-drop, held-body-delete, write-failure,
                                    416-restart, 200-replace, held-body-relaunch, drain-pause,
                                    or drain-delete.
  --drop-after-bytes N              Network-loss threshold for connection-drop (default: 2097152).
  --observe-seconds N               Probe post-start observation window (default: env or 90).
  --pause-after-seconds N           Delay before pause in --pause-resume mode (default: env or 8).
  --pause-resume                    Also exercise pause -> retry/resume after starting.
  --pause-only                      Pause without retry; used by drain-pause.
  --delete-during-transfer          Delete two seconds after transfer start (held-body-delete only).
  --relaunch-held                   Kill/relaunch after held bodies, then observe and delete the row.
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
fault=${LABSTREAM_PROBE_DOWNLOAD_FAULT:-connection-drop}
drop_after=${LABSTREAM_PROBE_DROP_AFTER_BYTES:-2097152}
observe_seconds=${LABSTREAM_PROBE_OBSERVE_SECONDS:-90}
pause_after_seconds=${LABSTREAM_PROBE_PAUSE_AFTER_SECONDS:-8}
preset=${LABSTREAM_PROBE_PRESET:-}
media_index=${LABSTREAM_PROBE_MEDIA_INDEX:-0}
part_index=${LABSTREAM_PROBE_PART_INDEX:-0}
pause_resume=0
pause_only=0
delete_during_transfer=0
relaunch_held=0
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
    --fault)
      [[ $# -ge 2 ]] || { echo "ERROR: --fault needs a value" >&2; exit 2; }
      fault=$2; shift 2 ;;
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
    --pause-only) pause_only=1; shift ;;
    --delete-during-transfer) delete_during_transfer=1; shift ;;
    --relaunch-held) relaunch_held=1; shift ;;
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
if [[ "$fault" != "connection-drop" && "$fault" != "validator-flip" \
      && "$fault" != "401-mid-train" && "$fault" != "held-body-pause" \
      && "$fault" != "held-body-delete" && "$fault" != "double-connection-drop" \
      && "$fault" != "write-failure" && "$fault" != "416-restart" \
      && "$fault" != "200-replace" && "$fault" != "held-body-relaunch" \
      && "$fault" != "drain-pause" && "$fault" != "drain-delete" ]]; then
  echo "ERROR: unsupported download fault '$fault'." >&2
  exit 2
fi
if [[ "$fault" == "drain-pause" && $pause_only -ne 1 ]]; then
  echo "ERROR: drain-pause requires --pause-only." >&2
  exit 2
fi
if [[ "$fault" == "drain-delete" && $delete_during_transfer -ne 1 ]]; then
  echo "ERROR: drain-delete requires --delete-during-transfer." >&2
  exit 2
fi
if [[ "$fault" == "held-body-pause" && $pause_resume -ne 1 ]]; then
  echo "ERROR: held-body-pause requires --pause-resume." >&2
  exit 2
fi
if [[ "$fault" == "held-body-delete" && $delete_during_transfer -ne 1 ]]; then
  echo "ERROR: held-body-delete requires --delete-during-transfer." >&2
  exit 2
fi
if [[ "$fault" == "held-body-relaunch" && $relaunch_held -ne 1 ]]; then
  echo "ERROR: held-body-relaunch requires --relaunch-held." >&2
  exit 2
fi
if [[ $relaunch_held -eq 1 && $delete_after -eq 1 ]]; then
  echo "ERROR: --relaunch-held owns second-launch cleanup; do not also pass --delete-after." >&2
  exit 2
fi
if [[ "$fault" == "connection-drop" || "$fault" == "double-connection-drop" ]] \
   && ! is_positive_int "$drop_after"; then
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
fault: $fault
observe_seconds: $observe_seconds
pause_resume: $pause_resume
pause_only: $pause_only
delete_during_transfer: $delete_during_transfer
relaunch_held: $relaunch_held
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
  --vp-probe-observe-seconds "$observe_seconds"
  --vp-probe-media-index "$media_index"
  --vp-probe-part-index "$part_index"
)
if [[ "$fault" == "connection-drop" ]]; then
  probe_args+=(--vp-probe-range-drop-after-bytes "$drop_after")
else
  probe_args+=(--vp-probe-download-fault "$fault")
  if [[ "$fault" == "double-connection-drop" ]]; then
    probe_args+=(--vp-probe-range-drop-after-bytes "$drop_after")
  fi
fi
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
if [[ $pause_only -eq 1 ]]; then
  probe_args+=(--vp-probe-pause-only --vp-probe-pause-after-seconds "$pause_after_seconds")
fi
if [[ "$fault" == "drain-pause" || "$fault" == "drain-delete" ]]; then
  probe_args+=(--vp-probe-range-segment-bytes 1048576)
fi
if [[ $delete_during_transfer -eq 1 ]]; then
  delete_delay=2
  [[ "$fault" == "drain-delete" ]] && delete_delay=4
  probe_args+=(--vp-probe-delete-during-transfer --vp-probe-delete-after-seconds "$delete_delay")
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

if [[ $relaunch_held -eq 1 ]]; then
  first_phase_seconds=$((observe_seconds + 18))
  printf '==> Waiting %ss for held bodies, then terminating for relaunch\n' "$first_phase_seconds"
  sleep "$first_phase_seconds"
  xcrun simctl terminate "$simid" com.jlipworth.Labstream >/dev/null 2>&1 || true
  # CoreSimulator can opportunistically shut the device down after the only foreground process is
  # terminated. Rebooting here still preserves the app container and is a stronger relaunch seam.
  xcrun simctl boot "$simid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$simid" -b >/dev/null
  printf '==> Relaunching without fault injection to exercise on-disk stash reattach/sweep\n'
  relaunch_args=(
    --vp-probe-backend plex
    --vp-probe-plex-download
    --vp-probe-observe-record
    --vp-probe-observe-seconds 8
    --vp-probe-delete-after-observe
  )
  [[ -n "$rating_key" ]] && relaunch_args+=(--vp-probe-rating-key "$rating_key")
  [[ -n "$query" ]] && relaunch_args+=(--vp-probe-query "$query")
  xcrun simctl launch --terminate-running-process --stdout="$stdout_file" --stderr="$stderr_file" \
    "$simid" com.jlipworth.Labstream "${relaunch_args[@]}"
  sleep 18
else
  sleep "$timeout_seconds"
fi
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
if [[ $delete_existing != "1" && $delete_existing != "true" && $delete_existing != "yes" ]]; then
  if ! grep -Eq "downloads\.fault_injected.*scenario.*$fault|scenario.*$fault.*downloads\.fault_injected" "$log_file"; then
    echo "ERROR: requested fault '$fault' was not observed; inspect $log_file" >&2
    probe_status=1
  fi
  case "$fault" in
    validator-flip)
      if ! grep -Eq 'downloads\.range_validator_changed' "$log_file"; then
        echo "ERROR: validator flip did not reach the engine's changed-resource path; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    401-mid-train)
      if ! grep -Eq 'downloads\.range_http_rehydrate' "$log_file"; then
        echo "ERROR: injected 401 did not reach the engine's request-rehydration path; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    held-body-pause)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      paused_line=$(grep -n -m1 'probe\.plex_download\.paused.*reached=true' "$log_file" | cut -d: -f1 || true)
      if [[ -z "$held_line" || -z "$paused_line" || $held_line -ge $paused_line ]]; then
        echo "ERROR: no held body was observed before the row reached paused; inspect $log_file" >&2
        probe_status=1
      elif sed -n "${held_line},${paused_line}p" "$log_file" | grep -Eq 'downloads\.range_held_segments_purged'; then
        echo "ERROR: pause purged a held segment body instead of preserving it; inspect $log_file" >&2
        probe_status=1
      fi
      if ! grep -Eq 'probe\.plex_download\.resume_check' "$log_file"; then
        echo "ERROR: held-body pause did not continue through the retry/resume path; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    double-connection-drop)
      first_fault_line=$(grep -n 'downloads\.fault_injected.*scenario=double-connection-drop' "$log_file" \
        | sed -n '1s/:.*//p')
      second_fault_line=$(grep -n 'downloads\.fault_injected.*scenario=double-connection-drop' "$log_file" \
        | sed -n '2s/:.*//p')
      first_blob_line=$(grep -n 'downloads\.range_blob_resume' "$log_file" | sed -n '1s/:.*//p')
      second_blob_line=$(grep -n 'downloads\.range_blob_resume' "$log_file" | sed -n '2s/:.*//p')
      if [[ -z "$first_fault_line" || -z "$second_fault_line" \
            || -z "$first_blob_line" || -z "$second_blob_line" \
            || $first_fault_line -ge $first_blob_line \
            || $first_blob_line -ge $second_fault_line \
            || $second_fault_line -ge $second_blob_line ]]; then
        echo "ERROR: expected fault→blob resume→second fault→second blob resume ordering; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    held-body-delete)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      deleted_line=$(grep -n -m1 'probe\.plex_download\.deleted_during_transfer.*row_missing=true' "$log_file" \
        | cut -d: -f1 || true)
      purged_line=$(grep -n -m1 'downloads\.range_held_segments_purged' "$log_file" | cut -d: -f1 || true)
      if [[ -z "$held_line" || -z "$deleted_line" || -z "$purged_line" \
            || $held_line -ge $purged_line || $purged_line -ge $deleted_line ]]; then
        echo "ERROR: expected held body→cancel purge→row deletion ordering; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    write-failure)
      if ! grep -Eq 'downloads\.move_failed.*reason=storage_full.*stage=append|downloads\.move_failed.*stage=append.*reason=storage_full' "$log_file"; then
        echo "ERROR: injected append failure was not classified terminally as storage_full; inspect $log_file" >&2
        probe_status=1
      fi
      if grep -Eq 'downloads\.range_move_retry' "$log_file"; then
        echo "ERROR: storage-full append incorrectly entered transient move retry; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    416-restart)
      appended_line=$(grep -n -m1 'downloads\.range_remainder_appended.*base_offset=0' "$log_file" \
        | cut -d: -f1 || true)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      fault_line=$(grep -n -m1 'downloads\.fault_injected.*scenario=416-restart' "$log_file" \
        | cut -d: -f1 || true)
      mismatch_line=$(grep -n -m1 'downloads\.range_416_mismatch' "$log_file" | cut -d: -f1 || true)
      supersede_line=$(grep -n -m1 'downloads\.range_train_superseded.*reason=changed_resource_restart' "$log_file" \
        | cut -d: -f1 || true)
      if [[ -z "$appended_line" || -z "$held_line" || -z "$fault_line" \
            || -z "$mismatch_line" || -z "$supersede_line" \
            || $appended_line -ge $fault_line || $held_line -ge $fault_line \
            || $fault_line -ge $mismatch_line || $mismatch_line -ge $supersede_line ]]; then
        echo "ERROR: expected append+held work→416 mismatch→serialized train restart; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    200-replace)
      appended_line=$(grep -n -m1 'downloads\.range_remainder_appended.*base_offset=0' "$log_file" \
        | cut -d: -f1 || true)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      fault_line=$(grep -n -m1 'downloads\.fault_injected.*scenario=200-replace' "$log_file" \
        | cut -d: -f1 || true)
      finished_line=$(grep -n -m1 'downloads\.range_remainder_finished.*http_status=200' "$log_file" \
        | cut -d: -f1 || true)
      purged_line=$(grep -n -m1 'downloads\.range_held_segments_purged' "$log_file" | cut -d: -f1 || true)
      supersede_line=$(grep -n -m1 'downloads\.range_train_superseded.*reason=replace_whole_adopted' "$log_file" \
        | cut -d: -f1 || true)
      if [[ -z "$appended_line" || -z "$held_line" || -z "$fault_line" \
            || -z "$finished_line" || -z "$purged_line" || -z "$supersede_line" \
            || $appended_line -ge $fault_line || $held_line -ge $fault_line \
            || $fault_line -ge $finished_line || $finished_line -ge $purged_line \
            || $purged_line -ge $supersede_line ]]; then
        echo "ERROR: expected append+held work→adopted 200→held purge→sibling supersede; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    held-body-relaunch)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      swept_line=""
      if [[ -n "$held_line" ]]; then
        swept_line=$(awk -v held="$held_line" 'NR > held && /downloads\.range_stash_swept/ { print NR; exit }' "$log_file")
      fi
      second_start_line=""
      if [[ -n "$swept_line" ]]; then
        second_start_line=$(awk -v swept="$swept_line" \
          'NR > swept && /probe\.plex_download\.start/ && /observe_only=true/ { print NR; exit }' "$log_file")
      fi
      if [[ -z "$held_line" || -z "$swept_line" || -z "$second_start_line" ]]; then
        echo "ERROR: expected held body→relaunch stash sweep→observe-only second launch; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    drain-pause)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      drain_line=$(grep -n -m1 'downloads\.fault_injected.*scenario=drain-pause.*stage=held_drain' "$log_file" \
        | cut -d: -f1 || true)
      assembled_line=$(grep -n -m1 'downloads\.range_segment_assembled' "$log_file" | cut -d: -f1 || true)
      pause_requested_line=$(grep -n -m1 'downloads\.pause_requested' "$log_file" | cut -d: -f1 || true)
      drain_halted_line=$(grep -n -m1 'downloads\.range_held_drain_halted' "$log_file" | cut -d: -f1 || true)
      paused_line=$(grep -n -m1 'probe\.plex_download\.paused.*reached=true' "$log_file" | cut -d: -f1 || true)
      if [[ -z "$held_line" || -z "$drain_line" || -z "$assembled_line" \
            || -z "$pause_requested_line" || -z "$drain_halted_line" || -z "$paused_line" \
            || $held_line -ge $drain_line || $drain_line -ge $assembled_line \
            || $assembled_line -ge $pause_requested_line \
            || $pause_requested_line -ge $drain_halted_line \
            || $drain_halted_line -ge $paused_line ]]; then
        echo "ERROR: expected held body→drain append→pause request→halted drain→confirmed pause ordering; inspect $log_file" >&2
        probe_status=1
      elif tail -n "+$pause_requested_line" "$log_file" | grep -Eq 'downloads\.range_start'; then
        echo "ERROR: drain-pause started new range work after the pause request; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
    drain-delete)
      held_line=$(grep -n -m1 'downloads\.range_segment_held' "$log_file" | cut -d: -f1 || true)
      drain_line=$(grep -n -m1 'downloads\.fault_injected.*scenario=drain-delete.*stage=held_drain' "$log_file" \
        | cut -d: -f1 || true)
      assembled_line=$(grep -n -m1 'downloads\.range_segment_assembled' "$log_file" | cut -d: -f1 || true)
      cancel_line=$(grep -n -m1 'downloads\.cancel_requested' "$log_file" | cut -d: -f1 || true)
      purge_line=$(grep -n -m1 'downloads\.range_held_segments_purged' "$log_file" | cut -d: -f1 || true)
      deleted_line=$(grep -n -m1 'probe\.plex_download\.deleted_during_transfer.*row_missing=true' "$log_file" \
        | cut -d: -f1 || true)
      if [[ -z "$held_line" || -z "$drain_line" || -z "$assembled_line" \
            || -z "$cancel_line" || -z "$purge_line" || -z "$deleted_line" \
            || $held_line -ge $drain_line || $drain_line -ge $assembled_line \
            || $assembled_line -ge $cancel_line || $cancel_line -ge $purge_line \
            || $purge_line -ge $deleted_line ]]; then
        echo "ERROR: expected held body→drain append→cancel→held purge→row deletion ordering; inspect $log_file" >&2
        probe_status=1
      elif tail -n "+$cancel_line" "$log_file" | grep -Eq 'downloads\.range_start'; then
        echo "ERROR: drain-delete started new range work after cancel; inspect $log_file" >&2
        probe_status=1
      fi
      ;;
  esac
fi

printf '==> Probe complete. Key outputs:\n'
printf '    %s\n' "$summary_file" "$build_log" "$log_file" "$stdout_file" "$stderr_file"
printf '\n==> Recent probe lines:\n'
grep -E 'probe\.|range-drop|fault_injected|Range|retry|failed|complete|downloads\.(enqueue|start|range_)' "$log_file" | tail -80 || true
if [[ $pause_only -eq 1 ]]; then
  xcrun simctl boot "$simid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$simid" -b >/dev/null
  cleanup_args=(--vp-probe-backend plex --vp-probe-plex-download --vp-probe-delete-existing)
  [[ -n "$rating_key" ]] && cleanup_args+=(--vp-probe-rating-key "$rating_key")
  [[ -n "$query" ]] && cleanup_args+=(--vp-probe-query "$query")
  xcrun simctl launch --terminate-running-process "$simid" com.jlipworth.Labstream "${cleanup_args[@]}" >/dev/null
  sleep 7
  xcrun simctl terminate "$simid" com.jlipworth.Labstream >/dev/null 2>&1 || true
fi
exit "$probe_status"
