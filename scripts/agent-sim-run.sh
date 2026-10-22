#!/usr/bin/env bash
set -euo pipefail
lease_original_args=("$@")

usage() {
  cat <<'USAGE'
Usage: scripts/agent-sim-run.sh <scenario> [options]

Scenarios:
  launch-home-passive        Build/install/launch visionOS app, capture video/screenshots/logs/run.json.
  launch-fixture-home-passive
                             Same evidence loop with credential-free synthetic browse content.

Options:
  --skip-build               Reuse the newest Debug-xrsimulator Labstream.app.
  --duration SECONDS         Seconds to keep recording after scenario action. Default: 8.
  --artifact-root PATH       Artifact root. Default: artifacts/agent-sim-runs.
  --keep-booted              Do not shut down the visionOS worktree simulator after the run.
  --allow-simulator          Required assertion that the caller owns the simulator lease.

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
allow_simulator=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) skip_build=1; shift ;;
    --duration) duration="${2:-}"; [ -n "$duration" ] || { echo "missing --duration value" >&2; exit 2; }; shift 2 ;;
    --artifact-root) artifact_root="${2:-}"; [ -n "$artifact_root" ] || { echo "missing --artifact-root value" >&2; exit 2; }; shift 2 ;;
    --keep-booted) shutdown_on_exit=0; shift ;;
    --allow-simulator) allow_simulator=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$allow_simulator" -eq 1 ] || {
  echo "Refusing to boot a simulator without --allow-simulator (lease assertion)." >&2
  exit 2
}

case "$scenario" in
  launch-home-passive|launch-fixture-home-passive) ;;
  *) echo "unknown scenario: $scenario" >&2; usage >&2; exit 2 ;;
esac

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
# Hold the same host lease across build/install/UI/teardown, not just compilation.
if ! python3 "$repo_root/scripts/xcodebuild-lease.py" held; then
  exec python3 "$repo_root/scripts/xcodebuild-lease.py" run --lane agent-sim-run -- "$repo_root/scripts/agent-sim-run.sh" "${lease_original_args[@]}"
fi
derived_data="$repo_root/build/DerivedData-agent-visionos"

simid=$(scripts/worktree-sim.sh --platform visionos id) || { echo "failed to resolve visionOS worktree simulator" >&2; exit 2; }
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

log_note "# Agent simulator run: $scenario"
log_note "- simulator: $simid"
log_note "- commit: $commit"
log_note "- artifact dir: $outdir"

if ! xcrun simctl list devices | grep -q "$simid"; then
  log_note "Simulator $simid not found."
  status="blocked"
  exit 2
fi

foreign_booted=$(SIMID="$simid" python3 - <<'PY'
import json, os, subprocess
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
wanted = os.environ["SIMID"]
print(" ".join(device["udid"] for devices in data["devices"].values() for device in devices
               if device.get("state") == "Booted" and device.get("udid") != wanted))
PY
)
if [ -n "$foreign_booted" ]; then
  log_note "Another simulator is booted; lease invariant violated: $foreign_booted"
  status="blocked"
  exit 2
fi

log_note "Booting simulator if needed..."
xcrun simctl boot "$simid" 2>/dev/null || true
xcrun simctl bootstatus "$simid" -b >/dev/null

if [ "$skip_build" -eq 0 ]; then
  log_note "Building Labstream for simulator..."
  rm -rf "$derived_data"
  scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme Labstream \
    -destination "platform=visionOS Simulator,id=$simid" \
    -configuration Debug -derivedDataPath "$derived_data" \
    build CODE_SIGNING_ALLOWED=NO -quiet >"$outdir/xcodebuild.log" 2>&1 || {
      log_note "Build failed; see xcodebuild.log."
      status="failed"
      exit 1
    }
else
  log_note "Skipping build by request."
fi

app="$derived_data/Build/Products/Debug-xrsimulator/Labstream.app"
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
xcrun simctl terminate "$simid" org.labstream.Labstream >/dev/null 2>&1 || true
launch_args=()
if [ "$scenario" = "launch-fixture-home-passive" ]; then
  launch_args=(--ui-testing --ui-testing-backend plex --ui-testing-fixture browse)
fi
set +e
xcrun simctl launch "$simid" org.labstream.Labstream "${launch_args[@]}" \
  >"$outdir/launch.log" 2>&1
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

sleep "$duration"
stop_recording
collect_tail_artifacts

if xcrun simctl get_app_container "$simid" org.labstream.Labstream app >/dev/null 2>&1; then
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
