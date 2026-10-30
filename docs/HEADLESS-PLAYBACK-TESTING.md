# Headless playback regression testing

The regression package tests generated audio/video signals through an isolated
AVPlayer host on an Apple silicon Mac running macOS 27. It requires Xcode command
line tools and `uv`. No simulator, server login, library-media access, or visible
player window is required for the routine suite.

## Milestone status

The bounded regression package is complete and integrated locally into
`downloads/overhaul` at the 2026-10-27 milestone. Further speculative capture work is paused at
this checkpoint. [Issue #422](https://github.com/jlipworth/Labstream/issues/422)
tracks the remaining work; integration does not close codec or hardware acceptance.
The routine synthetic suite is the repeatable baseline. Wider codec findings,
seek freshness, native original-file audio capture and authenticated cross-backend
quality checks remain explicit follow-ups described below. Earlier source-bound
reports remain historical evidence; rerun on the integrated checkout for fresh
acceptance rather than reusing old build attestations.

## Routine command

From the repository root:

```sh
uv run scripts/playback-regression.py run
```

The command generates six controlled H.264/AAC HLS cases, checks the detector using
independent FFmpeg decoding, builds the shared DEBUG capture implementation into a
standalone host, and measures actual AVPlayer decoding. The cases are clean
playback, an audio gap, reduced audio gain, delayed audio, frozen video, and increased
brightness. The clean case supplies the timing baseline; corrupted clips never
calibrate their own expected result.

A successful injected-defect case means the detector found the intended defect.
It does **not** mean the corrupted clip played correctly. Reports retain the
expected findings, measured findings, and clean-playback distinction.

Use `plan` to inspect commands and time bounds without executing them:

```sh
uv run scripts/playback-regression.py plan
```

Each execution creates a UUID directory beneath `build/playback-regression/`, with
machine-readable results, a Markdown report, command logs, and provenance. Raw
captures and generated media are removed by default after analysis. Add
`--keep-captures` when investigating a failure; this consumes substantially more
disk space. Existing experiments and private corpus archives are not deleted.

## Wider codec and channel coverage

Run the broader exploratory suites explicitly:

```sh
uv run scripts/playback-regression.py run --suite matrix --suite multichannel
```

The matrix requests fourteen SDR/stereo codec and packaging combinations. The
multichannel suite verifies generated six-channel tone fixtures independently,
then measures native channels and stereo downmixes. A missing channel-layout tag
does not establish speaker routing, even when individual tones are present.

These broader suites contain known findings and capture limitations. A nonzero
exit can mean incomplete evidence or a measured mismatch; it is not a universal
codec-support verdict. Consult the per-case status and scope before deciding
whether a player regression occurred. All requested cases must have results;
empty, missing, or duplicate cells cannot produce a successful package.

## Inventory priorities

Include the existing private inventory without reading or playing its media:

```sh
uv run scripts/playback-regression.py run \
  --inventory artifacts/media-corpus/2026-10-25/inventory.json
```

For coverage planning alone:

```sh
python3 scripts/playback-coverage.py \
  --inventory artifacts/media-corpus/2026-10-25/inventory.json \
  --output build/playback-coverage
```

Optional repeated `--results` arguments on the coverage command import existing
matrix or multichannel reports as **historical synthetic evidence**. Their hashes
are retained; they do not become fresh verification of the current checkout.

Coverage uses file counts rather than counting each audio track as a different
movie. Codec/layout buckets can overlap when a file has multiple tracks. Technical
combination priorities consider container, video profile, pixel format, resolution,
frame rate, HDR metadata, and audio profile/rate/channels/layout. They deliberately
exclude title, language and subtitle variants, so their combination count differs
from the full corpus inventory.

The report distinguishes available synthetic codec families, channel-count
matches, supplied synthetic results, and actual library validation. The last stays
unmeasured: matching a codec family does not prove a library file, delivered stream,
or backend route will play. Output contains technical aggregates and opaque
combination hashes, not library paths, titles or backend identifiers.

## Reading results

| Status | Meaning |
| --- | --- |
| `pass` | The stated check passed within its recorded scope. |
| `failure` | An admitted measurement did not match its expected result. |
| `unsupported-capture` | The requested measurement method is explicitly unavailable for that path. |
| `inconclusive` | Missing, incomplete, invalid or blocked evidence prevents a verdict. |

Transport progress, decoded audio coverage, known-reference signal quality, channel
routing, capture cleanup and seek freshness are separate claims. Neither an
advancing playhead nor a successful transport report proves audible audio quality.
An observed playback-readiness failure is not automatically an unsupported codec.

## Actual application and backend evidence

The standalone host exercises shared capture code but does not establish
Labstream application or backend acceptance. Explicit native Mac DEBUG controls
and admitted source-bound backend probes supply separate evidence. Keep native
app runs serialized with host measurements and preserve existing authentication.

`scripts/playback-native-control.py` supplies repeatable generated-fixture controls
for an already clean-built, isolated Mac app. Its `plan` action is read-only; `run`
requires `--allow-native` because it terminates that exact staged app process,
launches the control and then relaunches the normal app. It never selects the
production identity or accepts backend credentials or media identifiers.

```sh
python3 scripts/playback-native-control.py plan \
  --app build/macos-host/experiment-headless-av-quality/Labstream.app \
  --fixture build/av-quality/native-observer-control/index.m3u8 \
  --mode lifecycle
```

The existing research fixture is thirty seconds long. `retained` and `lifecycle`
use HLS; `tap-mixed` and `tap-asset` use a generated, seekable MP4 of the same length.
The runner's loopback server supports byte ranges and serves only the selected
media and its local HLS dependencies. All fixture dependencies are fingerprinted.
The app and fixture must already exist; this control does not build or generate
them. The research notes retain fixture preparation commands.

For execution, replace `plan` with `run --allow-native` and supply
`--build-attestation <private-json>`. A trusted local build collector must record
`schemaVersion: 1`, `cleanBuild: true`, `builtAtUTC`, `executableSHA256`, and the
exact `sourceSHA256` map declared by the runner. Emit that attestation only after
a clean canonical DerivedData build succeeds and staged/product bytes match.
Modification time alone does not prove a fresh build. Without matching build
provenance the overall result remains inconclusive. Control completion also does
not establish successful capture: every requested window and lifecycle phase
must independently satisfy its evidence gate.

Native evidence imports are explicit, run-bound local collector attestations with
source hashes, executable identity, capture time, and a checksummed compact
artifact. They must retain their measurement scope; imported transport or audio
coverage must never be promoted into reference-quality acceptance. Older loose
summary files are not accepted as fresh evidence merely because they exist.

An explicit import uses `--evidence <envelope-json> <expected-run-uuid>` on the
regression command. Imported artifacts must match the source checkout and be no
older than 24 hours. Saved package re-admission uses
`report --run-directory <uuid-directory>`; source changes or expired imports can
reject fresh re-admission while the archived Markdown remains readable. When raw
captures were pruned, re-admission checks compact evidence and provenance, not a
new analysis of unavailable samples.

Raw application captures remain in its sandbox. When macOS denies access, use
intended bounded structured diagnostics or a user-mediated export; do not bypass
privacy restrictions. Exact source bindings, inventories, raw logs, library frames
and credentials stay private and gitignored.

### Emby deep-seek reopen soak

`scripts/emby-reopen-soak.py` targets intermittent Emby copy-lane reopen failures (#421) and
audio dropouts (#420), which need many repetitions to observe. It relaunches the staged Mac dev
app with the admitted Emby `seek` scenario for each run, cycling seek targets, and waits for the
probe verdict. It then counts app signals from the unified log: prewarm outcome or skip, copy-lane
retry, `Could not create render pipeline`, `Resyncing AQ timeline` and `sbufIsOld`. Server signals
come from only the lines Emby appended to `/config/logs/embyserver.txt` during the run, notably
`Starting transcoding because currentTranscodingIndex=null` (a competing transcode start).

```sh
python3 scripts/emby-reopen-soak.py --query "<exact private title>" --runs 20
```

The app must already hold an Emby session; the runner never authenticates. It refuses to run while
the screen is locked, because the app cannot open its window or render. A run fails when the probe
gives no pass verdict or a prewarm runs against a verified copy child. A recovered retry and
audio-queue resyncs are reported, not failed. The printed summary omits the title, IDs, URLs and
tokens; redacted raw per-run logs stay under the gitignored `build/emby-reopen-soak/`. This is
Mac transport evidence only; lip sync, other platforms and hardware remain separate gates.

## Limits and remaining acceptance

Apple's decoded-audio sample output is documented for HLS. Negotiated original-file
routes require a separately proven measurement method. Retained HLS observation
has demonstrated consecutive-window audio and safe item replacement/cancellation,
but the tested runtime did not deliver the expected restart callback after seeks.
Seek capture therefore remains blocked rather than accepting potentially stale
samples. The research notes retain individual experiments and later findings.

A generated original-file MP4 also supplied usable audio through a mixed tap
attached **before playback** in the standalone host: 121 buffers, measured gain
about 0.998, no silence gaps, and continuous sample timestamps. The measured
envelope offset is not an absolute synchronization calibration. Two native-app
late-attachment controls, using mixed and exact-asset track modes, stopped before
publishing valid audio metrics. Those remain inconclusive; standalone success
does not authorize treating the corresponding backend tap as validated.

Physical speaker output, absolute A/V synchronization, passthrough/spatial audio,
HDR/Dolby Vision luminance, hardware decoder behavior and headset interaction remain
separate acceptance gates. SDR pixel comparisons cannot establish those properties.
Plex, Jellyfin and Emby must each retain their own source, delivery and authentication
results; a pass on one is not evidence for the others.

The current isolated Mac identity explicitly reports missing authentication for
Plex and Emby. A prior source-bound Jellyfin Original run passed transport checks
with audio/video copy and a negotiated original-file route; a later short rerun
did not expose its report within the collection bound. That later result is
inconclusive, not a new playback failure or a fresh backend pass. Normal signed-in
Jellyfin browsing was restored. Cross-backend audio-quality acceptance remains open.

See [the corpus workflow](MEDIA-CORPUS-TESTING.md),
[development guidance](DEVELOPMENT.md#experimental-headless-signal-measurement),
and repository research notes at `docs/research/HEADLESS-AV-SIGNAL-LAB.md`.
