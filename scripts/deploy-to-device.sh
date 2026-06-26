#!/usr/bin/env bash
# Deploy the locally-built VisionPlay app to a physical Apple Vision Pro over Wi-Fi.
#
# This is the single source of truth for on-device (NOT simulator) deploys; the
# `deploy-to-device` skill (.claude/skills/) just drives this script. It builds a
# Debug, development-signed visionOS *device* build and installs it with `devicectl`.
#
# Why a script: device signing has two non-obvious traps that bit us repeatedly —
#   1. The real DEVELOPMENT_TEAM is the signing cert's **OU**, NOT the parenthetical
#      in its common name. The keychain identity reads
#      "Apple Development: …@… (YYYYYYYYYY)" but the actual team is OU=XXXXXXXXXX.
#      Passing the CN parenthetical → "No Account for Team …" build failure.
#   2. There is no $SIMID here — a device build lands in Debug-xros (not -xrsimulator)
#      and MUST be code-signed (no CODE_SIGNING_ALLOWED=NO).
# This script derives the team from the cert OU and the device UUID from devicectl,
# so neither has to be hand-typed (override via env if you have several of either).
#
# Usage:
#   scripts/deploy-to-device.sh            # build + install to the one paired Vision Pro
#   scripts/deploy-to-device.sh --launch   # also launch it (headset should be awake/worn)
#   scripts/deploy-to-device.sh --no-build # install the last build as-is (skip rebuild)
#   scripts/deploy-to-device.sh --verbose  # print full device/team IDs (masked by default)
#
# Env overrides (rarely needed):
#   VP_DEVICE_ID=<uuid>        target device (default: the single visionOS device found)
#   VP_DEVELOPMENT_TEAM=<id>   signing team  (default: OU of the Apple Development cert)
#
set -euo pipefail

BUNDLE_ID="com.jlipworth.VisionPlay"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

LAUNCH=0
BUILD=1
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --launch)    LAUNCH=1 ;;
    --no-build)  BUILD=0 ;;
    --verbose|--full-ids) VERBOSE=1 ;;
    -h|--help)   sed -n '1,31p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "deploy-to-device: $*" >&2; exit 1; }

mask_id() {
  local value="$1"
  if [ "$VERBOSE" -eq 1 ] || [ ${#value} -le 8 ]; then
    printf '%s' "$value"
  else
    printf '%s…%s' "${value:0:4}" "${value: -4}"
  fi
}

redact_stream() {
  if [ "$VERBOSE" -eq 1 ]; then
    cat
  else
    sed \
      -e "s/${DEVICE_ID:-__NO_DEVICE_ID__}/$(mask_id "${DEVICE_ID:-__NO_DEVICE_ID__}")/g" \
      -e "s/${TEAM:-__NO_TEAM_ID__}/$(mask_id "${TEAM:-__NO_TEAM_ID__}")/g" \
      -e "s/${SIGNED_TEAM:-__NO_SIGNED_TEAM__}/$(mask_id "${SIGNED_TEAM:-__NO_SIGNED_TEAM__}")/g"
  fi
}

# --- Resolve the target device (a paired visionOS device) ----------------------
DEVICE_ID="${VP_DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -iE 'vision|reality' \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1 || true)
fi
[ -n "$DEVICE_ID" ] || die "no paired Vision Pro found. Plug it in / pair it, or set VP_DEVICE_ID.
  Check with: xcrun devicectl list devices"
echo "device:  $(mask_id "$DEVICE_ID")"

# Warn early if the headset is asleep/off-head — devicectl would otherwise fail the
# install with a cryptic CoreDeviceError 1011 ("unable to locate a device").
DEVICE_STATE=$(xcrun devicectl list devices 2>/dev/null | grep -i "$DEVICE_ID" | grep -oiE 'available|unavailable' | head -1 || true)
if [ "$DEVICE_STATE" = "unavailable" ]; then
  echo "  ⚠️  device reports 'unavailable' — wake/put on the headset and keep it on the same Wi-Fi."
fi

# --- Resolve the signing team (cert OU, NOT the CN parenthetical) ---------------
TEAM="${VP_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[^,/]+' | head -1 | cut -d= -f2 || true)
fi
[ -n "$TEAM" ] || die "could not derive a development team. Is an Apple Development cert in
  the keychain and an Apple ID signed into Xcode (Settings ▸ Accounts)? Or set VP_DEVELOPMENT_TEAM.
  See the deploy-to-device skill for the full signing-account setup."
echo "team:    $(mask_id "$TEAM")"

# --- Build (signed, device slice) ----------------------------------------------
# LINK-SKIP guard (see CLAUDE.md): delete the device .app first so a skipped Ld step
# can't leave us installing a stale binary.
if [ "$BUILD" -eq 1 ]; then
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData/VisionPlay-"*/Build/Products/Debug-xros/VisionPlay.app 2>/dev/null || true
  VERSION_ARGS=()
  while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(scripts/build-version-args.sh)
  echo "building (Debug, visionOS device, signed, versioned)…"
  xcodebuild "${VERSION_ARGS[@]}" -project VisionPlay.xcodeproj -scheme VisionPlay \
    -destination "platform=visionOS,id=$DEVICE_ID" \
    -configuration Debug \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" \
    build >/tmp/vp-device-build.log 2>&1 \
    || { tail -25 /tmp/vp-device-build.log | redact_stream >&2; die "build failed (full log: /tmp/vp-device-build.log)"; }
fi

# --- Locate the freshest device build product -----------------------------------
APP=$(/bin/ls -td "$HOME/Library/Developer/Xcode/DerivedData/VisionPlay-"*/Build/Products/Debug-xros/VisionPlay.app 2>/dev/null | head -1 || true)
[ -n "$APP" ] && [ -d "$APP" ] || die "no device build product found (Debug-xros/VisionPlay.app). Build first (omit --no-build)."

# Sanity: confirm it's signed for our team, not the simulator slice.
SIGNED_TEAM=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
[ "$SIGNED_TEAM" = "$TEAM" ] || echo "  ⚠️  built app TeamIdentifier=$(mask_id "$SIGNED_TEAM") (expected $(mask_id "$TEAM"))"
echo "app:     $APP  (team $(mask_id "$SIGNED_TEAM"))"

# --- Install over Wi-Fi ---------------------------------------------------------
echo "installing to device…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | redact_stream

if [ "$LAUNCH" -eq 1 ]; then
  echo "launching… (the headset must be awake/worn to actually appear)"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | redact_stream || \
    echo "  (launch failed — open it from the Home View on the headset instead)"
fi

echo "✅ $BUNDLE_ID deployed to $(mask_id "$DEVICE_ID")"
