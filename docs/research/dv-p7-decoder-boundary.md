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
| SDR control | Exact existing H.264 SDR library variant passes Original and 600-second seek with video/audio copy and inspected BT.709 frames | Exact-bound direct-file seek and corrected Original report pass inspected BT.709 frames | Same-file direct seek and corrected Original report pass inspected BT.709 frames |

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

### Pre-rebase candidate validation status

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


### Post-HDR integration follow-up

The DV commits were rebased onto the merged HDR dependency without changing their patches.
A bounded extension of baseline testing (five full pre-DV macOS runs total) consistently
reproduces the two Offline expectations; the replacement deadline fails in four runs.
Neither the extra consent condition nor revalidation first-attempt failure reproduces
in that bounded baseline sample. The earlier focused 22-test run covered consent and
startup-admission tests, not the revalidation lifecycle suite. Corrected targeting runs consent plus
`UnverifiedRevalidationLifecycleTests`: all 24 tests pass. Their behavioral assertions
and deadlines are unchanged from the base, but this is not sufficient to classify the full-suite failures as unrelated; those gates remain open.

An existing H.264/BT.709 library variant is the SDR control, not a newly requested encode
or extracted HDR base. Plex binds its exact media/part identifiers and passes inspected
Original copy playback. Jellyfin exposes HDR and SDR editions as separate same-title
items. The probe now permits a previously verified, case-sensitive expected item ID to
disambiguate an exact title; absent an ID, duplicate titles still fail closed. Empty,
unknown, duplicate-ID, wrong-type and fuzzy-title bindings are rejected by regression
coverage. The media-source identity check remains independent after metadata retrieval.


Both media-browser SDR sources resolve to server-reported direct play of the original
file, rather than copy HLS. Their initial Original scenario reports were **blocked** with
`decisionUnknown`: the DEBUG snapshot maps Plex decisions and enforced media-browser
HLS copy, but does not map media-browser direct play. The Original scenario requires
`.copy` before post-hold capture. This is a diagnosed evidence-classifier gap, not proof
of an encoding request or a valid Original scenario pass. Separate exact-file seek runs
to 600 seconds complete advancing holds with inspected BT.709 frames on both backends;
keep those results distinct. The initial Emby capture was an opening fade and is not
independent visual acceptance; the post-seek scene supplies the visual evidence.

Targeted test-only timeout diagnostics now record polling gaps and revalidation queue
counts without extending deadlines or changing consent policy. The first instrumented
full macOS run did not reproduce consent/revalidation failures, but failed both Offline
expectations and a home-provider progressive-order expectation. These variable full-suite
failures remain unresolved; focused passes and instrumented non-reproduction do not waive
them. Coordinated 1.7.1 build 1 source preparation includes all four apps and PMSKit;
no release tag, upload, merge or hardware acceptance is implied.


### 1.7.1 review-preparation validation

Fresh generic visionOS, iOS and tvOS builds and the isolated macOS hosted product build
pass. All four generated bundles report 1.7.1 build 1; the PMSKit fallback and sanity
check match. Hermetic PMSKit passes 1,707 Swift Testing cases and 119 XCTest cases.
The owned iPhone and tvOS semantic fixtures pass with their app-view attachments
inspected. A later audit found their UI-specific DerivedData had not been cleared; these
older runs establish visible behavior, not standalone full-clean revision freshness. Native 1.7.1 Plex SDR seek also passes with an inspected BT.709 frame.
The final-source macOS full suite (636) fails the replacement deadline and both Offline
expectations; iOS (620) fails the two Offline expectations. The tvOS test summary reports
all 338 tests passing, but its runner did not exit and was terminated after 301 seconds
without log progress (exit 143). All owned simulators are shut down and the lease is
released. These are not green full-suite results. The consent/revalidation
instrumentation does not extend a deadline or suppress any failure. No release tag or
upload has been created, and the P7 candidate remains default-off DEBUG macOS only.


### Draft review follow-up: direct play and deterministic preparation

The DEBUG snapshot now maps an explicitly negotiated media-browser `directPlay` to
video/audio copy with `serverDecision` provenance, matching the existing Plex direct-play
vocabulary. It does not infer copy from `directStream`, `transcode`, absent metadata, a
file extension or a rendered codec. Enforced copy HLS retains its separate provenance.
Both backend fixtures verify the positive case, negative cases, metadata invalidation,
and continued unknown rendering/cleanup without a player. All 12 evidence tests pass.
Fresh exact-source Jellyfin and Emby Original reopen runs now pass with inspected BT.709
post-hold frames. Earlier blocked reports remain historical evidence, not retroactive passes.

The repeated Offline expectation raced an independent 40-millisecond test sleep against
a queued task that only began its 20-millisecond delay after being scheduled. The test
now uses a DEBUG-only injected sleep gate and awaits actual task completion. It verifies
the requested delay, no publication before release, cancellation before release, and
publication afterward; the production 750-millisecond `Task.sleep` and cancellation
checks are unchanged. Two full macOS hosted runs now pass all 637 tests. These new runs
do not erase historical failures or prove the earlier intermittent unrelated conditions
cannot recur. Fresh iOS hosted tests pass all 621 cases, and fresh tvOS hosted tests
pass all 339 cases with normal runner exit in 24 seconds. The bounded diagnostic runner
would sample a stalled process before termination, but no stall occurred in this run;
therefore it does not establish the cause or resolution of earlier runner hangs. The
fresh generic visionOS build, hermetic package tests and hygiene checks also pass.

The fixture freshness audit identified separate `DerivedData-agent-iphone-ui` and
`DerivedData-agent-tvos-ui` directories. Earlier removal of non-UI directories did not
prove clean UI builds. Those historical artifacts are retained with that limitation;
replacement fixtures explicitly move the actual UI DerivedData aside before building.
Both replacement semantic fixtures pass from those clean UI build paths, with the iPhone
detail and tvOS home app-view attachments inspected. All owned simulators are shut down.

### Initialization representation identity follow-up

The candidate now binds the complete validated initialization bytes to each proxy open,
not merely its admitted MAP URL. Previously, two independently valid initializations
served at the same URL could each pass normalization, allowing successive player range
requests to receive parts of different representations. The session actor now validates
and pins the first complete initialization atomically, rejects later byte changes before
serving any full or partial body, and starts without that pin on a fresh open. Failed
validation cannot seed the pin; playlist refresh cannot replace it. Media bytes, profile
admission and default-off DEBUG macOS routing are unchanged.

Hermetic coverage exercises unchanged repeats, a malformed first response, two individually
admissible but different initializations at one URL, full/range rejection through the
loopback proxy, and fresh-open acceptance. This is a transport identity guard, not new
decoded-frame or live-backend acceptance. Exact-source live regression of this increment,
server-session cleanup confirmation, later-segment extracted-base equivalence, broader
source coverage and physical acceptance remain open. No new encoding authorization or
Release enablement follows from this guard.

### Initialization identity: fresh bounded validation

The initialization-pinning revision `bc224b81` was rebuilt from clean native macOS
DerivedData and run with the existing authenticated, isolated development identity.
The staged executable matches the freshly built product by SHA-256. These are new
exact-revision results, not reuse of the earlier candidate's playback evidence.

- Hermetic PMSKit passes 1,707 Swift Testing cases and 121 XCTest cases. The range
  regressions verify unchanged partial responses, rejection of changed complete and
  partial initialization responses, failed-first-validation recovery, playlist-refresh
  pin retention, and acceptance of a different initialization only after a fresh open.
  No live server initialization was deliberately mutated; that adversarial boundary is
  established by the hermetic loopback tests.
- The exact P7 source passes native Plex Original video-copy playback, a seek to
  600 seconds with a 35-second advancing hold, and a separate close/reopen hold.
  An audio-track transition also passes with replacement-generation evidence: video
  remains copy while audio changes from copy to encoding. No video encoding was
  authorized or requested by these scenarios.
- The same source, independently bound to each backend's expected item/source,
  passes Jellyfin's seek to 600 seconds and Emby's forward seek to 1,200 seconds,
  each with a 25-second hold. Emby's separate Original reopen passes. Jellyfin's
  first reopen reports `failed/playbackFailed`; its saved progress evidence identifies
  a 2.014-second observation gap, beyond the unchanged two-second oracle bound,
  while sampled positions continued advancing. It has no post-hold visual pass.
  One bounded reopen repeat passes the unchanged 25-second hold and frame gates;
  this does not retroactively pass the first attempt or resolve older pause findings.
- Fresh initial and post-scenario decoded frames were inspected for every passing
  run. They show recognizable, untinted video with 3840-by-2160 PQ/BT.2020 signaling.
  Some initial capture attempts lack a new pixel buffer; subsequent fresh frames
  provide the visual evidence. These tone-mapped captures do not establish HDR
  luminance accuracy, native Dolby Vision reconstruction, or physical audio output.
- Jellyfin/Emby app evidence reports request-enforced video copy and unknown audio;
  separate read-only server job logs confirm video copy and AAC encoding. The matched
  jobs show graceful quit and their specific playlists are absent after stop. Plex
  seek, reopen and audio-transition stops receive HTTP 200, with observed job exits
  and removal of the corresponding transcode directories. These are bounded job
  cleanup observations, not proof of every server resource's lifecycle.
- Fresh generic visionOS, iOS and tvOS builds pass, as do hygiene and strict
  documentation checks. Two full macOS hosted runs each pass 703 of 704 tests and
  fail `delayedTrackReplacementDoesNotAcceptThePredecessor` at its replacement
  deadline. A separate focused evidence run passes all 12 tests. The full-suite
  failure remains open; the focused result is not a waiver. No simulator was booted;
  visionOS run verification remains blocked by the missing golden-simulator pointer,
  and mobile/tvOS hosted and interactive lanes were not rerun in this validation.

No product code, profile selection, admission guard, session authority or consent policy
changed during validation. The candidate remains default-off, DEBUG macOS only. Broader
source coverage, later-segment extracted-base equivalence, full-suite stability and
physical-device acceptance remain open. No merge, upload or release enablement is implied.


### Review preparation: deterministic replacement and persistence barriers

The full-suite replacement failure was reproduced with test-only timing diagnostics:
the fixture's MainActor task did not begin until 1.849 seconds after the wait started,
and the unchanged two-second wait expired at 2.316 seconds before the first scheduled
20-millisecond continuation detached the predecessor. The player still held the old
item. This identifies fixture scheduling contention, not rejection of an observed
replacement. The diagnostic instrumentation was removed after establishing the cause.

Revision `fed053b9` injects the DEBUG replacement wait's monotonic clock and polling
step for deterministic tests. The live defaults remain `ContinuousClock` and a
cancellation-aware 250-millisecond sleep; deadline comparisons, authority, playback
failure, consent and item-identity checks are unchanged. Coverage now observes the
predecessor across multiple polls, a detached interval, a distinct replacement,
predecessor/detached deadline expiry, rejection exactly at the deadline, safety gates
that become active with replacement, and cancellation before polling. There is no
deadline extension, skipped test or weaker progress assertion.

The first clean macOS run passed all 712 tests with no skips, including the hermetic
browse-probe fixtures omitted by the earlier matrix command. An exact-build repeat
then failed a separate season-planner deletion test: its in-memory absence condition
could precede the artifact worker's terminal on-disk index commit. The existing store
explicitly removes the row and enqueues persistence before awaiting that commit; the
test incorrectly treated the earlier observation as durability proof. The isolated
prerequisite `f56afe8c` awaits the existing persistence ticket with a bounded ten-second
flush and asserts its committed revision before preserving the original fresh-index
deletion assertion. It changes no download production behavior and is kept on `codex/season-deletion-test-barrier` for
separate review. The P7 branch includes that prerequisite for stacked validation.

At integrated revision `a25c6ec8`, three consecutive full macOS hosted runs pass all
712 tests with zero skips, the first from clean DerivedData. These runs retain the
historical failures above rather than retroactively passing them. Hermetic PMSKit
passes 1,707 Swift Testing cases and 121 XCTest cases. Fresh generic visionOS, iOS
and tvOS builds also pass. The live host product was built from clean DerivedData at
`fed053b9`, with a fresh executable mtime and matching staged SHA-256; the prerequisite
and integration change only tests, so the runtime source is identical.

The fresh isolated Mac product passes the exact P7 source's Plex audio transition
and 600-second seek with the unchanged 35-second advancing holds. The audio run
changes replacement generation while video remains copy (audio changes from encoding
to copy); the seek stays video/audio copy. Fresh initial and post-scenario PNGs were
inspected and show recognizable untinted video with 3840-by-2160 PQ/BT.2020 signaling.
These tone-mapped frames do not establish physical HDR or audio-output accuracy.

Later native LaunchServices attempts do **not** extend that acceptance: Plex reopen
reports `blocked/playbackFailed`, and Jellyfin/Emby audio transitions report
`blocked/missingAuth`. PID-bounded host logs for each attempt show `Local network
prohibited` and URL error -1009 before playback; the media-browser report is not proof
that saved credentials disappeared. No privacy setting was changed or bypassed.
A preceding reopen launch-orchestration attempt was stopped before a probe result;
it has no visual pass. Existing pre-increment cross-backend/reopen evidence remains
historical, not a substitute for these blocked fresh lanes. Fresh cross-backend and
LaunchServices reopen acceptance therefore remain open pending the host permission
gate. App reports request cleanup; the earlier bounded server-job cleanup observations
are not reclassified as fresh server-side proof for this increment.

The owned iPhone's clean-built semantic fixture passes with its detail attachment
inspected. Its first full hosted run prints 629 Swift Testing and 67 XCTest passes,
but does not produce a terminal result: a bounded process sample locates the wait in
Xcode's `collectSimulatorDiagnostics` / `simCtlDiagnose` after the app process exits.
The run is terminated at the 300-second no-progress boundary and remains non-green.
One diagnostic repeat of the same compiled tests with `-collect-test-diagnostics never`
exits normally: 696 of 696 pass, zero skips. This flag disables ancillary verbose
simulator diagnostics, not tests, assertions or result bundles. The repeat does not
establish resolution of default diagnostic collection or of historical runner hangs.

The owned tvOS full hosted run exits normally with 383 of 383 passing and zero skips.
Both named tvOS launch/remote-navigation smoke tests pass from a clean UI DerivedData
path, with the focused home and leaf-detail attachments inspected. All created iPhone
and tvOS simulators were shut down and removed; the isolated live Mac staged app was
removed without resetting its saved container or credentials. visionOS run verification
remains blocked by the missing golden-simulator pointer; no replacement golden was
invented. These simulator fixtures are credential-free UI evidence, not live-backend
or physical-device acceptance.

This branch is reviewable as default-off hardening, not a shipping P7 solution. Local
network permission, default iOS diagnostic-collection completion, broader source
coverage, later-segment extracted-base equivalence and physical HDR/DV/audio acceptance
remain explicit gates. P5 safety, Plex Generic, consent, source/session authority and
Release behavior are unchanged. No video encoding was authorized, no PR was opened,
and no merge to the default branch or release upload is implied.

### Local-network permission recheck

After the user reported granting local-network access, revision `f4fc8da4` was rebuilt
from clean native macOS DerivedData and staged under the same isolated development
identity. Fresh executable mtime and matching built/staged SHA-256 were verified.
All three bounded LaunchServices retries used the existing saved authentication and
unchanged exact source bindings. None reproduced `Local network prohibited` or URL
error -1009 in their PID-bounded host logs; no privacy settings or credentials were
changed. The earlier permission block is therefore not the current observed blocker.

- Plex Original reopen remains blocked before playback: the exact metadata request
  returns HTTP 404, while other server requests succeed. No replacement item binding
  was substituted, and no fresh Plex frame pass is claimed.
- Jellyfin's audio-transition run now authenticates and plays. Initial decoded frames
  are fresh, recognizable and untinted, but the unchanged 25-second progress check
  fails after a 2.135-second observation gap; sampled positions continue advancing.
  There is no post-hold frame pass, and the failed scenario remains a failure.
- Emby's audio transition passes the unchanged 25-second hold and replacement-generation
  check. Request-enforced video copy remains in effect; audio decision and server-side
  cleanup remain unknown in app evidence. Fresh initial and post-scenario frames were
  inspected and show recognizable untinted video. These tone-mapped captures do not
  establish physical HDR or audio-output accuracy.

These results supersede only the outstanding permission diagnosis, not the prior
failures or broader acceptance gates. Plex exact-source availability and Jellyfin's
progress-observation failure remain open. No video encoding was requested or authorized;
P5 safety, Plex Generic, consent, default-off DEBUG macOS routing and Release behavior
are unchanged. The run processes and staged host app were cleaned up while preserving
saved sessions. No simulator was booted, and no PR, merge or release action followed.
