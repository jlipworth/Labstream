#!/usr/bin/env bash
# Bounded credential-free iPhone/iPad agent scenario runner.
#
# This is the durable repo-side half of the Xcode 27 Device Interaction loop: it proves the exact
# product can build, install, launch into deterministic fixture state, and emit an evidence bundle.
# Semantic hierarchy inspection and interaction can then attach to the same fixture launch without
# depending on a user's backend account. Never run without the repository's simulator lease.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/agent-mobile-run.sh <iphone|ipad> fixture-home-passive --allow-simulator [options]

Options:
  --backend plex|jellyfin|emby  Synthetic browse lane. Default: plex.
  --duration SECONDS            Recording/settle time after launch. Default: 5.
  --artifact-root PATH          Default: artifacts/agent-platform-runs.
  --keep-booted                 Leave the leased simulator booted after the run.
  --allow-simulator             Required assertion that the caller owns the one-simulator lease.

Exit codes: 0 passed, 1 failed, 2 blocked/precondition missing.
USAGE
}

platform=${1:-}
scenario=${2:-}
if [[ $platform == -h || $platform == --help || -z $platform ]]; then usage; exit 0; fi
[[ $platform == iphone || $platform == ipad ]] || { usage >&2; exit 2; }
[[ $scenario == fixture-home-passive ]] || { usage >&2; exit 2; }
shift 2

backend=plex
duration=5
artifact_root=artifacts/agent-platform-runs
allow_simulator=0
keep_booted=0
while (($#)); do
  case "$1" in
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
[[ $duration =~ ^[1-9][0-9]*$ ]] || { printf 'Duration must be a positive integer.\n' >&2; exit 2; }
((allow_simulator == 1)) || {
  printf 'Refusing to boot a simulator without --allow-simulator (lease assertion).\n' >&2
  exit 2
}

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
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
outdir="$artifact_root/$timestamp-$platform-$scenario-$backend"
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd -P)
derived_data="$repo_root/build/DerivedData-agent-$platform"
video_pid=
status=failed
result_code=1
app_path=
app_pid=

bounded_screenshot() {
  local destination=$1
  SIMID="$simid" DESTINATION="$destination" python3 - <<'PY'
import os, subprocess, sys
try:
    result = subprocess.run(
        ["xcrun", "simctl", "io", os.environ["SIMID"], "screenshot", os.environ["DESTINATION"]],
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
  APP_PATH="$app_path" APP_PID="$app_pid" COMMIT="$(git rev-parse HEAD)" python3 - <<'PY'
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
  "driver": "simctl-passive-fixture",
  "nextSemanticDriver": "xcode-device-interaction",
  "launchArguments": ["--ui-testing", "--ui-testing-backend", os.environ["BACKEND"],
                      "--ui-testing-fixture", "browse"],
  "semanticTargets": {
    "fixtureRoot": "labstream.fixture.browse.root",
    "firstHomeItem": f"labstream.home.fixture-resume.{os.environ['BACKEND']}-orbit",
    "detailText": "Some signals should stay distant.",
  },
  "artifacts": artifacts,
}
with open(f"{out}/run.json", "w") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
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
    --predicate 'process == "SpringBoard" OR eventMessage CONTAINS[c] "Labstream"' \
    >"$outdir/simulator.log" 2>&1 || true
  if [[ ! -s $outdir/screen-end.png ]]; then
    bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1 || true
  fi
  if ((keep_booted == 0)); then xcrun simctl shutdown "$simid" >/dev/null 2>&1 || true; fi
  if ((ec != 0)) && ((result_code == 0)); then result_code=$ec; status=failed; fi
  write_result
}
trap cleanup EXIT

xcrun simctl boot "$simid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simid" -b >/dev/null

scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMobile \
  -configuration Debug -destination "platform=iOS Simulator,id=$simid" \
  -derivedDataPath "$derived_data" clean build CODE_SIGNING_ALLOWED=NO \
  >"$outdir/xcodebuild.log" 2>&1

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Labstream.app"
[[ -x $app_path/Labstream ]] || { printf 'Built app missing: %s\n' "$app_path" >&2; result_code=2; exit 2; }
xcrun simctl install "$simid" "$app_path" >"$outdir/install.log" 2>&1
installed_app=$(xcrun simctl get_app_container "$simid" com.jlipworth.Labstream app)
built_uuid=$(xcrun dwarfdump --uuid "$app_path/Labstream" | awk '{print $2}')
installed_uuid=$(xcrun dwarfdump --uuid "$installed_app/Labstream" | awk '{print $2}')
[[ -n $built_uuid && $built_uuid == "$installed_uuid" ]] || {
  printf 'Installed executable does not match built product.\n' >&2; exit 1;
}

bounded_screenshot "$outdir/screen-start.png" >"$outdir/screenshot.log" 2>&1
xcrun simctl io "$simid" recordVideo "$outdir/screen-recording.mp4" >"$outdir/record-video.log" 2>&1 &
video_pid=$!
xcrun simctl terminate "$simid" com.jlipworth.Labstream >/dev/null 2>&1 || true
xcrun simctl launch "$simid" com.jlipworth.Labstream \
  --ui-testing --ui-testing-backend "$backend" --ui-testing-fixture browse \
  >"$outdir/launch.log" 2>&1
app_pid=$(awk -F': ' '/com\.jlipworth\.Labstream:/{print $2}' "$outdir/launch.log" | tail -1)
sleep "$duration"
[[ $app_pid =~ ^[0-9]+$ ]] && xcrun simctl spawn "$simid" /bin/kill -0 "$app_pid"

kill -INT "$video_pid" 2>/dev/null || true
wait "$video_pid" 2>/dev/null || true
video_pid=
bounded_screenshot "$outdir/screen-end.png" >>"$outdir/screenshot.log" 2>&1
[[ -s $outdir/screen-start.png && -s $outdir/screen-end.png && -s $outdir/screen-recording.mp4 ]]

status=passed
result_code=0
printf 'PASS: %s\n' "$outdir"
