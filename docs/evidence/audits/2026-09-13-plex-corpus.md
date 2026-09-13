# Bounded Plex corpus audit — 2026-09-13

Status: seven exact source versions exercised; three independent harness defects
corrected. This is simulator evidence, not release or hardware acceptance.

## Scope and provenance

Baseline: PR306 at `fbc808cc`. Exact-source work is
[PR310](https://github.com/jlipworth/Labstream/pull/310), frame/consent evidence is
[PR313](https://github.com/jlipworth/Labstream/pull/313), and track-transition readiness
is [PR314](https://github.com/jlipworth/Labstream/pull/314). Their explicit dependency
order is PR306 → PR310 → PR313 → PR314. None includes PR307/PR308's Emby playback fixes;
none was merged during this audit.

Private inventory paths and sizes were matched to fresh Plex metadata; duration,
codec, dimensions, exact rating key, Media ID and Part ID were checked. The additional
MP4 case deliberately selects version index 1 and is not mistaken for its HEVC primary.
All item names, paths, IDs, credentials, frames and raw logs stay outside Git.

Playback ran serially on an owned iPhone simulator with iOS 27, through the real
PMSKit → PlaybackController → AVPlayer path. Normal Plex linking used the app-generated
code and Codex in-app browser; browse readiness survived relaunch. No tokens were
injected or exported. No approved standalone CLI live-decision configuration was
available, so control-plane discovery/decisions used the signed-in app's PMSKit client
rather than extracting credentials for a shell probe.

Each successful scenario required 30 seconds sustained progress. Sampled initial and
post-transition decoded PNGs were inspected separately from transport reports. Quality
changes began at Original, not the destination quality. Original/Maximum, Generic
profile and encoding-consent production behavior were not changed.

## Tested matrix

“Visible” means sampled decoded video was present and reviewed; it does not establish
reference colorimetry, audible track correctness, or whole-title stability.

| Verified source cohort | Original result | Other bounded checks | Visual result |
| --- | --- | --- | --- |
| HEVC8, SD, MP3 stereo | Video copy; audio encode | Original → 8 Mbps retained video copy | Visible before/after |
| HEVC10, 720p, AAC stereo, no HDR signal | Video/audio copy | Original → 8 Mbps copy; Maximum server-confirmed encode; seek forward to 120 s and backward from resumed playback to 0 s | Visible, including after seeks/encode |
| H.264, 1080p, multiple AAC tracks | Video/audio copy | Original → 8 Mbps copy; alternate metadata audio selection | Visible after corrected track transition |
| AV1 10-bit, 2160p, AAC multichannel | Encoding consent required | Explicit consent → encode; 4 Mbps encode with 120 s and 600 s forward seeks | Visible movie frames after deep seek |
| VC-1, 1080p, AC-3/DTS choices, SubRip | Encoding consent required | Explicit consent → encode; 4 Mbps encode/120 s seek; metadata subtitle selection | Visible video and subtitle text after corrected transition |
| MPEG-2, 576p episode, AC-3 | Encoding consent required | Explicit consent → encode | Visible animated frames |
| H.264 MP4, SD, AAC, deliberately selected alternate version | Video/audio copy at media index 1 | Exact nonzero-version binding | Visible |

Even the MP4 version reported `plays_whole_file_directly=false`: this audit establishes
copy/remux, not whole-file Direct Play. SDR-cohort color metadata is incomplete;
absence of an HDR signal is not a calibrated display test.

## First failures and actual causes

The retained run ledger has 27 reports: 19 transport passes, four failures and four
blocks. These totals deliberately include first attempts rather than only retries.

1. **Wrong-source risk ([#309](https://github.com/jlipworth/Labstream/issues/309)).**
   The baseline accepted fuzzy/first search results and always used media index zero.
   Fresh exact item/Media/Part binding now fails closed. Hermetic tests cover reordered,
   missing, duplicate and mismatched sources, including unsupported multipart items.
2. **Stale frames / lost consent provenance
   ([#311](https://github.com/jlipworth/Labstream/issues/311)).** AV1 and VC-1 Original
   correctly withheld encoding consent, but the baseline timed out and retained eight
   PNGs from the preceding run. Those stale images were excluded. Entry-time reset and
   pre-cleanup consent snapshots now produce `blocked/consentRequired` with no frames;
   verified after a fresh successful capture using AV1 and MPEG-2.
3. **Track replacement race ([#312](https://github.com/jlipworth/Labstream/issues/312)).**
   First audio/subtitle runs sampled the still-playing predecessor item, then failed
   when the normal asynchronous restart replaced it. Waiting for the replacement before
   readiness/hold fixed both same-source reruns without weakening the hold invariant.

Two initial encode-approval attempts omitted the separate harness admission flag and
were correctly blocked. They remain in the ledger; explicitly admitted reruns passed.
No production decoder or server defect was established by this bounded set.

## Verification and remaining gates

- 1,699 hermetic PMSKit tests passed. Eight focused hosted evidence tests passed,
  including delayed replacement and capture-reset/consent regressions.
- Fresh iOS, visionOS, tvOS and isolated macOS builds passed. Exact installed executable
  and debug-library hashes were checked for final simulator products; passive native
  smoke checks were serialized separately from live playback.
- Strict MkDocs, repository links/anchors, Mermaid checks and CI hygiene passed locally.
- The first hosted-test invocation passed its suite but hung during Xcode coverage
  finalization. A bounded retry with `-enableCodeCoverage NO` reached terminal success.
- PR313's first PR hygiene run failed an unrelated existing Emby fixture ledger count
  assertion; push hygiene passed. The same-commit CI retry passed. The first failure
  remains recorded rather than being attributed to the playback changes.
- Hardware Vision Pro playback, HDR/colorimetry, multichannel audio/listening, full UI
  interactions, long-duration playback and exhaustive track/version combinations remain
  open. visionOS/tvOS fixture smoke is not codec playback acceptance on those platforms.
- No server configuration or library-wide encoding was performed. End-of-playback
  inspection found zero Plex Transcoder processes. Original checkout/HDR work was not
  modified. All three owned simulators were deleted after serialized smoke checks;
  no simulators remained booted and no staged host apps remained. Temporary pairing
  artifacts were removed from the worktree.

For the reusable procedure, see [Private media corpus testing](../../MEDIA-CORPUS-TESTING.md).
