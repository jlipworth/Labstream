# Agent playback troubleshooting

Use bounded fixtures and typed evidence before computer-driven exploration. The shipping
accessibility improvements remain ordinary user controls; the playback probes/exporter are
DEBUG-only and absent from Release/PerformanceAudit. No app API server or listener is added.

## Start without credentials or a server

```sh
uv run python scripts/playback-evidence.py --fixture
uv run python scripts/agent-playback-run.py fixture-consent
```

The first command checks a synthetic progress oracle. The second builds an isolated Mac hosted
controller fixture and requires four passing tests: consent lifecycle, admission, invalid options,
and backend-change refusal. It emits pass/fail/blocked JSON under an isolated run directory.
Neither command proves visible playback, hardware decoding, or server-job cleanup.

## Semantic Mac checks

Use Computer Use to select the exact isolated Mac app, launched with
`--ui-testing --ui-testing-fixture player`. Optional buffering/consent variants use
`--ui-testing-player-buffering` or `--ui-testing-player-consent`. The bounded CUA helper is
`scripts/cua/playback-fixture.js`; its checked identity is `agent-player-290`.

Command-Shift-K reveals controls without changing playback or approving encoding. Stable IDs
include `playback.playPause`, `playback.timeline`, `playback.close`, `playback.menu.<kind>`,
`playback.menu.close`, and quality/track rows. Re-read AX state after mutations. Chrome may
normally hide after a menu closes; explicitly reveal it before inspecting the next control.
Never bypass a locked session or Accessibility trust. Keep a small actual visual/frame check.

## Admitted live scenarios

Use the signed development app only with explicit permission to reuse its existing authenticated
identity. Never reset its container or Keychain. Supply the existing backend-specific playback
probe flag, `--vp-probe-backend`, a private `--vp-probe-query`, and `--vp-probe-allow-live`.
Initial bitrate defaults to Original (zero). `--vp-probe-evidence` opts into structured export.

Choose `--vp-probe-scenario original|seek|capped|maximum|consentDecline|consentApprove|audio|subtitles`.
Nonzero initial bitrate, capped/Maximum and approval require separately authorized
`--vp-probe-allow-video-encode`. This never grants durable approval or fabricates a pending
prompt. Unsupported tracks, absent consent, missing authentication or unproven decisions remain
blocked. A failed progress hold remains failed; it must not be described as a playback pass.

## Evidence interpretation and retrieval

The versioned allowlisted report distinguishes backend, generation, requested quality,
video/audio decisions and provenance, phase, consent, rendered format, attachment and cleanup
request. Unknown fields stay unknown. Request-enforced copy is not independent server evidence;
a client stop is not proof that a server job ended. Detached controller progress is not visible
rendering. Hardware HDR/audio, black frames and tint remain separate verification gates.

Named scenarios detach the player item and await their controller-owned stop requests before
publishing the terminal report. This prevents an external runner from terminating the app while
those requests are still pending. Request completion is not server-worker confirmation: retain
the separate bounded, exact-session server cleanup check and halt the queue if it fails.

Exports use fixed private app-support files, not arbitrary paths. When sandbox access is not
available, obtain a bounded exact-PID `PlaybackEvidence` category NDJSON unified-log pull using
`log show --info`. Public log fields are still strictly allowlisted. Long reports use ordered
512-character Base64 fragments to avoid OS string truncation; Base64 is not encryption.

```sh
uv run python scripts/playback-evidence.py --report /path/to/private-run.json
uv run python scripts/playback-evidence.py --unified-log /path/to/private-evidence.ndjson
```

Missing/reordered/truncated fragments fail validation. Do not mistake an empty or not-yet-flushed
log pull for a terminal app result. Keep raw logs private and bounded; retain diagnostics triage
for broader investigation. Stop the exact probe/fixture process and shut down any leased simulator
when finished. User-enabled diagnostics remain enabled.

Historical acceptance and the measured AX/screenshot comparison are in the
[completed implementation journal](https://github.com/jlipworth/Labstream/blob/main/docs/archive/plans/2026-09-06-agent-playback-evidence.md).

## Probe launch-argument reference

The procedures live in two skills: the
[`playback-frame-capture` skill](https://github.com/jlipworth/Labstream/blob/main/.claude/skills/playback-frame-capture/SKILL.md)
covers headless decoded-frame capture, and the
[`headless-pmskit-probe` skill](https://github.com/jlipworth/Labstream/blob/main/.claude/skills/headless-pmskit-probe/SKILL.md)
covers PMSKit requests against a real server without a simulator. The table below is a
compact map of the in-app flags. Unless noted, each flag is compiled only into DEBUG builds.
Files are under `Labstream/`. "Alters player" means the flag changes shipping player or
transport behavior for that run, so its results are not evidence for the default path.

| Flags | Owner | Purpose | Alters player |
| --- | --- | --- | --- |
| `--vp-probe-plex-playback`, `--vp-probe-jellyfin-playback`, `--vp-probe-emby-playback` | `Shared/Debug/Debug*PlaybackProbe.swift`, `Shared/App/ContentView.swift` | Backend playback probe entry points. | No |
| `--vp-probe-backend`, `--vp-probe-allow-live`, `--vp-probe-allow-video-encode` | `Shared/App/ContentView.swift`, `Shared/Debug/DebugPlaybackScenario.swift` | Backend switch and live/encoding admission. | No |
| `--vp-probe-query`, `--vp-probe-bitrate-kbps`, `--vp-probe-seek-ms`, `--vp-probe-playable-timeout-seconds`, `--vp-probe-stall-tolerance-seconds`, `--vp-probe-post-seek-hold-seconds` | `Shared/Debug/DebugPlaybackProbeSupport.swift` | Shared title, quality, seek, and timing options. | No |
| `--vp-probe-scenario`, `--vp-probe-evidence` | `Shared/Debug/DebugPlaybackScenario.swift`, `DebugPlaybackEvidence.swift` | Named scenarios and structured evidence export. | No |
| `--vp-probe-media-index`, `--vp-probe-expected-item-id`, `--vp-probe-expected-source-id`, `--vp-probe-discover-source` | `Shared/Debug/DebugJellyfinPlaybackProbe.swift`, `DebugEmbyPlaybackProbe.swift` | Jellyfin/Emby version selection, fail-closed identity checks, read-only source discovery. | No |
| `--vp-probe-rating-key`, `--vp-probe-media-id`, `--vp-probe-part-id`, `--vp-probe-plex-discover`, `--vp-probe-server-url` | `Shared/Debug/DebugPlexPlaybackProbe.swift` | Plex exact binding, discovery, and transport-endpoint override (keeps the restored token). | Endpoint only |
| `--vp-probe-decision-only`, `--vp-probe-bare-player` | `Shared/Debug/DebugEmbyPlaybackProbe.swift` | Emby control-plane-only run; Direct Play URL in a bare `AVPlayer`. | Bypasses controller |
| `--vp-probe-play-url`, `--vp-probe-rawurl-seek-s` | `Shared/Debug/DebugRawURLPlaybackProbe.swift` | Bare `AVPlayer` on a supplied URL, no backend or `PlaybackController`. | Bypasses controller |
| `--vp-probe-plex-browse` | `Shared/Debug/DebugPlexBrowseProbe.swift` | Read-only Plex browse-service acceptance. | No |
| `--vp-probe-capture-frames`, `--vp-probe-capture-hdr-signaling` | `Shared/Debug/DebugPlaybackFrameCapture.swift` | Decoded-frame PNG capture, optionally with HDR signaling. | No |
| `--vp-probe-hdr-evidence` (needs `--vp-probe-allow-live`) | `Shared/Debug/DebugPlexHDREvidence.swift`, `DebugMediaBrowserHDREvidence.swift` | Bounded HDR packaging evidence (playlist and init segment); no credentials or URLs. | No |
| `--vp-probe-system-buffering` | `Shared/Player/PlaybackController.swift` | Zero forward buffer and no stall waiting, for comparison. | Yes |
| `--vp-probe-disable-audio` | `Shared/Player/PlaybackController.swift` | Deselects the audible group for comparison. | Yes |
| `--vp-probe-emby-loopback-port` | `Shared/Player/PlaybackController.swift` | Routes Emby streams through a caller-owned `127.0.0.1` port-forward. | Yes |
| `--vp-probe-byte-ranges` | `Shared/Player/PlaybackController.swift` | Emby Direct Play range-request checks before playback. | Adds requests |
| `--vp-probe-p7-hdr10-candidate` (macOS; needs `--vp-probe-allow-live`) | `Shared/Player/PlaybackController.swift` | Plex DV Profile 7 copy opened as an HDR10 base-layer candidate through the loopback proxy. | Yes |
| `--vp-probe-plex-download`, `--vp-probe-jellyfin-download`, `--vp-probe-emby-download` and their lifecycle options (`start-download`, `start-optimize`, `download-preset`, `observe-*`, `pause-*`, `resume-observed`, `delete-*`, `keep-record`, `refresh-existing`, `existing-version`, `list-versions`, `range-check`, `dump-search`, `part-index`) | `Capabilities/Downloads/Debug/Debug*DownloadProbe.swift` | Download probes. | No |
| `--vp-probe-download-fault`, `--vp-probe-range-drop-after-bytes`, `--vp-probe-range-segment-bytes` | `Capabilities/Downloads/Core/BackgroundDownloadSession.swift`, `StaticRangeTransferConfiguration.swift` | Download fault injection and range-segment sizing. | Yes |
| `--vp-probe-background-download-session` (simulator builds, not DEBUG-gated) | `Capabilities/Downloads/Core/BackgroundDownloadSession.swift` | Forces the background `URLSession` in the simulator. | Yes |

## Playback failure codes

Playback failures use a closed, privacy-safe vocabulary shared by the player overlay,
pre-open playback errors, and `playback.failure_surfaced` diagnostics. Never infer an encoder,
GPU, or codec implementation failure from a delivery timeout alone.

| Code | Evidence and action |
| --- | --- |
| `LS-PB-001` | Backend explicitly rejected the playback decision. Try another version or contact the server administrator. |
| `LS-PB-002` | Server HTTP failure; show a numeric HTTP status only when supplied by a typed response or a recognized AVPlayer error. Check server/access and explicitly Retry. |
| `LS-PB-003` | Media delivery or reconnect deadline expired. Check server/network and explicitly Retry. |
| `LS-PB-004` | A safety policy blocked this playback path before unsafe video could be presented. Try another version. |
| `LS-PB-005` | Original playback failed without permission for video encoding. Obtain per-item consent rather than silently encoding. |
| `LS-PB-006` | Connection unavailable. Check server/network. |
| `LS-PB-007` | No authenticated backend session. Sign in again. |
| `LS-PB-008` | Previous Emby session stop was not acknowledged. No replacement encoder is started; check server connectivity and Retry. Acknowledgement does not prove worker exit. |
| `LS-PB-999` | Evidence does not identify the failure. Retry or provide app diagnostics; do not invent a server-specific diagnosis. |

Raw server text, URLs, paths, and framework descriptions are not user-facing messages.
Diagnostics retain the stable app code and available numeric HTTP/decision codes. Explicit
HTTP failures stop the attempt rather than triggering video-encoding consent. At least four
delivery error-log deadlines spanning 20 seconds within one item's rolling 30-second window
also stop resource retries; duplicate errors from a brief, recoverable prime do not satisfy
that time gate. A briefly advancing audio clock is not proof that video delivery recovered.
Transient deadlines remain eligible for the existing bounded recovery behavior.

Surfacing failure cancels attempt work, detaches the player item, and initiates exact-session
cleanup without requiring Close. Explicit Retry waits for that cleanup and then starts one
fresh attempt with the retained position, quality, consent, and pause intent. Repeated Retry
taps during cleanup do not create overlapping attempts. Server encoder implementation is
outside the app's acceptance scope: acceptance is an accurate error and safe recovery, not a
promise that every server can play every codec.
