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
| Exact P7 source, unchanged original delivery | Native failure and bounded original-HLS reproduction established | Exact source size/duration/basename bound; Original copy-request playback yields visible PQ/BT.2020 buffers without candidate; final selected copy initialization has no DV configuration box | Exact source size/duration/basename bound; Original yields visible PQ/BT.2020 buffers without candidate; final selected copy initialization has no DV configuration box |
| Exact P7 source, configuration-only HDR10-base candidate | Exact short-clip plus live multi-segment playback, 600-second seek and fresh-session reopen pass with inspected frames | Not enabled; final selected copy initialization lacks the retained DV configuration this candidate targets | Not enabled; final selected copy initialization lacks the retained DV configuration this candidate targets |
| P5 without compatible base | Exact P5 source stops at encoding consent; no encode or visual pass | Same exact P5 source stops at encoding consent; no encode or visual pass | Exact P5 source is blocked before playback request by the retained guard |
| P8 variants | Exact-bound P8.1 copy attempt fails then requests encoding consent; no encode or visual pass | Exact-bound P8.1 representative Original produces inspected PQ/BT.2020 frames; no DV processing claim | Same exact P8.1 source passes Original with inspected PQ/BT.2020 frames; final-child configuration unverified |
| Ordinary HDR10 control | Distinct-source native Original regression passes without selecting candidate | Same-source binding, fresh reopen and corrected copy seek pass with inspected frames | Same-source bound Original video-copy playback passes with inspected PQ/BT.2020 frames |
| SDR control | Candidate regression and cross-backend binding open | Open | Open |

The current evidence isolates one retained P7 configuration/native decoder boundary.
It does not yet establish backend-wide DV predictability, all-profile support or a
production-ready fix. Physical DV processing and HDR luminance remain separate gates.

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
not full DV enhancement processing or calibrated display luminance.
Both tested audio directions now pass: AAC encoding to AC-3 copy and the reverse,
with video copy and inspected post-transition frames. The earlier replacement failure
was a fail-closed initialization rejection, not a decoder failure. Its captured AC-3
entry justified a narrow additional whitelist: the exact observed six-channel, 48 kHz
sample-entry header and `dac3` configuration, with an optional well-formed `btrt` box.
Audio bytes remain unchanged; other AC-3 configurations, E-AC-3, encryption and unknown
extensions remain rejected. Regression coverage verifies exact byte preservation and
rejection boundaries.

A subtitle transition reached explicit encoding consent because the server selected
video transcode; no consent was granted and no post-transition visual pass is claimed.
Quality transitions and server-side cleanup confirmation remain open; local listener
teardown alone does not establish server cleanup.

The same-source Jellyfin binding matches exact file size, duration and basename under a
different mount prefix. Original playback and fresh-process reopen pass with inspected
PQ/BT.2020 frames. Earlier seeks to 600 and 1,200 seconds became ready and buffered,
then paused through a nonadvancing hold. An ordinary HDR10 source reproduced the same
failure, so it was not specific to P7. Instrumentation showed successful, current-item
seek completion with no user pause intent but a paused player. A guarded explicit
`play()` experiment briefly resumed then paused again; it was rejected and reverted.
A bounded debugger trace observed application `pause()` calls only at deliberate detach
and final stop, not at the intervening stall. Debugger timing is not acceptance evidence.

The existing short-buffer policy disabled automatic waiting for Jellyfin but already
retained it for Emby video-copy reopens. Extending that exception only to **verified
Jellyfin video-copy HLS** fixes the bounded reproductions: HDR10 seek from about 3,600
to 2,400 seconds and P7 seek from about 1,200 to 600 seconds both pass advancing holds
and inspected PQ/BT.2020 post-seek frames. The 12-second buffer target, paused-loading
setting, source/session authority and encoding consent are unchanged. This is a transport
recovery correction, not P7 decoding or DV support. Final selected-copy initialization
is now captured as described below; compressed
RPU/enhancement-layer sample inventory remains unverified.

Normal app authentication and exact-source binding are complete on both media-browser
backends. The corrected collector runs **after** all enforced copy-child selection and
delivery rewrites, on the final URL handed to AVPlayer. Earlier captures were from the
negotiated open before those rewrites and are not independently final-child evidence.
A 256 KiB diagnostic cap declined the long Jellyfin playlist; a technical-only report
identified its 889,210-byte declared length. The opt-in diagnostic playlist limit is now
1 MiB, enforced on both declared and received bytes; its initialization limit remains
1 MiB. **The runtime P7 proxy's 256 KiB playlist limit is unchanged.** Same-origin and
no-redirect protections remain; only initialization and technical reports are exported.

Fresh final-child P7-source captures from Jellyfin and Emby each contain `hvc1`, `hvcC`,
`colr` and `pasp`, but no `dvcC`/`dvvC`. Their `hvcC` payloads are byte-identical to the
captured Plex P7 configuration, and limited-range PQ/BT.2020 signaling matches. Both
original descriptions pass native decoder construction. This establishes a delivered
configuration difference and format admission, not native P7 reconstruction or removal
of compressed RPU/enhancement-layer data. Inspected native frames provide the separate
bounded playback evidence.

An initial Emby seek report was invalidated by a probe defect: a detached player's NaN
clock bypassed the wait and immediately reported a deadline. A finite-position predicate
now keeps that clock pending, with focused regression coverage. The corrected short
backward seek and a separate forward jump from about 630 to 1,200 seconds pass with
inspected post-seek frames and advancing 25-second holds. The early negotiated-open
replacement initialization also retains the same HEVC/color
configuration without a DV configuration box; its final-child provenance remains open.
This correction does not explain away Jellyfin's earlier sustained paused hold.
Read-only, exact-source Jellyfin server logs show video copy and AAC encoding, with the
seek segment job continuing after the client pause; delayed prior-stop timing alone does
not establish that cleanup killed the replacement job.

The exact P8.1 representative passes Original through Jellyfin and Emby, but Plex's
copy attempt fails before inspected frames and stops at encoding consent. Its captured
initialization has a 23-byte `hvcC` with zero parameter arrays and a `dvvC` atom.
The decoder-construction probe returns -4 with or without the DV atom. This is not the
same proven configuration-only P7 boundary, and the P7 candidate must not admit it.
Other P8 variants remain untested.

Read-only exact-source job checks observed graceful quit in the latest Jellyfin P7 and
Emby P8 remux logs and absence of their specific playlist/cache paths after stop. These
are bounded job-cleanup observations, not proof of every backend resource or session's
cleanup. They do not justify changing session-stop authority.

A distinct ordinary HDR10 source passes Original playback on the candidate build without
selecting the P7 route. This is not a same-file extracted-base control. Latest-source
validation is recorded below, separately from live media acceptance.

### Candidate validation status

- Hermetic PMSKit: 1,706 Swift Testing cases and 119 XCTest cases pass, including exact
  AC-3 preservation and rejection boundaries. The final-source focused macOS
  playback-evidence suite passes all 11 cases, including
  initialization-only and same-origin capture tests. This does not erase full-suite failures.
- Fresh final-source native macOS and generic iOS/tvOS/visionOS builds pass. The final-source
  owned iPhone and tvOS semantic fixtures pass with inspected app-view test attachments
  and verified install identity. Hygiene, strict documentation, link/anchor and Mermaid
  checks pass.
- Full hosted suites are **not green**. The final-source macOS run (636 Swift Testing cases)
  fails both `sustainedOfflineInitialWait` expectations and the replacement deadline in
  `delayedTrackReplacementDoesNotAcceptThePredecessor`. The final-source iOS run (620)
  has the same three failures; final tvOS (338) fails the two Offline expectations.
  Prior macOS full runs also failed
  `delayedTrackReplacementDoesNotAcceptThePredecessor` and four revalidation expectations
  in `activeToInactiveCancelsOnlyHeldRevalidationAndActiveRetriesExactlyOnce`.
  Prior iOS (617) and tvOS (340) runs failed the two Offline expectations.
- A fresh isolated macOS build of the exact inherited pre-DV base `3f1c8e0b` reproduces
  the same replacement deadline and both Offline expectations in two full 633-case runs.
  The local preparation-state implementation, replacement wait, and replacement test
  are byte-identical to the base. This demonstrates those failures predate this DV work
  on macOS; it is not an iOS/tvOS baseline run or a waiver of full-suite gates. Earlier
  revalidation failures have not been separately attributed. An immediate full candidate
  repeat reproduces the same three failures and additionally fails a consent-test condition
  deadline and the revalidation first-attempt wait (five issues total). Those additional
  failures remain unresolved; a focused green suite does not remove them.
- Two earlier tvOS hosted processes did not exit after their failed summaries; each was
  terminated after a 300-second no-progress bound (exit 143). The final-source tvOS run
  exits normally with test-failure status 65. Passing fixtures do not erase the earlier
  runner failures. All owned simulators are shut down.
- VisionOS install/run remains blocked by the missing canonical golden-simulator pointer;
  no other task's simulator is substituted. Hardware DV processing, HDR luminance,
  backend-wide profile support and release acceptance remain open.
