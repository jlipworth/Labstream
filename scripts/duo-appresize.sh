#!/usr/bin/env bash
# Headless iPhone Duo inner-display proxy for this worktree's Duo simulator.
#
# Folding cannot be driven headlessly (Device Hub's hinge control is GUI-only). This wrapper
# combines `devicectl device appResize` (a resizable app session at the inner-display size) with
# the app's DEBUG-only pose override (LABSTREAM_DEBUG_DUO_POSE) so book (951x669) and tabletop
# (669x951) layouts can be captured against the pose seam. Captures prove layout against the
# seam only; real Device Hub / hardware fold frames remain an open gate.
#
# Usage:
#   scripts/duo-appresize.sh launch [--pose book|tabletop|flat] [-- <extra app launch args>]
#       Terminate and relaunch the Debug app on the Duo sim, optionally with the pose override.
#   scripts/duo-appresize.sh start [--size WxH]     (default 669x951; app must be portrait+frontmost)
#       Start a resizable session in the background (pid in build/duo-appresize.pid).
#   scripts/duo-appresize.sh set WxH                e.g. 951x669 (book) or 669x951 (tabletop/upright)
#   scripts/duo-appresize.sh stop                   End the resizable session.
#   scripts/duo-appresize.sh shot PATH              Screenshot the Duo sim to PATH.
#
# The simulator must already be booted (and hold the one machine-wide simulator lease).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="org.labstream.Labstream"
PID_FILE="$ROOT/build/duo-appresize.pid"
LOG_FILE="$ROOT/build/duo-appresize.log"

die() { echo "duo-appresize: $*" >&2; exit 1; }

simid() {
  "$ROOT/scripts/worktree-sim.sh" --platform duo id
}

require_booted() {
  local id="$1"
  xcrun simctl list devices | grep -q "$id) (Booted)" || die "Duo simulator $id is not booted"
}

cmd="${1:-}"
[ -n "$cmd" ] || { sed -n '2,24p' "$0"; exit 2; }
shift

SIMID="$(simid)"
[ -n "$SIMID" ] || die "no Duo simulator for this worktree (run scripts/worktree-sim.sh --platform duo setup)"

case "$cmd" in
  launch)
    pose=""
    extra=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --pose) pose="${2:-}"; shift 2 ;;
        --) shift; extra=("$@"); break ;;
        *) die "unknown launch option: $1" ;;
      esac
    done
    require_booted "$SIMID"
    xcrun simctl terminate "$SIMID" "$BUNDLE_ID" 2>/dev/null || true
    if [ -n "$pose" ]; then
      case "$pose" in book|tabletop|flat) ;; *) die "--pose must be book, tabletop or flat" ;; esac
      SIMCTL_CHILD_LABSTREAM_DEBUG_DUO_POSE="$pose" \
        xcrun simctl launch "$SIMID" "$BUNDLE_ID" ${extra[@]+"${extra[@]}"}
    else
      xcrun simctl launch "$SIMID" "$BUNDLE_ID" ${extra[@]+"${extra[@]}"}
    fi
    ;;
  start)
    size="669x951"
    if [ "${1:-}" = "--size" ]; then size="${2:-}"; shift 2; fi
    require_booted "$SIMID"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      die "a resizable session is already running (pid $(cat "$PID_FILE"))"
    fi
    mkdir -p "$ROOT/build"
    nohup xcrun devicectl device appResize start --device "$SIMID" --preferred-size "$size" \
      >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    echo "started resizable session at $size (pid $(cat "$PID_FILE"), log $LOG_FILE)"
    ;;
  set)
    size="${1:-}"
    [ -n "$size" ] || die "usage: set WxH"
    xcrun devicectl device appResize set --device "$SIMID" --preferred-size "$size"
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      kill -INT "$(cat "$PID_FILE")" 2>/dev/null || true
      rm -f "$PID_FILE"
      echo "stopped resizable session"
    else
      echo "no resizable session recorded"
    fi
    ;;
  shot)
    path="${1:-}"
    [ -n "$path" ] || die "usage: shot PATH"
    xcrun simctl io "$SIMID" screenshot "$path"
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac
