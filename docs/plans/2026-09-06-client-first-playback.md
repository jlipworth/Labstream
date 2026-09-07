# Client-first playback and release acceptance

**Status:** implementation and acceptance in progress; not release-ready.

## Agreed behavior

Prefer native Apple decoding of original video. Container remux and audio-only server
conversion may happen automatically. Ask before an Original / Direct Play choice falls
back to server video encoding, including subtitle burn and Dolby Vision safety fallbacks.
An explicit capped or Maximum (HLS) quality choice authorizes encoding without another prompt.
Approval belongs to the current playback item, not a persistent account preference.

Keep the `Generic` Plex profile, source color metadata, backend/session authority,
seek/resume, progress reporting, and cleanup invariants. Do not weaken Dolby Vision guards.

## Implementation checkpoints

- [x] Plex Original uses `directPlay=0`, `directStream=1` HLS remux negotiation rather
  than the rejected literal `directPlay=1` HLS start.
- [x] Require an explicit video-copy decision before starting Original media; unknown
  decisions and failed copy playback offer consent instead of silently encoding.
- [x] Add a shared-player consent surface; stop the previous job before presenting it,
  reject stale approval after stop, and prime the resume offset on approved encoding.
- [x] Add bounded single-variant, same-origin HDR media-playlist selection on SDR displays.
  This preserves encoded color metadata; **live rendering/color acceptance remains open**.
- [x] Bound stall transport-progress deferrals to two existing watchdog intervals.
- [ ] Verify compatible original-file playback separately from HLS remux; do not claim
  that container remux is byte-for-byte Direct Play.
- [ ] Complete Plex live acceptance before extending the behavior to Jellyfin and Emby.
- [ ] Verify each MediaBrowser backend's Direct Play, video-copy/audio-only remux,
  and explicit Maximum semantics. Keep server-job cleanup separate from video encoding.
- [ ] Extend consent to initial negotiation and reopen with pinned source/auth authority,
  including stale success, cancellation, seek, audio, subtitles, and quality changes.

## Evidence and open gates

PMSKit hermetic tests passed (1,676 tests at the current checkpoint). Four focused Mac controller tests passed, covering approve/decline, saved resume, stop,
and rejection of an old button action against a newer prompt. Clean macOS, visionOS, iOS, and tvOS builds passed after the final consent-generation
hardening. Hosted and UI acceptance are tracked separately from build success. The iPhone fixture
home-to-detail smoke and both tvOS fixture navigation smokes passed; screenshot attachments
were inspected. All simulators are shut down. The repository hygiene suite, strict documentation build,
Markdown links/anchors, and Mermaid checks passed before this journal was added.

An opt-in probe using the actual PMSKit request builders received HTTP 200 for decision,
master playlist, child playlist, and stop. Independent server inspection confirmed HEVC
**video copy**, AAC audio conversion, and immediate job cleanup. This is control-plane
acceptance, not rendered playback acceptance.

The local hardware-required VideoToolbox experiment decoded the HDR10 sample. A single
HDR master was rejected on this SDR display before decoding; direct media-playlist
preparation succeeded. Neither result proves live visual quality or platform-wide support.

The production-identity Mac app is now accessible and live Plex playback was exercised.
A high-bitrate HEVC Main 10 HDR10 source rendered recognizable moving frames on an SDR
display through video-copy HLS remux with AAC audio conversion. Independent server
inspection confirmed video copy, successful segment delivery, and cleanup. Sustained
playhead progression, paused skip, a deep seek outside the buffered range, and resume
passed; the inspected player statistics reported no dropped frames or stalls in copy runs.
This is not a physical HDR-display or colorimetric acceptance result.

Selecting image subtitles under Original presented consent. Declining started no video
encoder; switching subtitles Off recovered video-copy playback. Approving subsequently
started the subtitle-burning encoder, and closing/reopening playback returned to video
copy without carrying approval forward. The approved software encode buffered, consistent
with server throughput rather than a LAN throughput limit. Final teardown left no encoder.
A subtitle picker appeared stale after reopening; this remains an explicit follow-up.
Separate original-file, H.264, Dolby Vision, and Maximum (HLS) controls remain open.

Jellyfin authentication and normal browse now work. Its first implementation passed
1,679 hermetic tests and five focused Mac consent tests. Exact server-version inspection
identified implicit SDR encoder alternatives in HDR-copy master playlists. Original now
validates a copy-eligible source, requests explicit video copy with fMP4 segments, and
selects the primary same-origin copy child before AVPlayer attachment. Unknown transforms,
image-subtitle burn, and Dolby Vision guards require consent. Maximum explicitly forces
video encoding; approval is carried only through the captured session reopener.

Live Jellyfin HDR10 playback rendered recognizable frames; server arguments confirmed
video copy plus AAC conversion. The first deep-seek attempt exposed a false target display
while content restarted from zero. The corrected copy-child path bypasses legacy remote
priming and performs a client seek on readiness. The retest showed the correct scene;
server input seek matched the target's preceding keyframe, with video still copied.
Image-subtitle decline stopped the prior job and started no video encoder; turning
subtitles Off recovered copy playback. The final VOD correction also removed legacy
priming from the encoded lane: approved subtitle burn used NVENC, overlay, and tone
mapping while retaining the requested position, with no repeated StartTimeTicks errors.
Maximum used NVENC and retained position; returning to Original restored video copy.
Switching from lossless audio to compatible Dolby Digital retained video copy and changed
the server to audio copy as well. A second SDR HEVC source resumed at its saved deep
position and advanced normally. A H.264/AAC MP4 control played the original file and sought
without any FFmpeg job; explicitly selecting Maximum started NVENC even for this otherwise
direct-playable file. Final cleanup left no FFmpeg process. These are Mac acceptance results,
not claims about every physical Apple device or HDR display.

Final clean Mac, visionOS, iOS, and tvOS builds passed. The iPhone semantic home-to-detail,
tvOS launch/navigation, and visionOS passive fixture-home smoke passed; screenshot artifacts
were inspected and all simulators were shut down. Hermetic tests remained green at 1,679,
and five focused controller consent tests passed. The full Mac hosted rerun exercised 610
tests but reported three assertions in the existing download poster-retirement and offline
transport-presentation cases; the complete hosted suite is not green.
Text-subtitle/alternate-rendition copy handling remains conservative and unaccepted;
unknown manifests are rejected rather than dropping selected tracks. The full Mac hosted
suite reported four assertions across three existing test cases. Isolated reruns passed
the transport-presentation suite but still failed the download keepalive cancellation and
cross-kind poster-retirement cases; do not treat the full suite as green.

A passive visionOS launch stayed running and displayed the sign-in screen, not authenticated
browse. Its simulator is shut down. The passive helper also exposed an empty launch-argument
array error; a manual canonical install/launch/screenshot loop supplied the limited smoke
evidence instead. This does not close authenticated browse or playback acceptance.

Required acceptance:

- [ ] Original control, HEVC remux, H.264, HDR10, and separate Dolby Vision cases.
- [ ] Visible frames and appropriate SDR appearance; separate physical HDR-display gate.
- [ ] Sustained playhead progress, initial/deep resume, seek, pause/resume, track changes.
- [ ] Consent approve/decline, stale callbacks, stop/restart, and return to Original.
- [ ] No server video encoder for accepted video-copy runs; no leaked jobs after teardown.
- [ ] Maximum/capped encoding reports actual behavior, including insufficient server speed.
- [ ] Hermetic and hosted tests plus all affected native build/smoke lanes.

## Release closeout

### macOS launch interruption

Emby verification exposed a recurring live process with no main window. The macOS reopen
delegate suppressed default scene creation even when it had no retained window to present.
It now suppresses that path only after successful retained-window activation. A clean signed
host build showed authenticated Emby Home, and a normal quit followed by another cold launch
again showed Home. Five focused window-lifecycle tests, 1,679 hermetic PMSKit tests, and
repository hygiene passed. This is window-lifecycle evidence, not Emby playback acceptance;
the earlier decision-only probe did not reach the server and remains unverified.

### Emby client-first acceptance checkpoint

Original negotiation now prefers a server-accepted native file over an optional encoded
URL. Negotiation is decision-only: a live PlaybackInfo-only probe started no FFmpeg job.
Copy delivery uses Emby's `m4s` dialect and a validated same-origin video-copy child.
Original subtitle burn requires consent; explicit Maximum authorizes encoding. Selected
AC-3 audio and the static-file recovery lane use AAC conversion without video encoding.

The signed Mac app rendered high-bitrate HDR10 HEVC with video copy and AAC conversion,
including saved resume and a deep seek. Subtitle decline started no video encoder;
approval produced hardware video encoding with subtitle overlay and tone mapping.
Maximum produced hardware encoding and retained position; returning to Original restored
video copy. The AC-3 copy delivery variant stalled, while audio-only AAC conversion
restored sustained video-copy playback. This is a delivery workaround, not a claim that
Apple hardware cannot decode AC-3.

Closing during a quality change exposed cancellation of an awaited exact-session stop,
leaving an approved encoder running. The first orphan required manual server cleanup.
Cleanup now runs in an uncancelled task; the live race retest reached successful stop
responses and left no encoder without manual intervention. A regression test covers
cancellation at that cleanup boundary.

A H.264/AAC MP4 control exposed intermittent native-file stalls, including in a bare
Apple player without the app controller. Origin-only delivery reproduced the failure;
four sampled HTTP byte ranges matched the source file exactly. No infrastructure change
was justified. Native playback did advance at another deep offset before stalling, so
this is not universal MP4 incompatibility. A bounded, one-time static-file recovery now
renegotiates video-copy HLS with AAC. Initial recovery rendered moving frames and advanced
for several minutes with no dropped frames or stalls. However, subsequent deep seeks
showed the target frame without sustained progression; this acceptance gate remains
**open**. Closing those sessions left no FFmpeg process. Do not call Emby end-to-end done.

A subsequent full-timeline/client-seek comparison with initial item-status observation
also failed sustained recovery playback and was reverted rather than promoted as a fix.
Server seek arguments matched requested targets, with successful delivery; the remaining
failure is not established as a double-offset bug. Investigate native transport/rate and
media delivery together. Avoid running hosted app or simulator audio tests during the
next live comparison to eliminate test-host interference as a confounder.

At this checkpoint, 1,685 hermetic tests and 11 focused Mac consent/window/cleanup tests
passed. Clean signed Mac, iOS, tvOS, and visionOS builds passed. The iPhone detail and both tvOS fixture smokes passed, with screenshot inspection;
the passive visionOS fixture Home also rendered and stayed running. All simulators are
shut down. Existing full-hosted failures remain separate release blockers.

### Emby H.264 recovery correction

A read-only independent review identified that short-buffer reopens disabled automatic
waiting. Buffer exhaustion could therefore leave AVPlayer paused at rate zero, outside
both normal stall and reconnect recovery. A one-variable Mac comparison enabled automatic
waiting only for verified Emby copy HLS while preserving the 12-second target and paused
network-loading behavior. It recovered the initial stalled copy run automatically, but
reopen-backed deep seeking still hit the reconnect deadline. This was not a complete fix.

The selected copy child was also being passed to a helper that expects a master playlist:
it tried to parse the first media segment as a playlist. A full-timeline comparison bypassed
that helper/proxy and used native client seeks, but fragmented-MP4 playback still failed.
A private server capture found repeated zero decode timestamps across adjacent fragments
and a rewritten shared init with large edit offsets. The physical playlist was not the
app's dynamic child; these findings support a packaging workaround, not a complete proof
of every source of timestamp discontinuity.

H.264 static-file recovery now uses MPEG-TS segments with explicit video copy and AAC.
HEVC and approved encoding retain their existing packaging. Combined with automatic
waiting and the full-timeline native-seek path, this passed isolated signed-Mac acceptance:
sustained deep resume, forward seek with more than a minute of subsequent movement,
backward seek outside previously generated media with more than a minute of movement,
and deliberate pause/seek/resume. Actual frames changed throughout. Final Stats reported
zero dropped frames and zero stalls. Independent server evidence confirmed video copy
plus AAC throughout; the forward seek reused generated segments and the backward seek
requested a new copy-only remux range in the same session. Final stop left no FFmpeg job
and no temporary port-forward; no infrastructure changes or manual cleanup were needed.

This is a verified recovery path, not a repair of native MP4 demux/delivery or a universal
Apple-device acceptance claim. Server remux/audio conversion can still generate substantial
temporary segment data; avoiding video encoding does not mean zero server I/O. Existing
full-hosted test failures and physical-device/release gates remain open. Playback probes
with endpoint-only or three-second progress criteria are not used as proof of sustained
acceptance here and still need a separate regression-oracle hardening follow-up.

The follow-up hardening limits all new timeline behavior to H.264 static recovery,
strips priming from the master as well as its child, and makes explicit full-timeline
resume unconditional once per item. A newer explicit user seek invalidates that captured
initial resume before asynchronous track setup can overwrite it. Regression tests cover unchanged buffering fields, TS copy-only parameters, and
session/auth/track preservation.

Final validation passed: 1,690 hermetic PMSKit tests across 213 suites and 11 focused
hosted consent/window-lifecycle tests across two suites. Clean native builds succeeded
for macOS, iOS, tvOS, and visionOS. iPhone and Apple TV fixture UI smokes passed; the
visionOS passive fixture launch, installed-build check, process/log check, and screenshot
inspection passed. All leased simulators were shut down afterward. Hygiene, strict
MkDocs, repository links/anchors, and Mermaid validation passed.

The final hardened signed Mac build was independently retested: sustained recovered
playback, a deep seek followed by more than a minute of advancing playback with changed
frames, and clean stop. Server evidence again confirmed H.264 video copy plus AAC in
MPEG-TS and zero remaining FFmpeg jobs after close. Diagnostic logging remains enabled
at the user's request. These focused successes do not clear the previously noted
full-hosted-suite failures or physical-device release gates.

After all three backends pass, confirm the platform scope and increment the patch version
using the repository version-bump procedure. Verify built bundle values and prepare release
notes. Update the relevant GitHub issues with sanitized implementation and test evidence;
keep unverified physical-device, App Store, and reviewer gates open. A version bump is not
an upload, submission, or release; commit/tag/publishing authorization remains separate.

Promote proven behavior into the canonical playback documentation and archive this plan
only once implementation and acceptance are complete.

## Sweep follow-up: hosted baseline restored

The follow-up correctness branch restores a clean macOS hosted baseline: 693 tests passed
(67 XCTest and 626 Swift Testing), with no tests skipped. The poster-retirement fixture now
uses an explicitly stale owner rather than invoking intentional legacy owner adoption;
shared main-media bytes remain readable. A coalesced side-asset test now establishes enqueue
order explicitly, and the 140-write checkpoint-retention test uses a bounded 30-second drain
allowance rather than treating five-second disk throughput as a correctness requirement.
Earlier keepalive and transport failures did not recur in the final full suite.

PMSKit's 1,695 hermetic tests, 320 tooling tests, strict documentation checks, all four native
builds, and passive iPhone/tvOS/visionOS fixture launch checks passed. These results do not
close the live playback, physical-device, or release gates above. Season-admission and artist
queue fixes have authority-level regression coverage; full manager/provider integration
coverage remains tracked in #293 and #295 rather than being inferred from passive smoke.
