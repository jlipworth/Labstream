# Agent playback evidence and semantic troubleshooting

**Closeout:** published on `codex/client-first-playback` in `51a91a5e`; #290 closed.
The dated journal below is historical. Current procedures are in
[agent playback troubleshooting](../../AGENT-PLAYBACK-TROUBLESHOOTING.md).

**Status:** implemented and locally verified; publication/issue closeout pending.
Tracks [#290](https://github.com/jlipworth/Labstream/issues/290). No claim of fixing all
underlying playback failures or passing physical-device release gates is made.
This is the next priority before release-readiness work. Deeper Emby native MP4 investigation
is deferred to [#291](https://github.com/jlipworth/Labstream/issues/291); its verified recovery
workaround is retained in the [client-first playback plan](../../plans/2026-09-06-client-first-playback.md).

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

The Python `--fixture` self-check exercises only the offline oracle. The separate hosted
app-controller fixture below exercises actual controller transitions. Backend and raw-player
probes now use the matching Swift oracle: the former three-second hold and pre-hold raw
player pass have been removed. An item replacement during a hold invalidates that window;
intentional seek/quality transitions establish a new hold only after preparation.

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

## App/controller and visible-UI runners

```sh
uv run python scripts/agent-playback-run.py fixture-consent
```

This one command builds an isolated hosted Mac test identity, runs three focused tests
(including parameterized media-browser consent transitions), and emits bounded JSON plus
private local build/xcresult artifacts under the ignored agent artifact directory. No
credentials or live-server admission are used. It asserts real controller pending-consent,
decline, stale-approval rejection, and cleanup-request transitions with synthetic callbacks.
A pass does not assert visible playback, hardware decoding, or server-job termination.
The runner requires the exact non-skipped test count, not just a successful compiler exit.

The CUA-only helper in `scripts/cua/playback-fixture.js` provides named `hidden`, `buffering`,
and `consent` visible-UI checks, using freshly read identifiers after each action and a
specific isolated fixture window. It does not execute arbitrary commands or approve
encoding. Load it into the Computer Use JavaScript session after selecting the exact
isolated app, then invoke `verifyPlaybackFixture(app, mode)`. Normal terminal execution
is deliberately not a second UI-driver implementation.

The Mac fixture is enabled only in DEBUG, under a development bundle identity, with
`--ui-testing --ui-testing-fixture player`. Add `--ui-testing-player-buffering` or
`--ui-testing-player-consent` for those variants. Normal playback reuses the local generated
video recipe shared with the existing TV fixture; consent uses synthetic media-browser
callbacks and never contacts the placeholder address. Generation has finite writer deadlines.

## Named live scenarios and evidence

Live backend launch probes require `--vp-probe-allow-live`. Original is now the default
quality for these probes. Nonzero initial quality, `capped`, `maximum`, and `consentApprove`
additionally require `--vp-probe-allow-video-encode`; only supply that flag after separate
user authorization. Admission is not authentication: probes still require existing app
sign-in and never supply credentials or bypass OS restrictions.

Choose `--vp-probe-scenario original|seek|capped|maximum|consentDecline|consentApprove|audio|subtitles`.
The backend flag and query are unchanged. Missing admission/auth/options, unavailable tracks,
unproven negotiation, cancellation, and stale backend/generation evidence cannot pass.
Subtitle scenarios exclude choices needing burn confirmation. Track scenarios verify the
resulting selection instead of treating an attempted action as success. Maximum/approval
require encoding evidence; where the current backend cannot provide it, report blocked.
No scenario silently upgrades a copy attempt into authorized video encoding.

`--vp-probe-evidence` opts into fixed, bounded exports in the app's own Application Support
`AgentPlaybackEvidence` directory: `progress.json` and `run.json`. The directory is private
and files are replaced atomically with restrictive permissions. A redacted run report is
also emitted as ordered, bounded Base64 fragments in the dedicated `PlaybackEvidence` log category
to avoid unified-log string truncation. Base64 is transport encoding, not encryption; the
underlying report remains strictly allowlisted. No arbitrary export path,
listener, remote command channel, or shipping API is added. Do not bypass protected container
access to retrieve evidence; use supported diagnostics/log access instead.

```sh
python3 scripts/playback-evidence.py /path/to/private-progress.json
python3 scripts/playback-evidence.py --report /path/to/private-run.json
# For an exact-process NDJSON PlaybackEvidence log pull (include --info in log show):
python3 scripts/playback-evidence.py --unified-log /path/to/private-evidence.ndjson
```

The run report's typed snapshots carry numeric build/generation, backend enum, phase,
requested quality, video decision plus provenance, audio decision, pending consent,
bucketed position/buffer, allowlisted runtime codec, window attachment, and cleanup-request
state. Media-browser copy enforcement is request provenance, not server-job observation.
Codec-family agreement never proves copy. Render format/decisions stay unknown when absent.
On Mac, attachment requires the hosting window to be visible and not minimized. Other
platforms retain unknown visibility unless proven. Server cleanup always remains unknown
without independent server evidence. A client stop request is not a cleanup confirmation.

The launch scenario owns cleanup on completion/error/cancellation. It checks backend validity
while waiting and holding, and controller generation before applying asynchronously loaded
subtitle choices. There is no external mutation adapter; stale command/capability admission
is therefore not a claimed feature. The real consent controller still rejects stale prompt
generations. Diagnostics restore their prior value, so a user who left them on keeps them on.

## Semantic controls and measured comparison

Mac player chrome now exposes stable IDs for play/pause, timeline, relative skips, close,
menus and menu-close; quality and track rows expose selected/pending state without embedding
private track identifiers in selector names. Buffering and retry actions are named too.
Command-Shift-K reveals controls without changing playback or accepting consent. The surface
also exposes a human-readable Accessibility action when present. A fully hidden empty SwiftUI
surface can disappear from AX, so the keyboard path is the reliable hidden-chrome entrypoint.

A single same-fixture comparison measured the legacy screenshot-plus-coordinate reveal
against keyboard-plus-AX reveal (not a statistical benchmark):

| Path | CUA calls | Screenshots | Returned bytes | API time | Retries |
| --- | --- | --- | --- | --- | --- |
| Screenshot, pointer reveal, full AX | 2 | 1 | 28,960 PNG + 1,786 AX | 1,058 ms summed calls | 0 |
| Keyboard reveal, full AX | 1 | 0 | 1,786 AX | 442 ms | 0 |

Both reached the same visible control set. This only measures revealing/inspecting controls;
it does not prove generic agent cost savings or playback correctness. A small actual visual
check confirmed fixture pixels, and semantic pause/resume, seek, audio-menu open/close,
quality-row selectors, buffering-menu access, and preserving pending consent were exercised.
The durable helper passed on the final native fixture for hidden chrome, buffering, and consent decline.
A first buffering replay exposed a runner postcondition that raced normal chrome auto-hide;
the helper now verifies menu dismissal, explicitly reveals controls again, and checks the
semantic postcondition. Live backend artifacts remain under verification.

## Scoped acceptance and publication boundary

- Contract/no-transport decision and evidence distinctions documented.
- One-command synthetic controller scenario passed with four hosted tests, including stale
  backend refusal before player-item creation. Admission, stale consent/progress, cancellation,
  timeouts, private fields, and malformed/truncated evidence have negative coverage.
- Final semantic hidden-chrome, buffering, and pending-consent fixtures passed. Manual semantic
  play/pause, seek, menu/quality selectors and small visual checks are recorded above.
- Live Plex/Jellyfin/Emby reports exercise Original/copy, seek, quality transition, consent
  eligibility, audio and subtitle attempts. Unsupported evidence remains blocked; actual playback
  failures remain failed. No prompt was fabricated to manufacture a live approval success.
- Final Debug builds and passive simulator smoke passed for mobile, TV and visionOS; the signed
  Mac app and hosted controller runner passed. All simulators and probe processes were stopped.
- Final Release/PerformanceAudit builds and DEBUG-marker exclusion passed; audit binary contract passed.
- Measured AX/screenshot comparison recorded without generalizing it into a benchmark.
- Hardware picture/audio/HDR and independent server-cleanup proof remain explicitly outside this
  contract. Existing playback investigations and release gates remain open.

Remaining: publish the reviewed local commits and update/close the GitHub issue accordingly.
Staged app/build artifacts and sandbox credentials are retained for that handoff; no other
worktree, production container, Keychain entry, or installed application was reset or removed.

## Verification checkpoint

- Hermetic PMSKit: 1,695 tests passed; focused hosted Mac tests: 14 passed.
- One-command hosted fixture: 3 assertions/tests passed; Python tooling: 314 tests passed.
- Debug native builds: macOS, mobile, tvOS, visionOS passed. Mobile and TV UI smoke passed;
  visionOS fixture launch, process/log checks, and visual smoke passed. All simulators shut down.
- Release and PerformanceAudit builds passed; DEBUG playback markers absent, audit contract passed.
- Final CUA helper: hidden 5 AX reads / 6,863 bytes / 4,530 ms; buffering 5 / 8,990 /
  22,004 ms; consent decline 3 / 6,507 / 1,685 ms. No screenshots or retries inside these runs.
- First live Emby Original run reported failed playback with detached presentation and requested
  cleanup, not a false green. It exposed a backend display-label/enum mismatch in the exporter;
  fixed to use the typed session backend, with a hosted regression assertion. Revalidation passed.
- Brief live encoding acceptance has been separately authorized; no durable approval is granted.

The live Jellyfin Maximum scenario exercised a quality reload and sampled progress, but
returned blocked because video-encode provenance was unavailable. Its multi-snapshot report
exposed unified-log dynamic-string truncation. The exporter now emits 512-character Base64
fragments; the offline validator rejects missing, reordered, duplicated, malformed, oversized,
or truncated fragments. Final native replay reconstructed and schema-validated both Plex and Jellyfin multi-snapshot reports.
Plex seek reported failed progress with server-proven video copy/audio encode; Jellyfin Maximum
reported blocked/decisionUnknown after its capped-to-Maximum transition and sampled progress.
Both were detached-controller probes and requested client cleanup. Neither proves server cleanup.
The Emby approval scenario produced a valid blocked/missingAuth report; live approval remains
unverified. A subsequent normal launch restored the saved Emby session; a retry with Emby
already selected completed as blocked/consentNotPending, rather than approving without a prompt. The final Python tooling suite has 315 passing tests.


Latest live track runs: Emby audio returned failed/playbackFailed, and subtitles returned
blocked/unsupportedTrack. Both produced complete validated reports with client cleanup requested.
These are diagnostic outcomes, not claims that backend playback bugs are fixed. Playback probes
now run directly after session restoration/backend selection, ahead of unrelated inactive-download
hydration; the final signed Mac build and three focused hosted controller tests passed. The
current final native process was quit after its terminal report. No new authentication is required.

Final post-correction validation repeated clean native Debug builds and passive install/launch/log/
visual smoke on mobile, TV and visionOS, then shut down every simulator. Final Mac Release and
PerformanceAudit builds passed, the audit artifact contract passed, and no DEBUG playback markers
were present. The final one-command controller fixture passed all four tests in 40.42 seconds.

The requested GPT-6 Astra medium codebase sweep has not started; its issue inventory and
last-200-commit inputs are prepared locally. It follows publication/closeout of this issue.
