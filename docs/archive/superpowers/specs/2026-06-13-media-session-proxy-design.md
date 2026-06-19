# Media Session Proxy — design of record

**Date:** 2026-06-13
**Status:** Approved design; staged implementation pending
**Issues:** #33 (media-plane poisoned connection → "Reconnecting" cascade), and the
seek-recovery / deep-seek-prime idiosyncrasies currently living in `PlaybackController`.

## Why this exists

Two problems pushed us here, one immediate and one structural.

**Immediate (#33).** A heavy HLS stream can wedge a CFNetwork socket. We already fixed the
*control plane*: `PlexClient.recovery(...)` swaps in a fresh ephemeral `URLSession` so
decision / probe / timeline / `start.m3u8` requests stop waiting behind a half-open
keep-alive (`-1001`). But the *media plane* — `AVURLAsset` fetching the HLS playlist and
segments — runs entirely inside AVFoundation's own process-wide CFNetwork pool. App code
cannot reach or flush it. `AVAssetResourceLoaderDelegate` is **not** invoked for native
`https` HLS, and there is no API to flush AVFoundation's media-plane connections. So when
that socket wedges we get `-1008` / CoreMedia `-12884`, and the OS only self-heals after
~30s — which is exactly the "second Retry works, first doesn't" behavior, the Reconnecting
cascade, and the black screen when the user closes mid-reconnect.

The only way to make the media plane recoverable from app code is to **interpose something
the app owns** between AVKit and PMS.

**Structural.** Once we own that interposition point, it should not be a one-trick
connection-rotation hack wired into `PlaybackController`. The player layer is already
carrying idiosyncratic PMS behavior as special cases: deep-seek prime (PMS takes 7–9s to
prime a transcode at a far offset), seek-confirm restart, stall watchdogs, control-plane
recovery. Some of those (the deep-seek-prime restart, the seek-confirm bypass for
unregistered `timeJumpedNotification`) are incompletely handled and leak as bugs.

So the interposition point becomes a **player-agnostic media session service**: it owns the
PMS-shaped idiosyncrasies behind a clean contract, and whatever renders video (AVKit today,
a custom/RealityKit player later) just consumes a URL and reports events.

### Guiding principle (user directive)

> Keep the idiosyncratic logic in the proxy; the player stays as standalone / simplistic as
> possible.

Concretely: seek-restart, deep-seek-prime hiding, stall-driven re-prime, and connection
recovery migrate **into** the proxy over the staged plan. `PlaybackController` trends toward a
thin consumer that (a) asks the proxy to `open` / `seek` / `stop`, (b) points `AVURLAsset` at
the URL the proxy returns, and (c) forwards player events back to the proxy. We do **not** add
another pile of special cases inside `PlaybackController`.

## The contract

A single explicit, player-agnostic surface. No AVFoundation types cross it.

```
open(item, offset, quality, mediaSelection)  -> localPlaybackURL        (+ stream generation)
seek(to:)                                     -> updated localPlaybackURL / stream generation
stop(generation)
status / metrics                              -> observable session state
```

- `open(...)` starts a logical media session. The proxy builds the PMS universal-transcode
  request (`TranscodeRequest` — Direct Stream probe + decision + `start.m3u8` /
  `directPlayStartM3U8URL()`), stands up the loopback origin, and returns a
  `http://127.0.0.1:<port>/…` URL plus a **generation** token identifying this stream.
- `seek(to:)` is the logical seek. In Stage 1 it is a thin pass-through (AVKit still seeks);
  in later stages the proxy owns the seek — it can re-prime PMS at the target offset and
  return a *new* URL/generation, hiding the 7–9s prime from the renderer.
- `stop(generation)` tears down the loopback origin and issues PMS
  `TranscodeRequest.stop(...)` so the server-side FFmpeg job is reaped (HLS gives PMS no
  other "client left" signal).
- `status / metrics` exposes session state (generation, upstream health, rotate count, prime
  state) for the player UI and for tests/diagnostics — no AVFoundation leakage.

**Position semantics.** The proxy owns the *logical* playback position / seek target. The
renderer reports wall-clock progress; the proxy maps that onto PMS offsets and decides when a
seek needs a re-prime vs. a native scrubber seek. This is what lets a future custom renderer
reuse the same session logic.

## Architecture

```
 Player / AVKit / future custom renderer
        │  consumes localPlaybackURL, reports events
        ▼
 VisionPlay Media Session Proxy   ── owns position / seek / prime / recovery
        │  loopback origin (NWListener on 127.0.0.1:<port>)
        │  forwards over an app-owned upstream URLSession
        ▼
 PMS universal transcode / direct stream
```

### Module boundary

A **separate PMSKit module/service**, not new branches inside `PlaybackController`. PMSKit is
the right home: it already owns request building (`TranscodeRequest`,
`PlexSessionConfiguration`) and is unit-tested in isolation on the macOS `swift test` host.
`Network.framework` (`NWListener`) is available on both the macOS test host and visionOS, so
the proxy and its tests are cross-platform.

The app layer keeps only the glue: construct the proxy, hand it the `TranscodeRequest`
inputs, point `AVURLAsset` at the returned URL, forward events.

### Loopback transport

- Hand-rolled `NWListener` bound to `127.0.0.1:0` (kernel-assigned port; read back the actual
  port for the base URL). Zero third-party dependencies.
- Each inbound HTTP request from AVKit is forwarded to PMS over an **app-owned upstream
  `URLSession`** configured like `PlexSessionConfiguration.recoveryControlPlane(...)`:
  `.ephemeral`, no cache, no cookies, `waitsForConnectivity = false`, request/resource
  timeouts. Streaming bodies are piped through (the proxy must stream, not buffer whole
  segments).
- `rotateUpstream()` = `invalidateAndCancel()` the upstream session + build a fresh ephemeral
  one. This is the only thing app code *can* do that AVFoundation's own pool won't: guarantee
  a brand-new socket for the next request.

### Relative-URL handling (probe-confirmed)

PMS emits **relative** URIs in `index.m3u8` (variant playlists, segment names). Because
`AVURLAsset` resolves those against the playlist's own URL — which is now the loopback base —
variant and segment requests come back to the proxy automatically. **No rewriting needed in
the common case.** As a safety net, the proxy rewrites any *absolute* PMS URL it sees in a
playlist body back to the loopback base.

### Transparent auto-rotate (#33 recovery)

The proxy rotates the upstream socket transparently so the user never taps Retry — but it
must **not** rotate on a legitimately-slow prime (~8s deep seek).

- **The discriminator is a generous time-to-first-byte deadline set above the known prime
  ceiling, not byte-progress alone.** A deep-seek prime can hold the connection open with *no
  bytes flowing* for 7–9s while PMS encodes the first segment, so "no bytes yet" cannot by
  itself mean "wedged." Instead the upstream request timeout is set comfortably above the
  observed prime ceiling (config constant, ~20s) so a real prime completes inside it; a socket
  that produces nothing past that deadline is treated as wedged. `URLSession`'s native
  byte-progress reset is a *helping* factor (a segment that streams steadily resets the
  deadline) — it is not the sole mechanism, because a silent prime never gets to reset it.
- On upstream timeout / connection error for a request: `rotateUpstream()` once, retry the
  same request on the fresh session.
- Bounded by a cooldown to avoid rotate-storms (reuse the `SeekRestartBudget` shape:
  cooldown / burst cap / window). A genuinely-down server exhausts the budget and surfaces
  through the existing failure path — we do not mask a real outage as an infinite reconnect.

### Trust & ATS

- **Upstream trust** mirrors the app default: `*.plex.direct` presents a valid publicly-trusted
  wildcard cert, so default trust evaluation "just works" with no delegate. The opt-in,
  host-scoped `PlexInsecureLANTrustDelegate` (bare-IP LAN) is wired into the upstream session
  only when the user has enabled insecure LAN — same posture as the rest of the app.
- **Loopback ATS:** the renderer loads `http://127.0.0.1:<port>/…`. Loopback HTTP is expected
  to be allowed without an ATS exception. Fallback if AVFoundation refuses the local load: add
  a scoped `NSAllowsLocalNetworking` to `Config/Info.plist` (no broad `NSAllowsArbitraryLoads`).

## Staged plan

Staged so we reach a runnable, testable state fast, then migrate idiosyncratic logic inward
without a risky big-bang rewrite. The **contract is fixed from Stage 1**; only how much the
proxy owns behind it grows.

### Stage 1 — loopback transport + transparent #33 recovery (testable target)

- PMSKit `MediaSessionProxy` implementing the full `open / seek / stop / status` contract.
- `NWListener` loopback origin; app-owned upstream session; streaming pass-through; relative
  URLs resolve naturally, absolute-URL rewrite safety net.
- Transparent auto-rotate with the byte-progress discriminator + budget.
- `seek(to:)` is a pass-through (AVKit still seeks natively); `open`/`stop` fully owned.
- Wire into `PlaybackController`: point `AVURLAsset` at the proxy URL; `stop` on teardown;
  ATS fallback if needed.
- **This is the "good shape for me to test" deliverable** — it fixes #33 end-to-end (media
  plane becomes recoverable) without changing seek behavior.

### Stage 2 — proxy-owned seek & deep-seek-prime hiding

- `seek(to:)` becomes authoritative: the proxy decides native-scrubber-seek vs. PMS re-prime
  at the target offset, returns a new URL/generation when it re-primes, and hides the 7–9s
  prime from the renderer (e.g. holds the new playlist until first segment is ready).
- Folds in the two leaking bugs: the seek-confirm restart and the **deep-seek bypass** where
  an unregistered `timeJumpedNotification` currently falls through to the 15s stall watchdog
  (which can only surface failure, not restart-at-target). The proxy owns restart-at-target.
- `PlaybackController`'s `handleTimeJump` / `confirmSeekStallRestart` / stall-watchdog
  special cases retire as the proxy takes ownership.

### Stage 3 — full position ownership for a custom renderer

- Proxy owns logical position/timeline end-to-end so a custom/RealityKit renderer can consume
  the same session with no AVKit-specific seek plumbing.

Stages 2–3 are out of scope for the first implementation plan; this spec records the
direction so Stage 1's contract doesn't paint us into a corner.

## Testing strategy

- **Unit (pure, design-stable):** URL mapping — loopback base ↔ PMS, relative-URI resolution,
  absolute-URL rewrite safety net. No network.
- **Integration with a stub origin:** an in-test `NWListener` standing in for PMS lets us
  exercise forward/stream/rotate against a controllable server: assert pass-through fidelity,
  assert a wedged-socket scenario triggers exactly one rotate + retry, assert the budget caps
  rotate-storms, assert a slow-but-progressing body is **not** rotated.
- **Live-through-proxy hook:** extend the existing live-probe pattern
  (`LiveSegmentProbeTests`) to fetch `index.m3u8` + a segment *through* the proxy against real
  PMS, behind the live-creds gate (never committed). Add a `TESTING-CHECKLIST.md` entry for
  the manual sim pass: deep seek (prime), forced wedge → transparent recovery (no Reconnecting
  box), close-mid-reconnect (no black screen).
- TDD order: pure URL mapping first (design-stable regardless of later staging), then stub-origin
  integration, then wire-in.

## Non-goals / YAGNI

- No full general-purpose HLS proxy or playlist transformation beyond the absolute-URL safety
  net — PMS relative URIs make that unnecessary.
- No `AVAssetResourceLoaderDelegate` custom-scheme approach (fragile, Apple-discouraged for
  full HLS).
- No broad ATS relaxation — loopback/local-networking scope only, and only if required.
- Stages 2–3 behaviors are documented but not built in the first plan.

## Risks

- AVFoundation may dislike some response framing from a hand-rolled origin (chunked vs.
  content-length, range requests for segments). Mitigation: stub-origin integration tests
  assert AVKit-compatible framing; the live-through-proxy hook catches real-PMS quirks early.
- Range requests: AVKit may issue `Range` headers for segments; the proxy must forward them
  and pass through `206 Partial Content` faithfully. Covered by the stub-origin tests.
- Rotate discriminator false-positives on a genuinely slow server. Mitigation: byte-progress
  resets the timer, and the budget bounds the blast radius.
