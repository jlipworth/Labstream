---
name: bump-version
description: Bump Labstream app marketing versions or build numbers for visionOS, iOS/iPadOS, macOS, tvOS, or a coordinated release. Use when the user asks to update, increment, set, release, upload, or change MARKETING_VERSION/CURRENT_PROJECT_VERSION. Covers platform release trains, PMSKit fallback-version policy, annotated Git tags, and required verification.
---

# Bumping Labstream versions

Labstream has four independently versioned native app targets sharing one source tree:

- `Labstream` target/scheme = native visionOS app.
- `LabstreamMobile` target/scheme = universal iPhone + iPad app. iPhone and iPad always share one version/build.
- `LabstreamMac` target/scheme = native macOS app.
- `LabstreamTV` target/scheme = native tvOS app.

Vision Pro and mobile are the supported product paths. Mac is a local-build development preview,
and tvOS is still in development. Their independent version settings support internal milestones;
do not describe either preview as an App Store release without an explicit distribution decision
and the physical/TestFlight gates documented elsewhere in the repository.

The shared toolkit is identified at runtime by the git-derived `LABSTREAM_BUILD_SLUG` from `scripts/build-version-args.sh`; do not force every platform to bump just because shared code changed.

## First choose the bump scope

If the user does not specify the scope, ask before editing. Valid scopes:

- `mobile`: change only `LabstreamMobile`.
- `visionos`: change only `Labstream`.
- `macos`: change only `LabstreamMac`.
- `tvos`: change only `LabstreamTV`.
- `all`: change all four app targets together.
- `toolkit`: change only `PMSKit.version` + its sanity test, when deliberately updating the shared library fallback version.

Typical policy:

- Frequent iPhone/iPad releases: `mobile`.
- Headset-only release: `visionos`.
- Mac-only internal milestone or explicitly approved release: `macos`.
- Apple TV-only internal milestone or explicitly approved release: `tvos`.
- Coordinated codebase milestone: `all` plus `toolkit` unless the user explicitly keeps the fallback version independent.
- Re-uploading another binary for an existing App Store Connect version: bump `CURRENT_PROJECT_VERSION` for that scope only; leave `MARKETING_VERSION` unchanged.

## Files and settings

Inspect before and after:

```sh
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' Labstream.xcodeproj/project.pbxproj
rg -n 'static let version|PMSKit.version ==' PMSKit/Sources PMSKit/Tests
```

Expected target settings in `Labstream.xcodeproj/project.pbxproj`:

- Each app target has `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Debug, Release, and PerformanceAudit.
- A coordinated `all` bump changes 12 marketing-version settings across the four app targets.
- Do not alter unit-test target settings.

Change exactly the selected target's Debug, Release, and PerformanceAudit settings. Do not edit the wrong platform while doing a scoped bump.

### Marketing version bump

Set `MARKETING_VERSION = X.Y.Z` for the selected scope. Use semver-ish `MAJOR.MINOR.PATCH`;
for a distributed platform, never decrease relative to what was already submitted in App Store
Connect. A preview-target version bump does not itself authorize or claim distribution.

For a brand-new marketing version, set that target's `CURRENT_PROJECT_VERSION = 1` unless the user explicitly requests another build number.

### Build-number-only bump

Set only `CURRENT_PROJECT_VERSION` for the selected scope. This is `CFBundleVersion`, not the user-visible version. Each upload under the same marketing version must have a higher build number than previous uploads for that same platform/version. Never decrease it.

### PMSKit fallback version

`PMSKit/Sources/PMSKit/PMSKit.swift` contains `PMSKit.version`; `PMSKit/Tests/PMSKitTests/SanityTests.swift` pins it.

The app normally passes `Bundle.main`'s `CFBundleShortVersionString` into `ClientIdentity`, so App Store-visible app headers track the target's `MARKETING_VERSION` even when `PMSKit.version` differs.

Update `PMSKit.version` only when:

- scope is `all` and the user expects the shared fallback to match the coordinated app version, or
- scope is explicitly `toolkit` / shared library.

Do **not** blindly sync `PMSKit.version` during a single-platform bump unless the user asks.

## Do NOT touch

- `Labstream/Platforms/visionOS/App/Labstream.swift`, `Labstream/Platforms/Mobile/App/LabstreamMobile.swift`, `Labstream/Shared/App/PlatformClientIdentity.swift`, or player code just to change versions; they read bundle versions automatically.
- Test fixtures that hardcode arbitrary `ClientIdentity(... version: "…")` values; those are local inputs, not the app version.
- `pyproject.toml` / `uv.lock`; that is separate Python tooling.

## Tags

Use scoped tags when release trains diverge:

- `mobile-vX.Y.Z` for `LabstreamMobile` iOS/iPadOS releases.
- `visionos-vX.Y.Z` for `Labstream` visionOS releases.
- `macos-vX.Y.Z` for explicitly approved `LabstreamMac` releases or named preview milestones.
- `tvos-vX.Y.Z` for explicitly approved `LabstreamTV` releases or named preview milestones.
- `vX.Y.Z` only for synchronized `all` releases or coordinated codebase milestones.
- `pmskit-vX.Y.Z` only for an intentional toolkit/fallback release.

Every completed marketing-version release or named milestone bump needs its corresponding annotated tag. Check
both local and remote tags before committing. Create the tag only after the version-bump commit
exists and commit/tag authorization is explicit; otherwise report the expected tag as pending.

```sh
git tag -a mobile-vX.Y.Z -m "LabstreamMobile X.Y.Z"
git tag -a visionos-vX.Y.Z -m "Labstream visionOS X.Y.Z"
git tag -a macos-vX.Y.Z -m "Labstream macOS X.Y.Z"
git tag -a tvos-vX.Y.Z -m "Labstream tvOS X.Y.Z"
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

### macOS preview bundle

```sh
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamMac \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/DerivedData-version-macos build CODE_SIGNING_ALLOWED=NO
APP=build/DerivedData-version-macos/Build/Products/Debug/Labstream.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
```

### tvOS preview bundle

```sh
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj -scheme LabstreamTV \
  -destination 'generic/platform=tvOS Simulator' -configuration Debug \
  -derivedDataPath build/DerivedData-version-tvos build CODE_SIGNING_ALLOWED=NO
APP=build/DerivedData-version-tvos/Build/Products/Debug-appletvsimulator/Labstream.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"
```

For build-number-only release prep, verify the marketing version stayed unchanged and the build
number changed only for the selected scope.
