#!/usr/bin/env bash
# Run a live probe command, filter noisy output, and preserve the command's exit status.
set -u
if [[ $# -lt 2 ]]; then
  echo "usage: $0 <egrep-pattern> <command> [args...]" >&2
  exit 64
fi
pattern="$1"
shift
set +e
"$@" 2>&1 | grep -E "$pattern"
cmd_status=${PIPESTATUS[0]}
exit "$cmd_status"
