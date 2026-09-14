# Dolby Vision P7 decoder boundary

Investigation for [issue #316](https://github.com/jlipworth/Labstream/issues/316).
No shipping metadata transformation or expanded device-support claim is established.
The [native HDR investigation](native-hdr-validation.md) owns general HDR evidence;
this note isolates the P7 format-description and compressed-sample gates.

## Control provenance

The passing native HDR10 control is a **different library file**, not an extracted
base layer from the failing P7 file. It disproves a blanket HDR decode failure on
that host but cannot establish safe normalization of the P7 source. The existing
same-source control is an explicitly approved capped encode: inspected decoded
frames and BT.709 attachments establish SDR output, not preserved DV or HDR10.

The failing source is HEVC Main10 in MKV with P7/HDR10-compatible base-layer facts.
Plex reports video copy and audio transcode. Its captured fMP4 initialization contains
`hvc1`, `hvcC`, `dvcC` P7 and PQ/BT.2020 color signaling. Native AVPlayer fails with
AVFoundation -11855 wrapping VideoToolbox -12910, with decoder-selection -12906.
HDR-on master and HDR-off bounded single-child attempts both failed.

## Exact-initialization experiment

On the same native macOS 27 beta host, the read-only
`scripts/dv-decoder-init-probe.swift` loads the captured local initialization file
through AVFoundation and calls `VTDecompressionSessionCreate`. It submits **no samples**.

| Format-description case | P7 HDR-on capture | P7 HDR-off capture | Separate HDR10 control |
| --- | --- | --- | --- |
| Original AVFoundation description | -12910 | -12910 | 0 |
| Reconstructed with all original extensions | -12910 | -12910 | 0 |
| Only DV atom entries omitted from extension-atom dictionary | 0 | 0 | 0 |
| Original extensions restored | -12910 | -12910 | 0 |

Both P7 descriptions contain `hvcC` and `dvcC`; the contrast removes only `dvcC`.
The configuration reports profile 7, level 6, compatibility ID 6 and BL/EL/RPU flags;
those flags describe signaling, not an inventory of compressed samples.
Subtype, dimensions and all other extensions, including color information, remain
unchanged. Round-trip and restoration controls reproduce rejection. This isolates
an admission gate in the delivered DV format description on this host. A successful
session constructor does **not** prove sample acceptance, accurate output, enhancement
layer reconstruction, AVPlayer HLS playback, seeking or physical HDR presentation.

Reproduce with private captured evidence, never a credential-bearing network URL:

```sh
mkdir -p build/dv316
swiftc -parse-as-library scripts/dv-decoder-init-probe.swift -o build/dv316/dv-init-probe
build/dv316/dv-init-probe --self-test
build/dv316/dv-init-probe /path/to/private/init.mp4
```

The deterministic self-test verifies that only DV atom dictionary entries change,
input dictionaries stay unchanged, and unrelated extensions survive. Decoder status
is a host-specific experimental result, not a portable CI assertion. The tool does
not rewrite its input, use app credentials or make a production playback change.

## Profiles and signaling are not interchangeable

- **P5** has no ordinary HDR10-compatible base layer. Keep the existing P5 safety
  guard and explicit encoding consent; this P7 experiment is not a P5 workaround.
- **P7** uses base and enhancement layers. HDR10 compatibility of the base does not
  imply that a player accepts a P7-signaled container. MEL and FEL are not equivalent:
  FEL carries nonzero residual information, while MEL does not require residual
  reconstruction. Delivering only the base is not full P7 reproduction.
- **P8.1** is HDR10-compatible; **P8.4** is HLG-compatible. Do not interpret every P8
  stream as HDR10, or relabel P7 as P8 without validating its metadata and samples.

Dolby's [UHD Blu-ray workflow, section 5](https://professional.dolby.com/siteassets/pdfs/dolby_vision_uhd_bluray_authoring_workflow.pdf)
describes the P7 base/enhancement distinction. Apple's
[HLS authoring rules](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)
and [codec-signaling appendix](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes)
describe delivery requirements and P8.1/P8.4 supplemental signaling; they do not
establish that this Plex P7 remux works on every Apple device. The
[dovi_tool implementation documentation](https://github.com/quietvoid/dovi_tool#conversion-modes)
distinguishes P8.1 RPU conversion (including removal of FEL mapping) from enhancement
layer removal. Merely changing a profile number or deleting a configuration box is
not that conversion. No new conversion dependency is introduced here.

## Exact-source sample and HLS experiment

After the host was unlocked, the isolated app reused its normal saved authentication
and exact source binding. A temporary collector requested a bounded byte range from
the first segment of the same single-variant copy playlist as its initialization.
The complete segment was 12,952,841 bytes, below the 16 MiB cap. Box lengths and
sample offsets validated that the capture was complete; an earlier 8 MiB prefix was
incomplete and was not used as decoding evidence. No full source file or credentials
were exported. The unchanged app copy path still ended with encoding consent required.

The segment contains 240 video samples spanning 10.009 seconds. Its compressed sample
inventory contains 240 type-62 RPU units and 798 type-63 wrapped enhancement-layer units.
The experiment does not determine MEL versus FEL or reconstruct the enhancement layer.

Two native VideoToolbox runs used the same timing and base configuration:

1. Omit only `dvcC` from the format-description atom dictionary; preserve all samples.
2. Additionally remove only sample NAL types 62/63, preserving VCL bytes, other NALs,
   timing and color information. This matches the base-layer separation described by
   [FFmpeg's `dovi_split` documentation](https://www.ffmpeg.org/ffmpeg-bitstream-filters.html#dovi_005fsplit).

Both runs submitted and decoded all 240 frames without errors. Their timestamp-matched
10-bit pixel-plane SHA-256 hashes were identical for every frame (193 unique images),
and output attachments were PQ/BT.2020. Late visible frames were inspected; the early
black frames are followed by visible content, not used alone as a visual pass.
This proves equivalence to the extracted base for this clip, **not** equivalence to
full P7 output, Dolby tone mapping or physical HDR luminance.

A separate native AVPlayer window then read bounded local HLS over loopback:

| Local HLS variant | Result |
| --- | --- |
| Original captured initialization and segment | -11855, no decoded-frame pass |
| Only initialization `dvcC` atom type changed to `free`, same length and byte-identical segment | Playback and local seek from 5 seconds to beyond 7 seconds; inspected visible postseek frame; PQ/BT.2020 3840×2160 buffers |
| Explicit base-only samples, repaired fragment sizes/offsets, unchanged audio and base VCL bytes | Playback and the same local seek; inspected visible postseek frame |
| Reopened configuration-only experimental HLS | Playback and local seek repeated successfully |

The explicit base-only fragment omits optional `sidx` indexes and updates video sample
sizes, audio data offset and `mdat` size; it does not re-encode video or audio. These
are **private experimental derivatives**, not an app playback transformation. The
local one-segment seek does not validate Plex server seek/restart, multi-segment
continuity, byte-range delivery or every source timestamp layout. Source media and
all experiment scripts, hashes and frames stay in private ignored evidence. Temporary
app acquisition changes are reverted and isolated resources cleaned up after testing.

## Safe-delivery acceptance gates

The bounded experiment closes sample and local-HLS gates only for this segment.
Before a shipping runtime normalization candidate can be justified:

1. Extend coverage beyond the tested initial segment: acquire bounded initialization
   and compressed sample sequences from the **same source and
   same copy session**, using normal app authentication. Bind the exact source and
   selected child in private provenance. A diagnostic child fetched independently
   is not automatically the variant that AVPlayer decoded.
2. Compare original samples with an explicitly identified HDR10 base-layer derivative.
   Preserve base VCL samples, timing, parameter sets, PQ/BT.2020 and applicable static
   HDR metadata. Inventory RPU and enhancement-layer NAL units; an initialization
   `el_present` flag alone does not establish actual sample contents or MEL/FEL type.
3. Separately test configuration-only admission, compressed-sample decoding and
   inspected frame equivalence. Retained EL/RPU data, mismatched container signaling,
   incomplete fragments and unknown source facts must not silently become “HDR10.”
4. Validate any proposed HLS remux end to end, including initial frames, seek, reopen,
   range requests and discontinuities. Require deterministic malformed-input and
   P5/P7/P8 regression coverage. Keep Generic and copy/encode consent unchanged.
5. Record physical device/display gates independently. A native decoder session or
   simulator frame cannot establish DV processing, HDR luminance or support elsewhere.

## Fallback proposal

Until those gates pass, retain the existing behavior: attempt eligible copy playback;
if it fails, stop that attempt and ask before starting a video encoder. Explain that
Original could not decode on the current path and that an approved compatibility
encode may lower resolution and produce SDR. Declining must not launch an encoder.
Do not globally block all P7, change server configuration, rewrite library files,
weaken the P5 guard or treat speculative metadata stripping as a repair.

## Scoped implementation candidate (not shipping-enabled)

The worktree candidate adds a macOS DEBUG launch-only controller route and isolated
proxy policy. It is intentionally **not** enabled by a default, release setting or
backend capability claim. Its output intent is **HDR10-base fallback**, not native DV.

- Source admission requires the exact selected single-part Plex copy source to report
  P7, level 6, compatibility 6, BL/EL/RPU present. Missing or other profile facts do not
  qualify. P5 and P8 policy remains unchanged.
- Delivered initialization is parsed structurally, not searched for a byte string.
  It must have one unencrypted `hvc1` Main10 4:2:0 video description, complete parameter
  arrays, limited-range PQ/BT.2020 `nclx`, and the matching P7 configuration. Unknown
  extensions, duplicate descriptions/configuration, truncation and unsupported boxes
  are rejected. Only the validated box type changes to `free`; byte lengths are stable.
- The selected unencrypted media playlist must explicitly admit each resource.
  Multi-variant/rendition playlists, encryption, byte-range playlists, discontinuities,
  initialization changes and unknown tags fail closed. Multiple ordinary segments and
  sliding updates are supported by the candidate policy. Real multi-segment Plex VOD
  playback is verified; live/sliding-stream behavior remains unverified. The observed
  legacy `EXT-X-ALLOW-CACHE` YES/NO advisory is accepted without changing authority.
- Initialization requests are fetched in full with a 1 MiB application read limit;
  playlists have a 256 KiB limit. All candidate redirects are refused before forwarding credentials or player responses. Client initialization
  ranges are served only after full validation/normalization, with recomputed range
  headers. Unsupported/multipart ranges fail; media segments remain byte-identical.
- Every proxy open owns fresh resource admission. Existing controller generation checks,
  proxy teardown, Plex session authority, Generic profile and encoding consent remain.

Hermetic coverage includes profile/color/encryption/truncation rejection, exact output
bytes, multi-segment admission, initialization range slices (including partial atom
headers), unknown resources and changed initialization rejection. The captured private
initialization produces exactly the previously proven experimental output. These tests
are not substitutes for live server seek, reopen or decoded-frame acceptance. No locked-screen attempt is counted as a visual pass; subsequent unlocked native
checks are recorded below.

### Three-backend acceptance matrix

All rows require exact per-backend binding to the same underlying source; matching a
movie title alone is insufficient. Record initial playback, seek, reopen, track/quality
transitions, delivery decision and cleanup separately. Do not project a Plex result onto
Jellyfin or Emby, nor classify all decoder failures as DV-specific.

| Source/control | Plex | Jellyfin | Emby |
| --- | --- | --- | --- |
| Exact P7 source, unchanged original delivery | Native failure and bounded original-HLS reproduction established | Exact source size/duration/basename bound; Original copy-request playback yields visible PQ/BT.2020 buffers without candidate; delivered configuration still unverified | Same-source delivery and native outcome open |
| Exact P7 source, configuration-only HDR10-base candidate | Exact short-clip plus live multi-segment playback, 600-second seek and fresh-session reopen pass with inspected frames | Not enabled; first establish actual packaging and retained DV configuration | Not enabled; first establish actual packaging and retained DV configuration |
| P5 without compatible base | Existing guard retained; new regression/live coverage open | Existing guard retained; new regression/live coverage open | Existing block retained; new regression/live coverage open |
| P8 variants | Candidate rejects; representative delivery/visual coverage open | Candidate not enabled; representative coverage open | Candidate not enabled; representative coverage open |
| Ordinary HDR10 control | Distinct-source native Original regression passes without selecting candidate; cross-backend binding open | Open | Open |
| SDR control | Candidate regression and cross-backend binding open | Open | Open |

The current evidence isolates one retained P7 configuration/native decoder boundary.
It does not yet establish backend-wide DV predictability, all-profile support or a
production-ready fix. Physical DV processing and HDR luminance remain separate gates.

### Candidate validation status

The pre-live candidate revision had 1,705 hermetic Swift Testing cases plus 117 XCTest
cases passing (including 13 new candidate tests). Fresh macOS, iOS, tvOS and visionOS
products build. The final iPhone and Apple TV fixture screenshots were inspected and
show expected browse UI; install identity checks pass. All owned simulators were shut
down after the serialized checks. VisionOS install/run remains blocked by the missing
canonical golden-simulator pointer; no other task's simulator is substituted.

Full hosted suites are **not green**: the final macOS run (633 tests) fails
`delayedTrackReplacementDoesNotAcceptThePredecessor`; iOS (617) and tvOS (335) fail
`sustainedOfflineInitialWait`. Earlier candidate runs also showed the Offline timing
failure on macOS and a download-keepalive cancellation timing failure on iOS. Focused
reruns pass: macOS 18 tests, iOS 13, tvOS 10. Keep the full-suite failures visible rather
than presenting focused passes as all-green hosted evidence. These tests do not exercise
the opt-in normalization lane; their baseline/reliability classification remains open.

### Unlocked native acceptance increment

The isolated macOS development identity now has a development-only network-server
entitlement. Production entitlements remain unchanged. The listener is explicitly bound
to IPv4 loopback, and repeated live socket observations show `127.0.0.1`, not a wildcard.
The listener disappears after stop. Initial failed attempts were listener-permission and
legacy-playlist-tag failures, not new decoder evidence.

The exact Plex P7 source passes Original video-copy playback over real multiple segments,
a seek to 600 seconds, and a fresh process/controller/server-session reopen. Inspected
frames contain changing recognizable scenes without obvious tint or corruption; decoded
buffers are 3840 × 2160, 10-bit `x420`, PQ and BT.2020. This establishes HDR10-base output,
not full DV enhancement processing or calibrated display luminance. Audio was encoded;
video-encoding consent was not granted. An audio-track transition is blocked: the replacement reports video/audio copy,
its different initialization is rejected with HTTP 502, and the app reaches explicit
video-encoding consent without granting it. The exact rejected audio description has
not yet been captured; do not broaden the initialization whitelist by inference.
Subtitle/quality transitions and server-side cleanup confirmation remain open; local listener teardown alone does not establish server cleanup.

The same-source Jellyfin binding matches exact file size, duration and basename under a
different mount prefix. Native Original playback and fresh-session reopen at 600 seconds without the candidate
pass their copy requests and produce inspected visible PQ/BT.2020 buffers. The separate
seek-to-600 run fails after a controller reopen: the replacement becomes ready and
buffered, then pauses and fails the hold. No post-seek frame was captured. This is an
open transition failure, not established DV decoding failure or a seek pass. Actual delivered initialization/sample
configuration is still unverified, so this is not proof that Jellyfin retained native P7.
Audio decision is unknown in the bounded report. Browser metadata alone is not delivery
proof. Emby app authentication and native acceptance remain open; the authorized password
vault is locked, so normal user credential entry is required.

A distinct ordinary HDR10 source passes Original playback on the candidate build without
selecting the P7 route. This is not a same-file extracted-base control. The newest debug
source-discovery and loopback/playlist changes require fresh affected-platform validation;
the pre-live full-suite failures above remain recorded, not erased by live passes.

Updated hermetic validation passes 1,705 Swift Testing cases plus 118 XCTest cases;
hygiene, strict documentation, links and Mermaid checks pass. Fresh updated macOS, iOS, tvOS and visionOS products build. Updated full hosted runs
remain non-green: macOS (633 tests) repeats the replacement-deadline failure and adds
four revalidation lifecycle expectations in
`activeToInactiveCancelsOnlyHeldRevalidationAndActiveRetriesExactlyOnce`; iOS (617)
and tvOS (340) repeat the two Offline preparation expectations. Do not describe these
as confirmed unrelated or silently replace them with focused passes. Updated owned iPhone/tvOS fixture smoke screenshots are inspected and both runners pass;
all owned simulators are shut down. The tvOS hosted process did not exit after its final
failed-test summary and was terminated after a 300-second bound; its separate passing
smoke does not erase that runner failure.
