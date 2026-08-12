#!/usr/bin/env bash
# Bounded, credential-free native macOS fixture scenario.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/agent-macos-run.sh fixture-detail [options]

Options:
  --artifact-root PATH  Default: artifacts/agent-platform-runs.
  --timeout SECONDS     AX target/assertion timeout. Default: 15.
  --skip-build          Reuse this worktree's staged isolated app.

Exit codes: 0 passed, 1 failed, 2 blocked/precondition missing.
USAGE
}

scenario=${1:-}
if [[ -z $scenario || $scenario == -h || $scenario == --help ]]; then usage; exit 0; fi
[[ $scenario == fixture-detail ]] || { usage >&2; exit 2; }
shift

artifact_root=artifacts/agent-platform-runs
timeout=15
skip_build=0
while (($#)); do
  case "$1" in
    --artifact-root) artifact_root=${2:-}; shift 2 ;;
    --timeout) timeout=${2:-}; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $timeout =~ ^[1-9][0-9]*$ ]] && ((timeout <= 60)) || {
  printf 'Timeout must be an integer from 1 through 60.\n' >&2; exit 2;
}

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log_start=$(date '+%Y-%m-%d %H:%M:%S')
outdir="$artifact_root/$timestamp-macos-$scenario"
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd -P)
suffix="agent-fixture-$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print substr($1,1,8)}')"
app_pid=
app_path=
status=failed
result_code=1

write_result() {
  OUTDIR="$outdir" STATUS="$status" RESULT_CODE="$result_code" STARTED_AT="$started_at" \
  APP_PATH="$app_path" APP_PID="$app_pid" SCENARIO="$scenario" COMMIT="$(git rev-parse HEAD)" \
  python3 - <<'PY'
import json, os
out = os.environ["OUTDIR"]
driver_path = f"{out}/driver.json"
driver = None
if os.path.exists(driver_path):
    try:
        with open(driver_path) as handle:
            driver = json.load(handle)
    except (OSError, json.JSONDecodeError):
        pass
payload = {
    "schemaVersion": 1,
    "platform": "macos",
    "scenario": os.environ["SCENARIO"],
    "status": os.environ["STATUS"],
    "exitCode": int(os.environ["RESULT_CODE"]),
    "commit": os.environ["COMMIT"],
    "startedAt": os.environ["STARTED_AT"],
    "appPath": os.environ["APP_PATH"],
    "appPID": int(os.environ["APP_PID"]) if os.environ["APP_PID"].isdigit() else None,
    "driver": "macos-accessibility",
    "credentialPolicy": "synthetic-fixture-only",
    "driverResult": driver,
    "artifacts": {
        "screenBefore": f"{out}/screen-before.png",
        "screenAfter": f"{out}/screen-after.png",
        "appLog": f"{out}/app.log",
        "processLog": f"{out}/process.log",
        "buildLog": f"{out}/deploy.log",
        "driverResult": driver_path,
    },
}
with open(f"{out}/run.json", "w") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

cleanup() {
  local ec=$?
  if [[ -n ${app_pid:-} ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    for _ in {1..20}; do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$app_pid" 2>/dev/null || true
  fi
  /usr/bin/log show --start "$log_start" --style compact \
    --predicate 'process == "Labstream" OR subsystem == "com.jlipworth.Labstream"' \
    >"$outdir/app.log" 2>&1 || true
  if ((ec != 0)) && ((result_code == 0)); then result_code=$ec; status=failed; fi
  write_result
}
trap cleanup EXIT

deploy_args=(--bundle-id-suffix "$suffix")
((skip_build == 0)) || deploy_args+=(--no-build)
scripts/deploy-macos-to-host.sh "${deploy_args[@]}" >"$outdir/deploy.log" 2>&1 || {
  tail -60 "$outdir/deploy.log" >&2 || true
  exit 1
}
app_path=$(awk -F'app:[[:space:]]+' '/^app:/ {print $2}' "$outdir/deploy.log" | tail -1)
[[ -d $app_path ]] || { printf 'Could not resolve staged app.\n' >&2; result_code=2; exit 2; }
executable="$app_path/Contents/MacOS/Labstream"
[[ -x $executable ]] || { printf 'Staged executable is missing.\n' >&2; result_code=2; exit 2; }

xcrun swiftc scripts/agent-macos-ax-driver.swift -o "$repo_root/build/agent-macos-ax-driver"
pkill -f "^$executable( |$)" >/dev/null 2>&1 || true
open -n "$app_path" --args --ui-testing --ui-testing-backend plex --ui-testing-fixture browse \
  >"$outdir/process.log" 2>&1
for _ in {1..100}; do
  app_pid=$(ps -axo pid=,command= | awk -v executable="$executable" \
    '$2 == executable && !found {value=$1; found=1} END {if (found) print value}')
  [[ -n $app_pid ]] && break
  sleep 0.1
done
[[ $app_pid =~ ^[0-9]+$ ]] && kill -0 "$app_pid" 2>/dev/null || {
  printf 'App did not register a running process.\n' >&2; result_code=2; exit 2;
}
running_command=$(ps -p "$app_pid" -o command= || true)
[[ $running_command == "$executable"* ]] || { printf 'PID does not match staged executable.\n' >&2; exit 1; }

set +e
"$repo_root/build/agent-macos-ax-driver" --pid "$app_pid" --output "$outdir/driver.json" \
  --screenshot-before "$outdir/screen-before.png" \
  --screenshot-after "$outdir/screen-after.png" --timeout "$timeout"
driver_code=$?
set -e
if ((driver_code != 0)); then
  result_code=$driver_code
  [[ $driver_code -eq 2 ]] && status=blocked
  exit "$driver_code"
fi

[[ -s $outdir/screen-before.png && -s $outdir/screen-after.png ]] || exit 1
status=passed
result_code=0
printf 'PASS: %s\n' "$outdir"
