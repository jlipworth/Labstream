# Native HDR validation

Active investigation: [Plex DV P7 decoder failure (#316)](https://github.com/jlipworth/Labstream/issues/316).
This is not a universal platform-support or release-readiness claim.
The live results below cover Plex only. Equivalent exact-source Jellyfin and Emby
validation is untested here; cross-backend acceptance remains open.

## Evidence levels

Keep these independent:

1. Source codec, container, HDR transfer and Dolby Vision profile.
2. Server copy/encode decision and delivered initialization/stream signaling.
3. Successful decoding, advancing playback and inspected decoded frames.
4. The actual player screen's eligibility, potential EDR and current headroom.
5. Measured or device-observed HDR presentation. SDR screenshots and tone-mapped probe
   PNGs cannot establish luminance, colorimetry, DV processing or HDR10+ preservation.

Stats **Stream signal** reports observed AVFoundation stream facts when available. Until
then it marks copy/encode intent unverified. It must not predict successful HDR10 fallback
from a DV source label or claim successful server tone-mapping from an encode request.

## Current bounded results

| Platform | Evidence | Remaining gate |
| --- | --- | --- |
| Native Mac, macOS 27 beta | HEVC Main10/PQ/BT.2020 copy control decoded with HDR both off and on; inspected frames. Actual player-screen diagnostics distinguish eligible HDR from SDR. | HDR luminance/colorimetry; paused mixed-screen moves/hot-plug; wider source/profile coverage. |
| Physical iPad | Paired device discovered; signed deployment attempted. | Xcode preparation/unlock/connectivity; no candidate hardware playback claim. |
| Physical iPhone | Paired device discovered; deployment attempted. | Device unavailable to Xcode; no candidate hardware playback claim. |
| Physical Vision Pro | Paired device discovered, unavailable. Existing app not removed. | Wake/unlock and physical test. |
| Physical tvOS | No hardware available. | Device/display/link test; simulator is not a substitute. |

On the tested Mac, a DV P7 MKV source delivered by Plex as `hvc1` fMP4 retained a
profile-7 `dvcC` record alongside PQ/BT.2020 `colr` signaling. VideoToolbox rejected decoder
creation (-12906/-12910), surfaced as AVFoundation -11855. Both HDR-on master playback
and HDR-off single-child playback failed. The ordinary HDR10 control without that DV
configuration decoded successfully, but it is a different library file, not an
exact-source base-layer derivative. This isolates a profile/packaging gate more narrowly
than display eligibility, but does not yet prove which normalization would be safe.
The [P7 decoder-boundary investigation](dv-p7-decoder-boundary.md) records the
exact-initialization contrast and remaining sample-level gates.

The HDR10 control also produced decoded 3840×2160 buffers with PQ transfer and BT.2020
primaries/matrix attachments. Explicit 8 Mbps encoding of the failing DV source passed
playback/seek with inspected frames and decoded 1920×1080 BT.709 attachments (SDR).
Neither result establishes measured display luminance or native DV output. Original's explicit-consent boundary remained intact. Do not
strip DV configuration or enhancement data blindly, change the P5 guard, or silently encode.

One tested scaled display mode hid the HDR switch; default scaling exposed it. Temporary
scaling and HDR changes were restored. That host-specific observation is not a universal
macOS scaling rule or a diagnosis of a cable/adapter.

## Simulator evidence boundaries

| Simulator runtime | HDR10 control | Source-verified HDR10+ file | Remaining gate |
| --- | --- | --- | --- |
| iPhone, iOS 27 | Copy, actual 60-second seek/hold, inspected post-seek frames passed. | Same bounded sequence passed; decoded PQ/BT.2020. | Dynamic-metadata preservation/application and physical output unknown. |
| iPad, iOS 27 | Copy, actual 60-second seek/hold, inspected post-seek frames passed. | Same bounded sequence passed; decoded PQ/BT.2020. | Same limits; normal server selection required. |
| tvOS 27 | Copy, actual 60-second seek/hold, inspected post-seek frames passed. | Same bounded sequence passed; decoded PQ/BT.2020. | Same limits; hardware decoder/display not established. |
| visionOS 27 | Not run. | Not run. | Missing root golden simulator pointer; root checkout not modified. |

These are individual source/path results, not universal HDR10+ support. No video-encoding
consent was granted in these six copy tests. Retain the initial missing-auth, wrong-server
and UI-harness attempts; they are not decoder failures. Normal tvOS pairing persisted even
though the first UI test expected a phone-only Copy button; the corrected readiness locator
compiled but was not re-run live, to avoid signing out the saved session.

A normal Plex link can be completed through the explicitly opted-in mobile live-auth
UI test and the Codex in-app browser even when Device Hub accessibility is unavailable.
On iPad, use the actual floating Home button rather than assuming a phone-style tab bar.
Server selection must finish before UI-test teardown; a successful tap followed by
“Selecting…” is not a completed server switch. Confirm the exact source after relaunch.

Source HDR10+ classification requires evidence beyond a release filename or Plex's HDR10
label. A bounded source-frame probe found SMPTE2094-40 dynamic metadata in a corpus
candidate; private Plex discovery matched its path suffix and size. PQ/BT.2020 delivered
initialization and decoder-buffer attachments alone cannot establish preservation or
application of that dynamic metadata. Keep those results unknown unless separately tested.

The `original` scenario verifies progression/hold, **not seek**. A folder named
`plex-postseek` is reused by the capture helper even for a non-seek scenario; use the
report's scenario and position snapshots as evidence. Run `seek` at bitrate zero for an
Original-quality seek test without granting video-encoding consent.

## Reproducible probes

Use exact source binding and the existing explicit live/encoding admission flags. Native
Mac probes now create a real isolated player-layer window and close it during cleanup;
headless CLI progress is not substituted for a render surface. Authentication stays in the
app's existing session, never in exported tokens.

Optional `--vp-probe-hdr-evidence` records bounded technical master attributes and a
same-origin unencrypted initialization segment inside the app container, only with
`--vp-probe-allow-live`. This adds diagnostic requests and is not a performance benchmark.
Private source references, initialization bytes, logs and frames must remain gitignored.

`--vp-probe-capture-frames --vp-probe-capture-hdr-signaling` additionally requests 10-bit
video-output buffers and records their transfer/primaries/matrix attachments beside PNGs.
Requested 10-bit storage alone does not establish source bit depth or HDR. These are
post-decoder/pre-display observations; the PNGs are not HDR measurement artifacts.

See [Apple's HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)
for delivery requirements. Apple-format support does not establish that a particular
server remux, source DV profile, hardware display or Labstream path has passed.
