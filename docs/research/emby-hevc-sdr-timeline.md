# Emby HEVC 10-bit SDR quality-reopen corruption

Tracking: [issue #304](https://github.com/jlipworth/Labstream/issues/304).
[Issue #291](https://github.com/jlipworth/Labstream/issues/291) is related Emby delivery
context, not evidence of the same underlying defect. The AV1 startup failure is tracked
separately in [issue #305](https://github.com/jlipworth/Labstream/issues/305), and
[issue #303](https://github.com/jlipworth/Labstream/issues/303) remains Jellyfin-only.
HDR work is paused and excluded from this mitigation.

## Evidence and causal boundary

The exact item and media source reproduced block/smear artifacts after Original to an
8 Mbps ceiling on an independently owned iPhone simulator. Initial playback looked
normal. The bounded transport scenario passed while its post-transition decoded frames
were visibly corrupted: frame counts and playhead movement alone were insufficient.

Independent software decoding of the same source interval produced clean frames.
Captured server commands for the two original stages both copied video/audio into
fragmented MP4; they did not establish a video-encoder defect.

A full-timeline control initially showed clean frames but resumed near zero. It is not
counted as a successful fix because it did not preserve the target position. The
strengthened control removed server offset priming and the legacy playlist proxy while
explicitly applying the native initial resume. It preserved the position and produced
clean frames in the previously corrupted scene.

This A/B establishes the legacy offset-primed startup/proxy path as the reproduced client
boundary. It does not identify the precise fragment/init or decoder mechanism. In
particular, a physical server playlist is not a substitute for the actual dynamic
playlist delivered to the player; no generalized claim that Emby fragmented MP4 is
invalid is made here.

## Narrow mitigation

Use the full VOD timeline and native resume/seek for known HEVC 10-bit SDR HLS when
video copy has already been enforced, or when the capped negotiation has a known source
bitrate within the ceiling and explicit copy-compatible server reasons. Unknown facts,
video transforms, other bit depths/codecs, HDR, direct files, Maximum without enforced
copy, and sources above the ceiling retain their existing paths.

Preserve the negotiated URL, codec/container, audio selection, and server-session
authority; remove only `StartTimeTicks`. Fragmented MP4 stays fragmented MP4. This is not
the H.264 MPEG-TS workaround from #291, and does not force a new video encode or relax a
quality ceiling. The full-timeline path bypasses the legacy priming prewarmer/proxy and
uses explicit native initial resume even when asynchronous setup has advanced the clock.
A newer user seek still supersedes a delayed initial resume.

## Validation and limits

Pure tests cover scope exclusions, unknown/duplicate reasons, bitrate limits, and
preservation of session, audio, and fragmented-MP4 parameters. Private evidence retains
failed controls as well as successful ones. Actual dynamic-fragment analysis,
physical-device playback, and broader server-version acceptance remain open.

No private media names, identifiers, paths, addresses, credentials, or frames are
included in this document or GitHub attachments.

### Candidate acceptance

- Final-build Original to 8 Mbps transition and a repeat each produced four initial and
  four clean post-transition frames with preserved progress. Correlated source-matched
  server captures retained HEVC video copy and fragmented MP4.
- A separate 10-minute native seek at 8 Mbps passed a bounded subsequent hold and delivered
  visible frames. This single seek is not a full seek/lifecycle acceptance matrix.
- The exact reported HEVC 8-bit SDR episode and an exact H.264 control each still passed
  Original to 8 Mbps with visible post-transition frames. Neither selected the new lane.
- Hermetic PMSKit checks passed (1,701 tests), alongside repository hygiene, strict MkDocs,
  links/anchors, and Mermaid validation. No server encoder remained after the final stop.
- Fresh iOS, visionOS, tvOS, and isolated macOS builds succeeded. Installed iOS/visionOS/tvOS
  executable and debug-library hashes matched their respective fresh products. iPhone browse,
  visionOS fixture, and tvOS/macOS signed-out smoke UI were inspected; these do not replace
  physical-device HEVC playback acceptance.
- Non-fatal simulator runtime warnings about audio-session main-thread activation and the
  GroupActivities capability remain outside this fix; the smoke processes stayed alive.
