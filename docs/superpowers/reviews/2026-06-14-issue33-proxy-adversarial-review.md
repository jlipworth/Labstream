# Adversarial review — MediaSessionProxy as it stands (#33)

**Date:** 2026-06-14
**Reviewed artifact:** `PMSKit/Sources/PMSKit/MediaSession/` at the Stage-2 commit (`1758e51`):
`MediaSessionProxy.swift`, `LoopbackOrigin.swift`, `UpstreamConnection.swift`,
`UpstreamURLMapper.swift`, `PlaylistRewriter.swift`, `HTTPMessage.swift`.
**Lens:** read in the light of the Stage-3 design
(`docs/superpowers/specs/2026-06-14-issue33-stage3-proxy-owned-playlist-design.md`), which moves
the seek-restart trigger off the player and into the proxy's segment-request path. The question
this review answers: *is the proxy foundation sound enough to carry that new load?*

## Method

Three independent adversarial passes, each with a distinct failure-hunting lens:

1. **HTTP / proxy-correctness** — does the byte-for-byte forwarding preserve HLS semantics under
   compression, range requests, partial responses, and HEAD?
2. **Lifecycle / concurrency** — what leaks, races, or outlives teardown across the loopback origin,
   the upstream session, and the re-prime task?
3. **Seek / re-prime / budget semantics** — does the coalescing + budget machinery still mean what
   it was tuned to mean once the *trigger cadence* changes from "one per settled drag" (Stage 2) to
   "one per stub segment request" (Stage 3)?

Severity is rated for the **Stage-3 target**, not just today: several findings are latent or benign
at Stage 2 and become load-bearing the moment the proxy owns the seek trigger.

## Headline

**Stage 3 is the right direction and it cleanly retires an entire family of player-side bugs**
(echo guard, debounce, `handleSeekJump`, lossy `player.currentTime()`, `timeJumpedNotification`
wiring — all deleted; chapter/skip/deep-scrub become correct-by-construction). See *What Stage 3
fixes* below.

**But Stage 3 also relocates the hard part into the proxy and amplifies three foundation hazards**
that are currently dormant because the Stage-2 trigger is coarse (one re-prime per *settled* drag,
fired by the player). Once AVKit's autonomous per-segment requests drive the proxy directly, the
cadence is finer and the hold-open is longer (~7 s poll), and these become real:

- **Critical:** content-encoding handling defeats stub detection (finding A).
- **High ×5:** rewrite-on-non-200 / Content-Range (B), stop-ordering race (C), orphaned handler
  tasks (D), budget granularity (E), mid-body truncation (F).
- **Medium ×2:** HEAD Content-Length (G), unbounded head read (H).

**Recommendation: harden A–F as prerequisites *before* (or in the same plan as, ahead of) the
segment-re-prime work.** They are cheap relative to the bug they prevent, and each is independently
testable at the PMSKit unit level. G and H are good-hygiene follow-ups that can land alongside.

---

## Lens 1 — HTTP / proxy-correctness

### A. Content-Encoding handling defeats stub detection — **Critical (for Stage 3)**

`MediaSessionProxy.serve` forwards the client's `Accept-Encoding` to upstream
(`MediaSessionProxy.swift:298`) and then unconditionally drops the response's `content-encoding`
header (`MediaSessionProxy.swift:308`) while forwarding the body unchanged.

The trap is `URLSession`'s transparent-decompression rule: it auto-inflates a response **only when
it added the `Accept-Encoding` header itself**. Here we set that header explicitly (relaying
AVKit's), so `URLSession` hands us the **still-compressed** bytes *and* the `Content-Encoding: gzip`
header — which we then strip. AVKit therefore receives gzipped bytes labeled as identity → garbage.

- **Stage 2 today:** mostly latent — PMS may not compress `.ts`/playlists, and AVKit may not request
  encoding for HLS, so it has not bitten. But it is a correctness landmine.
- **Stage 3:** **fatal.** `isRealMedia` classifies a segment by looking for the MPEG-TS sync byte
  `0x47` and a video PES. A gzipped real segment has neither → misclassified as a stub → a needless
  re-prime on *every* segment → permanent re-prime storm. Stub detection cannot work over a
  compressed body.

**Fix:** stop relaying the client's `Accept-Encoding`. Either send `Accept-Encoding: identity`
upstream (PMS returns raw bytes; cleanest for a body-inspecting proxy), or send nothing and let
`URLSession` auto-decode + strip the header itself. Do **not** forward an arbitrary client encoding
and then strip the response header. Add a unit test: upstream returns `Content-Encoding: gzip` →
proxy must deliver a body AVKit can read as identity (or must have requested identity upstream).

### B. PlaylistRewriter runs on non-200; Content-Range can desync — **High**

`serve` calls `rewriter?.rewrite(data, contentType:)` unconditionally
(`MediaSessionProxy.swift:304`), regardless of status code, and the header copy preserves
`Content-Range`/`Accept-Ranges` (`MediaSessionProxy.swift:306-314`). `HTTPResponse.serialized()`
recomputes `Content-Length` from `body.count` (`HTTPMessage.swift:71`).

Two problems:

1. **Rewrite on a 206.** If a playlist (or any sniffed `#EXTM3U` body) ever comes back as a
   `206 Partial Content` and `PlaylistRewriter` finds an absolute upstream URL to swap, the body
   length changes. We then emit a recomputed `Content-Length` alongside the **forwarded, now-stale**
   `Content-Range` — a self-contradictory 206 that AVKit may reject or mis-range.
2. **Rewrite on an error.** On 404/416/500 the body is not media and rewriting it is meaningless
   work; harmless today (sniff fails) but it signals the missing gate.

The rewrite is normally a no-op (PMS emits relative URIs, so the upstream string is absent), which
is why this hasn't bitten — but the gate is missing, not the hazard.

**Fix:** only run `PlaylistRewriter` on `status == 200` **and** a playlist content-type. If a rewrite
changes body length on a response carrying `Content-Range`, strip `Content-Range`/`Accept-Ranges`
(the response is no longer a faithful byte-range). Test: a 206 body that rewrites must not ship a
mismatched `Content-Range`.

### F. Mid-body truncation is forwarded as a short-but-valid response — **High**

`SessionBox.fetch` returns `(Data, HTTPURLResponse)` and `serve` re-derives `Content-Length` from
`body.count`. If upstream declares `Content-Length: N` but the connection delivers fewer bytes
before a *clean* EOF, `URLSession`'s buffered `data(for:)` may hand back a short `Data` without
throwing. We then forward it with a freshly-computed (short) `Content-Length` — internally
consistent, so AVKit accepts a **truncated segment** as complete → decode corruption / silent
playback glitches.

- **Stage 3:** also poisons stub detection — a truncated real segment can fall under
  `STUB_MAX_BYTES` and trip a needless re-prime, or a truncated stub-region read can be misread.

**Fix:** when the upstream response carries a `Content-Length`, compare it to `data.count`; on a
short read, treat it as a wedge (rotate+retry via `UpstreamConnection`) rather than forwarding the
truncation. Test: upstream declares 3 MB, delivers 1 MB then EOF → proxy retries / errors, never
forwards 1 MB as a 200 with `Content-Length: 1 MB`.

### G. HEAD returns Content-Length: 0 — **Medium**

`serve` forwards the method verbatim (`MediaSessionProxy.swift:296`), so a client `HEAD` goes
upstream as `HEAD` and returns an empty body. `serialized()` then writes
`Content-Length: body.count` = **0** (`HTTPMessage.swift:71`), discarding the upstream
`Content-Length` (dropped at `MediaSessionProxy.swift:308`). An AVKit HEAD probe that asks "how big
is this segment / do you support ranges?" gets `Content-Length: 0` → range planning breaks.

**Fix:** for a HEAD (more precisely: any response with an empty body but an upstream
`Content-Length`), propagate the upstream `Content-Length` instead of `body.count`. Test: HEAD with
upstream `Content-Length: 1234` → proxy emits `Content-Length: 1234`, empty body.

---

## Lens 2 — Lifecycle / concurrency

### C. stopPreviousTranscode is time-bounded, not ordered — **High (worsened by Stage 3 cadence)**

`reprimeOnce` awaits `stopPreviousTranscode(request)` *before* issuing the new `start.m3u8`
(`MediaSessionProxy.swift:242-243`). But `stopPreviousTranscode` races the stop against a 2 s
timeout via `withTaskGroup`, takes whichever finishes first, then `cancelAll()`
(`MediaSessionProxy.swift:261-266`). On the timeout branch, the stop's child task is cancelled — but
the underlying `URLSession` request may already be in flight to PMS. Since the stop targets the
**same `sessionID`** the new start reuses, a late-landing stop can kill the *replacement*
transcode.

- **Stage 2:** rare — re-primes are one-per-settled-drag, seconds apart.
- **Stage 3:** the re-prime cadence is segment-driven and can fire deep seeks back-to-back; the
  window for a stale stop to clobber a fresh start widens. This is the kind of race that produces
  "it worked the first three times" flakiness.

**Fix:** make stop/start reliably ordered or the stop idempotent w.r.t. session replacement —
e.g. tag the stop with the generation it intends to kill and have PMS-side logic (or proxy-side
guard) ignore a stop whose target generation is already superseded; or fence the new start until
the stop genuinely completes (with the 2 s cap surfacing as a deferred re-prime, not a fire-and-
forget). At minimum, document and test the ordering guarantee.

### D. Loopback handler tasks are untracked and outlive teardown — **High (worsened by ~7s poll)**

`LoopbackOrigin.handle` spawns a detached `Task { await handler(head); conn.send(...) }`
(`LoopbackOrigin.swift:65-71`) that is never retained. `stop()` cancels the **listener**
(`LoopbackOrigin.swift:54-59`) but in-flight handler tasks keep running to completion.

- **Stage 2:** a handler returns quickly (one upstream fetch), so an orphan is short-lived.
- **Stage 3:** a handler can block ~7 s inside `pollUntilReal`, and can itself **trigger a
  re-prime**. On teardown / re-open, orphaned handlers keep hammering upstream and can re-prime a
  session the proxy believes is gone — exactly the fork-bomb shape #33 exists to kill.

**Fix:** track per-connection handler tasks (a set, guarded), and cancel them all in `stop()`. The
Stage-3 poll loop must observe cancellation and bail. Test: open → start a slow handler → stop →
assert the handler task is cancelled and issues no further upstream work.

### H. readHead has no read timeout — **Medium**

`LoopbackOrigin.readHead` recurses on `conn.receive` with no deadline
(`LoopbackOrigin.swift:75-91`). A client that connects and sends a partial head (never completing
`\r\n\r\n`) holds the connection and its read callback chain open indefinitely. Loopback-only and
AVKit-driven, so low real-world risk — but it is an unbounded resource hold with no backstop.

**Fix:** add a read deadline (e.g. a few seconds) after which `readHead` delivers `nil` and the
connection is cancelled. Test: a connection that sends a partial head is closed after the deadline.

---

## Lens 3 — Seek / re-prime / budget semantics

### E. SeekRestartBudget is tuned for drag-granularity, not segment-granularity — **High (the headline Stage-3 risk)**

`reprimeBudget = SeekRestartBudget(cooldownSeconds: 2, burstLimit: 5, burstWindowSeconds: 60)`
(`MediaSessionProxy.swift:39`). In Stage 2 the budget counts **one re-prime per settled drag** —
the player debounce guarantees that granularity, so `burstLimit: 5` means "5 user seeks in 60 s
before we escalate to the failure overlay," which is generous.

In Stage 3 the *unit being counted changes*. The trigger is AVKit's stub segment requests. Latest-
wins coalescing (`runReprimeLoop`, `MediaSessionProxy.swift:216-236`) collapses *concurrent* stub
requests within one in-flight re-prime, which protects against a single drag's storm. But it does
**not** collapse *sequential* deep seeks: a user who jumps chapter → chapter → scrubs back, each
landing in a different un-primed region, spends one budget count per jump. A handful of legitimate
deep seeks can now reach `burstLimit` and escalate to the *failure overlay* — turning normal use
into a spurious error.

There is also no **post-settle reset**: once a re-prime succeeds and the user is watching happily,
the burst counter should decay/reset so the next deep seek minutes later isn't counted against a
stale burst.

This is the finding most likely to manifest as a user-visible regression, because it converts
"seek a lot" into "error overlay."

**Fix (the core of the Stage-3 plan's budget task):**
- Re-tune for segment-granularity, and/or **count per user-perceived seek** rather than per
  re-prime — e.g. only the *first* re-prime after a settle counts; re-primes that are part of
  resolving one seek's segment storm do not.
- Add a **post-settle reset**: when a re-prime produces real media and playback resumes, reset (or
  age out) the burst counter so independent later seeks start fresh.
- Keep the escalation as the genuine-storm backstop (a wedged server that can't produce media), not
  a normal-usage tripwire.
- Tests: (1) N sequential legitimate deep seeks spaced past the settle do **not** escalate;
  (2) a true storm (stub never resolves) still escalates; (3) post-settle reset clears the burst.

---

## What Stage 3 fixes (the positive ledger)

The design is worth the hardening because it **deletes**, not patches, the bug family that has
cost the most live-debugging time:

- **Lossy `player.currentTime()` on deep backward seeks** — the root cause of "scrubbed backward,
  went forward." AVKit pins `currentTime()` to the playable position when the target is a stub; the
  segment request does not lie about the target. Moving the trigger to the segment path removes the
  lossy signal entirely.
- **The echo guard** (`lastProxySeekTargetMs` / `proxySeekEchoEpsilonMs`) — no player-side trigger,
  no echo to suppress.
- **The debounce** (`pendingReprimeTargetMs`, `reprimeDebounce`, `scheduleReprime`,
  `cancelPendingReprime`) — coalescing now lives in the proxy where the requests actually are.
- **`handleSeekJump` + `timeJumpedNotification` wiring** — retired.
- **Chapter taps / skip / resume** — become ordinary native `seek(to:)` calls that AVKit turns into
  a segment request the proxy intercepts; correct by construction, no special-casing.
- **Fork-bomb driver (b)** from DEVELOPMENT.md — AVPlayer's autonomous scrub segment storm is
  collapsed at the proxy's single chokepoint instead of hitting PMS raw.

The PTS-continuity gate (verified live: absolute PTS → no-reload splice) is what makes this
deletion possible without a playlist reload or `EXT-X-DISCONTINUITY`. That was the one
architectural unknown and it resolved in the design's favor.

---

## Prioritized remediation (prerequisite hardening for the Stage-3 plan)

| # | Finding | Severity | Must precede segment re-prime? |
|---|---------|----------|--------------------------------|
| A | Content-Encoding defeats stub detection | **Critical** | **Yes** — stub detection cannot work until fixed |
| E | Budget granularity / post-settle reset | **High** | **Yes** — normal use would escalate to error overlay |
| C | stopPreviousTranscode ordering | **High** | **Yes** — per-segment cadence widens the race |
| D | Orphaned handler tasks on teardown | **High** | **Yes** — ~7 s poll + re-prime makes orphans dangerous |
| F | Mid-body truncation | **High** | **Yes** — poisons both playback and stub detection |
| B | Rewrite-on-non-200 / Content-Range | **High** | Alongside — gate before adding the segment path |
| G | HEAD Content-Length | **Medium** | Alongside / follow-up |
| H | readHead timeout | **Medium** | Follow-up |

Each item is unit-testable in PMSKit against an injected upstream fake, with no live server — so
the hardening can land TDD-first ahead of the segment dispatch work, and each becomes its own
small, revertable commit to `main`.

## Non-findings (checked, deliberately fine)

- **`UpstreamURLMapper` string concatenation** (`UpstreamURLMapper.swift:14-19`) — intentional, to
  preserve AVKit's exact percent-encoding (re-encoding corrupts the `X-Plex` token/query). Correct.
- **One-request-per-connection / `Connection: close`** (`HTTPMessage.swift:50-51`,
  `LoopbackOrigin.swift:6-7`) — correct for HLS; keep-alive is a deferred refinement, not a
  correctness gap.
- **`reprimeTask = nil` set atomically with the guard / throw** (`MediaSessionProxy.swift:219-234`)
  — the no-await-between reasoning holds on the actor; a late `seek` can't strand a target on a dead
  task. Sound.
- **`X-Plex-Client-Profile-Name=Safari`** — untouched by the proxy; must stay (an unknown profile
  makes PMS return a bare 400). No change proposed.
