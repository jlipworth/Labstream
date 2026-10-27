# Headless audio/video signal experiment

This experiment establishes a measurement method before expanding codec coverage. It
uses generated media with a standalone macOS 27 run-loop host and an opt-in
visionOS 27 raw-URL probe. Both compile the same capture implementation. It does **not** establish PlaybackController, Plex/Jellyfin/Emby packaging,
physical audio output, HDR display, or universal codec acceptance.

## Reproduce

For the simulator lane, use a clean visionOS Debug build and the worktree simulator procedures in
[Development](../DEVELOPMENT.md). No backend session or library changes are needed.
The signal launch flag bypasses session and download restoration for that process.
The simulator must be shut down before the runner starts; the caller owns the sole
simulator lease. The runner installs the worktree product, checks its installed UUID,
launches each scenario, copies evidence, and shuts the simulator down in cleanup.
The UUID check verifies installation identity, not build freshness.

```sh
uv run scripts/playback-signal-lab.py generate
uv run scripts/playback-signal-lab.py self-test
uv run scripts/playback-signal-lab.py run-host
uv run scripts/playback-signal-lab.py run --case clean
uv run scripts/playback-signal-lab.py run
python3 -m unittest discover -s scripts/tests -p test_playback_signal_lab.py
```

`run-host` requires Apple Silicon macOS 27 and Xcode 27. It compiles the shared capture
source with `SIGNAL_LAB_HOST` and a small `NSApplication` event-loop entry point. It
does not launch LabstreamMac, use a production app identity, or open a player window.
No simulator is needed. The `self-test` action instead decodes fixtures with FFmpeg
and tests only the classifier; its artifacts are explicitly marked offline evidence.

The script declares its NumPy and imageio-ffmpeg dependencies for `uv`. It serves only
the generated fixture directory on an ephemeral loopback port during the run.
Generated fixtures, raw captures, screenshot, and results remain under the gitignored
`build/av-quality/` directory. Each capture has a unique run ID. `results.json` records
the latest run; individual runs retain their own capture and analysis files.

## Method and interpretation

Six 12-second H.264/AAC stereo SDR HLS/fMP4 fixtures share a known source. The clean
source has distinct channel tones, periodic audio amplitude pulses, corresponding
video flashes, a changing gray field, and fixed color patches. Mutations introduce a
one-second audio gap, quarter-amplitude audio, a 250 ms audio delay, a one-second
frozen picture, or a 50-code-value picture brightness increase.

The opt-in Debug-only `--vp-probe-capture-signals <run-id>` path captures approximately
ten seconds. It attaches `AVPlayerItemSampleBufferOutput` and
`AVPlayerItemVideoOutput` to the same player item. The former is OS-27-only and,
according to the installed SDK, currently supports decoded HLS audio only. The probe runs off the main actor to keep UI work out of its sampling loop. It
requests 48 kHz stereo float PCM and fails if it receives an unsupported format.
Video is copied from BGRA buffers into small RGBA frames without Core Image.

Audio records retain media timestamps, arrival time, player position, sample counts,
and raw samples. Video records retain media timestamps, observation time, player
position, and frame bytes. Decoded audio can arrive ahead of playback: arrival times
are **not** speaker-output timestamps. This experiment cannot establish audible
render continuity or physical A/V synchronization.

Analysis checks audio RMS envelopes in approximately 10 ms blocks, relative gain,
unexpected silence, envelope offset against a separately captured clean baseline, and timestamp
continuity. It compares decoded video with the clean fixture decoded independently
by FFmpeg. Lossy encoding and conversion have explicit tolerances; the brightness
check is SDR code-value comparison, not measured display luminance.

The detector does not read the case name when classifying the capture. The runner
compares its classifications with the independently specified injected defects.
Stale IDs, incomplete data, unsupported formats, invalid timestamps, and video
sampling gaps above 200 ms are rejected, not counted as clean playback.
A detector-suite success means clean playback was accepted and intentional defects
were rejected; it does not mean every test clip was good.

## Findings and remaining work

The initial Core Image conversion blocked capture during first use and missed the
beginning of playback. Direct pixel copying removed that problem in the next clean
run: 297 frames were captured with a maximum sampled-frame interval of 33 ms.
That run also returned 61 PCM buffers and preserved reference audio gain within one
percent, but showed an apparent early audio-envelope offset of approximately 90 ms.
Waiting for readiness, pre-rolling, and pulling initial audio before play did not
resolve that offset. Its cause is unproven: absolute A/V synchronization remains
explicitly unverified. Each suite first captures the clean fixture and uses its
measured envelope offset as a fixed baseline for the remaining cases. It never
calibrates separately against the corrupted clip. Relative delay detection therefore
does not establish absolute synchronization or excuse an unexplained codec offset.

A separate run during tooling checks had a 533 ms video sampling gap and was rejected
as inconclusive. Run the signal experiment without competing build/test workloads;
the recorder's scheduling limits must remain visible rather than being labeled a
playback defect.

The standalone macOS host completed all six cases with the expected classification:
clean accepted; audio gap, quarter gain, 250 ms relative delay, frozen video, and
brightness increase detected. Each run captured 300 video frames with a maximum
33 ms sampled-frame interval. Measured quarter gain was approximately 0.249 and
relative delay was 0.250 seconds. The offline classifier suite also passed all six
cases. The latest off-main-thread simulator variant still needs its full six-case run;
another worktree's simulator lease prevented that run at this checkpoint.

Remaining work includes additional codecs/containers, multichannel routing checks,
seek and track transitions, long-running and network impairment tests, and attaching
measurement to the actual backend PlaybackController routes. The audio-mix tap experiment below adds a second observation point; host-output
capture is still needed to investigate physical output-stage skipping.
Hardware tests remain necessary for headset brightness, spatial audio, passthrough,
and platform-specific hardware decoder behavior.

References: [Apple HLS 2026 update](https://developer.apple.com/streaming/Whats-new-HLS.pdf)
and [private media corpus testing](../MEDIA-CORPUS-TESTING.md).

## Codec/packaging matrix

The next experiment generates fourteen SDR/stereo combinations and runs each through
the same standalone host:

```sh
uv run scripts/playback-signal-matrix.py generate
uv run scripts/playback-signal-matrix.py run
# Narrow a rerun; the six-case detector admission suite still runs first:
uv run scripts/playback-signal-matrix.py run --profile hevc10-aac-fmp4
```

The matrix covers H.264, HEVC Main/Main 10, AV1 10-bit, MPEG-2 and MJPEG requests;
audio requests include AAC, AC-3, E-AC-3, MP3, ALAC, FLAC and Opus. HLS fMP4 and
MPEG-TS are separate cases. These are small 160×90, 30 fps, twelve-second reference
fixtures; passing them is not proof of high-bitrate, long-duration, multichannel or
HDR playback. All ten-bit fixtures here are **SDR**, not HDR test assets.

`build/av-quality-matrix/matrix-manifest.json` records requested encoders, observed
FFmpeg stream descriptions and SHA-256 fingerprints of generated media. Modified or
missing fixtures are rejected before playback. The runner first requires all six
clean/injected-defect cases to classify correctly, then measures each matrix cell
against that fixed H.264/AAC baseline. It retains incremental JSON results and a
Markdown table in `matrix-results.json` and `matrix-report.md`.

A signal mismatch is a finding for investigation, not attribution to a decoder bug:
codec priming, encoder metadata and the capture API can also change measured output.
Generation failure, capture timeout, player readiness failure, incomplete capture and
signal mismatch are separate outcomes. One failed cell does not discard the rest of
the sweep. An unsupported capture path must never be reported as proof that the codec
cannot play. The command exits nonzero if any requested cell lacks a signal pass.
VC-1 reference assets, DTS, multichannel routing and HDR/Dolby Vision remain explicit
coverage gaps.

### Recovered historical library scan

The [September 13, 2026 full-scan comment](https://github.com/jlipworth/Labstream/issues/303#issuecomment-5654063918)
records 6,789 movie/TV candidates, 6,784 successful probes, five invalid Matroska/EBML
headers, and 1,771 distinct observed stream combinations. It lists HEVC, H.264, AV1,
VC-1, MPEG-2 and MJPEG video. These are historical counts, not a fresh inventory.
The [bounded playback audit](../evidence/audits/2026-09-13-plex-corpus.md) includes AAC,
AC-3, DTS and MP3 audio examples, but is not a complete audio inventory.

The scan's full `inventory.json`, `representatives.json` and `summary.json` were
intentionally kept under the gitignored `build/media-corpus/`. They were not located
in the current checkouts or indexed local files during this investigation. The
retained summary guides video priorities; it cannot establish audio counts or exact
library-wide combination coverage. E-AC-3, ALAC, FLAC and Opus in this synthetic matrix
are exploratory additions, not claims inferred from the retained library report.

### First matrix result

All fourteen fixtures generated and the six-case detector admission suite passed.
The first macOS sweep produced seven signal passes (H.264 with AAC/fMP4, AAC/TS,
AC-3/fMP4, E-AC-3/fMP4, MP3/TS, ALAC/fMP4 and Opus/fMP4). AV1/AAC, MPEG-2/AC-3 and
MJPEG/AAC delivered decoded content but measured relative audio-envelope offsets of
110, 85 and 110 ms against the fixed H.264/AAC baseline. These are timing findings,
not confirmed audible synchronization defects.

Three HEVC cases did not reach player readiness or complete pre-roll; the generic
host error does not distinguish those stages or establish that HEVC is unsupported.
The FLAC case produced insufficient capture evidence. All four outcomes remain open
investigations, including fixture size/packaging and capture-method constraints.

An exact 80 ms MP3 offset initially compared above the 80 ms tolerance because of
floating-point representation. The comparator now includes a numerical epsilon,
with a regression test covering both sides of the boundary. The original captures
were reanalyzed without changing the baseline or tolerance, and the original report
was retained as `matrix-results-initial.json`. Current counts are seven signal passes,
three timing mismatches, three player-not-ready outcomes and one inconclusive capture.


## Audio-mix tap and fixture controls

The OS-27 host now optionally attaches `MTAudioProcessingTap` to the mixed HLS
track, using a preferred 48 kHz stereo float format. Its callback copies into
preallocated storage and publishes completed rows atomically. Capture overflow,
unsupported formats, missing samples, and incomplete coverage are inconclusive.
The tap never modifies the audio and does not measure the speakers.

```sh
SIGNAL_LAB_AUDIO_TAP=1 uv run scripts/playback-signal-lab.py run-host
uv run scripts/playback-signal-compare.py --fixture clean
uv run scripts/playback-signal-compare.py --generate-controls
uv run scripts/playback-signal-compare.py --fixture controls/hevc8-no-bframes --mode post
```

The first command requires both decoded-sample and tap audio classifications to
match the injected defects. Each uses its own fixed clean baseline. The comparison
command records pre/post-effects and default/varispeed experiments without declaring
an absolute sync pass. Results and raw captures stay under the selected private
build directory.

On the clean H.264/AAC fixture, decoded audio measured approximately −90 ms against
the generated envelope, while both pre- and post-effects tap measurements were
+110 ms. Varispeed changed the tap measurement to +85 ms without changing the
decoded measurement. The 200 ms default discrepancy is therefore a measurement
finding, not proof of audible delay. The post-effects tap preserved the injected
250 ms relative delay and captured the gap and quarter gain.

The three initial HEVC failures now report a readiness-stage file-parse error:
AVFoundation −11829, with underlying CoreMedia −12848. Adding a master playlist,
increasing resolution to 320×180 or 640×360, or declaring level 4 did not resolve the
8-bit fixture failure. Disabling B-frames did: HEVC Main/AAC then advanced and
returned matching audio levels and video content. H.264 without B-frames also
changed the decoded envelope measurement from −90 ms to +20 ms. This implicates
fixture encoding/timestamp structure in the observations; it does not isolate an
encoder or player defect, nor close Main 10 coverage. Original matrix results are
retained; these controls are separate evidence.

The FLAC case still stalled at position zero with one video frame and no tap audio
when the decoded-audio output was removed. That rules out that output as the sole
cause in this configuration, but does not establish general FLAC incompatibility.

## Refreshed private corpus

The October 25 investigation refreshed 6,844 movie/TV candidates: 6,839 successful
probes, five probe failures, and 1,785 observed stream combinations. The summary now
separates track counts from per-file codec counts and records audio channel layouts.
Files can contain several codecs, so per-codec file counts are not additive.

| Audio codec | Files containing it |
| --- | ---: |
| E-AC-3 | 2,598 |
| DTS | 1,989 |
| AC-3 | 1,892 |
| AAC | 1,351 |
| TrueHD | 564 |
| Opus | 185 |
| FLAC | 106 |
| MP3 | 6 |
| PCM 24-bit | 5 |
| PCM 16-bit | 2 |

The refreshed video inventory contains HEVC, H.264, MPEG-2, VC-1 and MJPEG. Unlike the
historical summary, it contains no AV1 stream. AV1 remains exploratory coverage.
DTS, TrueHD, PCM, VC-1, multichannel routing and HDR are the largest remaining
library-backed gaps in the synthetic tests.

Full inventory, representative bindings and summary are preserved privately under
`artifacts/media-corpus/2026-10-25/`, locally Git-excluded and outside disposable
build products. This is a local archive, not an off-machine backup. Refreshing
`build/media-corpus/` does not overwrite it.

The clean visionOS app build and 1,529 hermetic PMSKit tests pass. The latest
simulator suite was refused because another worktree held the simulator lease.
Consequently the new simulator capture path and live Plex/Jellyfin/Emby scenarios
remain unverified in this iteration. Existing simulator guidance also records no
Jellyfin/Emby login; backend authentication and exact source bindings must be checked
when that lane becomes available. Host signal passes do not close these gates.


## Further HEVC and observer controls

A subsequent simulator-free run extended the B-frame controls to Main 10. Both
HEVC Main 10/AAC and Main 10/E-AC-3 with B-frames disabled advanced past ten seconds,
captured 300–301 video frames, and matched the expected audio gain and video content.
FFmpeg inspection confirmed Main 10, 10-bit pixels, and the intended audio codecs.
These are still small SDR/stereo fixtures, with absolute synchronization unverified.

An 8-bit HEVC fixture allowing one B-frame reproduced the readiness-stage parse
failure (AVFoundation −11829 / CoreMedia −12848). This narrows the generated-fixture
investigation but does not establish that HEVC B-frames generally fail in AVPlayer.
The generator now includes these three controls. Comparison runs also retain a
UUID-named report under `build/av-quality-matrix/comparisons/` so the latest-results
file is no longer the only report retained.


FLAC observer isolation further separates transport from capture support:

| Audio observers on H.264/FLAC fixture | Playback / capture result |
| --- | --- |
| Neither | Advanced ten seconds, 300 video frames; audio unmeasured |
| Decoded-sample output only | Advanced ten seconds, 299 video frames, zero audio buffers |
| Audio-mix tap only | Stalled at zero, one video frame, no tap samples |

These controls implicate the tap configuration in the observed stall. The decoded
output also supplies no FLAC audio in this setup. Neither result is proof of a
FLAC decoding failure. The no-observer run provides video/playhead evidence only;
audio quality remains inconclusive. No codec-support claim or timing tolerance was
changed to make these runs pass.


## Multichannel fixtures and existing-player observation

`scripts/playback-multichannel-lab.py` generates 12-second 5.1 sources with distinct
400, 600, 800, 60, 1000 and 1200 Hz tones for FL, FR, FC, LFE, SL and SR. It requests
six-channel decoded PCM and, separately, stereo downmix PCM. Each encoded fixture
must first preserve channel identity through an independent FFmpeg decode; fixture
hashes are checked before playback. Detector self-tests reject swapped and missing
channels and incomplete data. These tests do not measure physical speakers.

```sh
uv run scripts/playback-multichannel-lab.py generate
uv run scripts/playback-multichannel-lab.py self-test
uv run scripts/playback-multichannel-lab.py run
# Bounded reruns:
uv run scripts/playback-multichannel-lab.py run --profile ac3 --channels 2
```

The initial controls exposed two measurement/packaging limits:

- AAC encoded from a side-surround layout failed AVPlayer parsing. A separate AAC
  fixture explicitly encoded with the standard `5.1` layout played and passed
  stereo-downmix routing. Both fixtures remain in the matrix.
- Six-channel PCM descriptions lacked layout metadata. The AVAudioFormat wrapper
  rejected them even though their ASBD described valid 48 kHz planar float PCM.
  The recorder now validates those byte-format fields directly before copying.
  The resulting slots expose the channel tones, but the observed order differs
  from the requested layout. Such rows are **layout-unverified**, retaining the
  measured gain matrix and dominant source tone per slot. No inferred permutation
  is silently applied to turn them into a routing pass.

AC-3, E-AC-3, standard-layout AAC and PCM stereo downmixes preserve left/right and
center routing in the controls. Exact LFE inclusion is measured without a universal
pass criterion. TrueHD HLS/TS produces no usable decoded-audio capture and remains inconclusive.
The final independent fixture check rejects DTS before player testing because its
decoded LFE amplitude is approximately 0.322 of the source. Earlier DTS capture
attempts returned no samples, but that invalid fixture cannot establish a player
verdict. Neither result establishes general codec incompatibility.
The runner exits nonzero when any requested cell lacks a routing pass, while still
retaining all results and UUID-named reports under `build/av-multichannel/`.

### Capture the app's current player

Existing Plex/Jellyfin/Emby `DebugPlaybackScenario` runs can opt into
`--vp-probe-observe-signals <UUID>` on visionOS 27 or macOS 27. Add this flag to an already
admitted, source-bound backend probe command; it does not authenticate or bypass
source/encoding admission. The scenario observes the **same PlaybackController
player and item** after initial readiness and after its scenario hold. Each window
requests eight seconds of advancement, bounded by 25 seconds of wall time.

The observer attaches decoded audio/video outputs without starting, pausing,
seeking, replacing the item, or installing an audio-mix tap. It removes only its
own outputs on exit and rejects item replacement during capture. This avoids
introducing the known FLAC audio-tap stall. Captures remain private in
`Documents/ProbeSignalCaptures/<UUID>/<backend>-initial|postseek/`.

After copying a capture from the app container, summarize it with:

```sh
uv run scripts/playback-observation-report.py --self-test
uv run scripts/playback-observation-report.py <private-capture-directory> --run-id <UUID>
```

The report checks current-run identity, byte counts, finite and monotonic timestamps,
playback progress, acquisition delay and sampling gaps. It records RMS/peak values
and audio/video coverage. It deliberately emits `qualityVerdict=not-evaluated-no-reference`:
silence and dark frames in arbitrary content are not automatically defects. Complete
capture evidence is not equivalent to a known-reference quality pass.

The standalone host has a regression mode for the same observer:

```sh
SIGNAL_LAB_OBSERVE_EXISTING=1 uv run scripts/playback-signal-compare.py --fixture clean --mode off
```

It begins playback before attaching, then asserts that the item is unchanged and
playback remains active afterward. A verified run captured 240 video frames and
47 audio buffers over eight seconds, with continuous audio timestamps and a 33 ms
video interval. The synthetic start-at-zero classifier is not used for this
mid-playback observation.

This verifies the observer against a real running AVPlayer, not backend integration.
The first implementation checkpoint could not run the app because another worktree
held the simulator lease. The subsequent real-app verification below closes that
runtime gap for one Plex source; cross-backend and hardware acceptance remain open.


## Real-app observer verification

A subsequent bounded run used the existing visionOS simulator and restored Plex
session. The installed app matched the fresh build by UUID and binary bytes. Fresh
exact-source discovery matched one private corpus entry by filename and size.
Original and seek scenarios exercised an SDR H.264/AAC source through the actual
PlaybackController. Both transport scenarios passed. Server evidence showed Direct
Stream/remux with video and audio copied, not video encoding. The report's delivered
render format and server-worker cleanup remain unverified.

| Scenario / window | Audio buffers | Video buffers | Capture evidence |
| --- | ---: | ---: | --- |
| Original initial | 49 | 186 | Complete |
| Original second | 0 | 176 | Partial: missing audio |
| Seek initial | 48 | 184 | Partial: 292 ms sampled video gap |
| Seek second | 0 | 189 | Partial: missing audio |

Decoded PNGs were inspected and showed recognizable content without obvious
corruption or tint. Initial black frames were opening content rather than persistent
missing video. Arbitrary-content quality remains `not-evaluated-no-reference`;
transport success and complete capture coverage do not prove audible quality.

The second window lost decoded-audio samples even in the Original/no-seek control,
with the same controller generation and no scenario item replacement. Reattaching
AVPlayerItemSampleBufferOutput to the same item is therefore a measurement-lifecycle
suspect, not an established playback defect. The next experiment should retain one
output across both windows, test Original and seek separately, and reject stale
pre-seek samples. Do not change capture-gap thresholds or infer an audio pass from
video/playhead progress.

Jellyfin and Emby readiness probes both reported missing authentication. Plex was
restored as the active backend, the final authenticated app runtime was checked, and
the simulator was shut down. No source code changed during this verification.
Structured reports, source bindings, captures and screenshots remain private under
`build/av-quality/app-runtime/`; `sanitized-summary.json` records the bounded outcome.
Diagnostics were preprocessed before inspection: 63 events, zero parse errors,
ten schema warnings, and two CoreMedia −12318 bandwidth warnings. Cross-backend,
physical audio, HDR/hardware, and server-worker cleanup gates remain open.


### Native Mac authentication and evidence gate

The observer's DEBUG platform guards and availability checks now also permit
macOS 27. A clean isolated native app build succeeded, its staged binary matched
the fresh product, and all 1,529 hermetic PMSKit tests passed. The authenticated
Jellyfin session survived the rebuild and the native app was left at browse Home.
No simulator was used for this checkpoint.

Live native playback validation is blocked by macOS app-data privacy: the test
process could not read the development app's private Documents or Application
Support evidence directories. Title-only source discovery explicitly failed;
a subsequent exact-item discovery has an unknown outcome because success is silent
and its output file cannot be inspected. No dependent playback was attempted.

The existing diagnostic-report export contains redacted text rather than the
required source bindings and capture binaries. Continue only after permitted
app-data access or a user-mediated copy of the specific evidence becomes available.
Do not bypass privacy controls or infer discovery success from absent log output.
At that checkpoint only Mac runtime startup was verified. The user-mediated export
and native playback results below are the subsequent evidence.


### Native Jellyfin results after user-mediated export

The user copied the private discovery JSON through Finder. It contained one exact
source binding, matched to the private corpus by filename and size. Native Jellyfin
Original and seek scenarios then passed their transport checks on the authenticated
isolated Mac app. Both reported server-confirmed video/audio copy, Original quality,
an attached video surface and rendered format `avc1`. The seek reached the requested
60-second region. App cleanup was requested; server-worker completion is unverified.

The user subsequently copied both observer-run directories and decoded PNG captures.
Analysis required matching UUIDs and retained the original thresholds:

| Scenario / window | Audio buffers | Video buffers | Maximum video timestamp gap | Evidence |
| --- | ---: | ---: | ---: | --- |
| Original initial | 0 | 193 | 41.7 ms | Partial: missing audio |
| Original second | 0 | 192 | 41.7 ms | Partial: missing audio |
| Seek initial | 0 | 192 | 41.7 ms | Partial: missing audio |
| Seek second | 0 | 193 | 41.7 ms | Partial: missing audio |

Each window advanced about eight seconds. All eight exported PNGs and sampled raw
observer frames spanning all four windows were inspected: content changed normally,
with no persistent black, obvious corruption or gross tint. This is visual evidence
for the tested source, not reference-quality, HDR or physical-display acceptance.

Native Jellyfin provided no decoded-audio samples in **either** window. This differs
from the Plex visionOS result, where first-window audio was present. The source is
MP4/H.264/AAC, but neither that fact nor copy/copy and `avc1` establish the actual
delivered container/protocol. The OS-27 decoded-audio API is HLS-only. Delivered
packaging therefore remains a necessary measurement gate; absent samples do not
establish absent or broken audible playback.

The next controlled experiment should use known H.264/AAC HLS through the same
native app late-attachment observer, then test detach/reattach separately. Add safe
delivery-kind evidence for the backend route without exposing URLs or credentials.
Do not merge the native all-window absence and simulator second-window absence into
one assumed cause.

Private results are in `build/av-quality/mac-runtime/observations-summary.json` and
`sanitized-summary.json`. The authenticated native Jellyfin browse session remains
open. The manual copies permit analysis of those exports only; they did not grant
ongoing access to the protected app container. No source code changed during these
playback and analysis runs.

### Native app HLS observer control

The DEBUG raw-URL entry point accepts `--vp-probe-observer-control <UUID>` only
with an HTTP loopback URL ending in `.m3u8`, without user information or a query.
It bypasses backend restoration for that process, starts one synthetic player,
waits for advancement, and invokes the same late-attachment observer twice for
eight seconds each. It preserves the normal authenticated session for the next
launch. No audio-mix tap is enabled.

A twelve-second fixture cannot cover both windows. Generate the normal clean
fixture first, then use a seekable MP4 intermediate when extending it: FFmpeg's
HLS-input `-stream_loop` produced only twelve seconds in the initial attempt.
That incomplete attempt remains excluded from full-window findings.

```sh
uv run scripts/playback-signal-lab.py generate
uv run --with imageio-ffmpeg python - <<'PY'
from pathlib import Path
import subprocess
import imageio_ffmpeg
root = Path('build/av-quality/native-observer-control')
root.mkdir(parents=True, exist_ok=True)
source = root.parent / 'native-observer-control-source.mp4'
ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
def run(*args):
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)], check=True)
run('-i', 'build/av-quality/clean/index.m3u8', '-c', 'copy', source)
run('-stream_loop', '2', '-i', source, '-t', '30', '-c', 'copy',
    '-f', 'hls', '-hls_time', '1', '-hls_list_size', '0',
    '-hls_segment_type', 'fmp4', root / 'index.m3u8')
duration = sum(float(line.split(':')[1].rstrip(','))
               for line in (root / 'index.m3u8').read_text().splitlines()
               if line.startswith('#EXTINF:'))
assert duration >= 29, 'fixture is too short for two observation windows'
print('Verified playlist duration:', duration)
PY
python3 -m http.server 0 --bind 127.0.0.1 --directory build/av-quality/native-observer-control
```

Leave that server running and use its printed ephemeral port below. Build and stage
the isolated native app through the normal host helper. Quit only that isolated
app between runs; use a fresh UUID for every launch. Replace the app identity and
port placeholders with the staged app and printed port:

```sh
APP=build/macos-host/IDENTITY/Labstream.app
PORT=PRINTED_PORT
RUN_ID=$(uuidgen)
open -n "$APP" --args --vp-probe-play-url "http://127.0.0.1:$PORT/index.m3u8" \
  --vp-probe-observer-control "$RUN_ID"
```

Add `--vp-probe-retain-observer-audio` for the separate experimental retained-output
control. This option affects only this explicit synthetic control, not backend
scenarios. One output remains attached to the exact player item between windows;
its owner removes it on success, error or cancellation. Item replacement fails
closed. Each window drops whole audio buffers starting before that window.
Look-ahead is bounded by the window end, and the first future buffer is retained
for the next window rather than drained or discarded. Queued prior-window samples
therefore cannot establish current-window coverage.
Window coverage and timestamp gaps retain their existing criteria.

Intended bounded `PlaybackEvidence` observation summaries include counts,
advancement, audio acquisition/coverage and timestamp gaps; raw samples remain in
`Documents/ProbeSignalCaptures/<UUID>/control-initial|control-second`. macOS privacy
still governs access: use a user-mediated copy for raw analysis, never an alternate
export location. Stop the loopback server and restore the normal native browse
launch when finished.

The verified thirty-second detach/reattach control advanced both windows about
eight seconds. The first captured 47 PCM buffers and 233 video frames; the second
captured zero PCM buffers and 234 video frames. Maximum video timestamp gaps were
below 67 ms. This reproduces second-window decoded-audio loss inside the native
app on independently known HLS. It does not establish an audible-output failure.

DEBUG controller reports also carry a bounded `deliveryTransport` enum.
`hlsPlaylistURL` describes the actual attached HTTP playlist request URL;
`remoteOriginalFileRoute` describes an attached remote asset with a negotiated
original-file route; `localFileURL` describes a local asset. These are request/route
facts, not HTTP-body/container verification. Ambiguous routes remain `unknown`;
codec and source extensions are not transport evidence. Snapshots are write-only;
the offline validator continues to accept older private v1 exports.


The separate retained-output synthetic control then captured PCM in **both**
windows: 46 and 47 audio buffers, with 231 and 232 video frames. Both advanced
about eight seconds. Audio acquisition delays were 317 and 146 ms; measured audio
coverage satisfied the unchanged observer criteria, with no meaningful internal
PCM timestamp gaps. Maximum video timestamp gaps remained below 67 ms. The scoped
owner preserved future buffers rather than draining them at the first window's
end. A focused regression exercises actual buffer deferral, single consumption,
item identity and idempotent cleanup; all twenty native evidence tests passed.

This establishes a targeted native known-HLS capture-lifecycle correction, not
reference-signal quality or audible-output acceptance. Retained output remains
synthetic-control-only. Backend integration still needs controller/item lifetime,
seek/discontinuity and replacement tests before it can replace normal observation.
The subsequent source-bound Jellyfin route-evidence attempt was stopped after a
bounded session-restoration wait, before probe entry. Its live delivery kind is
therefore still unknown in this iteration; previous successful copy/copy/`avc1`
reports must not be retroactively assigned a container.

Compact native results remain under `build/av-quality/mac-runtime/`; raw app
captures remain protected pending any separately requested user-mediated copy.
The authenticated development identity and credentials are preserved. Focused
native test products were removed by the final canonical clean build; the staged
app and compact test logs remain available.

### Native lifecycle boundaries and corrected startup evidence

Add `--vp-probe-observer-lifecycle` to the generated loopback control command to
exercise retained observation around forward/backward seeks, item replacement
and cancellation. It uses the verified thirty-second fixture: an initial window,
a forward seek to eighteen seconds, a backward seek to three seconds, then a
fresh player item and a cancelled window. No backend item or production playback
state is changed by this control.

The installed OS-27 SDK documents `outputSequenceWasRestarted` after seeks or
playback-direction changes and warns that notification can race sample copying.
The retained owner therefore serializes restart generations with sample pulls,
clears deferred samples on restart, and rejects an entire window if its generation
changes. Publication rechecks cancellation, item identity and generation; failed
finalization removes the manifest. Seek admission requires completed seeking,
an observed target clock and an acknowledged new output generation. Bounded
quarantine pulls discard every sample until acknowledgment; none can enter an
accepted capture.

Observed results in the current native app/runtime were:

| Phase | Result |
| --- | --- |
| Initial | 47 PCM / 234 video buffers; audio coverage captured; maximum video gap 33.3 ms |
| Forward seek | Seek completed and target reached; 73 buffers quarantined; no output restart notification; capture blocked |
| Backward seek | Seek completed and target reached; 93 buffers quarantined; no output restart notification; capture blocked |
| Replacement | Old owner rejected the new item and was detached; fresh owner captured 47 PCM / 233 video buffers; maximum video gap 66.7 ms |
| Cancellation | Cancelled task produced no manifest; owned audio and video outputs were removed |

Both accepted windows advanced about eight seconds and had no meaningful internal
PCM timestamp gaps. The delegate's Objective-C selector and installed delegate
identity were confirmed at runtime, but the restart generation remained zero for
both seeks, including while quarantine pulling resumed. This is an observed limit
of this fixture/app/runtime combination, not a universal SDK defect or an audible
seek failure. No seek-window samples were accepted. Backend retained-output
integration remains disabled until authoritative freshness across seeks is proven.
Fresh-item replacement is ownership-safe in this control; it must not silently
replace actual in-place seek verification.

Startup breadcrumbs and the final exact-process structured report also supersede
the earlier suspected Jellyfin restoration stall. The same instrumented process
restored its saved session in about 49 ms and completed source-bound Original
playback about 11.6 seconds after task entry. Earlier live unified-log queries had
returned empty; those events became visible in a later bounded pull. Empty logs
were therefore an observation/visibility problem, not evidence of failed startup.
Future bounded runners must distinguish an unavailable report from a terminal app
failure and preserve exact-process correlation.

The successful native Jellyfin report recorded `remoteOriginalFileRoute` while
attached, with server-confirmed video/audio copy, `avc1`, Original quality and no
encoding consent. This describes the negotiated original-file route and attached
remote asset, not independently verified HTTP response bytes or container.
The prior all-window native Jellyfin PCM absence remains distinct from the known
HLS detach/reattach issue: an HLS-only capture API need not supply PCM on a negotiated
original-file route. Neither finding establishes missing or defective audible audio.
App cleanup was requested; server-worker completion remains unknown.

Private compact lifecycle and startup results are retained beneath
`build/av-quality/mac-runtime/`. Latest raw control captures remain protected;
summary coverage does not substitute for raw integrity/reference-quality analysis.
The normal authenticated native Jellyfin browse app is restored for handback.

### Bounded original-file tap feasibility

A separate DEBUG alternative tests the existing `MTAudioProcessingTap` against a
known generated original-file source. The native entry point is
`--vp-probe-tap-control <UUID>` with a loopback HTTP MP4 URL and
`--vp-probe-tap-track mixed|asset`. Asset mode requires exactly one audio track;
mixed mode uses the OS-27 mixed-output track ID. The generated thirty-second
H.264/AAC stereo fixture is remuxed to fast-start MP4 without encoding and served
with bounded HTTP Range/206 support.

The tap callback retains a fixed sixty-second allocation and immutable published
rows, without allocating or locking on the realtime callback. Admission validates
float PCM byte layout, packet/frame sizes and endianness. Rows include source
flags and discontinuity epochs. Window exports carry UUID/window identity,
coverage, continuity, RMS and peak measurements; overflow, unsupported format,
invalid timing or epoch changes remain inconclusive. Installation rejects an
existing audio mix, retains the immutable mix actually copied into the player item,
and removes only that owned mix. Cancellation/item/mix/epoch checks precede
publication; failed publication removes its tap manifest.

Two native late-attachment trials exercised mixed-output and exact-asset-track
modes. Each advanced an eight-second video window with 240 frames and a maximum
33.3 ms timestamp gap, but terminated before an admitted tap summary was published.
Both remain inconclusive. This does not establish unsupported original-file audio,
a codec failure, or an audible defect; the native failure was not localized further
within this bounded experiment. Their historical run envelopes preserve the actual
source hashes used, rather than being relabelled after later packaging changes.

The third distinct path used the existing standalone host with the same generated
MP4, a tap installed before playback, and decoded-sample output disabled. It exited
successfully and captured 121 tap buffers / 495,616 PCM frames without overflow or
unsupported format. Independent known-signal analysis measured gain 0.998049,
zero silent fraction, no amplitude/gap findings and negligible internal timestamp
gaps. The measured envelope offset was 220 ms; this is not an absolute synchronization
or speaker-output claim. Start-of-stream was present on one row and the captured
epoch remained stable. No seek-freshness claim follows from that initial-only run.
This establishes a preattached standalone tap measurement path, not native
late-attachment or backend tap acceptance.

The generated-only reusable runner is `scripts/playback-native-control.py`:
`plan|run --app <isolated-staged-app> --fixture <generated-media> --mode
 tap-mixed|tap-asset|retained|lifecycle`. Execution additionally requires
`--allow-native`; a clean-build attestation binds the executable and relevant source
hashes. It serves only the selected generated media dependencies, records intended
exact-process structured evidence, separates harness completion from measurement
coverage, and restores the normal native app. It accepts no backend title, item ID,
server URL or credential arguments. Envelopes and private artifacts remain under
`build/av-quality/native-control-runs/`.

An explicitly admitted backend-only experiment can request
`--vp-probe-observe-tap <UUID>` instead of decoded-signal observation, with the same
track-mode option. It retains normal exact-source, live and encoding admission;
ambiguous tracks or conflicting effects block the measurement. No such backend tap
was activated because neither matching native synthetic mode established admitted
tap evidence. Existing backend playback behavior remains the default.

Readiness probes on the isolated native identity reported Plex and Emby blocked by
missing authentication. The final cross-backend Jellyfin probe had no available
terminal report within its bound; its source-bound transport result is inconclusive
in that attempt. The saved Jellyfin session was preserved and the ordinary app was
restored to authenticated browse Home. Earlier successful Original/seek and route
reports remain their own evidence, not substitutes for a fresh tap result.

## Bounded regression package validation

The repeatable entry point is `uv run scripts/playback-regression.py run`; current
usage and evidence interpretation are published in
[Headless playback testing](../HEADLESS-PLAYBACK-TESTING.md). The routine suite plus
private inventory reporting passed thirteen checks: six independent offline
classifications, six actual standalone-host classifications, and coverage generation.
Saved-report re-admission passed. Default cleanup retained about 640 KiB of compact
reports and metadata while removing owned generated media and raw captures.

The optional codec/multichannel sweep with fresh native lifecycle evidence accounted
for all forty-seven requested checks: twenty-eight scoped passes, three measured
timing findings, and sixteen inconclusive results. The three findings were AV1,
MPEG-2 and MJPEG relative audio-envelope timing mismatches. The command correctly
exited nonzero and saved-report re-admission retained the same verdict. This is
explicit experimental coverage, not a claim that all codecs or library files pass.
Its retained compact package occupied about 2.2 MiB.

On the final clean native build, initial and replacement observation again captured
forty-seven PCM buffers each, with 231 and 236 video frames respectively. Old-owner
rejection and cancellation cleanup passed; forward/backward audio sequence
acknowledgment remained absent. The collector initially counted the same events
twice because live and archived unified logs format timestamps differently. It now
merges message multisets across those sources while preserving repeated events
within either source. The same unchanged raw logs were re-analyzed, and both the
pre-correction metadata and corrected source-bound envelope were retained privately.

Final checks passed: clean native build/staged byte verification, twenty-one focused
native tests, 1,529 hermetic PMSKit tests, 443 tooling tests, standalone Swift
compilation, documentation/link/Mermaid checks and repository hygiene. The private
inventory report selects twenty technical combinations representing 2,092 files;
family matches remain separate from actual library-file validation. Integration and
the remaining gates continue under issue #422.
