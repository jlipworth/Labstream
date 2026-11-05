# App Store screenshot automation

`scripts/app-store-screenshots.py` has two capture modes that share one export format and
validator:

- **Fixture mode** (`capture`) drives the real native shells with the Debug-only synthetic browse
  catalog and launch routes. It does not authenticate, contact a media server, or read persisted
  accounts. Its images are **layout evidence only**: every manifest says so, and none may be
  uploaded.
- **Live-catalog mode** (`live start|shot|finish`) captures an ordinary signed-in session against
  the controlled licensed review catalog. The exporter launches the installed app with no arguments
  at all, a person signs in and navigates normally, and each shot requires the same process to
  still be running. This is the only lane that can produce final images; see the
  [licensed-media capture plan](https://github.com/jlipworth/Labstream/blob/main/docs/plans/2026-09-15-store-demo-capture.md).

The licensed catalog's public source and license provenance is checked in at
[`scripts/app-review-media-provenance.json`](https://github.com/jlipworth/Labstream/blob/main/scripts/app-review-media-provenance.json)
and covered by `scripts/tests/test_app_store_screenshots.py`. Raw runner evidence stays under the
ignored `artifacts/` tree; an export contains only JPEGs and a sanitized checksum manifest.

## Apple requirements checked on 2026-11-05

Source: Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications),
[upload requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots),
and the linked [iPhone Duo launch page](https://developer.apple.com/iphone-duo/). Apple allows one
to ten PNG, JPEG, or JPG screenshots per device size and forbids alpha channels and transparency.
Apple can change classes and sizes independently of this repository, so recheck before each release.

Apple's page now names iPhone classes rather than inch sizes. Its "Required device sizes" section
reads: *"iPhone: At least one screenshot for iPhone with Dynamic Island (medium display)"* and
*"iPad (if your app supports iPadOS): At least one screenshot for iPad 13-inch display."* Mac, Apple
TV, and Apple Vision Pro screenshots are each required for apps on that platform.

| Apple display class (repository shorthand) | Accepted portrait / landscape pixels | Apple's requirement text | Exporter target |
| --- | --- | --- | --- |
| Apple Vision Pro | 3840 × 2160 | Required for Apple Vision Pro | `visionos` |
| iPhone Duo, outer display | 1398 × 2034 / 2034 × 1398 | Starting in April 2027, required for any app using the iOS 27.1 SDK or later; submitting Duo screenshots adds a "made for iPhone Duo" product-page badge | `duo-outer` |
| iPhone Duo, inner display | 2007 × 2853 / 2853 × 2007 | Same as outer | `duo-inner` |
| iPhone with Dynamic Island, large ("6.9-inch") | 1260 × 2736, 1290 × 2796, 1320 × 2868 (and landscape) | None stated; falls back to scaled Face ID (large) | `iphone69` (1320 × 2868) |
| iPhone with Face ID, large ("6.5-inch") | 1284 × 2778, 1242 × 2688 (and landscape) | Required if the app runs on iPhone and Dynamic Island (large) screenshots aren't provided | none (fallback class) |
| iPhone with Dynamic Island, medium ("6.3-inch") | 1179 × 2556, 1206 × 2622 (and landscape) | Required (see above) | `iphone` (1206 × 2622) |
| iPad 13-inch | 2064 × 2752, 2048 × 2732 (and landscape) | Required if the app runs on iPad | `ipad` (2064 × 2752) |
| Apple TV | 1920 × 1080 or 3840 × 2160 | Required for Apple TV apps | `tvos` (3840 × 2160) |
| Mac | 1280 × 800, 1440 × 900, 2560 × 1600, 2880 × 1800 | Required for Mac apps | `macos` (2560 × 1600) |

Smaller iPhone and iPad classes are optional and scaled from these. Labstream builds with the
iOS 27.1 SDK, so the Duo requirement applies to its submissions from April 2027; a 1.8.0 submission
before then may omit Duo screenshots but loses the badge.

### What Apple's page does not state (recorded as unknown)

- No inch sizes: "6.9-, 6.5-, 6.3-inch" are repository shorthand for the named classes.
- It does not reconcile its two iPhone rules: Dynamic Island (medium) is listed as required, while
  Face ID (large) is required unless Dynamic Island (large) is provided. Coverage enforces both, so
  the conservative iPhone set is **6.3-inch and 6.9-inch** (or 6.3-inch and the 6.5-inch fallback).
- It gives only "April 2027" for Duo; coverage treats 2027-04-01 as the effective date.
- It does not say whether both Duo displays are needed or whether either one suffices, or whether
  Duo screenshots scale to/from other iPhone classes. Coverage requires both Duo displays.

These rules and unknowns are machine-readable in `scripts/app-store-screenshot-specs.json`
(`displayClasses`, `coverageRules`, `unknowns`, `verifiedAt`).

## Scenes and fixture routes

Each target captures named scenes, exported as `<target>-<NN>-<scene>-<W>x<H>.jpg` so the number
gives the upload order. Fixture mode reaches each scene through Debug-only launch routes, so no
simulator taps are needed:

| Scene | Fixture route | Targets |
| --- | --- | --- |
| home | `--ui-testing-fixture browse` | all |
| library | `--ui-testing-open-first-library` | all (the Mac sidebar selects its first library row) |
| detail | `--ui-testing-open-item plex-orbit` | all |
| playback | `--ui-testing-fixture player --ui-testing-player-paused` (Mac unpaused; Duo inner adds `--ui-testing-player-present-delay 8` so the appResize session starts first) | iPhone, iPad, Duo, tvOS, Mac; **visionOS has no fixture route** (spatial player, passive-only simulator) |
| downloads | `--ui-testing-initial-tab offline` | all except tvOS (streaming-only, no Downloads) |

The tab, first-library, and open-item routes are applied for every product by `RootView`
(`DebugUITestLaunchConfiguration.applySharedCaptureRoute`); Settings routing stays in the mobile
shell. The platform runners pass routes through `--launch-arg`, which accepts only `--ui-testing-*`
flags and plain values.

Mobile playback locks to landscape, so those images are landscape sizes of the same class. The Duo
inner target is a **proxy**: a `devicectl device appResize` session at 669 × 951 points (3×, Apple's
2007 × 2853 inner size) on the folded simulator, cropped from the Resizable display. Simulator
folding is GUI-only and `simctl io screenConfig` power changes do not unfold the device, so the
proxy proves layout only. Live Duo inner captures read the real inner display (`primary-1`) after a
person unfolds the simulator in Device Hub; live outer captures read `primary`.

## Fixture capture

Hold the repository's one-simulator lease first. No other simulator may be booted. The exporter
resolves only IDs recorded by `scripts/worktree-sim.sh`, captures one target at a time (building
once per target and keeping the simulator booted between its scenes), and shuts each simulator
down before the next target. The 6.9-inch lane uses its own Pro Max-only simulator
(`scripts/worktree-sim.sh --platform iphone69 setup`); the default iPhone simulator is unchanged.

```sh
scripts/app-store-screenshots.py capture --target all --allow-simulator
scripts/app-store-screenshots.py capture --target iphone69 --target duo-outer \
  --scene home --scene detail --allow-simulator
scripts/app-store-screenshots.py capture --target macos
```

Targets: `visionos`, `iphone`, `iphone69`, `ipad`, `duo-outer`, `duo-inner`, `tvos`, `macos`.
The command prints the export directory, `artifacts/app-store-screenshots/<UTC>-fixture/export`.
Scenes without a fixture route are listed in the manifest's `skippedScenes`.

Capture refuses an uncommitted source tree so its manifest commit is authoritative. The explicit
`--allow-dirty` escape hatch is for local layout review only; its manifest records `gitDirty: true`.

## Live-catalog capture

Live mode never passes launch arguments and never accepts credentials. Install the release
candidate on the target's worktree simulator first, then for each target:

```sh
scripts/app-store-screenshots.py live start --target iphone69 --allow-simulator
# A person signs in to the review server through the normal Jellyfin login, then navigates.
scripts/app-store-screenshots.py live shot <session> --scene home
scripts/app-store-screenshots.py live shot <session> --scene detail
scripts/app-store-screenshots.py live finish <session>
```

`live start` refuses to boot while another simulator is booted, overrides the iPhone/iPad status bar
to 9:41 with full signal, launches with no arguments, and records the process ID plus the installed
marketing/build version. `live shot` refuses a relaunched process, waits for two identical frames,
checks the display-class size, and replaces any earlier shot of the same scene. `live finish`
clears the status bar and shuts the simulator down. A session's export lives at
`<session>/export`. macOS has no live lane yet; capture its window by hand with the isolated host
path and apply the same checks.

## Validate and check coverage

```sh
scripts/app-store-screenshots.py validate <export>
scripts/app-store-screenshots.py coverage <export> [<export> ...] [--live-only] \
  [--target ipad ...] [--as-of 2027-04-01] [--include-upcoming]
```

`validate` fails unless every image has an accepted pixel size for its target's display class, no
alpha channel, the recorded SHA-256, at most ten images per class, and the wording that matches its
mode: fixture entries must record their `--ui-testing` flags and the fixture content line; live
entries must record an empty argument list and the live-catalog content line. No manifest may claim
`releaseEligible: true`; release approval is a human decision outside the tool.

`coverage` validates each export, unions their display classes, and fails on any missing
`coverageRules` entry. Requirements that are not yet in effect (Duo before April 2027) are reported
as `upcoming` and fail only with `--include-upcoming`. Use `--live-only` for a release set so a
fixture export can never satisfy coverage.

## Determinism and privacy boundary

Fixture captures use `--ui-testing --ui-testing-backend plex --ui-testing-fixture browse|player`
plus routes. The fixture contains invented titles, people, studio names, summaries, IDs, and a
non-resolving `fixture.invalid` URL. Artwork requests cannot reach a real service, so the production
UI renders its own placeholders. Mobile captures override the status bar to 9:41 with full Wi-Fi and
battery and clear it during cleanup. Release builds do not compile the catalog or routes.

Exports exclude runner logs, video, `.xcresult` data, app paths, simulator IDs, host paths, server
addresses, accounts, and launch manifests. Keep the generated `artifacts/` tree untracked.

## Automated versus gated

Automated: clean builds, exact-product installation, fixture launch per scene, process/log smoke
checks supplied by the platform runners, device/window capture, Duo display selection, conversion,
dimensions, alpha rejection, checksums, mode wording, and display-class coverage.

Outside automation:

- **Apple Vision Pro interaction and playback:** Xcode 27's supported path is passive. Live
  navigation, authentication, and spatial playback need a person on the simulator or headset;
  coordinate clicking must not be used.
- **iPhone Duo folding:** the inner fixture image is an appResize proxy; a real unfold (Device Hub
  or hardware) is required for final inner images.
- **Mac host permissions:** the isolated Accessibility driver and window-only capture require the
  host permissions in [macOS development](MACOS.md). A missing permission is a blocker, not a reason
  to capture the full desktop.
- **Hardware truth:** simulator images do not prove HDR, HDMI/audio, Siri Remote, gaze, comfort,
  performance, or physical-device rendering.
- **Editorial and legal review:** a person must inspect every final image for composition, clipped
  content, transient system UI, branding, licensed artwork, credits, and privacy.
- **Upload:** App Store Connect authentication, localization, ordering, and upload remain a
  release-owner action. The workflow never accepts App Store credentials.
