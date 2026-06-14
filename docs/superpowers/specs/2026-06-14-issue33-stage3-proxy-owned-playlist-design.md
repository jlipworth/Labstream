# Issue #33 Stage 3 — proxy-owned full-timeline playlist & segment-level re-prime

**Date:** 2026-06-14
**Status:** Approved architecture (user chose "build proxy-owned playlist"); PTS gate verified; design pending user review.
**Issue:** #33 — Stage 3 of the media-session-proxy staging plan.
**Extends:** `2026-06-13-issue33-stage2-proxy-owned-seek-design.md` (Stage 2 moved re-prime
orchestration into the proxy but kept the *trigger* in the player). Stage 3 moves the trigger into
the proxy too and retires the player-side seek path.

## The bug this closes

Reported live: **"scrubbing backward went forward — the thumb holds at the back position for a
second, then playback loads just after where it was scrubbed *from*."** Stage 2's debounce
genuinely fixed the mid-gesture item-swap / reconnect storm (the original "drag twice"), but the
backward-seek capture persists. Root-caused this session with two independent live traces:

```
[VP] seekjump: now=7900.6s target=7900564ms lastPrime=7906560ms rate=0.00 seekable=[0-10548] loaded=[EMPTY]
[VP] seekjump: debounce settled — re-prime to 7900564ms      ← user had dragged to ~2600s
```

**Root cause (verified):** Stage 2's re-prime trigger is the player-side signal
`AVPlayerItem.timeJumpedNotification` + `player.currentTime()`. PMS serves a full-timeline playlist
whose segments *before the current prime offset are 188-byte PAT-only stubs* (see DEVELOPMENT.md).
When AVKit's native scrubber seeks far back, it finds no media at the target (a stub) and **pins
`currentTime()` to the currently-playable position** (~the original playhead) while the thumb holds
at the release point. So the only signal the player can read reports ≈the original position, and the
re-prime lands there. **The player-side signal is lossy for exactly the deep seeks that need a
re-prime, and the scrubber is AVKit's out-of-process black box in the expanded cinema experience —
no delegate exposes the true target.**

## The fix in one sentence

Stop asking the player where the user seeked. **AVKit, on any seek, autonomously requests the HLS
segment for the target time** — that request carries the intent losslessly. The proxy intercepts
it, and when it resolves to a stub, re-primes PMS at that segment's time, waits for real media, and
serves it under one stable playlist. AVKit's native seek then "just works" and `currentTime`
follows — forward, backward, any distance, in windowed *and* expanded cinema.

## Why this is now known-viable (the evidence gate)

Three live probes against the real server established the foundation (recorded in DEVELOPMENT.md):

- **Full-timeline playlist.** `start.m3u8` → tiny one-variant master; the media playlist lists
  **every** segment t=0→end (10548 one-second segments for the test film). Nothing needs rewriting
  into a full timeline — PMS already serves one. AVKit's scrubber already sees the full duration.
- **Absolute-time segment URIs.** Segment N is named `0NNNNN.ts`; `02600.ts` is t=2600s in *every*
  session regardless of prime offset. The segment request thus encodes the absolute seek target.
- **Per-session stub bytes.** A session primed at X serves real TS only from X forward (~60s
  throttle window); earlier segments are 188-byte stubs. This is the deep-seek stall — and the
  thing the proxy detects.
- **Absolute PTS (the gate, verified by `LivePTSProbe`).** `0NNNNN.ts` carries PTS ≈ N + a constant
  ~10.0s base in *every* session. Two sessions primed 600s apart produced PTS exactly 600s apart
  (3310.0s vs 3910.0s). **Therefore a segment from a session re-primed at the seek target splices
  into AVPlayer's existing timeline with NO reload and NO `#EXT-X-DISCONTINUITY`.** This is the only
  architectural unknown, and it resolved in favor of the design.
- **Re-prime cost ≈ 6.5–7s** for the first real segment — the latency a seek must tolerate.

This also closes fork-bomb driver (b) from DEVELOPMENT.md: AVPlayer's autonomous segment storm
during a scrub (seen live: 536 404s, 140 concurrent GETs, 8 stacked encodes) no longer hits PMS
raw — the proxy is the single chokepoint that collapses it into one coalesced, budgeted re-prime.

## Architecture

The proxy gains a **segment-aware serve path**. Everything else (loopback origin, upstream
connection, control-plane seam, coalescing re-prime loop, `SeekRestartBudget`, `stopPreviousTranscode`)
already exists from Stages 1–2 and is reused.

### Request dispatch (in `MediaSessionProxy.serve`)

Each loopback request is classified by its target path:

1. **Playlist** (`.m3u8` or `Content-Type` mpegurl): forward upstream, run the existing
   `PlaylistRewriter` (absolute-URL safety net — real URIs are relative and pass through), and
   **cache the media playlist's segment→time map** (accumulate `#EXTINF`, keyed by playlist path).
   The map is authoritative and content-agnostic (does not assume 1-second segments).
2. **Segment** (`.ts`): the new path below.
3. **Anything else:** unchanged transparent forward.

### Segment path — stub detection → re-prime-on-demand

```
serveSegment(target):
    t  = segmentTime(target)              // from cached playlist map; fallback parse 0NNNNN.ts
    up = fetchUpstream(target)            // from the CURRENT session
    if isRealMedia(up):                   // TS sync 0x47 AND body > stub threshold
        return up                         // passthrough — the common case, no re-prime
    // stub → the requested time is outside the current prime's produced window
    await reprime(toMs: t)                // existing coalescing/latest-wins/budget machinery
    return await pollUntilReal(target, deadline)   // re-fetch 0NNNNN.ts from the new session
```

- **`isRealMedia`:** a real segment at these bitrates is megabytes; a stub is ~188 bytes (PAT only,
  no video PES). Classify a body `<= STUB_MAX_BYTES` (a small constant, e.g. 4 KB) **and** lacking a
  video PES start as a stub. Tight by construction — no real segment is that small here.
- **`reprime(toMs:)`** is the Stage-2 coalescing entry, now invoked *internally* by the segment
  handler instead of by the player: stop the previous transcode → fresh decision at `t` → new
  upstream session. Latest-wins coalescing means a continuing drag (a newer stub request at `t'`)
  supersedes `t`; the **settle-point request is correct by construction**. `SeekRestartBudget`
  bounds storms and escalates to the failure overlay (unchanged).
- **`pollUntilReal`** re-fetches `0NNNNN.ts` from the new session until it is real or a deadline
  (tied to the rotate budget) passes, then returns the real bytes as the response to AVKit's
  *original* request. AVKit never sees a reload — it just waited ~7s for its segment.
- **Stable face:** the loopback URL AVKit loaded stays fixed across re-primes; the proxy rotates the
  *upstream* session beneath one stable playlist. Because segment URIs are absolute, even if AVKit
  re-fetches the playlist it is consistent across sessions. **No `replaceCurrentItem`, no item swap.**

### Mapping a loopback segment request onto the current upstream session

Segment URIs are relative, so `0NNNNN.ts` resolves against the media-playlist URL — i.e. the
current upstream session's path (`.../session/<id>/.../0NNNNN.ts`). On re-prime the session id
changes, so the proxy maps the **stable loopback segment path** onto the **current** upstream
session (the proxy already tracks the live handle/generation). `UpstreamURLMapper` becomes
re-prime-aware: it resolves against the session current at request time, not a frozen base.

## `PlaybackController` — Stage 3 is mostly deletion

The player becomes thin: build `MediaSessionRequest` → `proxy.open(request, offsetMs:)` → load the
**one** returned loopback URL → let AVKit's native scrubber drive. Every seek (scrubber, chapter
tap, resume) is a native `player.seek(to:)` that AVKit turns into a segment request the proxy
intercepts. There is no player-side seek special-casing left.

**Delete** (all in `PlaybackController.swift`):
- The Stage-2-this-session **debounce**: `pendingReprimeTargetMs`, `reprimeDebounce`,
  `reprimeDebounceNanos`, `scheduleReprime`, `cancelPendingReprime`.
- `handleSeekJump`'s re-prime trigger, its TEMP diagnostics, and `loadedRangesDescription()`.
- `repositionViaProxy(toMs:)` and the `lastProxySeekTargetMs` echo guard — with no player-side
  re-prime trigger there is no echo to suppress.
- The `timeJumpedNotification` observer wiring used only for the seek-driven re-prime (and its
  removal in `removeObservers()`).

**Keep:** the generic stall watchdog (a real "nothing is happening" backstop, not seek-specific),
the status/buffering/error observers, the #33 transport auto-rotate, and `open`/`reload`/`retry`
wiring to the proxy.

**Proxy API:** `proxy.seek(to:)` stops being a player-called entry; the coalescing re-prime it
fronts is now driven by the segment handler. Whether to keep `seek(to:)` public for any residual
caller (none expected) is decided in implementation — the live-proxy probe still exercises it.

## Testing strategy (TDD, smallest design-stable unit first)

1. **Dispatch + segment→time map** (pure unit): classify `.m3u8` vs `.ts`; parse a media playlist
   into the segment→time map; assert `02600.ts → 2600s`.
2. **Stub detection** (pure unit): a 188-byte PAT body → stub; an MB-sized `0x47…` TS → real;
   boundary at `STUB_MAX_BYTES`.
3. **Re-prime-on-stub** (proxy unit, injected upstream fake that returns a stub until a re-prime at
   `t` then returns real bytes): a stub segment request triggers a coalesced re-prime at the
   segment's `t`, then re-fetches and serves real bytes; the real-segment case forwards with **no**
   re-prime.
4. **Coalescing latest-wins under stub storm** (reuse Stage 2's coalescer): two stub requests for
   different times converge on the latest target; earlier is superseded, not serially replayed.
5. **Budget escalation** (reuse): a stub storm past burst/window throws → `surfaceFailure`, no
   silent loop.
6. **Live (`LiveProxyProbe` extension, behind the creds gate):** prime at offset X, then request a
   **backward** stub segment (`0(X-600).ts`) through the proxy and assert it returns real TS (the
   proxy re-primed) — the headless analog of the live bug.
7. **Manual sim (`TESTING-CHECKLIST.md`):** deep backward scrub lands at the **release point** (THE
   bug); deep forward scrub; drag-twice to different targets (lands on the second, no sticky); in-
   buffer scrub stays instant (native, no re-prime); backward chapter jump; forced wedge during a
   seek still recovers.

## Risks

- **AVKit segment-fetch timeout (the one to watch live).** The re-prime holds AVKit's segment
  request open ~7s. If AVKit's HLS segment-load timeout is shorter mid-playback, it errors the seek.
  Mitigation: keep the connection warm during the poll; AVKit retries a failed segment and the
  retry finds it already real (fast). We know AVKit tolerates ~7s at open (deep-resume works); the
  mid-seek tolerance is the first thing to verify on the sim. Not architectural — a tuning risk.
- **Real-segment buffering churn.** The proxy reads full segment bodies to forward (pre-existing
  Stage-1/2 behavior; ~3 MB × buffered segments, transient). Streaming the body is a future
  optimization — YAGNI for Stage 3; flagged, not fixed.
- **Stub false-positive.** A genuinely tiny real segment (stream end) could trip a needless
  re-prime. Mitigation: classify on structure (PAT-only / no video PES) plus a small size bound, not
  size alone.
- **Superseded held segment requests.** A stub request for a target the user drags past is served
  best-effort (or AVKit cancels it); correctness rests only on the **settle-point** request, which
  the latest-wins coalescer guarantees. Exercised by the drag-twice checklist item.

## Non-goals / YAGNI

- No custom renderer or injected scrubber — keeping AVKit's native scrubber is the entire point.
- No streaming-body rewrite (buffer-and-forward stays).
- No change to `X-Plex-Client-Profile-Name=Safari` or any transport framing.
- No change to the Direct Stream decision (it still picks copy-vs-transcode per offset on each
  re-prime, via the proxy's existing `open`/decision logic).
