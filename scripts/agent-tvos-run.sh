#!/usr/bin/env bash
# Bounded, credential-free tvOS XCUITest/XCUIRemote evidence runner.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/agent-tvos-run.sh <scenario> --allow-simulator [options]

Scenarios:
  fixture-home-semantic  Launch and drive the synthetic Home-to-detail journey.
  fixture-player-basic   Exercise deterministic local playback chrome and Back behavior.

Options:
  --artifact-root PATH  Default: artifacts/agent-platform-runs.
  --keep-booted         Leave the leased simulator booted after the run.
  --allow-simulator     Required assertion that the caller owns the one-simulator lease.

Exit codes: 0 passed, 1 failed, 2 blocked/precondition missing.
USAGE
}

scenario=${1:-}
if [[ -z $scenario || $scenario == -h || $scenario == --help ]]; then usage; exit 0; fi
[[ $scenario == fixture-home-semantic || $scenario == fixture-player-basic ]] || {
  usage >&2; exit 2;
}
shift

artifact_root=artifacts/agent-platform-runs
allow_simulator=0
keep_booted=0
while (($#)); do
  case "$1" in
    --artifact-root) artifact_root=${2:-}; shift 2 ;;
    --allow-simulator) allow_simulator=1; shift ;;
    --keep-booted) keep_booted=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
((allow_simulator == 1)) || {
  printf 'Refusing to boot a simulator without --allow-simulator (lease assertion).\n' >&2
  exit 2
}

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
simid=$(scripts/worktree-sim.sh --platform tvos id) || {
  printf 'No worktree-owned tvOS simulator. Acquire the lease before setup.\n' >&2
  exit 2
}
foreign_booted=$(SIMID="$simid" python3 - <<'PY'
import json, os, subprocess
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
wanted = os.environ["SIMID"]
print(" ".join(device["udid"] for devices in data["devices"].values() for device in devices
               if device.get("state") == "Booted" and device.get("udid") != wanted))
PY
)
[[ -z $foreign_booted ]] || {
  printf 'Another simulator is booted; lease invariant violated: %s\n' "$foreign_booted" >&2
  exit 2
}

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
outdir="$artifact_root/$timestamp-tvos-$scenario"
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd -P)
derived_data="$repo_root/build/DerivedData-agent-tvos-ui"
result_bundle="$outdir/Test.xcresult"
video_pid=
status=failed
result_code=1

bounded_screenshot() {
  SIMID="$simid" DESTINATION="$1" python3 - <<'PY'
import os, subprocess, sys
try:
    result = subprocess.run(
        ["xcrun", "simctl", "io", os.environ["SIMID"], "screenshot", os.environ["DESTINATION"]],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15,
    )
except subprocess.TimeoutExpired:
    print("screenshot timed out after 15 seconds")
    raise SystemExit(1)
sys.stdout.write(result.stdout)
raise SystemExit(result.returncode)
PY
}

write_result() {
  OUTDIR="$outdir" STATUS="$status" RESULT_CODE="$result_code" SCENARIO="$scenario" \
    SIMID="$simid" STARTED_AT="$started_at" COMMIT="$(git rev-parse HEAD)" python3 - <<'PY'
import json, os
out = os.environ["OUTDIR"]
summary = None
try:
    with open(f"{out}/test-summary.json") as handle:
        summary = json.load(handle)
except (OSError, json.JSONDecodeError):
    pass
payload = {
    "schemaVersion": 1,
    "platform": "tvos",
    "scenario": os.environ["SCENARIO"],
    "status": os.environ["STATUS"],
    "exitCode": int(os.environ["RESULT_CODE"]),
    "simulatorUDID": os.environ["SIMID"],
    "commit": os.environ["COMMIT"],
    "startedAt": os.environ["STARTED_AT"],
    "driver": "xcuitest-xcuiremote",
    "credentialPolicy": "synthetic-fixture-only",
    "assertions": None if summary is None else {
        "result": summary.get("result"),
        "passedTests": summary.get("passedTests"),
        "failedTests": summary.get("failedTests"),
    },
    "artifacts": {
        "screenStart": f"{out}/screen-start.png",
        "screenEnd": f"{out}/screen-end.png",
        "screenRecording": f"{out}/screen-recording.mp4",
        "appLog": f"{out}/app.log",
        "simulatorLog": f"{out}/simulator.log",
        "buildLog": f"{out}/xcodebuild.log",
        "testResult": f"{out}/Test.xcresult",
        "testSummary": f"{out}/test-summary.json",
        "attachments": f"{out}/attachments",
    },
}
with open(f"{out}/run.json", "w") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

cleanup() {
  local ec=$?
  if [[ -n ${video_pid:-} ]] && kill -0 "$video_pid" 2>/dev/null; then
    kill -INT "$video_pid" 2>/dev/null || true
    wait "$video_pid" 2>/dev/null || true
  fi
  xcrun simctl spawn "$simid" log show --start "$started_at" --style compact \
    --predicate 'process == "Labstream"' >"$outdir/app.log" 2>&1 || true
  xcrun simctl spawn "$simid" log show --last 30s --style compact \
    --predicate 'process == "PineBoard" OR eventMessage CONTAINS[c] "Labstream"' \
    >"$outdir/simulator.log" 2>&1 || true
  [[ -s $outdir/screen-end.png ]] || bounded_screenshot "$outdir/screen-end.png" \
    >>"$outdir/screenshot.log" 2>&1 || true
  ((keep_booted == 1)) || xcrun simctl shutdown "$simid" >/dev/null 2>&1 || true
  if ((ec != 0)) && ((result_code == 0)); then result_code=$ec; status=failed; fi
  write_result
}
trap cleanup EXIT

xcrun simctl boot "$simid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simid" -b >/dev/null
bounded_screenshot "$outdir/screen-start.png" >"$outdir/screenshot.log" 2>&1
xcrun simctl io "$simid" recordVideo "$outdir/screen-recording.mp4" \
  >"$outdir/record-video.log" 2>&1 &
video_pid=$!

selectors=()
expected_passes=2
if [[ $scenario == fixture-home-semantic ]]; then
  selectors+=(
    -only-testing:LabstreamTVUITests/LabstreamTVLaunchTests/testAppLaunches
    -only-testing:LabstreamTVUITests/LabstreamTVLaunchTests/testRemoteBrowsesFromFixtureHomeIntoDetailAndBack
  )
else
  selectors+=(
    -only-testing:LabstreamTVUITests/LabstreamTVPlayerTests/testDirectionalPressRevealsHiddenChrome
    -only-testing:LabstreamTVUITests/LabstreamTVPlayerTests/testBackExitsPlayback
  )
fi

set +e
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamTV \
  -testPlan LabstreamTVUITests -destination "platform=tvOS Simulator,id=$simid" \
  -derivedDataPath "$derived_data" -resultBundlePath "$result_bundle" \
  "${selectors[@]}" test CODE_SIGNING_ALLOWED=NO -enableCodeCoverage NO \
  >"$outdir/xcodebuild.log" 2>&1
test_code=$?
set -e
kill -INT "$video_pid" 2>/dev/null || true
wait "$video_pid" 2>/dev/null || true
video_pid=
bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1 || true

if [[ -d $result_bundle ]]; then
  xcrun xcresulttool get test-results summary --path "$result_bundle" \
    >"$outdir/test-summary.json" 2>"$outdir/xcresult-summary.log" || true
  mkdir -p "$outdir/attachments"
  xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$outdir/attachments" \
    >"$outdir/xcresult-attachments.log" 2>&1 || true
fi
[[ $test_code -eq 0 && -s $outdir/test-summary.json && -s $outdir/screen-recording.mp4 ]] || {
  result_code=$test_code
  ((result_code != 0)) || result_code=1
  exit "$result_code"
}
TEST_SUMMARY="$outdir/test-summary.json" EXPECTED_PASSES="$expected_passes" python3 - <<'PY'
import json, os
with open(os.environ["TEST_SUMMARY"]) as handle:
    summary = json.load(handle)
if (summary.get("result") != "Passed" or summary.get("failedTests") != 0
        or summary.get("passedTests") != int(os.environ["EXPECTED_PASSES"])):
    raise SystemExit(1)
PY

status=passed
result_code=0
printf 'PASS: %s\n' "$outdir"
