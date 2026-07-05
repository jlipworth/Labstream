#!/usr/bin/env bash
# Build, export, and install a distribution-signed Ad Hoc Labstream build.
#
# This is for "take it on a plane" installs where a 7-day free/development
# provisioning profile is not acceptable. It uses an Apple Distribution
# certificate plus an Ad Hoc distribution provisioning profile whose device list
# includes the target Apple Vision Pro.
#
# Prereqs:
#   - Apple Distribution certificate installed in the keychain.
#   - A non-expired Ad Hoc distribution provisioning profile for
#     com.jlipworth.VisionPlay installed in Xcode's profile cache.
#   - The headset UDID registered in that Ad Hoc profile.
#
# Usage:
#   scripts/deploy-ad-hoc-to-device.sh
#   scripts/deploy-ad-hoc-to-device.sh --launch
#   scripts/deploy-ad-hoc-to-device.sh --list-profiles
#   scripts/deploy-ad-hoc-to-device.sh --profile "<profile name or UUID>"
#   scripts/deploy-ad-hoc-to-device.sh --verbose
#
# Env overrides:
#   VP_DEVICE_ID=<coredevice-id|udid|name>       target Vision Pro
#   VP_DISTRIBUTION_TEAM=<team-id>              distribution team id
#   VP_AD_HOC_PROFILE_SPECIFIER=<name-or-uuid>  provisioning profile
#
set -euo pipefail

BUNDLE_ID="com.jlipworth.VisionPlay"
APP_NAME="Labstream"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_HELPER="$REPO/scripts/provisioning-profile-info.py"

cd "$REPO"

LAUNCH=0
VERBOSE=0
LIST_PROFILES=0
PROFILE_SPECIFIER="${VP_AD_HOC_PROFILE_SPECIFIER:-}"

die() { echo "deploy-ad-hoc-to-device: $*" >&2; exit 1; }

usage() {
  sed -n '1,31p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --launch) LAUNCH=1; shift ;;
    --verbose|--full-ids) VERBOSE=1; shift ;;
    --list-profiles) LIST_PROFILES=1; shift ;;
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires a profile name or UUID"
      PROFILE_SPECIFIER="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

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
      -e "s/${DEVICE_UDID:-__NO_DEVICE_UDID__}/$(mask_id "${DEVICE_UDID:-__NO_DEVICE_UDID__}")/g" \
      -e "s/${TEAM:-__NO_TEAM_ID__}/$(mask_id "${TEAM:-__NO_TEAM_ID__}")/g"
  fi
}

identity_installed() {
  local sha1="$1"
  security find-identity -p codesigning -v 2>/dev/null | grep -qi "$sha1"
}

list_matching_profiles() {
  "$PROFILE_HELPER" list \
    --bundle-id "$BUNDLE_ID" \
    --team "$TEAM" \
    --kind ad-hoc \
    --device-udid "$DEVICE_UDID" \
    --format tsv
}

# --- Resolve target device -----------------------------------------------------
DEVICE_ID="${VP_DEVICE_ID:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -iE 'vision|reality' \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1 || true)
fi
[ -n "$DEVICE_ID" ] || die "no paired Vision Pro found. Check: xcrun devicectl list devices"

DETAILS_JSON="$(mktemp)"
if xcrun devicectl device info details --device "$DEVICE_ID" --timeout 20 --json-output "$DETAILS_JSON" >/tmp/vp-adhoc-device-details.log 2>&1; then
  DEVICE_UDID=$(jq -r '.result.hardwareProperties.udid // ""' "$DETAILS_JSON")
else
  DEVICE_UDID=""
fi
rm -f "$DETAILS_JSON"

echo "device:  $(mask_id "$DEVICE_ID")"
[ -n "$DEVICE_UDID" ] && echo "udid:    $(mask_id "$DEVICE_UDID")"

DEVICE_STATE=$(xcrun devicectl list devices 2>/dev/null | grep -i "$DEVICE_ID" | grep -oiE 'available|unavailable' | head -1 || true)
if [ "$DEVICE_STATE" = "unavailable" ]; then
  echo "  ⚠️  device reports 'unavailable' — wake/put on the headset and keep it on the same Wi-Fi."
fi

# --- Resolve distribution team -------------------------------------------------
TEAM="${VP_DISTRIBUTION_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(security find-certificate -a -c "Apple Distribution" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -oE 'OU=[^,/]+' | head -1 | cut -d= -f2 || true)
fi
[ -n "$TEAM" ] || die "could not derive a distribution team. Is an Apple Distribution cert installed?"
echo "team:    $(mask_id "$TEAM")"

if [ "$LIST_PROFILES" -eq 1 ]; then
  echo
  echo "matching non-expired/expired Ad Hoc profiles for $BUNDLE_ID on this device:"
  printf 'UUID\tName\tTeam\tExpires\tNotExpired\tDevices\tFile\tPath\tCertSHA1\tContainsDevice\tGetTaskAllow\tTTL\tRemainingHours\n'
  list_matching_profiles || true
  exit 0
fi

# --- Resolve Ad Hoc profile ----------------------------------------------------
if [ -z "$PROFILE_SPECIFIER" ]; then
  PROFILE_SPECIFIER="$(list_matching_profiles | awk -F '\t' '$5 == "true" {print $1; exit}')"
fi

if [ -z "$PROFILE_SPECIFIER" ]; then
  die "no usable Ad Hoc distribution profile found for $BUNDLE_ID containing this headset UDID.

Create/download an Ad Hoc profile in Apple Developer:
  Certificates, Identifiers & Profiles ▸ Profiles ▸ + ▸ Ad Hoc
  App ID: $BUNDLE_ID
  Certificate: your Apple Distribution certificate
  Devices: include this Vision Pro UDID

Then install/download it into Xcode and rerun.
Use --list-profiles to inspect local candidates."
fi

PROFILE_PATH="$($PROFILE_HELPER find \
  --specifier "$PROFILE_SPECIFIER" \
  --bundle-id "$BUNDLE_ID" \
  --team "$TEAM" \
  --kind ad-hoc \
  --device-udid "$DEVICE_UDID" || true)"
[ -n "$PROFILE_PATH" ] || die "profile not found locally by name/UUID: $PROFILE_SPECIFIER"

eval "$($PROFILE_HELPER summary --format env --device-udid "$DEVICE_UDID" "$PROFILE_PATH")"

[ "$PROFILE_TEAM" = "$TEAM" ] || die "profile team $PROFILE_TEAM does not match distribution team $TEAM"
[ "$PROFILE_APP_ID" = "$TEAM.$BUNDLE_ID" ] || die "profile app id $PROFILE_APP_ID does not match $TEAM.$BUNDLE_ID"
[ "$PROFILE_GET_TASK_ALLOW" = "false" ] || die "profile appears to be a development profile (get-task-allow=$PROFILE_GET_TASK_ALLOW)"
[ "$PROFILE_PROVISIONED_DEVICE_COUNT" -gt 0 ] || die "profile has no ProvisionedDevices; this is not an Ad Hoc profile"
[ "$PROFILE_NOT_EXPIRED" = "true" ] || die "profile is expired: $PROFILE_NAME ($PROFILE_EXPIRATION)"
[ -n "$PROFILE_FIRST_CERTIFICATE_SHA1" ] || die "profile does not contain a distribution certificate"
identity_installed "$PROFILE_FIRST_CERTIFICATE_SHA1" || die "profile certificate $PROFILE_FIRST_CERTIFICATE_SHA1 is not installed as a signing identity in the keychain"
if [ -n "$DEVICE_UDID" ] && [ "$PROFILE_CONTAINS_DEVICE" != "true" ]; then
  die "profile does not include this headset UDID: $PROFILE_NAME"
fi

echo "profile: $PROFILE_NAME ($(mask_id "$PROFILE_UUID"), expires $PROFILE_EXPIRATION)"
echo "cert:    $(mask_id "$PROFILE_FIRST_CERTIFICATE_SHA1")"

# --- Archive and export --------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$REPO/build/ad-hoc/ad-hoc-$STAMP"
ARCHIVE_PATH="$OUT_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$OUT_DIR/export"
EXPORT_OPTIONS="$OUT_DIR/ExportOptions-release-testing.plist"
PAYLOAD_DIR="$OUT_DIR/payload"

mkdir -p "$OUT_DIR"

VERSION_ARGS=()
while IFS= read -r arg; do VERSION_ARGS+=("$arg"); done < <(scripts/build-version-args.sh)

echo "archiving Release visionOS app with Apple Distribution signing…"
xcodebuild "${VERSION_ARGS[@]}" \
  -project Labstream.xcodeproj \
  -scheme Labstream \
  -configuration Release \
  -destination "generic/platform=visionOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$PROFILE_FIRST_CERTIFICATE_SHA1" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  archive >"$OUT_DIR/archive.log" 2>&1 || {
    tail -40 "$OUT_DIR/archive.log" | redact_stream >&2
    die "archive failed (full log: $OUT_DIR/archive.log)"
  }

cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>release-testing</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$TEAM</string>
  <key>signingCertificate</key>
  <string>$PROFILE_FIRST_CERTIFICATE_SHA1</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key>
    <string>$PROFILE_UUID</string>
  </dict>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

echo "exporting Ad Hoc/release-testing IPA…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates >"$OUT_DIR/export.log" 2>&1 || {
    tail -40 "$OUT_DIR/export.log" | redact_stream >&2
    die "export failed (full log: $OUT_DIR/export.log)"
  }

IPA="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print | head -1 || true)"
[ -n "$IPA" ] || die "export succeeded but no .ipa was found under $EXPORT_PATH"

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
/usr/bin/unzip -q "$IPA" -d "$PAYLOAD_DIR"
APP="$PAYLOAD_DIR/Payload/$APP_NAME.app"
[ -d "$APP" ] || die "exported IPA did not contain Payload/$APP_NAME.app"

SIGNED_TEAM="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
[ "$SIGNED_TEAM" = "$TEAM" ] || die "exported app signed by $SIGNED_TEAM, expected $TEAM"

eval "$($PROFILE_HELPER summary --format env "$APP/embedded.mobileprovision")"
echo "app:     $APP"
echo "ipa:     $IPA"
echo "signed:  team $(mask_id "$SIGNED_TEAM"), get-task-allow=$PROFILE_GET_TASK_ALLOW, expires $PROFILE_EXPIRATION"

# --- Install and optionally launch --------------------------------------------
echo "installing Ad Hoc app to device…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" --timeout 60 2>&1 | redact_stream

if [ "$LAUNCH" -eq 1 ]; then
  echo "launching…"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" --timeout 30 2>&1 | redact_stream || \
    echo "  (launch failed — if the install succeeded, try opening it from the headset Home View.)"
fi

echo "✅ $BUNDLE_ID Ad Hoc build installed to $(mask_id "$DEVICE_ID")"
echo "   Export bundle: $OUT_DIR"
