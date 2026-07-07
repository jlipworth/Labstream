---
name: bump-version
description: Bump Labstream app marketing versions or build numbers for visionOS, iOS/iPadOS mobile, or both. Use when the user asks to update, increment, set, release, TestFlight/App Store upload, or change MARKETING_VERSION/CURRENT_PROJECT_VERSION. Covers split release trains for Labstream and LabstreamMobile, PMSKit fallback-version policy, tags, and required verification.
---

# Bumping Labstream versions

Labstream now has two App Store release trains sharing one source tree:

- `Labstream` target/scheme = native visionOS app.
- `LabstreamMobile` target/scheme = universal iPhone + iPad app. iPhone and iPad always share one version/build.

The shared toolkit is identified at runtime by the git-derived `LABSTREAM_BUILD_SLUG` from `scripts/build-version-args.sh`; do not force every platform to bump just because shared code changed.

## First choose the bump scope

If the user does not specify the scope, ask before editing. Valid scopes:

- `mobile`: change only `LabstreamMobile` Debug + Release build settings.
- `visionos`: change only `Labstream` Debug + Release build settings.
- `all`: change both targets together.
- `toolkit`: change only `PMSKit.version` + its sanity test, when deliberately updating the shared library fallback version.

Typical policy:

- Frequent iPhone/iPad releases: `mobile`.
- Headset-only release: `visionos`.
- Coordinated public milestone: `all` plus usually `toolkit`.
- Re-uploading another binary for an existing App Store Connect version: bump `CURRENT_PROJECT_VERSION` for that scope only; leave `MARKETING_VERSION` unchanged.

## Files and settings

Inspect before and after:

```sh
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' Labstream.xcodeproj/project.pbxproj
rg -n 'static let version|PMSKit.version ==' PMSKit/Sources PMSKit/Tests
```

Expected target settings in `Labstream.xcodeproj/project.pbxproj`:

- `Labstream`: two `MARKETING_VERSION` and two `CURRENT_PROJECT_VERSION` settings across Debug/Release.
- `LabstreamMobile`: two `MARKETING_VERSION` and two `CURRENT_PROJECT_VERSION` settings across Debug/Release.
- Total project count is normally four marketing-version and four build-number settings.

Change exactly the selected target's Debug + Release settings. Do not edit the wrong platform while doing a scoped bump.

### Marketing version bump

Set `MARKETING_VERSION = X.Y.Z` for the selected scope. Use semver-ish `MAJOR.MINOR.PATCH`; never decrease relative to what was already submitted for that platform in App Store Connect.

For a brand-new marketing version, set that target's `CURRENT_PROJECT_VERSION = 1` unless the user explicitly requests another build number.

### Build-number-only bump

Set only `CURRENT_PROJECT_VERSION` for the selected scope. This is `CFBundleVersion`, not the user-visible version. Each upload under the same marketing version must have a higher build number than previous uploads for that same platform/version. Never decrease it.

### PMSKit fallback version

`PMSKit/Sources/PMSKit/PMSKit.swift` contains `PMSKit.version`; `PMSKit/Tests/PMSKitTests/SanityTests.swift` pins it.

The app normally passes `Bundle.main`'s `CFBundleShortVersionString` into `ClientIdentity`, so App Store-visible app headers track the target's `MARKETING_VERSION` even when `PMSKit.version` differs.

Update `PMSKit.version` only when:

- scope is `all` and the user expects the shared fallback to match the coordinated app version, or
- scope is explicitly `toolkit` / shared library.

Do **not** blindly sync `PMSKit.version` during a mobile-only or visionOS-only bump unless the user asks.

## Do NOT touch

- `Labstream/App/Labstream.swift`, `Labstream/App/LabstreamMobile.swift`, `Labstream/App/PlatformClientIdentity.swift`, or player code just to change versions; they read bundle versions automatically.
- Test fixtures that hardcode arbitrary `ClientIdentity(... version: "…")` values; those are local inputs, not the app version.
- `pyproject.toml` / `uv.lock`; that is separate Python tooling.

## Tags

Use scoped tags when release trains diverge:

- `mobile-vX.Y.Z` for `LabstreamMobile` iOS/iPadOS releases.
- `visionos-vX.Y.Z` for `Labstream` visionOS releases.
- `vX.Y.Z` only for synchronized `all` releases.
- `pmskit-vX.Y.Z` only for an intentional toolkit/fallback release.

Create annotated tags only after the version-bump commit exists:

```sh
git tag -a mobile-vX.Y.Z -m "LabstreamMobile X.Y.Z"
git tag -a visionos-vX.Y.Z -m "Labstream visionOS X.Y.Z"
git tag -a vX.Y.Z -m "Labstream X.Y.Z"
```

If the tag exists locally or remotely, stop and ask; do not overwrite release tags.

## Verify

Minimum verification for every bump:

```sh
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' Labstream.xcodeproj/project.pbxproj
cd PMSKit && swift test
```

Then build the touched target and verify the generated bundle:

### visionOS simulator bundle

```sh
SIMID=$(scripts/worktree-sim.sh --platform visionos id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme Labstream \
  -destination "platform=visionOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-xrsimulator/Labstream.app | head -1)
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"
```

### mobile simulator bundle

```sh
printf 'ipad\n' > .simplatform
SIMID=$(scripts/worktree-sim.sh --platform ipad id)
xcrun simctl boot "$SIMID" 2>/dev/null || true
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMobile \
  -destination "platform=iOS Simulator,id=$SIMID" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
APP=$(/bin/ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Labstream-*/Build/Products/Debug-iphonesimulator/Labstream.app | head -1)
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"
```

For build-number-only release prep, verify the marketing version stayed unchanged and the build number changed only for the selected scope.
