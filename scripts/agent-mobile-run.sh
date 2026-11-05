#!/usr/bin/env bash
# Bounded credential-free iPhone/iPad/iPhone Duo agent scenario runner.
#
# This is the durable repo-side half of the Xcode 27 Device Interaction loop: it proves the exact
# product can build, install, launch into deterministic fixture state, and emit an evidence bundle.
# Semantic hierarchy inspection and interaction can then attach to the same fixture launch without
# depending on a user's backend account. Never run without the repository's simulator lease.
set -euo pipefail
lease_original_args=("$@")

usage() {
  cat <<'USAGE'
Usage: scripts/agent-mobile-run.sh <iphone|iphone69|ipad|duo> <scenario> --allow-simulator [options]

Platforms resolve this worktree's simulator through scripts/worktree-sim.sh --platform <platform>:
iphone (default 6.3-inch lane), iphone69 (6.9-inch Pro Max lane), ipad, or duo (iPhone Duo).

Scenarios:
  fixture-home-passive    Launch fixture and collect passive evidence.
  fixture-detail-semantic Run the durable accessibility-targeted XCUITest and collect evidence.

Options:
  --backend plex|jellyfin|emby  Synthetic browse lane. Default: plex.
  --duration SECONDS            Recording/settle time after launch. Default: 5.
  --artifact-root PATH          Default: artifacts/agent-platform-runs.
  --keep-booted                 Leave the leased simulator booted after the run.
  --allow-simulator             Required assertion that the caller owns the one-simulator lease.
  Passive-only options:
  --fixture browse|player|offline  Debug fixture kind. Default: browse.
  --launch-arg ARG              Extra fixture launch argument (repeatable). Only --ui-testing-*
                                flags and their plain values are accepted.
  --skip-build                  Reuse this platform's last agent build (still installs and
                                verifies the installed executable).
  --duo-display outer|inner     iPhone Duo only. outer (default) captures the folded 1398x2034
                                display; inner starts a 669x951-point appResize session and
                                captures the Resizable display as the inner-display proxy.

Exit codes: 0 passed, 1 failed, 2 blocked/precondition missing.
USAGE
}

platform=${1:-}
scenario=${2:-}
if [[ $platform == -h || $platform == --help || -z $platform ]]; then usage; exit 0; fi
[[ $platform == iphone || $platform == iphone69 || $platform == ipad || $platform == duo ]] || {
  usage >&2; exit 2;
}
[[ $scenario == fixture-home-passive || $scenario == fixture-detail-semantic ]] || {
  usage >&2; exit 2;
}
shift 2

backend=plex
duration=5
artifact_root=artifacts/agent-platform-runs
allow_simulator=0
keep_booted=0
status_bar_overridden=0
fixture=browse
extra_launch_args=()
skip_build=0
duo_display=outer
appresize_pid=
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:-}; shift 2 ;;
    --launch-arg) extra_launch_args+=("${2:-}"); shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --duo-display) duo_display=${2:-}; shift 2 ;;
    --backend) backend=${2:-}; shift 2 ;;
    --duration) duration=${2:-}; shift 2 ;;
    --artifact-root) artifact_root=${2:-}; shift 2 ;;
    --allow-simulator) allow_simulator=1; shift ;;
    --keep-booted) keep_booted=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $backend == plex || $backend == jellyfin || $backend == emby ]] || {
  printf 'Unsupported backend: %s\n' "$backend" >&2; exit 2;
}
[[ $fixture == browse || $fixture == player || $fixture == offline ]] || {
  printf 'Unsupported fixture: %s\n' "$fixture" >&2; exit 2;
}
for arg in ${extra_launch_args[@]+"${extra_launch_args[@]}"}; do
  [[ $arg =~ ^--ui-testing-[a-z0-9-]+$ || $arg =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Rejected launch argument: %s\n' "$arg" >&2; exit 2;
  }
  [[ $arg != --ui-testing-backend && $arg != --ui-testing-fixture ]] || {
    printf 'Use --backend/--fixture instead of %s.\n' "$arg" >&2; exit 2;
  }
done
[[ $duo_display == outer || $duo_display == inner ]] || {
  printf 'Unsupported --duo-display: %s\n' "$duo_display" >&2; exit 2;
}
[[ $duo_display == outer || $platform == duo ]] || {
  printf '--duo-display inner requires the duo platform.\n' >&2; exit 2;
}
if [[ $scenario == fixture-detail-semantic ]] && {
  [[ $fixture != browse ]] || ((${#extra_launch_args[@]} > 0)) || ((skip_build == 1)) ||
  [[ $duo_display != outer ]]; }; then
  printf 'Fixture, launch-arg, skip-build and duo-display options apply to fixture-home-passive only.\n' >&2
  exit 2
fi
[[ $duration =~ ^[1-9][0-9]*$ ]] || { printf 'Duration must be a positive integer.\n' >&2; exit 2; }
((allow_simulator == 1)) || {
  printf 'Refusing to boot a simulator without --allow-simulator (lease assertion).\n' >&2
  exit 2
}

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
# Hold the same host lease across build/install/UI/teardown, not just compilation.
if ! python3 "$repo_root/scripts/xcodebuild-lease.py" held; then
  exec python3 "$repo_root/scripts/xcodebuild-lease.py" run --lane agent-mobile-run -- "$repo_root/scripts/agent-mobile-run.sh" "${lease_original_args[@]}"
fi
simid=$(scripts/worktree-sim.sh --platform "$platform" id) || {
  printf 'No worktree-owned %s simulator. Run worktree-sim setup only after acquiring the lease.\n' "$platform" >&2
  exit 2
}

foreign_booted=$(SIMID="$simid" python3 - <<'PY'
import json, os, subprocess
data=json.loads(subprocess.check_output(["xcrun","simctl","list","devices","--json"]))
wanted=os.environ["SIMID"]
print(" ".join(d["udid"] for devices in data["devices"].values() for d in devices
               if d.get("state") == "Booted" and d.get("udid") != wanted))
PY
)
[[ -z $foreign_booted ]] || {
  printf 'Another simulator is booted; lease invariant violated: %s\n' "$foreign_booted" >&2
  exit 2
}

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log_start=$(date '+%Y-%m-%d %H:%M:%S')
outdir="$artifact_root/$timestamp-$platform-$scenario-$backend"
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd -P)
derived_data="$repo_root/build/DerivedData-agent-$platform"
video_pid=
status=failed
result_code=1
app_path=
app_pid=
test_result=
test_summary=
attachments_dir=

# iPhone Duo: a plain screenshot targets the inner LCD-1, which is black while folded. The outer
# display's device name is `primary`; the appResize session renders on `resizable`.
capture_display=
if [[ $platform == duo ]]; then
  # The Resizable display exists only while an appResize session runs, so inner-proxy runs capture
  # the outer display until the session starts (below) and switch to `resizable` afterwards.
  capture_display=primary
fi
fixture_launch_args=(--ui-testing --ui-testing-backend "$backend" --ui-testing-fixture "$fixture"
  ${extra_launch_args[@]+"${extra_launch_args[@]}"})

bounded_screenshot() {
  local destination=$1
  SIMID="$simid" DESTINATION="$destination" DISPLAY_NAME="$capture_display" python3 - <<'PY'
import os, subprocess, sys
display = ["--display=" + os.environ["DISPLAY_NAME"]] if os.environ["DISPLAY_NAME"] else []
try:
    result = subprocess.run(
        ["xcrun", "simctl", "io", os.environ["SIMID"], "screenshot", *display, os.environ["DESTINATION"]],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15,
    )
except subprocess.TimeoutExpired as error:
    output = error.stdout or ""
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="replace")
    sys.stdout.write(output)
    print("screenshot timed out after 15 seconds")
    raise SystemExit(1)
sys.stdout.write(result.stdout)
raise SystemExit(result.returncode)
PY
}

write_result() {
  OUTDIR="$outdir" PLATFORM="$platform" SCENARIO="$scenario" BACKEND="$backend" \
  STATUS="$status" RESULT_CODE="$result_code" SIMID="$simid" STARTED_AT="$started_at" \
  APP_PATH="$app_path" APP_PID="$app_pid" COMMIT="$(git rev-parse HEAD)" \
  FIXTURE="$fixture" DUO_DISPLAY="$duo_display" \
  LAUNCH_ARGS="$(printf '%s\n' "${fixture_launch_args[@]}")" python3 - <<'PY'
import json, os
out=os.environ["OUTDIR"]
artifacts={
  "screenStart": f"{out}/screen-start.png",
  "screenEnd": f"{out}/screen-end.png",
  "screenRecording": f"{out}/screen-recording.mp4",
  "appLog": f"{out}/app.log",
  "simulatorLog": f"{out}/simulator.log",
  "buildLog": f"{out}/xcodebuild.log",
  "installLog": f"{out}/install.log",
  "launchLog": f"{out}/launch.log",
  "terminateLog": f"{out}/terminate.log",
}
payload={
  "schemaVersion": 1,
  "platform": os.environ["PLATFORM"],
  "scenario": os.environ["SCENARIO"],
  "backend": os.environ["BACKEND"],
  "status": os.environ["STATUS"],
  "exitCode": int(os.environ["RESULT_CODE"]),
  "simulatorUDID": os.environ["SIMID"],
  "commit": os.environ["COMMIT"],
  "startedAt": os.environ["STARTED_AT"],
  "appPath": os.environ["APP_PATH"],
  "appPID": int(os.environ["APP_PID"]) if os.environ["APP_PID"].isdigit() else None,
  "driver": ("xcuitest-accessibility" if os.environ["SCENARIO"] == "fixture-detail-semantic"
             else "simctl-passive-fixture"),
  "nextSemanticDriver": "xcode-device-interaction",
  "fixture": os.environ["FIXTURE"],
  "launchArguments": os.environ["LAUNCH_ARGS"].splitlines(),
  "semanticTargets": {
    "fixtureRoot": "labstream.fixture.browse.root",
    "firstHomeItem": f"labstream.home.fixture-resume.{os.environ['BACKEND']}-orbit",
    "detailText": "Some signals should stay distant.",
  },
  "artifacts": artifacts,
}
if os.environ["PLATFORM"] == "duo":
  payload["duoDisplay"] = os.environ["DUO_DISPLAY"]
if os.environ["SCENARIO"] == "fixture-detail-semantic":
  payload["testResult"] = f"{out}/Test.xcresult"
  payload["testSummary"] = f"{out}/test-summary.json"
  payload["attachments"] = f"{out}/attachments"
  try:
    with open(payload["testSummary"]) as handle:
      summary = json.load(handle)
    payload["assertions"] = {
      "result": summary.get("result"),
      "passedTests": summary.get("passedTests"),
      "failedTests": summary.get("failedTests"),
    }
  except (OSError, json.JSONDecodeError):
    payload["assertions"] = None
with open(f"{out}/run.json", "w") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

cleanup() {
  local ec=$?
  if [[ -n ${appresize_pid:-} ]] && kill -0 "$appresize_pid" 2>/dev/null; then
    kill -INT "$appresize_pid" 2>/dev/null || true
    wait "$appresize_pid" 2>/dev/null || true
  fi
  if [[ -n ${video_pid:-} ]] && kill -0 "$video_pid" 2>/dev/null; then
    kill -INT "$video_pid" 2>/dev/null || true
    wait "$video_pid" 2>/dev/null || true
  fi
  xcrun simctl spawn "$simid" log show --start "$log_start" --style compact \
    --predicate 'process == "Labstream"' >"$outdir/app.log" 2>&1 || true
  xcrun simctl spawn "$simid" log show --last 30s --style compact \
    --predicate 'process == "SpringBoard" OR eventMessage CONTAINS[c] "Labstream"' \
    >"$outdir/simulator.log" 2>&1 || true
  if [[ ! -s $outdir/screen-end.png ]]; then
    bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1 || true
  fi
  if ((status_bar_overridden == 1)); then
    xcrun simctl status_bar "$simid" clear >/dev/null 2>&1 || true
  fi
  if ((keep_booted == 0)); then xcrun simctl shutdown "$simid" >/dev/null 2>&1 || true; fi
  if ((ec != 0)) && ((result_code == 0)); then result_code=$ec; status=failed; fi
  write_result
}
trap cleanup EXIT

xcrun simctl boot "$simid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simid" -b >/dev/null
if xcrun simctl status_bar "$simid" override --time 09:41 \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName '' \
    --batteryState charged --batteryLevel 100 >/dev/null 2>&1; then
  status_bar_overridden=1
fi

if [[ $scenario == fixture-detail-semantic ]]; then
  test_result="$outdir/Test.xcresult"
  test_summary="$outdir/test-summary.json"
  attachments_dir="$outdir/attachments"
  bounded_screenshot "$outdir/screen-start.png" >"$outdir/screenshot.log" 2>&1
  xcrun simctl io "$simid" recordVideo "$outdir/screen-recording.mp4" \
    >"$outdir/record-video.log" 2>&1 &
  video_pid=$!
  set +e
  scripts/run-bounded-command.py --timeout 300 --output "$outdir/xcodebuild.log" -- \
    scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMobile \
    -testPlan LabstreamTests -destination "platform=iOS Simulator,id=$simid" \
    -derivedDataPath "$derived_data-ui" -resultBundlePath "$test_result" \
    -only-testing:LabstreamMobileUITests/LabstreamMobileFixtureUITests/testFixtureHomeOpensDetailSemantically \
    test CODE_SIGNING_ALLOWED=NO -enableCodeCoverage NO
  test_code=$?
  set -e
  kill -INT "$video_pid" 2>/dev/null || true
  wait "$video_pid" 2>/dev/null || true
  video_pid=
  bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1 || true
  if [[ -d $test_result ]]; then
    xcrun xcresulttool get test-results summary --path "$test_result" \
      >"$test_summary" 2>"$outdir/xcresult-summary.log" || true
    mkdir -p "$attachments_dir"
    xcrun xcresulttool export attachments --path "$test_result" --output-path "$attachments_dir" \
      >"$outdir/xcresult-attachments.log" 2>&1 || true
  fi
  app_path="$derived_data-ui/Build/Products/Debug-iphonesimulator/Labstream.app"
  [[ $test_code -eq 0 && -s $test_summary && -s $outdir/screen-recording.mp4 ]] || {
    result_code=$test_code
    ((result_code != 0)) || result_code=1
    exit "$result_code"
  }
  TEST_SUMMARY="$test_summary" python3 - <<'PY'
import json, os
with open(os.environ["TEST_SUMMARY"]) as handle:
    summary = json.load(handle)
if summary.get("result") != "Passed" or summary.get("failedTests") != 0 or summary.get("passedTests") != 1:
    raise SystemExit(1)
PY
  status=passed
  result_code=0
  printf 'PASS: %s\n' "$outdir"
  exit 0
fi

if ((skip_build == 0)); then
  # Clean DerivedData so the Ld step cannot be skipped (see CLAUDE.md LINK-SKIP TRAP).
  rm -rf "$derived_data"
  scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMobile \
    -configuration Debug -destination "platform=iOS Simulator,id=$simid" \
    -derivedDataPath "$derived_data" build CODE_SIGNING_ALLOWED=NO \
    >"$outdir/xcodebuild.log" 2>&1
else
  printf 'skip-build: reusing %s\n' "$derived_data" >"$outdir/xcodebuild.log"
fi

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Labstream.app"
[[ -x $app_path/Labstream ]] || { printf 'Built app missing: %s\n' "$app_path" >&2; result_code=2; exit 2; }
xcrun simctl install "$simid" "$app_path" >"$outdir/install.log" 2>&1
installed_app=$(xcrun simctl get_app_container "$simid" org.labstream.Labstream app)
built_uuid=$(xcrun dwarfdump --uuid "$app_path/Labstream" | awk '{print $2}')
installed_uuid=$(xcrun dwarfdump --uuid "$installed_app/Labstream" | awk '{print $2}')
[[ -n $built_uuid && $built_uuid == "$installed_uuid" ]] || {
  printf 'Installed executable does not match built product.\n' >&2; exit 1;
}

bounded_screenshot "$outdir/screen-start.png" >"$outdir/screenshot.log" 2>&1
record_display=(${capture_display:+"--display=$capture_display"})
xcrun simctl io "$simid" recordVideo ${record_display[@]+"${record_display[@]}"} \
  "$outdir/screen-recording.mp4" >"$outdir/record-video.log" 2>&1 &
video_pid=$!
xcrun simctl terminate "$simid" org.labstream.Labstream >/dev/null 2>&1 || true
xcrun simctl launch "$simid" org.labstream.Labstream "${fixture_launch_args[@]}" \
  >"$outdir/launch.log" 2>&1
app_pid=$(awk -F': ' '/org\.labstream\.Labstream:/{print $2}' "$outdir/launch.log" | tail -1)
if [[ $platform == duo && $duo_display == inner ]]; then
  # Inner-display proxy: 669x951 points at 3x is Apple's 2007x2853 inner screenshot size. The app
  # must be portrait and frontmost when the session starts, so start it immediately after launch.
  sleep 2
  xcrun devicectl device appResize start --device "$simid" --preferred-size 669x951 \
    >"$outdir/appresize.log" 2>&1 &
  appresize_pid=$!
  sleep 3
  capture_display=resizable
fi
sleep "$duration"
[[ $app_pid =~ ^[0-9]+$ ]] || { printf 'Launch did not return an app PID.\n' >&2; exit 1; }

kill -INT "$video_pid" 2>/dev/null || true
wait "$video_pid" 2>/dev/null || true
video_pid=
bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1
[[ -s $outdir/screen-start.png && -s $outdir/screen-end.png && -s $outdir/screen-recording.mp4 ]]
# `kill` is not an executable in current iOS simulator runtimes, so a `simctl spawn ... kill -0`
# liveness probe fails with LaunchdSimError 111 even while the app is healthy. A successful exact-
# bundle termination after capture proves the launched process was still registered without relying
# on unavailable guest utilities.
xcrun simctl terminate "$simid" org.labstream.Labstream >"$outdir/terminate.log" 2>&1

status=passed
result_code=0
printf 'PASS: %s\n' "$outdir"
