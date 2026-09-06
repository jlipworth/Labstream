# Agent playback evidence and semantic troubleshooting

**Status:** active, first offline foundation implemented; live integration and semantic UI
acceptance remain open. Tracks [#290](https://github.com/jlipworth/Labstream/issues/290).
This is the next priority before release-readiness work. Deeper Emby native MP4 investigation
is deferred to [#291](https://github.com/jlipworth/Labstream/issues/291); its verified recovery
workaround is retained in the [client-first playback plan](2026-09-06-client-first-playback.md).

## Decision: no control transport yet

Start with finite, versioned artifacts and named in-process DEBUG scenarios. No listener,
HTTP/MCP server, custom-URL command admission, or external mutation endpoint is added.
Read-only offline evaluation does not authorize live playback, changing quality/tracks,
approving encoding, exporting credentials, or resetting any app identity. Only consider
an authenticated local adapter if scenario and semantic Accessibility limitations are
measured after those foundations exist.

Keep fixture, live-controller, visible-UI, and physical-device evidence separate. A sampled
playhead can prove progress but cannot prove changing frames, hardware decode, HDR/audio
output, controller-to-window attachment, or server-job cleanup. Unknown facts remain unknown.

## Implemented first slice: bounded progress oracle

Run the synthetic oracle self-check without a build, credentials, app, or network:

```sh
python3 scripts/playback-evidence.py --fixture
python3 -m unittest discover -s scripts/tests -p 'test_playback_evidence.py' -v
```

This is **not** the issue's app fixture transition acceptance: it exercises an offline
contract component only. Existing app probes do not emit this contract yet and their
current weak hold checks are not repaired by adding this evaluator. Live wiring must
replace those checks before claiming a stronger live-probe result.

The v1 input is a JSON object with exactly these fields:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `evidenceKind` | `synthetic`, `liveController`, or `rawPlayer` |
| `backend` | `fixture`, `plex`, `jellyfin`, `emby`, or `unknown`; fixture iff synthetic |
| `generation` | Run-local integer 1–1,000,000; not a backend session/client identifier |
| `holdSeconds` | Finite 5–300 seconds |
| `stallToleranceSeconds` | Finite 1–60 seconds |
| `samples` | 2–601 exact-shape observations |

Each sample has only `elapsedSeconds` (finite, strictly increasing, starting at zero,
maximum 360), `positionSeconds` (finite nonnegative, maximum seven days), `phase`
(`playing`, `waiting`, `paused`, `failed`, `cancelled`), and the same integer `generation`.
File input is capped at 256 KiB. Unknown/duplicate fields, stale generations, booleans in
numeric fields, nonfinite values, and unsupported versions are rejected. Error output
never echoes field names, input values, parser exceptions, or input paths. This is a
strict executable schema in the validator, not arbitrary diagnostic JSON passthrough.
Generation consistency detects mixed evidence; it is not authenticated live command admission.

```sh
python3 scripts/playback-evidence.py /path/to/private-bounded-evidence.json
```

Exit codes are 0 passed, 1 failed, 2 blocked. The allowlisted result distinguishes sustained
sampled progress from insufficient evidence. A pass requires at least the requested wall
window, moving intervals totaling at least 80% of that window, and a progressing terminal
interval. A waiting, paused, or nominally playing frozen clock all count as nonprogress.
A tolerance-length nonprogress interval fails. Observation gaps over two seconds and
seek-like jumps block rather than being credited as playback. The finite deadline is the
hold plus tolerance. This initial oracle deliberately assumes uninterrupted 1x playback;
intentional pause, seek, rate change, and controller generation changes need separate windows.

The result always reports video/audio decisions, visible attachment, hardware decoding,
and server cleanup as `unknown`: none can be inferred from this input. It does not claim
authenticity of user-supplied files. Seven regression tests cover valid progress, the old
three-second-then-frozen false green, paused/waiting starvation, endpoint seeks, short/gapped
observations, failure/cancellation, invalid/private fields, stale generations, and bounded
redacted CLI failures.

## Remaining implementation and acceptance

1. Add the typed app snapshot/event contract for build identity, opaque run generation,
   attachment, phase, requested quality, copy/encode provenance, audio, consent, errors,
   and cleanup-request state. Keep server-confirmed cleanup distinct.
2. Wire bounded progress observations into existing DEBUG probes, replacing endpoint-only
   and three-second hold success. Enforce cancellation/deadlines and restore diagnostics
   unless the user explicitly requested that they remain enabled.
3. Add an isolated synthetic **app** playback-transition command and schema validation.
   Preserve release/PerformanceAudit exclusion checks for every new app hook.
4. Add opt-in backend live scenarios for Original, seek, quality/track changes, consent
   decline and separately authorized approval. Unsupported/missing-auth cases are blocked.
5. Complete stable semantic controls and a non-coordinate way to reach hidden player chrome;
   test buffering, menus, and pending consent while preserving VoiceOver semantics.
6. Reject stale/unauthorized mutation if a mutation adapter is eventually introduced;
   none exists in this first slice. Test cancellation, logout/backend changes, and exact
   process/identity cleanup in the actual runner.
7. Measure comparable before/after AX calls, screenshots, elapsed time, retries and artifact
   bytes. No savings claim is made from this offline foundation. Retain small visual checks
   and physical-device gates.

Do not close #290 or begin release readiness on the strength of this first slice alone.
