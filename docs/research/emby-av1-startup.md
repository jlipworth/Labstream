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

The post-integration check for [PR #307](https://github.com/jlipworth/Labstream/pull/307)
used a fresh build and exact item/source assertions. Warm readiness took 7.4 seconds;
four initial and four post-hold frames were visually inspected, with progress after
seek-to-zero. A forced one-second preparation deadline stopped before item attachment;
the post-stop server check found no remaining encoder. Earlier candidate and repeat
runs also passed the bounded visible-frame check. Seek-to-zero is **not** deep-seek evidence.

Pure tests cover the cold AV1 policy, excluded decisions/codecs/offsets, and rejection
of empty, missing, case-mismatched or different expected identifiers. At integration,
1,700 hermetic PMSKit tests, repository hygiene and docs checks passed. All four native
products built and passed their bounded UI/fixture smokes; those smokes do not establish
AV1 playback acceptance on other platforms.

Physical-device decoding, deep seeks, other server versions and release acceptance
remain open. Frame counts alone are not a visual correctness oracle. Private names,
identifiers, paths, addresses, credentials and frames remain in ignored local evidence,
not this document or GitHub attachments.
