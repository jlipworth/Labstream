#!/usr/bin/env bash
set -euo pipefail

# Bounded native-macOS launch smoke for issue #228.
#
# This deliberately uses an isolated dev bundle id by default so it can launch to the
# signed-out/auth screen without touching a normal worktree's Mac app container or keychain
# service. It does not validate real auth, playback, downloads, or subjective UI quality.
#
# Do not reset the sandbox container by default: macOS may protect container-manager
# metadata even when the app data is otherwise throwaway, and a reset failure would make
# this smoke flaky. Override LABSTREAM_MAC_SMOKE_SUFFIX for a fresh identity if needed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SUFFIX="${LABSTREAM_MAC_SMOKE_SUFFIX:-macos-228-smoke}"
DURATION_SECONDS="${LABSTREAM_MAC_SMOKE_SECONDS:-8}"
CANONICAL_BUNDLE_ID="org.labstream.Labstream"
EFFECTIVE_BUNDLE_ID="$CANONICAL_BUNDLE_ID.dev.$SUFFIX"
LOG_DIR="$ROOT/build/validation/macos-228"
mkdir -p "$LOG_DIR"

die() {
  echo "smoke-macos-host: $*" >&2
  exit 1
}

echo "smoke bundle: $EFFECTIVE_BUNDLE_ID"
echo "duration:     ${DURATION_SECONDS}s"

DEPLOY_LOG="$LOG_DIR/macos-smoke-deploy.log"
scripts/deploy-macos-to-host.sh \
  --bundle-id-suffix "$SUFFIX" >"$DEPLOY_LOG" 2>&1 || {
    tail -80 "$DEPLOY_LOG" >&2 || true
    die "Mac host build/stage failed (log: $DEPLOY_LOG)"
  }

STAGED_APP="$(awk -F'app:[[:space:]]+' '/^app:/ {print $2}' "$DEPLOY_LOG" | tail -1)"
[ -n "$STAGED_APP" ] || die "could not parse staged app path from $DEPLOY_LOG"
[ -d "$STAGED_APP" ] || die "staged app does not exist: $STAGED_APP"

echo "app:          $STAGED_APP"
echo "launching staged executable…"
EXECUTABLE="$STAGED_APP/Contents/MacOS/Labstream"
[ -x "$EXECUTABLE" ] || die "staged executable is missing or not executable: $EXECUTABLE"

RUN_LOG="$LOG_DIR/macos-smoke-process.log"
"$EXECUTABLE" >"$RUN_LOG" 2>&1 &
APP_PID="$!"

cleanup() {
  if kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

sleep "$DURATION_SECONDS"

if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
  tail -120 "$RUN_LOG" >&2 || true
  die "staged app process exited before launch window completed (process log: $RUN_LOG)"
fi

RUNNING_COMMAND="$(ps -p "$APP_PID" -o command= || true)"
case "$RUNNING_COMMAND" in
  "$EXECUTABLE"*) ;;
  *)
    echo "unexpected process command for pid $APP_PID: $RUNNING_COMMAND" >&2
    die "running process does not match staged executable $EXECUTABLE"
    ;;
esac

LOG_SNAPSHOT="$LOG_DIR/macos-smoke-log-show.log"
/usr/bin/log show --last 2m --style compact \
  --predicate "process == \"Labstream\" OR subsystem == \"org.labstream.Labstream\"" \
  >"$LOG_SNAPSHOT" 2>&1 || true

echo "running pid:  $APP_PID"
echo "process log:  $RUN_LOG"
echo "log snapshot: $LOG_SNAPSHOT"
echo "macOS host launch smoke passed."
