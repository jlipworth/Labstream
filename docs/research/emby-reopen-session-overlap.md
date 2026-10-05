# Emby overlapping-session reopen investigation

Status: local correction under validation; not release or physical-device acceptance.

## Reproduced boundary

A capped HEVC 10-bit SDR movie session on the isolated macOS host played from a
fresh resume position, but an in-session audio change or out-of-buffer seek failed
with segment starvation followed by HTTP 404. The audio change at position zero
worked. Original video-copy delivery also passed a deep seek; that comparison changed
negotiation and therefore did not isolate the failure mechanism.

Opt-in, privacy-bounded diagnostics showed successful master and child requests.
Both fresh and replacement sessions described the full timeline, starting at media
sequence zero with a positive start-offset tag. The first segment arrived on a fresh
session but timed out on replacement. No quoted-URI offset parameter explained the
failure. The timeout preceded the deferred old-session stop, so late-stop timing
alone did not prove that cleanup destroyed the replacement.

## Controlled ordering comparison

A Debug-only control changed only replacement ordering: detach the old player item,
await its exact-session stop callback, then negotiate and prepare the replacement.
The bitrate cap, audio choice, prewarm, playlist proxy and resume handling were retained.
The audio change and subsequent deep seek each sustained more than a minute of
playback with inspected intact frames. First-segment responses were HTTP 200 in
under a second. Relaunching the same binary without the control reproduced HTTP 404.

This A/B/A result supports overlapping old/new server sessions as the correction
boundary on the tested server and source. It does not establish the server's precise
encoder-resource or device-session mechanism, nor does a stop acknowledgement prove
that its worker exited. Raw logs, source bindings and frames remain local and private.

## Correction and remaining gates

The candidate correction requires actual Boolean stop acknowledgement for Emby
reopen, retains failed cleanup authority for Retry, and serializes superseded
negotiation/result cleanup before a newer replacement. Missing or failed
acknowledgement surfaces `LS-PB-008` rather than starting another encoder.
Plex and Jellyfin retain their previous replacement ordering. The experimental
launch flag is not a production feature.

Controller and policy tests must cover overlapping intents, failed-stop Retry,
cancellation, stale replacement cleanup and reused session IDs. Live correction
validation, source-matched cross-backend checks, broader server/source coverage,
physical hardware, and audible output remain separate gates. Do not infer acceptance
from a moving playhead alone or from the diagnostic control's success.

## Local correction validation

The normal, unflagged correction build passed the exercised macOS Emby audio
change and out-of-buffer forward/backward seeks, with intact captured frames.
All three replacement attempts recorded acknowledgement before prewarm and HTTP
200 for the first segment; no new playback-error or surfaced-failure events appeared
in the bounded diagnostic delta. Stop/reopen resumed near the saved position.
Logging was disabled after the reproduction.

Plex and Jellyfin separately passed the exercised relative-jump, changed-audio and
deep-seek visual smokes. These are not source-matched equivalence results: source
metadata differs and exact file identity has not been established. Audible output,
subtitles, next-episode behavior, broader sources/servers and hardware remain open.
The initial quiet Mac retry passed 737 tests, but parallel repetitions exposed test
synchronization and real-clock freshness assumptions. Test-only event handshakes and
manual clocks replaced those assumptions. The final clean-build default-parallel run
passed all three repetitions of 737 distinct tests. Prior failures remain in local
evidence. This bounded result is not a guarantee against all flakiness. Affected
simulator validation is recorded separately from live-backend acceptance.
