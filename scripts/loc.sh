#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

count_dir() {
  local dir=$1
  local label=$2
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  local lines
  lines=$(find "$dir" -type f \
    \( -name '*.swift' -o -name '*.md' -o -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.yaml' \) \
    -not -path '*/.build/*' \
    -not -path '*/build/*' \
    -not -path '*/site/*' \
    -print0 | python3 -c '
import sys
from pathlib import Path
count = 0
for raw in sys.stdin.buffer.read().split(b"\0"):
    if not raw:
        continue
    path = Path(raw.decode())
    try:
        for line in path.read_text(errors="ignore").splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith(("//", "#")):
                count += 1
    except OSError:
        pass
print(count)
')
  printf '%-36s %8s\n' "$label" "$lines"
}

printf '%-36s %8s\n' 'Module' 'LOC'
printf '%-36s %8s\n' '------' '---'

for dir in Labstream/Shared/* Labstream/Capabilities/* Labstream/Platforms/*; do
  [[ -d "$dir" ]] || continue
  count_dir "$dir" "$dir"
done

for dir in PMSKit/Sources/PMSKit/*; do
  [[ -d "$dir" ]] || continue
  count_dir "$dir" "$dir"
done

count_dir PMSKit/Tests/PMSKitTests PMSKit/Tests/PMSKitTests
count_dir scripts scripts
count_dir docs docs
