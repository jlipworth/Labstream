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
[completed implementation journal](archive/plans/2026-09-06-agent-playback-evidence.md).
