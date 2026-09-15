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
