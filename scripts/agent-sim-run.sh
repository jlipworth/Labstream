#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/agent-sim-run.sh <scenario> [options]

Scenarios:
  launch-home-passive        Build/install/launch, capture video/screenshots/logs/run.json.
  click-login-jellyfin-tab   Launch, click the Jellyfin tab on the login panel, verify UI pixels changed.

Options:
  --skip-build               Reuse the newest Debug-xrsimulator Labstream.app.
  --duration SECONDS         Seconds to keep recording after scenario action. Default: 8.
  --artifact-root PATH       Artifact root. Default: artifacts/agent-sim-runs.
  --keep-booted              Do not shut down the worktree simulator after the run.

Exit codes:
  0 passed with artifacts
  1 scenario failed with artifacts
  2 blocked by missing simulator/build/app precondition
  3 human assist required
USAGE
}

scenario="${1:-}"
case "$scenario" in -h|--help) usage; exit 0 ;; esac
[ -n "$scenario" ] || { usage >&2; exit 2; }
shift || true

skip_build=0
duration=8
artifact_root="artifacts/agent-sim-runs"
shutdown_on_exit=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) skip_build=1; shift ;;
    --duration) duration="${2:-}"; [ -n "$duration" ] || { echo "missing --duration value" >&2; exit 2; }; shift 2 ;;
    --artifact-root) artifact_root="${2:-}"; [ -n "$artifact_root" ] || { echo "missing --artifact-root value" >&2; exit 2; }; shift 2 ;;
    --keep-booted) shutdown_on_exit=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$scenario" in
  launch-home-passive|click-login-jellyfin-tab) ;;
  *) echo "unknown scenario: $scenario" >&2; usage >&2; exit 2 ;;
esac

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

simid=$(scripts/worktree-sim.sh id) || { echo "failed to resolve worktree simulator" >&2; exit 2; }
commit=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
outdir="$artifact_root/${timestamp}-${scenario}"
mkdir -p "$outdir"
notes="$outdir/notes.md"
status="running"
human_assist="false"
video_pid=""
app=""
launch_exit_code=""
click_name=""
click_device_x=""
click_device_y=""
click_screen_x=""
click_screen_y=""
click_before_sha=""
click_after_sha=""
click_changed="false"

log_note() { printf '%s\n' "$*" | tee -a "$notes"; }

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

json_value_or_null() {
  if [ -z "$1" ]; then
    printf 'null'
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '%s' "$1"
  else
    json_string "$1"
  fi
}

write_run_json() {
  local exit_code="$1" end_time
  end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$outdir/run.json" <<JSON
{
  "scenario": "${scenario}",
  "status": "${status}",
  "exitCode": ${exit_code},
  "humanAssistRequired": ${human_assist},
  "simulatorUDID": "${simid}",
  "commit": "${commit}",
  "startedAt": "${timestamp}",
  "endedAt": "${end_time}",
  "durationSeconds": ${duration},
  "buildSkipped": $([ "$skip_build" -eq 1 ] && echo true || echo false),
  "shutdownOnExit": $([ "$shutdown_on_exit" -eq 1 ] && echo true || echo false),
  "appPath": $(json_string "$app"),
  "launchExitCode": $(json_value_or_null "$launch_exit_code"),
  "click": {
    "name": $(json_string "$click_name"),
    "deviceX": $(json_value_or_null "$click_device_x"),
    "deviceY": $(json_value_or_null "$click_device_y"),
    "screenX": $(json_value_or_null "$click_screen_x"),
    "screenY": $(json_value_or_null "$click_screen_y"),
    "beforeSHA256": $(json_string "$click_before_sha"),
    "afterSHA256": $(json_string "$click_after_sha"),
    "screenshotChanged": ${click_changed}
  },
  "artifacts": {
    "notes": "${notes}",
    "screenStart": "${outdir}/screen-start.png",
    "screenEnd": "${outdir}/screen-end.png",
    "screenRecording": "${outdir}/screen-recording.mp4",
    "appLog": "${outdir}/app.log",
    "simLog": "${outdir}/sim.log",
    "xcodebuildLog": "${outdir}/xcodebuild.log",
    "launchLog": "${outdir}/launch.log"
  }
}
JSON
}

stop_recording() {
  if [ -n "${video_pid:-}" ] && kill -0 "$video_pid" 2>/dev/null; then
    kill -INT "$video_pid" 2>/dev/null || true
    wait "$video_pid" 2>/dev/null || true
    video_pid=""
  fi
}

collect_tail_artifacts() {
  xcrun simctl io "$simid" screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1 || true
  xcrun simctl spawn "$simid" log show --last 2m --style compact --predicate 'process == "Labstream"' >"$outdir/app.log" 2>&1 || true
  # Keep the broad simulator log bounded; full all-process logs are enormous on visionOS.
  xcrun simctl spawn "$simid" log show --last 30s --style compact --predicate 'process == "SpringBoard" OR process == "launchd_sim" OR eventMessage CONTAINS[c] "Labstream"' >"$outdir/sim.log" 2>&1 || true
}

cleanup() {
  local ec=$?
  stop_recording
  if [ -n "${simid:-}" ]; then
    collect_tail_artifacts
  fi
  if [ "$shutdown_on_exit" -eq 1 ] && [ -n "${simid:-}" ]; then
    log_note "Shutting down simulator $simid."
    xcrun simctl shutdown "$simid" >/dev/null 2>&1 || true
  fi
  if [ "$status" = "running" ]; then
    status="failed"
  fi
  write_run_json "$ec"
}
trap cleanup EXIT

compile_click_helper() {
  if ! command -v swiftc >/dev/null 2>&1; then
    log_note "swiftc unavailable, cannot compile click helper."
    status="blocked"
    exit 2
  fi
  swiftc -O scripts/simclick.swift -o "$outdir/simclick"
}

simulator_window_frame() {
  # simctl can boot/headlessly record the device without opening a clickable Simulator window.
  # Synthetic clicks need the Simulator app window, so explicitly open/activate it first.
  open -a Simulator >/dev/null 2>&1 || true
  sleep 1
  osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1 || true
  sleep 0.5
  osascript -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1' 2>/dev/null || true
}

screen_point_for_device_point() {
  local frame="$1" device_x="$2" device_y="$3"
  printf '%s\n' "$frame" | tr -d '{}' | tr ',' ' ' | awk -v dx="$device_x" -v dy="$device_y" '{
    winX=$1; winY=$2; winW=$3; winH=$4;
    scale=winW/3840.0;
    contentTop=winY + (winH - 2160.0*scale);
    printf "%d %d\n", int(winX + dx*scale), int(contentTop + dy*scale);
  }'
}

perform_device_click() {
  local name="$1" device_x="$2" device_y="$3" frame
  click_name="$name"
  click_device_x="$device_x"
  click_device_y="$device_y"
  compile_click_helper
  frame=$(simulator_window_frame)
  printf '%s\n' "$frame" > "$outdir/simulator-window-frame.txt"
  if [ -z "$frame" ]; then
    log_note "Could not read Simulator window frame; user should open the Simulator window or fix local UI automation permissions."
    human_assist="true"
    status="blocked"
    exit 3
  fi
  read -r click_screen_x click_screen_y < <(screen_point_for_device_point "$frame" "$device_x" "$device_y")
  log_note "Clicking $name at device ${device_x},${device_y} -> screen ${click_screen_x},${click_screen_y}; window frame: $frame."
  xcrun simctl io "$simid" screenshot "$outdir/click-before.png" >>"$outdir/screenshot.log" 2>&1 || true
  click_before_sha=$(shasum -a 256 "$outdir/click-before.png" | awk '{print $1}')
  "$outdir/simclick" "$click_screen_x" "$click_screen_y" >>"$outdir/click.log" 2>&1 || {
    log_note "Click helper failed."
    status="failed"
    exit 1
  }
  sleep 2
  xcrun simctl io "$simid" screenshot "$outdir/click-after.png" >>"$outdir/screenshot.log" 2>&1 || true
  click_after_sha=$(shasum -a 256 "$outdir/click-after.png" | awk '{print $1}')
  if [ "$click_before_sha" = "$click_after_sha" ]; then
    click_changed="false"
    log_note "Click produced no screenshot delta; treating as a failed synthetic-click probe."
    status="failed"
    exit 1
  fi
  click_changed="true"
  log_note "Click changed the screenshot (${click_before_sha} -> ${click_after_sha})."
}

log_note "# Agent simulator run: $scenario"
log_note "- simulator: $simid"
log_note "- commit: $commit"
log_note "- artifact dir: $outdir"

if ! xcrun simctl list devices | grep -q "$simid"; then
  log_note "Simulator $simid not found."
  status="blocked"
  exit 2
fi

log_note "Booting simulator if needed..."
xcrun simctl boot "$simid" 2>/dev/null || true
xcrun simctl bootstatus "$simid" -b >/dev/null

if [ "$skip_build" -eq 0 ]; then
  log_note "Building Labstream for simulator..."
  rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app
  scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme Labstream \
    -destination "platform=visionOS Simulator,id=$simid" \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet >"$outdir/xcodebuild.log" 2>&1 || {
      log_note "Build failed; see xcodebuild.log."
      status="failed"
      exit 1
    }
else
  log_note "Skipping build by request."
fi

app=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app 2>/dev/null | head -1 || true)
if [ -z "$app" ] || [ ! -d "$app" ]; then
  log_note "No built Labstream.app found."
  status="blocked"
  exit 2
fi
log_note "Installing $app"
xcrun simctl install "$simid" "$app" >>"$outdir/install.log" 2>&1 || {
  log_note "Install failed; see install.log."
  status="failed"
  exit 1
}

log_note "Launching Labstream..."
xcrun simctl terminate "$simid" com.jlipworth.Labstream >/dev/null 2>&1 || true
set +e
xcrun simctl launch "$simid" com.jlipworth.Labstream >"$outdir/launch.log" 2>&1
launch_exit_code=$?
set -e
if [ "$launch_exit_code" -ne 0 ]; then
  log_note "Launch failed; see launch.log."
  status="failed"
  exit 1
fi
sleep 2

xcrun simctl io "$simid" screenshot "$outdir/screen-start.png" >>"$outdir/screenshot.log" 2>&1 || true
log_note "Starting video recording..."
xcrun simctl io "$simid" recordVideo "$outdir/screen-recording.mp4" >>"$outdir/record-video.log" 2>&1 &
video_pid=$!
sleep 1

if [ "$scenario" = "click-login-jellyfin-tab" ]; then
  # Device-space center of the Jellyfin tab in the unauthenticated login panel at 3840x2160.
  # If the simulator is signed in or otherwise not on the login panel, this probe should fail
  # with artifacts instead of claiming useful UI-driving evidence.
  perform_device_click "login-jellyfin-tab" 1920 1245
fi

sleep "$duration"
stop_recording
collect_tail_artifacts

if xcrun simctl get_app_container "$simid" com.jlipworth.Labstream app >/dev/null 2>&1; then
  log_note "App container exists after launch."
fi

if grep -Eiq 'Fatal error:|fatalError|uncaught exception|terminating app due to uncaught exception' "$outdir/app.log"; then
  log_note "Detected fatal/exception text in app log."
  status="failed"
  exit 1
fi

status="passed"
log_note "Scenario passed."
exit 0
