# Issue #33 Stage 2 — proxy-owned seek & re-prime

**Date:** 2026-06-13
**Status:** Approved design; implementation pending
**Issue:** #33 — Stage 2 of the media-session-proxy staging plan.
**Extends:** `docs/superpowers/specs/2026-06-13-media-session-proxy-design.md` (the design of
record). Stage 1's contract — `open` / `seek` / `stop` / `status` — is fixed; this spec only
grows how much the proxy owns behind `seek`, and moves the PMS decision behind `open`.

## The bug this closes

Reported live: **"scrub-drag once → works (a bit slow); drag twice → sticky to the original
point + reconnect hell."** Stage 1 already proved the *transport* is sound (a wedged media
socket recovers and plays). The remaining failure is not transport — it is
`PlaybackController`'s fragile seek-restart orchestration. Two defects, both in
`PlaybackController.swift`:

- **Defect 1 — drifting target ("sticky").** A deep seek arms a re-prime keyed on
  `pendingSeekTargetMs`. A transient `.playing` blip in the buffering observer
  (~line 1555) clears `pendingSeekTargetMs` mid-flight. When the re-prime then fires it has
  lost the real target and falls back to the drifting `currentResumeMs`, so playback restarts
  near the *original* point — the "sticky" symptom.
- **Defect 2 — swallowed second drag ("reconnect hell").** `handleTimeJump` opens with
  `guard hasPlayedThisItem else { return }` (~line 1952). During the post-re-prime window
  `hasPlayedThisItem` is briefly false, so a genuine *second* drag is silently swallowed. No
  restart is armed; the 15s stall watchdog eventually fires `surfaceFailure` →
  `rebuildPlayer`, which hammers PMS into `serverUnreachable` — the "reconnect hell" cascade.

Both defects are symptoms of the same root cause: **seek-restart state lives as mutable flags
in the player, where it races player lifecycle events.** Patching either flag in place leaves
the architecture that produced them. Stage 2 removes the architecture: the seek target travels
as a value straight into the proxy, and the proxy — not the player — owns coalescing, budget,
re-prime, and the previous-transcode teardown.

## What moves, and the new boundary

Stage 1 left `open` as "dumb forwarder fed a pre-built `start.m3u8` URL" and `seek` as a
pass-through. Stage 2 makes the proxy **Plex-aware** (the boundary decision the user approved):
the proxy owns the PMS decision so it can re-run it at a new offset without a round-trip back
through the player.

The boundary rule from the design of record still holds — **no AVFoundation types cross it.**
The PMSKit types `TranscodeRequest` / `PlexRequest` / `DecisionResponse` *may* cross (they are
PMSKit, not AVFoundation), and the proxy now *builds and decodes* them itself. The proxy moves
from "knows about loopback sockets" to "knows about loopback sockets *and* how to ask PMS for a
stream at an offset."

**Layering caveat (important).** `PlexClient` lives in the **app layer**
(`PlexAVPApp/Networking/`), not PMSKit — PMSKit is a package the app depends on, so the proxy
**cannot** import `PlexClient`. The proxy therefore takes an **injected control-plane send
closure** — `@Sendable (PlexRequest) async throws -> Data` — exactly mirroring the existing
`upstreamFetch` (media-plane) seam. The app wires that closure to its live `PlexClient.send(_:)`
(reading the *current* client so a `retry()` recovery-client swap is picked up). The decision
*logic* — build `TranscodeRequest`, run the Direct Stream probe, read `savesVideoEncode`, pick
`startM3U8URL()` vs `directPlayStartM3U8URL()`, decode `DecisionResponse` — all moves **into**
the proxy (the user's "proxy owns the decision" choice). Only the transport is injected. The
`Accept: application/json` header that PMS needs (#7) is already baked into the `PlexRequest`
built by `decisionRequest()` / `directPlayProbeRequest()`, so routing through the raw closure
preserves it.

### Revised contract

```
open(_ request: MediaSessionRequest, offsetMs: Int) -> MediaSessionHandle   (localURL + generation)
seek(to offsetMs: Int)                              -> MediaSessionHandle   (coalescing; latest-wins)
stop(generation:)
status()                                            -> MediaSessionStatus
```

`MediaSessionHandle` and `MediaSessionStatus` are unchanged from Stage 1
(`MediaSessionTypes.swift`).

### `MediaSessionRequest` (new PMSKit type)

A `Sendable` value carrying everything the proxy needs to build a `TranscodeRequest` and run a
decision — *not* a pre-built URL. It is the player→proxy input that used to be assembled inline
in `PlaybackController.startStreaming`:

```
public struct MediaSessionRequest: Sendable, Equatable {
    public let server: URL
    public let token: String
    public let identity: ClientIdentity
    public let metadataKey: String
    public let maxVideoBitrateKbps: Int
    public let sessionID: String
    public let mediaIndex: Int
    public let partIndex: Int
    public let burnSubtitleStreamID: Int?
    public let directStreamEnabled: Bool
    public init(...)   // memberwise; all fields public
}
```

This is the audio/subtitle/quality `mediaSelection` from the contract, made concrete: it is the
exact set of `TranscodeRequest` inputs minus `startOffsetSeconds` (the offset is the separate
`offsetMs` argument, because it changes on every seek while the rest is stable for the session).
`burnSubtitleStreamID` is currently always nil in the live path (subtitle/audio selection is a
separate `StreamSelectionRequest` + restart), but is carried for fidelity with `TranscodeRequest`.

The proxy receives the control-plane transport as an injected `@Sendable (PlexRequest) async
throws -> Data` closure (see the layering caveat above), wired by the app to its `PlexClient`.
Test seam: the existing `init(upstreamFetch:)` gains a matching `controlSend:` parameter so a
test can drive both planes with in-process fakes (no live session).

## Seek flow

The proxy now distinguishes two kinds of seek; the player asks the proxy for the verdict
implicitly by always calling `seek(to:)`, but the *renderer-side* native-vs-deep decision stays
in `PlaybackController` because it is the only layer that can see AVKit's loaded ranges.

### Renderer-side: native seek vs. proxy re-prime

`PlaybackController.repositionViaProxy(toMs:)` (new) is called from the seek UI path. It checks
the target against the current `AVPlayerItem.loadedTimeRanges`:

- **Target inside a loaded range (+ a small guard band):** a native `player.seek(to:)` will
  satisfy it from already-buffered media. Do that; do **not** call the proxy. This preserves the
  fast, in-buffer scrub.
- **Target outside loaded ranges (deep seek):** call `await proxy.seek(to: targetMs)`, then on
  the returned handle do **one** `replaceCurrentItem` with a fresh `AVURLAsset(localURL)`
  (the "New localURL + replaceItem" reload mechanism the user approved). The proxy has already
  re-primed PMS at the target and held the playlist until the first segment is ready, so the new
  item starts at the target with no 7–9s black gap visible as a stall.

The threshold is **AVKit's own loaded-range knowledge**, not a hardcoded seconds delta. This
retires the brittle `seekJumpMinDeltaSeconds = 90` heuristic: "is it buffered?" is the real
question, and AVKit already answers it.

### Echo suppression — by target value, not a global flag

The status observer's resume-seek fallback and the time-jump path can both observe the *proxy's
own* re-prime landing as if it were a user seek. Stage 1 / pre-Stage-2 guarded this with the
global `hasPlayedThisItem` flag — which is exactly Defect 2: it cannot tell "the re-prime I just
issued" from "a real second user drag."

Replace it with **echo suppression keyed on the target value.** When `repositionViaProxy` issues
a deep seek to `T`, it records `lastProxySeekTargetMs = T`. An observed time-jump whose landing
position is within a small epsilon of `lastProxySeekTargetMs` is the echo of our own re-prime →
ignore. A jump to any *other* position is a genuine user action → forward to
`repositionViaProxy`. A real second drag goes to a *different* target, so it is no longer
swallowed. This is the precise fix for Defect 2, and it has no dependence on player lifecycle
flags, so the `.playing` blip (Defect 1's trigger) can no longer corrupt it.

## Coalescing & budget — owned by the proxy

`seek(to:)` is **coalescing, latest-wins, never-drop-the-latest:**

- If no re-prime is in flight, start one for the requested offset.
- If a re-prime **is** in flight and a new `seek(to:)` arrives, record the new offset as
  "pending latest" and let the in-flight one finish (or cancel it if cancellation is cheap and
  safe); then immediately start a re-prime for the pending-latest offset. Intermediate offsets
  superseded while waiting are dropped; the **latest is never dropped.** This is what makes
  "drag twice" correct by construction — the second drag's target supersedes the first's, and
  the proxy converges on it instead of the player racing two restarts.
- Each re-prime, before standing up the new stream, issues `TranscodeRequest.stop(...)` for the
  previous transcode (folding in `PlaybackController.stopPreviousTranscode`), so PMS reaps the
  old FFmpeg job instead of accumulating parallel transcodes (the fork-bomb noted in
  `DEVELOPMENT.md`).

The `SeekRestartBudget` (cooldown / burst / window) **moves into the proxy** from
`PlaybackController`. It now bounds *re-prime* storms rather than player-restart storms. When the
budget escalates, `seek(to:)` throws a typed error; `PlaybackController` surfaces it through the
existing failure path (`surfaceFailure`) instead of silently looping. A genuinely-down server
still exhausts the budget and surfaces — we do not mask an outage as infinite reconnect.

The proxy already owns the media-socket rotate budget for #33 transport recovery (Stage 1,
`UpstreamConnection` / `SeekRestartBudget`). Stage 2 adds the *re-prime* budget alongside it;
they are distinct counters (one bounds socket rotation, one bounds transcode re-priming).

## `PlaybackController` deletions

Stage 2 is as much a deletion as an addition. The following retire (all in
`PlaybackController.swift`):

- `handleTimeJump` timer machinery and `confirmSeekStallRestart` — the proxy owns
  restart-at-target now.
- Tunables `seekStallConfirmSeconds`, `seekJumpMinDeltaSeconds`, and the
  `seekRestartBudget` instance (budget moves into the proxy).
- `pendingSeekTargetMs` — the seek target no longer lives as mutable player state; it travels as
  a value into `proxy.seek(to:)` and (for echo suppression) as `lastProxySeekTargetMs`.
- The buffering observer's `.playing` branch lines that set `hasPlayedThisItem = true` and clear
  `pendingSeekTargetMs` (Defect 1's trigger). `hasPlayedThisItem` itself is removed if it has no
  remaining consumer after echo-suppression-by-target replaces it.

What stays in `PlaybackController`: the generic stall watchdog (`armStallWatchdog` /
`handleStallTimeout` — a real "nothing is happening" backstop, not seek-specific), the status /
buffering / error observers, and the new thin `repositionViaProxy` + `lastProxySeekTargetMs`
echo guard.

`startStreaming`, `reload(bitrateKbps:)`, `retry()`, and `selectAudioStream()` rewire to the new
proxy API: they build a `MediaSessionRequest` (the inputs they already gather) and call
`proxy.open(request, offsetMs:)` instead of assembling a `TranscodeRequest` + `start.m3u8` URL
inline and calling `open(origin:)`. The Direct Stream probe + decision logic moves *into* the
proxy's `open`, so these call sites shrink to "gather inputs → open → load returned URL."

## Error handling

- `seek(to:)` throws a typed `MediaSessionError` on: decision failure, prime-deadline exceeded
  past the rotate budget, or re-prime budget escalation. `PlaybackController` maps it to
  `surfaceFailure` (existing UI path) — never to a silent swallow or an unbounded rebuild loop.
- A native (in-buffer) seek never touches the proxy, so it cannot fail through this path.
- `open` failures (decision/probe) surface exactly as Stage 1 (the direct-URL fallback for the
  loopback-load-refused case is unchanged).

## Testing strategy

TDD order, smallest design-stable unit first:

1. **Coalescing never drops the latest** (proxy unit, injected decision closure): fire
   `seek(A)` then `seek(B)` while A is in flight; assert the proxy converges on B's offset and
   the final handle reflects B. Assert A's intermediate target is not the final state.
2. **Latest-wins under N concurrent seeks:** fire `seek(t1..tN)` rapidly; assert exactly the
   last target survives and earlier ones are superseded (not serially replayed).
3. **Budget escalation throws:** drive re-primes past the burst/window; assert `seek` throws
   `MediaSessionError` rather than looping.
4. **Decision re-run on re-prime:** assert each re-prime runs a fresh decision at the new
   offset (the injected closure is called with the new `offsetMs`).
5. **stopPreviousTranscode before re-prime:** assert the previous transcode's `stop` is issued
   before the new stream stands up (ordering, via the injected seam).
6. **Headless live-proxy probe extension:** `LiveProxyProbeTests` gains a **seek hop** — after
   priming at the initial offset, call `proxy.seek(to:)` to a second deep offset and assert the
   new variant + a primed segment forward through the loopback. Behind the live-creds gate
   (never committed); `swift test` stays hermetic without creds.
7. **Manual sim checklist** (`TESTING-CHECKLIST.md`): drag once (works), **drag twice in quick
   succession** (lands on the *second* target, no sticky, no reconnect cascade), in-buffer scrub
   (native, instant), deep seek (prime hidden), forced wedge during a seek (transport recovers).

## Non-goals / YAGNI

- No Stage 3 work (full logical-position ownership for a custom renderer) — the proxy still maps
  a renderer-reported wall-clock only where Stage 2 needs it (echo epsilon), not end-to-end.
- No new playlist transformation beyond Stage 1's absolute-URL safety net.
- No change to the `X-Plex-Client-Profile-Name=Safari` constraint or any transport framing.
- `hasPlayedThisItem` is removed only if no non-seek consumer remains; if one does, it is left
  for its real purpose and merely stops gating the seek path.

## Risks

- **Cancel-in-flight re-prime safety.** Cancelling an in-flight decision/prime to start the
  latest must not leak a half-stood-up loopback origin or an un-reaped PMS transcode. Mitigation:
  the coalescer's default is *let in-flight finish, then start latest* (no hard cancel); a hard
  cancel is only added if a test shows the let-finish path is too slow, and that test also
  asserts teardown of the abandoned stream.
- **Echo epsilon tuning.** Too tight → a real seek near the re-prime target is wrongly forwarded
  (harmless: just an extra re-prime to the same place). Too loose → a genuine small second drag
  is wrongly suppressed. Mitigation: epsilon is keyed to segment granularity, and the
  "drag twice to a *different* target" checklist item exercises the boundary.
- **Loaded-range readback timing.** `loadedTimeRanges` right after `replaceCurrentItem` is empty
  until buffering starts, so the first seek after a reload always reads "deep." This is correct
  (a fresh item has nothing buffered) and not a regression.
