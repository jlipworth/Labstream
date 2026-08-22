#!/usr/bin/env bash
# Deploy the LabstreamMobile app to a physical iPhone or iPad.
#
# This is the iOS/iPadOS companion to deploy-to-device.sh. It builds a Debug,
# development-signed *device* build of the LabstreamMobile scheme and installs it
# with devicectl. Simulator builds use CODE_SIGNING_ALLOWED=NO and land in
# Debug-iphonesimulator; those will NOT install on real hardware. This script
# produces Debug-iphoneos/Labstream.app and requires normal Apple development
# signing/provisioning.
#
# Usage:
#   scripts/deploy-mobile-to-device.sh            # build + install to the paired iPhone/iPad
#   scripts/deploy-mobile-to-device.sh --launch   # also launch after install
#   scripts/deploy-mobile-to-device.sh --no-build # install the last Debug-iphoneos build
#   scripts/deploy-mobile-to-device.sh --verbose  # print full device/team IDs (masked by default)
#
# Env overrides:
#   IOS_DEVICE_ID=<uuid>            target iPhone/iPad (default: the single iOS device found)
#   IOS_DEVELOPMENT_TEAM=<id>       signing team (default: OU of the Apple Development cert)
#   MOBILE_DEVICE_ID=<uuid>         alias for IOS_DEVICE_ID
#   MOBILE_DEVELOPMENT_TEAM=<id>    alias for IOS_DEVELOPMENT_TEAM
#   IOS_REFRESH_SHORT_DEV_PROFILES=0
#                                  opt out of deleting stale/short-lived matching
#                                  development profiles before build.
#
set -euo pipefail

BUNDLE_ID="org.labstream.Labstream"
APP_NAME="Labstream"
SCHEME="LabstreamMobile"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_HELPER="$REPO/scripts/provisioning-profile-info.py"
cd "$REPO"

LAUNCH=0
BUILD=1
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --launch)    LAUNCH=1 ;;
    --no-build)  BUILD=0 ;;
    --verbose|--full-ids) VERBOSE=1 ;;
    -h|--help)   sed -n '1,24p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "deploy-mobile-to-device: $*" >&2; exit 1; }
[ -x "$PROFILE_HELPER" ] || die "missing helper: $PROFILE_HELPER"

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

# --- Resolve the target physical iOS/iPadOS device ----------------------------
DEVICE_ID="${IOS_DEVICE_ID:-${MOBILE_DEVICE_ID:-}}"
if [ -z "$DEVICE_ID" ]; then
  IOS_DEVICE_IDS=()
  while IFS= read -r id; do
    IOS_DEVICE_IDS+=("$id")
  done < <(xcrun devicectl list devices 2>/dev/null \
    | grep -iE 'iphone|ipad|ipod' \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | awk '!seen[$0]++' || true)
  if [ "${#IOS_DEVICE_IDS[@]}" -gt 1 ]; then
    die "multiple iPhone/iPad devices found; set IOS_DEVICE_ID to one of:
$(printf '  %s\n' "${IOS_DEVICE_IDS[@]}" | sed 's/^/  /')"
  fi
  DEVICE_ID="${IOS_DEVICE_IDS[0]:-}"
fi
[ -n "$DEVICE_ID" ] || die "no paired iPhone/iPad found. Plug it in / pair it, trust this Mac, or set IOS_DEVICE_ID.
  Check with: xcrun devicectl list devices"
echo "device:  $(mask_id "$DEVICE_ID")"

DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep -i "$DEVICE_ID" | head -1 || true)
DEVICE_STATE=$(printf '%s\n' "$DEVICE_LINE" | grep -oiE 'available|unavailable' | head -1 || true)
if [ "$DEVICE_STATE" = "unavailable" ]; then
  echo "  ⚠️  device reports 'unavailable' — unlock it, keep it connected/on Wi-Fi, and trust this Mac."
fi

# --- Resolve the signing team (cert OU, not the CN parenthetical) -------------
TEAM="${IOS_DEVELOPMENT_TEAM:-${MOBILE_DEVELOPMENT_TEAM:-}}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[^,/]+' | head -1 | cut -d= -f2 || true)
fi
[ -n "$TEAM" ] || die "could not derive a development team. Is an Apple Development cert in
  the keychain and an Apple ID signed into Xcode (Settings ▸ Accounts)? Or set IOS_DEVELOPMENT_TEAM."
echo "team:    $(mask_id "$TEAM")"

# Refresh only matching short-lived development profiles. This avoids reinstalling a
# nearly-expired free-team profile when Xcode can create a fresh one.
if [ "${IOS_REFRESH_SHORT_DEV_PROFILES:-1}" != "0" ]; then
  "$PROFILE_HELPER" prune \
    --bundle-id "$BUNDLE_ID" \
    --team "$TEAM" \
    --kind development \
    --short-ttl-days 14 || true
fi

# --- Build signed iOS/iPadOS device slice -------------------------------------
# LINK-SKIP guard: remove the old device .app before building so a skipped link
# cannot leave us installing a stale binary.
if [ "$BUILD" -eq 1 ]; then
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData/Labstream-"*/Build/Products/Debug-iphoneos/$APP_NAME.app 2>/dev/null || true
  VERSION_ARGS=()
  while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(scripts/build-version-args.sh)
  echo "building (Debug, iOS/iPadOS device, signed, versioned)…"
  xcodebuild "${VERSION_ARGS[@]}" -project Labstream.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -configuration Debug \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" \
    build >/tmp/labstream-mobile-device-build.log 2>&1 \
    || { tail -25 /tmp/labstream-mobile-device-build.log | redact_stream >&2; die "build failed (full log: /tmp/labstream-mobile-device-build.log)"; }
fi

# --- Locate and sanity-check the freshest device build product -----------------
APP=$(/bin/ls -td "$HOME/Library/Developer/Xcode/DerivedData/Labstream-"*/Build/Products/Debug-iphoneos/$APP_NAME.app 2>/dev/null | head -1 || true)
[ -n "$APP" ] && [ -d "$APP" ] || die "no iOS device build product found (Debug-iphoneos/$APP_NAME.app). Build first (omit --no-build)."

SIGNED_TEAM=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
[ "$SIGNED_TEAM" = "$TEAM" ] || echo "  ⚠️  built app TeamIdentifier=$(mask_id "$SIGNED_TEAM") (expected $(mask_id "$TEAM"))"
echo "app:     $APP  (team $(mask_id "$SIGNED_TEAM"))"

if [ -f "$APP/embedded.mobileprovision" ]; then
  eval "$("$PROFILE_HELPER" summary --format env "$APP/embedded.mobileprovision")"
  echo "profile: profile_expires=$PROFILE_EXPIRATION time_to_live_days=$PROFILE_TIME_TO_LIVE_DAYS get_task_allow=$PROFILE_GET_TASK_ALLOW remaining_hours=$PROFILE_REMAINING_HOURS remaining_days=$PROFILE_REMAINING_DAYS"
  if [ -n "$PROFILE_TIME_TO_LIVE_DAYS" ] && [ "$PROFILE_TIME_TO_LIVE_DAYS" -le 14 ]; then
    echo "  ⚠️  short-lived development profile; reinstalling before expiry usually does not roll the date forward."
    if [ -n "$PROFILE_REMAINING_HOURS" ] && [ "$PROFILE_REMAINING_HOURS" -lt 144 ]; then
      echo "  ❌ refusing to install a short-lived profile with <6 days remaining."
      echo "     Re-run with IOS_REFRESH_SHORT_DEV_PROFILES=1, check Xcode account signing,"
      echo "     or use TestFlight/App Store for longer-lived installs."
      exit 1
    fi
  elif [ -n "$PROFILE_REMAINING_HOURS" ] && [ "$PROFILE_REMAINING_HOURS" -lt 72 ]; then
    echo "  ⚠️  provisioning profile expires soon; regenerate/reinstall before relying on it offline."
  fi
fi

# --- Install and optionally launch --------------------------------------------
echo "installing to device…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | redact_stream

if [ "$LAUNCH" -eq 1 ]; then
  echo "launching…"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1 | redact_stream || \
    echo "  (launch failed — if install succeeded, open it from the device Home Screen instead)"
fi

echo "✅ $BUNDLE_ID ($SCHEME) deployed to $(mask_id "$DEVICE_ID")"
