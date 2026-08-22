#!/usr/bin/env bash
# Build and optionally launch the native macOS Labstream target on this host Mac.
#
# macOS has no simulator lane in this repo. This script treats macOS as the host
# platform, never uses simctl/devicectl, and defaults to a per-worktree dev bundle
# id so parallel worktrees do not all collide with org.labstream.Labstream state.
#
# Usage:
#   scripts/deploy-macos-to-host.sh                 # build + stage dev app
#   scripts/deploy-macos-to-host.sh --launch        # build + stage + launch
#   scripts/deploy-macos-to-host.sh --no-build --launch
#   scripts/deploy-macos-to-host.sh --delete        # remove staged dev app only
#   scripts/deploy-macos-to-host.sh --delete-all-staged # remove every app staged by this worktree
#   scripts/deploy-macos-to-host.sh --reset-container  # dev bundle id only
#   scripts/deploy-macos-to-host.sh --use-production-bundle-id --launch
#
# Dev identity controls:
#   --bundle-id-suffix SUFFIX            use org.labstream.Labstream.dev.SUFFIX
#   LABSTREAM_MAC_BUNDLE_ID_SUFFIX=...   env equivalent
#   --use-production-bundle-id           use org.labstream.Labstream intentionally
#                                        (Apple Development signed for canonical Keychain access)
#
# Safety:
#   - The staged app lives under this worktree's build/macos-host/<identity>/.
#   - This script never deletes /Applications/Labstream.app.
#   - --reset-container removes ~/Library/Containers/<effective bundle id> only.
#   - Production container reset requires --allow-production-container-reset too.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP_NAME="Labstream"
SCHEME="LabstreamMac"
CANONICAL_BUNDLE_ID="org.labstream.Labstream"
BUILD=1
LAUNCH=0
DELETE=0
DELETE_ALL_STAGED=0
RESET_CONTAINER=0
USE_PRODUCTION=0
ALLOW_PRODUCTION_CONTAINER_RESET=0
BUNDLE_SUFFIX="${LABSTREAM_MAC_BUNDLE_ID_SUFFIX:-}"

usage() { sed -n '1,34p' "$0"; }
die() { echo "deploy-macos-to-host: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --launch) LAUNCH=1; shift ;;
    --no-build) BUILD=0; shift ;;
    --delete|--uninstall) DELETE=1; BUILD=0; shift ;;
    --delete-all-staged) DELETE_ALL_STAGED=1; BUILD=0; shift ;;
    --reset-container) RESET_CONTAINER=1; shift ;;
    --use-production-bundle-id|--production-bundle-id) USE_PRODUCTION=1; shift ;;
    --allow-production-container-reset) ALLOW_PRODUCTION_CONTAINER_RESET=1; shift ;;
    --bundle-id-suffix)
      [ "$#" -ge 2 ] || die "--bundle-id-suffix requires a value"
      BUNDLE_SUFFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

sanitize_suffix() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [ -n "$raw" ] || raw="worktree"
  if [[ "$raw" =~ ^[0-9] ]]; then raw="wt-$raw"; fi
  # Keep bundle IDs readable but bounded; append a repo path hash if truncating.
  if [ "${#raw}" -gt 48 ]; then
    local hash
    hash="$(printf '%s' "$REPO" | shasum -a 256 | awk '{print substr($1,1,8)}')"
    raw="${raw:0:39}-$hash"
    raw="$(printf '%s' "$raw" | sed -E 's/-+$//')"
  fi
  printf '%s' "$raw"
}

if [ "$USE_PRODUCTION" -eq 1 ]; then
  EFFECTIVE_BUNDLE_ID="$CANONICAL_BUNDLE_ID"
  IDENTITY_SLUG="production"
  KEYCHAIN_SERVICE="org.labstream.Labstream"
else
  if [ -z "$BUNDLE_SUFFIX" ]; then
    BUNDLE_SUFFIX="$(git branch --show-current 2>/dev/null || basename "$REPO")"
  fi
  IDENTITY_SLUG="$(sanitize_suffix "$BUNDLE_SUFFIX")"
  EFFECTIVE_BUNDLE_ID="$CANONICAL_BUNDLE_ID.dev.$IDENTITY_SLUG"
  KEYCHAIN_SERVICE="$EFFECTIVE_BUNDLE_ID"
fi

if [ "$USE_PRODUCTION" -eq 1 ]; then
  DISPLAY_NAME="Labstream"
else
  DISPLAY_NAME="Labstream Dev — $IDENTITY_SLUG"
fi

DERIVED_DATA="$REPO/build/DerivedData-macos"
PRODUCT_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
STAGE_ROOT="$REPO/build/macos-host"
STAGE_DIR="$STAGE_ROOT/$IDENTITY_SLUG"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
CONTAINER_PATH="$HOME/Library/Containers/$EFFECTIVE_BUNDLE_ID"
LOG_COMMAND="log stream --style compact --predicate 'process == \"$APP_NAME\" OR subsystem == \"org.labstream.Labstream\"'"

echo "platform: macOS host (no simulator/devicectl/simctl)"
echo "scheme:   $SCHEME"
echo "bundle:   $EFFECTIVE_BUNDLE_ID"
echo "display:  $DISPLAY_NAME"
echo "keychain: $KEYCHAIN_SERVICE"
echo "stage:    $STAGED_APP"
echo "container:$CONTAINER_PATH"

terminate_if_running() {
  /usr/bin/osascript -e "tell application id \"$EFFECTIVE_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
}

if [ "$RESET_CONTAINER" -eq 1 ] && [ "$USE_PRODUCTION" -eq 1 ] && [ "$ALLOW_PRODUCTION_CONTAINER_RESET" -ne 1 ]; then
  die "refusing to reset production container $CONTAINER_PATH without --allow-production-container-reset"
fi

if [ "$DELETE" -eq 1 ]; then
  echo "deleting staged app for effective bundle id only…"
  terminate_if_running
  rm -rf "$STAGED_APP"
  rmdir "$STAGE_DIR" 2>/dev/null || true
fi

if [ "$DELETE_ALL_STAGED" -eq 1 ]; then
  echo "deleting every macOS app staged by this worktree (containers/keychain preserved)…"
  pkill -f "$STAGE_ROOT/.*/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  find "$STAGE_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$APP_NAME.app" \
    -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$PRODUCT_APP"
  find "$STAGE_ROOT" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
fi

if [ "$RESET_CONTAINER" -eq 1 ]; then
  echo "resetting sandbox container for effective bundle id…"
  terminate_if_running
  rm -rf "$CONTAINER_PATH"
fi

if [ "$BUILD" -eq 0 ] && [ "$LAUNCH" -eq 0 ] \
  && { [ "$DELETE" -eq 1 ] || [ "$DELETE_ALL_STAGED" -eq 1 ] || [ "$RESET_CONTAINER" -eq 1 ]; }; then
  echo "cleanup complete; no app was launched"
  exit 0
fi

if [ "$BUILD" -eq 1 ]; then
  # LINK-SKIP/stale-product guard, scoped to this worktree's DerivedData.
  rm -rf "$PRODUCT_APP" "$STAGED_APP"
  mkdir -p "$DERIVED_DATA" "$STAGE_DIR"
  echo "building (Debug, macOS host arm64)…"
  BUILD_LOG="$STAGE_DIR/build.log"
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
  if [ "$USE_PRODUCTION" -eq 1 ]; then
    # A canonical-service build uses a synchronizable Plex token. An ad-hoc signature has no
    # application identifier/keychain group and Security rejects it with errSecMissingEntitlement
    # (-34018), presenting a misleading Plex-token/session failure. Sign intentional production-
    # identity host builds with the development team and a Mac provisioning profile instead.
    TEAM="${LABSTREAM_MAC_DEVELOPMENT_TEAM:-}"
    if [ -z "$TEAM" ]; then
      TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU=[^,/]+' | head -1 | cut -d= -f2 || true)
    fi
    [ -n "$TEAM" ] || die "production-identity host build requires an Apple Development certificate/team"
    SIGNING_ARGS=(
      -allowProvisioningUpdates
      -allowProvisioningDeviceRegistration
      "DEVELOPMENT_TEAM=$TEAM"
      CODE_SIGN_STYLE=Automatic
      "CODE_SIGN_IDENTITY=Apple Development"
    )
  else
    # The worktree-isolated identity must not inherit the canonical keychain access group.
    # Keeping sandbox/network entitlements makes the staged app representative while allowing
    # local ad-hoc signing without a provisioning profile for the synthetic bundle identifier.
    SIGNING_ARGS=("CODE_SIGN_ENTITLEMENTS=Config/LabstreamMacDevelopment.entitlements")
  fi
  if ! scripts/xcodebuild-versioned.sh \
    -project Labstream.xcodeproj \
    -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER="$EFFECTIVE_BUNDLE_ID" \
    INFOPLIST_KEY_CFBundleDisplayName="$DISPLAY_NAME" \
    LABSTREAM_KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE" \
    "${SIGNING_ARGS[@]}" \
    build >"$BUILD_LOG" 2>&1; then
    tail -60 "$BUILD_LOG" >&2 || true
    die "build failed (full log: $BUILD_LOG)"
  fi
  echo "build log: $BUILD_LOG"
  [ -d "$PRODUCT_APP" ] || die "build succeeded but product was not found: $PRODUCT_APP"
  if [ "$USE_PRODUCTION" -eq 1 ]; then
    SIGNED_TEAM=$(codesign -dvvv "$PRODUCT_APP" 2>&1 \
      | sed -nE 's/^TeamIdentifier=(.+)$/\1/p' | head -1)
    [ -n "$SIGNED_TEAM" ] && [ "$SIGNED_TEAM" != "not set" ] \
      || die "production-identity app was not development-signed; refusing Keychain-broken build"
    codesign -d --entitlements :- "$PRODUCT_APP" 2>/dev/null \
      | plutil -extract keychain-access-groups xml1 -o - - >/dev/null 2>&1 \
      || die "production-identity app lacks keychain-access-groups entitlement"
  fi
  ditto "$PRODUCT_APP" "$STAGED_APP"
fi

if [ "$BUILD" -eq 0 ] && [ "$DELETE" -eq 0 ] && [ "$DELETE_ALL_STAGED" -eq 0 ] \
  && [ ! -d "$STAGED_APP" ]; then
  die "no staged app found for --no-build: $STAGED_APP (run without --no-build first)"
fi

if [ "$LAUNCH" -eq 1 ]; then
  [ -d "$STAGED_APP" ] || die "no staged app to launch: $STAGED_APP"
  echo "launching staged app…"
  terminate_if_running
  open -n "$STAGED_APP"
fi

echo "app:      $STAGED_APP"
echo "logs:     $LOG_COMMAND"
echo "note:     Mac host runs share hardware. Use per-worktree dev bundle ids unless intentionally testing production identity."
