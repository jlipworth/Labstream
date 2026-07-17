# macOS development preview

Labstream includes a native macOS target on `main` for local source builds. The target and
scheme are named `LabstreamMac`, require macOS 26, and share the app source tree and `PMSKit`
package with the visionOS and iOS/iPadOS targets.

The Mac target is a **development preview**, not a released or supported App Store product.
Its final distribution, signing, credential-sharing, versioning, and App Store Connect strategy
remain deferred. In particular, the repository's GPL section-7 exception currently names the
visionOS, iOS, and iPadOS application paths; Mac distribution requires a separate licensing and
release review.

## Current implementation

The preview provides a native Mac app shell and adapts the shared browse, search, detail,
playback, music, downloads/offline, settings, diagnostics, and backend flows for the host Mac.
Mac-specific code supplies window commands, keyboard navigation, fullscreen/player presentation,
and system media integration while backend wire behavior and pure policies remain shared.

Treat this as source-build coverage rather than a compatibility promise. Real Plex, Jellyfin,
and Emby authentication, media-key behavior, playback, and background-download recovery still
need platform-specific validation.

## Build, stage, and launch

There is no macOS simulator lane. Use the host helper, which builds an arm64 Debug app into
worktree-local DerivedData and stages it under the repository rather than installing into
`/Applications`:

```sh
scripts/deploy-macos-to-host.sh          # build + stage
scripts/deploy-macos-to-host.sh --launch # build + stage + launch
scripts/deploy-macos-to-host.sh --no-build --launch
```

By default, the helper derives a development bundle identifier from the worktree, such as
`com.jlipworth.Labstream.dev.issue-228-macos`. The staged app lives at
`build/macos-host/<identity>/Labstream.app`. This keeps parallel worktrees from sharing a sandbox,
offline library, LaunchServices identity, or background-download session.

Noncanonical Mac development identities also use isolated, backup-excluded credential files in
their sandbox instead of the production Keychain path. This avoids repeated Keychain prompts as
an ad-hoc development app is rebuilt. The canonical production-style identity continues to use
the normal Keychain policy, but it should be exercised only for intentional identity testing.

`--use-production-bundle-id` switches to `com.jlipworth.Labstream`. Do not use it for routine
development: multiple production-identity builds share the same LaunchServices identity,
sandbox, Keychain behavior, and logs.

## Cleanup

Clean up host preview state after a one-off test or before removing its worktree:

```sh
scripts/deploy-macos-to-host.sh --delete
scripts/deploy-macos-to-host.sh --delete-all-staged
scripts/deploy-macos-to-host.sh --reset-container
```

Development identities use the visible display name `Labstream Dev — <identity>`, while an
intentional production-identity build remains `Labstream`. `--delete-all-staged` terminates and
removes every Mac app staged by the current worktree but preserves containers and Keychain data.

The production-identity host path is Apple-Development-signed and provisions the Mac because its
canonical service reads the synchronized Plex-token Keychain item. An ad-hoc canonical build lacks
an application identifier/keychain group and fails that access with OSStatus `-34018`; use the
helper rather than launching a generic ad-hoc product for signed-in testing.

`--delete` removes only the staged app for the effective identity. `--reset-container` removes
only that identity's sandbox container. The helper never deletes `/Applications/Labstream.app`,
and resetting the canonical container requires both `--use-production-bundle-id` and
`--allow-production-container-reset`.

## Validation

The Mac scheme owns the `LabstreamMacTests` target and `LabstreamMacTests.xctestplan`. The plan
hosts the shared `LabstreamTests/` sources in `LabstreamMac`; run it directly when changing
app-owned persistence, lifecycle, auth-storage, or playback/system-media seams:

```sh
scripts/xcodebuild-versioned.sh -project Labstream.xcodeproj \
  -scheme LabstreamMac -testPlan LabstreamMacTests \
  -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
```

The current repeatable Mac sweep is:

```sh
scripts/validate-macos-228.sh
```

The script retains its issue-era filename for now. It covers static identity checks, the Mac
build, visionOS and iPhone-simulator builds, focused PMSKit diagnostics tests, and a bounded host
launch smoke through `scripts/smoke-macos-host.sh`. It does not prove real sign-in, subjective UI
quality, live media playback, system media keys, background-download durability, or the full
app-hosted test plan.

See [Testing strategy](TESTING-STRATEGY.md) for the repository-wide validation layers.

## Release status

The Mac target currently has its own marketing/build settings so its development work does not
silently join the visionOS/iOS release train. Before any Mac archive or distribution, the project
must explicitly decide and review:

1. licensing and the GPL section-7 exception's platform scope;
2. App Store Connect SKU or universal-purchase structure;
3. production bundle identifier, signing, sandbox, and entitlements;
4. production Keychain service and cross-device credential behavior;
5. version/build-number policy and the full validation matrix;
6. App Store/TestFlight versus notarized direct distribution.

Downloads remain inside the app container for the preview. External download folders and
security-scoped bookmark migration are deferred.
