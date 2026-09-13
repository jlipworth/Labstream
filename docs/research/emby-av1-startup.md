# Emby AV1 cold-start media deadlines

Tracking: [issue #305](https://github.com/jlipworth/Labstream/issues/305).
This investigation is separate from the HEVC SDR visual defect in
[issue #304](https://github.com/jlipworth/Labstream/issues/304) and the Jellyfin-only
[issue #303](https://github.com/jlipworth/Labstream/issues/303). HDR work remains paused.

## Established failure boundary

An exact-item, exact-media-source iPhone simulator check reproduced failure before
initial AV1-source video at a 12 Mbps ceiling. CoreMedia reported no media response
within three seconds (`-12889`). Repeated server encode attempts happened before the
app's single explicit startup retry.

Correlated server events showed encode start, a server stop command about three
seconds later, encoder exit 137, and response completion after client disconnect.
Exit 137 here is not independent evidence of an out-of-memory or hardware-encoder
failure. The retained encode logs had no output-frame progress or definitive encoder
error; they stopped after stream mapping.

A bounded warm-request control against the same verified source reached ready after
approximately 6.6 seconds, delivered visible decoded video, and sustained progress.
This supports the cold-start deadline/disconnect/teardown cycle as the reproduced
failure mechanism. It does not establish that every AV1 failure has this cause.

The initial warm control used the `original` scenario while deliberately requesting
encoding. Its report correctly blocked on the copy-decision assertion despite visible
video and progress; it is not counted as a passed Original-quality scenario.

## Narrow client mitigation

Before attaching AVPlayer, warm the same Emby AV1 transcode session at an absent or
zero resume position, with a 20-second soft budget. The existing prewarmer fetches the
master, child, and initial media. It does not negotiate additional sessions or add
retries. Its failure remains soft, and the existing one-shot startup retry is unchanged.

The policy excludes direct/copy decisions, other source codecs, and positive offsets.
Jellyfin is unchanged. Existing generation/cancellation checks prevent a stale warm-up
from attaching an item after stop or replacement. Server-wide settings are untouched.

## Regression evidence and remaining gates

- Exact identity assertions reject empty, missing, case-mismatched, and different opaque
  identifiers before playback negotiation; title matching remains unique and exact.
- Pure policy tests cover the cold AV1 path and excluded decisions/codecs/offsets.
- The shipping-path candidate passed a bounded seek-to-zero/progress scenario and
  produced four initial and four post-hold visible frames. A seek to zero is not a deep
  seek acceptance claim. No active encoder remained in the post-stop server check.
- A fresh-build repeat passed the same visible-frame check. A forced one-second
  preparation deadline stopped during warm-up without attaching a late item; a subsequent
  server check found no encoder running.
- Hermetic PMSKit checks passed (1,698 tests), as did repository hygiene, strict MkDocs,
  links/anchors, and Mermaid validation. All four native products built; iPhone browse,
  tvOS/macOS signed-out UI, and visionOS fixture smoke were inspected. The visionOS
  fresh-device first launch was denied before boot readiness; waiting for boot completion
  resolved it. These smokes are not AV1 playback acceptance on those other platforms.
- Physical-device decoding, deep seeks, other server versions, and release gates remain
  open. Frame-count success alone never establishes visual correctness.

Private media names, identifiers, paths, addresses, credentials, and frames remain in
ignored local evidence, not in this document or GitHub attachments.
