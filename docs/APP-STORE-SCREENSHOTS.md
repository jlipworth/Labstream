# App Store screenshot automation

Labstream's App Store capture workflow uses the real native shells with the Debug-only synthetic
browse catalog. It does not authenticate, contact a media server, or read persisted accounts. Raw
runner evidence remains ignored; the export contains only JPEGs and a sanitized checksum manifest.

## Apple requirements checked on 2026-08-21

Apple allows one through ten screenshots per device size in PNG, JPEG, or JPG and forbids alpha
channels. Apple's current accepted capture sizes relevant to the preferred Labstream lanes are:

| Product | Preferred store export | Other accepted sizes used by fallback checks |
| --- | --- | --- |
| Apple Vision Pro | 3840 × 2160 | None |
| iPhone | 1206 × 2622 portrait (iPhone 17/17 Pro lane) | The checked manifest also includes Apple's current 6.9-, 6.5-, 6.3-, and 6.1-inch portrait sizes |
| iPad | 2064 × 2752 portrait (13-inch M5/M4 lane) | 2048 × 2732 and current 11-inch portrait sizes |
| Apple TV | 3840 × 2160 | 1920 × 1080 |
| Mac | 2560 × 1600 | 1280 × 800, 1440 × 900, and 2880 × 1800 |

The machine-readable checked set and verification date live in
`scripts/app-store-screenshot-specs.json`. Recheck it before each release against Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
and [upload requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots).
Apple can change the accepted device families and dimensions independently of this repository.

## Capture all native targets

Acquire the repository's one-simulator lease first. No other simulator may be booted. The workflow
provisions or resolves only IDs recorded by `scripts/worktree-sim.sh`, captures one target at a
time, and each runner shuts its simulator down before the next target starts.

```sh
scripts/app-store-screenshots.py capture --target all --allow-simulator
```

To capture only one or more products, repeat `--target` in canonical target names:

```sh
scripts/app-store-screenshots.py capture \
  --target iphone --target ipad --allow-simulator
scripts/app-store-screenshots.py capture --target macos
```

The command prints the absolute `store-ready` directory. Validate an existing export without
launching anything:

```sh
scripts/app-store-screenshots.py validate \
  artifacts/app-store-screenshots/<UTC timestamp>/store-ready
```

Capture refuses an uncommitted source tree so its manifest commit is authoritative. The explicit
`--allow-dirty` escape hatch is for local layout review only; its manifest records `gitDirty: true`
and must not be used as release evidence.

Validation fails unless every requested image has an Apple-accepted pixel size, no alpha channel,
and the SHA-256 recorded in the sanitized manifest. iPhone, iPad, Apple TV, and Apple Vision Pro
captures must already be native accepted dimensions; they are never stretched. The isolated Mac
window capture is aspect-fit onto a dark 16:10 canvas and exported at 2560 × 1600. Every store file
is encoded as a maximum-quality JPEG so alpha is structurally absent.

## Determinism and privacy boundary

The capture scenarios use `--ui-testing --ui-testing-backend plex --ui-testing-fixture browse`.
The fixture contains invented titles, people, studio names, summaries, IDs, and a non-resolving
`fixture.invalid` URL. Artwork requests cannot reach a real service, so the production UI renders
its own placeholders. Visible merchandising copy avoids test-only labels, and mobile captures
temporarily override the simulator status bar to 9:41 with full Wi-Fi and battery before clearing
the override during cleanup. Release builds do not compile the catalog.

The export deliberately excludes runner logs, video, `.xcresult` data, app paths, simulator IDs,
host paths, and launch manifests. Do not replace these captures with a signed-in simulator or copy
raw evidence into App Store metadata. Keep the generated `artifacts/` tree untracked.

## Automated versus gated

The workflow fully automates clean builds, exact-product installation, fixture launch, process/log
smoke checks supplied by the platform runners, window/device capture, conversion, dimensions,
alpha rejection, and checksum validation where the local runtime prerequisites are available.

These gates remain outside automation:

- **Apple Vision Pro interaction:** Xcode 27's supported repository path is passive. The automated
  store image is Home. A detail, gaze/hover, pinch-drag, immersive, or hardware-specific image needs
  a person on the simulator or headset; coordinate clicking must not be used.
- **Mac host permissions:** the isolated Accessibility driver and window-only screen capture require
  the host permissions documented in [macOS development](MACOS.md). A missing permission is a
  blocker, not permission to fall back to a full-desktop capture. A headless host can also refuse
  to make the window frontmost; the window-only image remains private and deterministic, but a
  release owner should focus and recapture if the controls appear dimmed.
- **Hardware truth:** simulator images do not prove HDR, HDMI/audio, Siri Remote, gaze, comfort,
  performance, or physical-device rendering.
- **Editorial and legal review:** a person must inspect every final image for composition, clipped
  content, transient system UI, accurate product representation, and marketing/legal suitability.
  Pixel and checksum validation cannot make that judgment.
- **Upload:** App Store Connect authentication, localization, ordering, and final upload remain a
  release-owner action. The workflow never accepts App Store credentials.
