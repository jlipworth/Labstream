# Private media corpus testing

Status: initial tooling; release integration and cross-server playback acceptance remain open.

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

## Developer workflow refresh backlog

### Verified iPhone authentication fallback

When Device Hub's desktop accessibility connection times out, first check the exact
worktree simulator with `simctl list devices` and boot it through `worktree-sim.sh`.
Do not confuse a running Device Hub process with a booted simulator. The named
`agent-mobile-run.sh iphone fixture-detail-semantic --allow-simulator` runner proves
semantic app navigation independently of Device Hub's desktop window.

The opt-in `LabstreamMobileLiveAuthUITests/testJellyfinQuickConnect` test drives the
ordinary signed-out app's Jellyfin picker, server field, and Quick Connect button.
Build for testing with the mobile scheme and `LabstreamTests` plan. In an ignored copy
of the generated `.xctestrun` next to the original (preserving `__TESTROOT__`), set the
UI-test target's `EnvironmentVariables` entries `LABSTREAM_LIVE_AUTH_ALLOWED=1` and
`LABSTREAM_LIVE_AUTH_SERVER` to the authorized HTTPS server origin. Execute only that
test with `test-without-building`, the explicit simulator UDID, and
`-parallel-testing-enabled NO`. Default test runs skip it before launching the app.

Read the fresh simulator screenshot, approve only its displayed code in the existing
authenticated **Codex in-app browser**, and let the test verify the Home tab appears.
It waits at most 240 seconds for browser approval, never signs out an existing session,
and never copies tokens or browser cookies. Keep all test logs, `.xcresult` bundles,
server configuration, and pairing-code screenshots private and gitignored. Relaunch
without test flags to verify that the app's own stored session survives. Shut down the
leased simulator when the verification session ends. This iPhone fallback has been
verified; it does not establish visionOS interaction support or fix Device Hub itself.

### Remaining workflow review

- Prefer an authenticated in-app browser for Plex link, Jellyfin Quick Connect, and
  supported Emby connection approvals. Let the app initiate its own one-time code and
  complete its normal credential storage; do not export browser cookies or copy tokens
  into simulator containers. Browser sessions may still expire or require user MFA.
- Validate this closed-loop authentication path before making it the default agent
  workflow, including backend switching and repeat runs without repeated manual login.
- Review current simulator interaction, physical-device build/install, and device log
  collection tools against the existing scripts and skills. Adopt newer supported paths
  only after proving their install identity, artifact provenance, privacy, and cleanup
  behavior; retain device-only acceptance gates and one-simulator-at-a-time scheduling.
- Keep authentication artifacts private, approve only codes generated by the current
  test app, and never broaden account access or bypass security prompts to automate tests.

## Verified findings and current limits

The Jellyfin capped HLS profile and URL now request `mp4` (fMP4). A bitrate ceiling
can retain HEVC video copy; TS is not an Apple-compatible HEVC HLS container. Request
regressions cover both HEVC and H.264 and preserve caps/audio/subtitle choices. Emby's
separate `m4s` dialect is unchanged. See [issue #303](https://github.com/jlipworth/Labstream/issues/303).
Simulator frames established the reported Jellyfin fix; physical Vision Pro and deep
seek/reopen acceptance remain open. Emby corpus defects are separate investigations.

Jellyfin/Emby live probes now require a unique exact playable title in the returned
search page; missing, fuzzy-only, and duplicate matches fail closed. This is not yet a
backend-ID manifest runner: inspect actual source provenance, especially with alternate
versions or generic episode names. A matching item outside the bounded search page is
unsupported rather than guessed. The default transport report still requires separate
human/agent visual inspection; an automatic perceptual correctness oracle is not shipped.

Smallest representatives can be studio logos or secondary encodes. Review duration and
source identity before selecting release cases. Starting a capped scenario at the same
8 Mbps value is a no-op, not a valid quality-transition test. Use a different initial
quality. Record first failures even when later repeats pass.

The opt-in Emby auth tests support Connect PIN and normal server credentials. The latter
uses private UI-test environment values `LABSTREAM_LIVE_EMBY_AUTH_ALLOWED=1`,
`LABSTREAM_LIVE_AUTH_SERVER`, `LABSTREAM_LIVE_AUTH_USERNAME`, and
`LABSTREAM_LIVE_AUTH_PASSWORD`. Never commit these values or expose them in logs. Delete
credential-bearing xctestrun/result bundles after use; keep only redacted summaries.
Emby Connect requires its own credentials; a server web-UI login does not authenticate
that central service. Default runs skip all live-auth tests without opt-in.
