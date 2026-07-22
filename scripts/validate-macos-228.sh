#!/usr/bin/env bash
set -euo pipefail

# Deterministic validation for issue #228's native macOS pass.
# This intentionally avoids real-auth/server/manual UI checks. It covers the checks that agents can
# run without user involvement and writes build logs under build/validation/macos-228/.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/build/validation/macos-228"
mkdir -p "$LOG_DIR"
cd "$ROOT"

log_step() { printf '\n==> %s\n' "$*"; }
run_logged() {
  local name="$1"; shift
  local log="$LOG_DIR/$name.log"
  printf 'log: %s\n' "$log"
  "$@" 2>&1 | tee "$log"
}

log_step "git diff whitespace check"
git diff --check

log_step "conflict-marker scan"
if rg -n '^(<<<<<<<|=======|>>>>>>>)' Labstream PMSKit scripts docs Config . --glob '!build/**' --glob '!*.xcuserstate'; then
  echo "conflict markers found" >&2
  exit 1
fi

log_step "Mac app icon asset check"
python3 - <<'PY'
import json
import struct
import sys
from pathlib import Path

root = Path("Labstream/Shared/Resources/Assets.xcassets/MacAppIcon.appiconset")
contents_path = root / "Contents.json"
expected = {
    ("16x16", "1x"): (16, 16),
    ("16x16", "2x"): (32, 32),
    ("32x32", "1x"): (32, 32),
    ("32x32", "2x"): (64, 64),
    ("128x128", "1x"): (128, 128),
    ("128x128", "2x"): (256, 256),
    ("256x256", "1x"): (256, 256),
    ("256x256", "2x"): (512, 512),
    ("512x512", "1x"): (512, 512),
    ("512x512", "2x"): (1024, 1024),
}

def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG with an IHDR header")
    return struct.unpack(">II", data[16:24])

try:
    contents = json.loads(contents_path.read_text())
    images = contents.get("images", [])
    seen = {}
    for image in images:
        if image.get("idiom") != "mac":
            continue
        key = (image.get("size"), image.get("scale"))
        filename = image.get("filename")
        if key not in expected:
            raise ValueError(f"unexpected Mac icon slot: {key}")
        if not filename:
            raise ValueError(f"Mac icon slot {key} has no filename")
        path = root / filename
        if not path.exists():
            raise FileNotFoundError(f"missing Mac icon file for {key}: {path}")
        actual = png_size(path)
        if actual != expected[key]:
            raise ValueError(f"{path} is {actual}, expected {expected[key]} for slot {key}")
        seen[key] = filename
    missing = sorted(set(expected) - set(seen))
    if missing:
        raise ValueError(f"missing Mac icon slots: {missing}")
except Exception as exc:
    print(f"Mac app icon validation failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

print("Mac app icon asset check passed.")
PY

log_step "Mac identity wiring static checks"
python3 - <<'PY'
from pathlib import Path
import sys

checks = [
    ("Config/Info.plist",
     ["LabstreamKeychainService", "$(LABSTREAM_KEYCHAIN_SERVICE)"],
     "Mac keychain service build setting must be present in Info.plist"),
    ("scripts/deploy-macos-to-host.sh",
     ["PRODUCT_BUNDLE_IDENTIFIER=\"$EFFECTIVE_BUNDLE_ID\"", "LABSTREAM_KEYCHAIN_SERVICE=\"$KEYCHAIN_SERVICE\""],
     "Mac host deploy must override bundle id and keychain service together"),
    ("Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift",
     ["#if os(macOS)", "Bundle.main.bundleIdentifier", ".downloads.background"],
     "Mac background download session id must derive from effective bundle id"),
    ("Labstream/Shared/UI/SettingsView.swift",
     ["backgroundDownloadSessionIdentifier: BackgroundDownloadSession.identifier", "keychainService: Self.keychainService", "sandboxContainerIdentifier: Self.sandboxContainerIdentifier"],
     "Mac diagnostics must include keychain/container/background-session context"),
]

failures = []
for file, needles, description in checks:
    text = Path(file).read_text()
    missing = [needle for needle in needles if needle not in text]
    if missing:
        failures.append((file, description, missing))

if failures:
    for file, description, missing in failures:
        print(f"{description}: {file} missing {missing}", file=sys.stderr)
    raise SystemExit(1)

print("Mac identity wiring static checks passed.")
PY

log_step "macOS host build"
run_logged macos-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme LabstreamMac \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug \
    build

log_step "visionOS simulator build"
VSIM="$(scripts/worktree-sim.sh --platform visionos id)"
run_logged visionos-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme Labstream \
    -destination "platform=visionOS Simulator,id=$VSIM" \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO

log_step "iOS simulator build"
ISIM="$(scripts/worktree-sim.sh --platform iphone id)"
run_logged ios-build \
  scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme LabstreamMobile \
    -destination "platform=iOS Simulator,id=$ISIM" \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO

log_step "PMSKit diagnostics/redaction tests"
run_logged pmskit-diagnostic-tests \
  swift test --package-path PMSKit --filter DiagnosticLoggingTests

log_step "macOS host launch smoke"
run_logged macos-smoke \
  scripts/smoke-macos-host.sh

log_step "summary"
printf 'Validation logs: %s\n' "$LOG_DIR"
printf 'macOS #228 deterministic validation passed. Current manual real-server/UI targets are in docs/MACOS.md and TESTING-CHECKLIST.md.\n'
