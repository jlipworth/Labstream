# Private media corpus testing

Status: metadata tooling and opt-in authentication verified; release integration and
cross-server playback acceptance remain open.

## Purpose and privacy

Inventory the shared movie/TV files once, then select representatives of **observed**
stream combinations for bounded playback tests. This is not universal codec coverage,
not proof of playback, and not a requirement to replay a whole library on each commit.
Display/HDR capability acceptance is separate and currently deferred.

The reusable script contains no server credentials. All filenames, raw ffprobe output,
source references, inventory and representative manifests remain in gitignored
`build/media-corpus/`. No media files are downloaded or encoded. Do not attach these
private artifacts to public issues or CI logs; only publish reviewed aggregate counts.
The inventory requires an already authenticated Kubernetes context and a container with
GNU `find`, `timeout`, and `ffprobe`; it never starts an authentication flow.

## Run and resume

From the repository root, substitute an authorized context and actual read-only source
roots. The target/container defaults are Jellyfin but can be overridden:

```sh
python3 scripts/media-corpus.py --context YOUR_CONTEXT \
  --root /media/movies --root /media/tv --limit 500
```

The script enumerates files, probes at most two concurrently, and applies per-probe
server and client timeouts. It reads metadata, not decoded frames. The limit bounds probes, not enumeration: every candidate remains in the manifest.
Candidates interleave source roots deterministically so bounded passes include movies
and TV rather than all movies first. Remove `--limit` for the complete metadata pass. Results cache by source/container, probe configuration/schema, path, size and modification
time; successful unchanged probes are reused and failed probes retried. Cache identity does not fingerprint the ffprobe executable; discard the cache after
a server ffprobe upgrade. It is not a content hash: replace the cache when files change without size/mtime changes.
Probe depth is bounded, so absent codec details remain unknown rather than guessed.

Use `--summarize-only` with the same source options to export cached evidence without
probing missing files. Run it after an interrupted pass to create current manifests.
`complete_file_inventory` records successful enumeration; `complete_probe_coverage`
is false if files were skipped, remain unprobed, or failed.
`files.nul` is the complete filesystem listing, including sidecars; recognized video
extensions are candidates, not a guarantee that extensionless/unusual media is covered.

Outputs:

- `inventory.json`: source provenance, raw metadata, facts, and explicit failure status.
- `representatives.json`: one smallest source file per exact observed combination,
  preserving video profiles/pixel format/color metadata, resolution/frame rates,
  audio layouts, subtitle codecs, and codec side-data types/Dolby Vision profiles.
- `summary.json`: aggregate progress, error counts, and codec counts; attached artwork
  is excluded from primary video counts. Multiple real video tracks are counted separately.

Representatives are private **source references**, not local copies of movies or TV.
Unknown facts remain in grouping keys. Exact stream-order/resolution/frame-rate grouping
can produce many groups; do not mistake that for a minimal pairwise test suite.

## Release and future CI acceptance

Next steps before claiming release coverage:

1. Refresh the resumable metadata scan and review unknown/error categories. The initial
   full pass completed; invalid-file errors remain explicit, not silently omitted.
2. Map representative paths to each server's item identifiers in a private manifest;
   shared files do not imply identical Plex/Jellyfin/Emby item IDs.
3. Select a bounded release matrix by codec/container/audio/subtitle dimensions.
4. Capture decoded nonblack frames and post-seek evidence for direct play, remux and
   explicitly authorized bitrate-limited transcodes; transport success alone is insufficient.
5. Keep hardware-only display/audio gates separate from simulator evidence.
6. Consider opt-in, trusted self-hosted release CI with restricted credentials, serialized
   playback, transcode resource budgets, private artifact retention and no untrusted-PR
   access to the media network. Do not wire public hosted CI to private media credentials.

No infrastructure configuration is changed by this read-only workflow.

## Opt-in authentication and local workflow

Use the ordinary app login with an authenticated **Codex in-app browser**, not Safari.
Approve only the current app's one-time code; never export cookies or inject tokens.
Browser sessions can expire or require user MFA. Live-auth UI tests skip by default
and do not sign out an existing app session.

For the verified iPhone Jellyfin fallback:

1. Check and boot the exact worktree simulator through `worktree-sim.sh`; Device Hub
   running does not mean the simulator is booted. The
   `agent-mobile-run.sh iphone fixture-detail-semantic --allow-simulator` scenario
   verifies navigation independently of Device Hub.
2. Build for testing with the mobile scheme and `LabstreamTests` plan. Copy the
   `.xctestrun` beside the original under ignored build output to preserve `__TESTROOT__`.
   Set the UI-test target environment to `LABSTREAM_LIVE_AUTH_ALLOWED=1` and an
   authorized HTTPS `LABSTREAM_LIVE_AUTH_SERVER`.
3. Run only `LabstreamMobileLiveAuthUITests/testJellyfinQuickConnect` using
   `test-without-building`, an explicit simulator UDID, and `-parallel-testing-enabled NO`.
   Read the fresh screenshot and approve its code in the in-app browser; the test waits
   up to 240 seconds for Home. Relaunch without test flags to check session persistence.
4. Keep logs, pairing screenshots, configuration and results private; shut down the
   leased simulator afterward. This fallback neither fixes Device Hub nor proves
   visionOS interaction support.

Emby tests support Connect PIN and normal server credentials. The latter uses private
UI-test environment values `LABSTREAM_LIVE_EMBY_AUTH_ALLOWED=1`,
`LABSTREAM_LIVE_AUTH_SERVER`, `LABSTREAM_LIVE_AUTH_USERNAME`, and
`LABSTREAM_LIVE_AUTH_PASSWORD`. Delete credential-bearing xctestrun/result bundles
and retain only redacted summaries. A server web-UI login does not authenticate Emby
Connect's separate central service.

Workflow follow-up: verify backend switching and repeat authentication before making
this the default agent path. Review simulator driving, physical-device installation,
and log collection against existing scripts/skills; adopt replacements only after
checking install identity, evidence provenance, privacy and cleanup. Retain the
one-simulator-at-a-time policy and physical-device acceptance gates.

## Verified findings and current limits

The Jellyfin capped HLS profile and URL now request `mp4` (fMP4). A bitrate ceiling
can retain HEVC video copy; TS is not an Apple-compatible HEVC HLS container. Request
regressions cover both HEVC and H.264 and preserve caps/audio/subtitle choices. Emby's
separate `m4s` dialect is unchanged. See [issue #303](https://github.com/jlipworth/Labstream/issues/303).
Simulator frames established the reported Jellyfin fix; physical Vision Pro and deep
seek/reopen acceptance remain open. Emby corpus defects are separate investigations.

Jellyfin/Emby live probes now require a unique exact playable title in the returned
search page; missing, fuzzy-only, and duplicate matches fail closed. Emby also supports optional expected-item/source-ID assertions. This is not yet a
backend-ID manifest runner: inspect actual source provenance, especially with alternate
versions or generic episode names. A matching item outside the bounded search page is
unsupported rather than guessed. The default transport report still requires separate
human/agent visual inspection; an automatic perceptual correctness oracle is not shipped.

Smallest representatives can be studio logos or secondary encodes. Review duration and
source identity before selecting release cases. Starting a capped scenario at the same
8 Mbps value is a no-op, not a valid quality-transition test. Use a different initial
quality. Record first failures even when later repeats pass.

## Plex exact-source probes

Plex playback probes require a private, previously verified binding in addition to the
exact `--vp-probe-query` title: `--vp-probe-rating-key`, `--vp-probe-media-id`, and
`--vp-probe-part-id`. Fresh full metadata must match that item, title, Media ID and
single Part ID before opening playback. Media array order is not an identity; the
probe resolves the current index from the ID. Missing/mismatched bindings, duplicate
Media IDs and multipart sources fail closed. Movie/episode items only are supported.
This removes the old fuzzy-search fallback and unconditional version-zero selection.

For read-only mapping, add `--vp-probe-plex-discover` to the normal
`--vp-probe-plex-playback --vp-probe-allow-live --vp-probe-query "Exact fixture title"`
launch. It never opens playback. At most five unique exact-title search hits are
hydrated; larger results fail closed. Inspect the private
`Documents/ProbeDiscovery/plex.json` in the app container, then match its source path
and size to the inventory (server mount prefixes may differ). Review duration, codec,
resolution and alternate versions; titles alone cannot establish corpus identity.
An empty result is not a source match. Discovery removes its prior result before
requesting metadata; external runners must additionally require a fresh file timestamp.
Never publish this file: it contains media identifiers and source paths, but no token.

The opt-in mobile `LabstreamMobileLiveAuthUITests/testPlexLink` test uses
`LABSTREAM_LIVE_PLEX_AUTH_ALLOWED=1`, taps ordinary **Sign in with Plex**, and waits
for the Home tab after browser linking. Approve only the current app-generated code
in the Codex in-app browser. The test never signs out a saved session or injects a
credential. Run without test flags afterward to verify session persistence. If server
selection requires interaction, Home remains an explicit gate rather than a false pass.


### Startup gates and frame freshness

Capture-enabled probes reset all previous labels before admission/readiness; inability
to reset blocks the probe. Collect only frames created by the current process/run and
retain an explicit missing-frame result. Older builds may leave the previous run's
frames untouched if startup fails before capture. A directory's presence is not proof
that the current source decoded. See [issue #311](https://github.com/jlipworth/Labstream/issues/311).

An Original source for which Plex requests video encoding remains subject to explicit
consent. Probes report `blocked/consentRequired`, retaining a pre-cleanup pending-consent
snapshot and a separate post-stop snapshot. This is not a decoding failure and does not
authorize automatic encoding. Use the separately admitted `consentApprove` scenario only
with the user's encoding authorization; missing admission is a harness block, not a
server defect. Original/Maximum and Generic-profile production policies are unchanged.

Metadata-owned audio and subtitle changes restart asynchronously. Their probes wait for
a nonnil replacement AVPlayerItem before testing readiness and sustained progress, just
as quality transitions do. Soft AVFoundation/offline subtitle switches do not require
replacement. Replacement-wait unit tests inject a monotonic clock and poll step to
exercise predecessor, detached, replacement, deadline and safety-gate states without
racing independently scheduled fixture sleeps. Live probes retain the continuous-clock
deadline and 250-millisecond polling interval. The hold still fails if its item changes
unexpectedly; it is not weakened to tolerate arbitrary restarts. See [issue #312](https://github.com/jlipworth/Labstream/issues/312).

The [historical bounded Plex audit](https://github.com/jlipworth/Labstream/blob/main/docs/evidence/audits/2026-09-13-plex-corpus.md) records the tested
cohorts, first failures, independent fixes and hardware gates. For focused hosted
probe tests on Xcode 27, disable coverage with `-enableCodeCoverage NO` and wait for
terminal xcodebuild success before installing or launching another app process;
a completed test-suite log alone is not a completed test invocation.
