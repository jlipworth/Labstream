# Media Optimizer / Offline Download Redesign — Design

**Date:** 2026-06-14
**Status:** Approved design. Direct-download path is fully specified and unit-testable now.
The Media Optimizer path is rewritten to the best-known contract and is **gated on a live
discovery probe (Phase 0)** before it can be trusted.

---

## 1. Problem

Offline downloads currently use a single **progressive transcode**:
`TranscodeRequest.downloadURL()` requests `/video/:/transcode/universal/start` with
`protocol=http` + `download=1`, and `DownloadManager.optimizeAndDownload(_:quality:)`
fetches that body with one background `URLSession.downloadTask`.

On the live server this is unreliable:

- It returns **HTTP 400** intermittently.
- When it *does* start it **truncates partway** (e.g. dies at ~40% with a clean 200 EOF),
  leaving an MP4 with **no `moov` atom** → AVFoundation `load(.isPlayable)` is `false`,
  and the existing D1 playability probe correctly rejects it as `.invalidDownload`.

**Root cause:** one long progressive pull gives PMS no keep-alive signal, so the transcode
session is reaped/ended early. Streaming works because continuous HLS segment requests keep
the session alive; a single progressive `downloadTask` does not. A **static file** download
(the original file, or a fully-rendered optimized file) has none of these problems and carries
a real `Content-Length`.

## 2. Approved solution — a probe-driven dual path

Mirror how the native Plex client downloads. Decide at download time which of two paths to
take, and converge both on a **static file with a real `Content-Length`**:

- **Path A — Direct download:** when the client can already play the *whole* original file
  as-is, download the original `Part.key` (`<server><partKey>?download=1&X-Plex-Token=…`).
- **Path B — Media Optimizer:** when a transcode is genuinely required, ask PMS to render a
  compatible MP4 server-side (the real optimize/background-processing flow), poll for the
  rendered Part, and download *that* static part.

Both paths reuse the existing, verified download machinery from the optimized-part fetch:
`OptimizeRequest.downloadURL(server:token:partKey:)` → background `URLSession` → atomic
move → MIME/size/`AVURLAsset.isPlayable` validation → `DownloadStore`.

### 2.1 Decision rule (reuses the player's own capability decision)

At download time, run the **direct-play probe** against
`/video/:/transcode/universal/decision` using the existing
`TranscodeRequest.directPlayProbeRequest()`.

- If PMS says the **whole file direct-plays** under our `Safari` profile → **Path A**
  (download the original `Part.key`).
- Anything else (direct-stream/remux = copy video + transcode audio, or full transcode)
  → **Path B** (optimizer).

"Whole file direct-plays" must be **stricter** than the existing
`DecisionResponse.savesVideoEncode`. `savesVideoEncode` is intentionally true for
direct-stream (copy video / transcode audio) because the player only cares about avoiding
the expensive *video* re-encode (issue #7). For downloads we want a **single static original
file**, which is only valid when the entire file — container, video, AND audio — plays as-is.

A new computed property captures this:

```swift
/// True only when PMS will play the WHOLE file as-is (container + every stream),
/// so the original file can be downloaded byte-for-byte. STRICTER than
/// `savesVideoEncode` (which is also true for Direct Stream = copy video / transcode
/// audio). Used for the download decision ONLY — the player keeps using
/// `savesVideoEncode` (issue #7). Structured signals only, never `mdeDecisionText`:
///   1. `mdeDecisionCode == 1000` — MDE says whole-file direct play, OR
///   2. `decision == .directPlay` (generalDecisionCode 1000), OR
///   3. `partDecision` (lowercased, spaces removed) == "directplay".
/// A part/stream "copy" (remux / Direct Stream) is deliberately NOT enough.
var playsWholeFileDirectly: Bool
```

`savesVideoEncode` is **not weakened** — it keeps its three-way OR including part/stream
`copy`. `playsWholeFileDirectly` is a separate, additive property.

### 2.2 The no-cap nuance (critical)

The download-mode probe must advertise **no meaningful bitrate cap** — use the very high
ceiling the code already uses for `.original`: **200_000 kbps** (mirrors
`PlaybackController` and `LiveDecisionProbeTests`). A bitrate cap legitimately *forces* a
transcode verdict for **live streaming** (you cap to fit the link), but **"Download original"
is full quality**: a high-bitrate-but-codec-compatible file must still qualify for Path A. A
cap must **never** push the download decision toward transcode.

So the probe built for the download decision uses `maxVideoBitrateKbps: 200_000`,
independent of any streaming cap.

## 3. Path A — Direct download (fully implementable now)

No live discovery needed; the original-file download is a static GET that always carries a
real `Content-Length` and a valid `moov` atom.

- **URL:** reuse `OptimizeRequest.downloadURL(server:token:partKey:)` with the **original**
  `Part.key`. It already builds `<server><partKey>?download=1&X-Plex-Token=<token>` for any
  part key. No change to that builder.
- **Why it's reliable:** a static file on disk → real progress %, ETA, speed from
  `totalBytesExpectedToWrite`; valid container → passes the existing playability probe.
- **Size + resolution for the UI label** come from `Part.size` and `Media.width`/`Media.height`
  already on the `MediaItem` (the probe's chosen `mediaIndex`/`partIndex`). No extra fetch.
- **Expected bytes** for the storage pre-flight + progress bar = `Part.size` (real, exact).

## 4. Path B — Media Optimizer (rewrite to real contract; live-verify later)

The current `triggerOptimize` uses a best-effort flat `PUT /library/optimize`. The **real**
Plex optimize posts to `{backgroundProcessing.key}/items`, where:

- `backgroundProcessing.key` is fetched at runtime from `GET /playlists?type=42` (the
  background-processing playlist), and
- `targetTagID` is a **server-specific** id resolved from the server's
  `mediaProcessingTarget` tag list — **NOT** the conventional `2`/`1`/`3` hardcoded in
  `OptimizeRequest.Target`.

### 4.1 What we build now (PMSKit request builders)

Add pure, tested builders to `OptimizeRequest`:

- `backgroundProcessingRequest(server:token:identity:)` →
  `GET /playlists?type=42` (Accept JSON). Response gives the background-processing
  playlist `key` (e.g. `/playlists/<id>/items`).
- `mediaProcessingTargetsRequest(server:token:identity:)` →
  `GET /media/processing/targets` (Accept JSON). Best-known endpoint exposing the server's
  optimize targets (name + `targetTagID`). **Flagged server-specific** — the exact path and
  field names are what Phase 0 confirms.
- `createOnPlaylist(server:token:identity:backgroundProcessingKey:ratingKey:title:targetTagID:mediaSettings:)`
  → `POST {backgroundProcessingKey}` (or `…/items`) carrying the nested `Item[...]` grammar
  (`Item[type]=42`, `Item[title]`, `Item[target]`, `Item[targetTagID]`,
  `Item[Location][uri]`, `Item[MediaSettings][...]`). `targetTagID` comes from the resolved
  server target, not a hardcoded enum.
- Decodable response models for the two GETs (`BackgroundProcessingPlaylist`,
  `MediaProcessingTargets`), lenient/optional per house style.

The legacy `create(...)` flat-PUT builder is **retired** from the live path; it may remain
only if a test still references it, but the manager no longer calls it.

### 4.2 What stays the same

- `pollForOptimizedPart` — diffs part IDs against the original set to find the rendered
  output, then downloads it via `OptimizeRequest.downloadURL(partKey:)`. **Kept.**
- `statusRequest` (item metadata GET) — **kept** as the poll source.

### 4.3 Isolation + honesty

The entire optimizer path lives behind the single `triggerOptimize` seam in
`DownloadManager`. The runtime steps (fetch key → resolve target → POST to playlist) are
implemented to the best-known contract but **clearly flagged `// TODO(live, Phase 0)`** as
needing live confirmation. A failure is recorded as `.optimizeFailed`; the caller still polls
metadata so an out-of-band optimized part is still picked up.

## 5. Download sheet behavior (`DownloadOptionsSheet`)

Probe-first, with a sensible fallback:

1. On appear, run the direct-play probe (download-mode, 200_000 kbps cap) for the chosen
   `mediaIndex`/`partIndex`.
2. **If direct-playable** → offer a single action:
   **"Download original — `<size>` · `<res>`"** (no quality picker). `<size>` from
   `Part.size` via `ByteCountFormatter`; `<res>` from `Media.width`/`height` (e.g. "1080p",
   "4K", or "1920×1080" fallback).
3. **If not direct-playable** → present the **server's real optimize presets** (discovered
   names + `targetTagID`s), per the product decision "expose the server's real presets" —
   not the synthetic 480/720/1080 enum.
4. **Probe failure / server unreachable at sheet time** → **fall back to offering the
   optimizer presets** (sensible default; the optimizer can transcode anything). The UI
   notes that the probe was skipped.

While the probe is in flight the sheet shows a brief "Checking…" state. The existing
already-downloaded / downloading / failed states are unchanged.

The optimizer-presets list is sourced from the server when reachable
(`mediaProcessingTargetsRequest`). Until Phase 0 confirms that endpoint, the sheet falls back
to a small built-in preset list (the existing target names) so the UI is never empty; this
fallback is flagged as provisional.

## 6. What is retired

- **`TranscodeRequest.downloadURL()`** (the `protocol=http` progressive path, ~line 212) —
  no longer used to fetch media. Removed, along with its tests.
- **`DownloadManager.optimizeAndDownload(_:quality:mediaIndex:partIndex:)`** — replaced by
  the probe-driven `download(_:choice:mediaIndex:partIndex:)` entry point.
- **`DownloadManager.estimatedTranscodeBytes`** — both paths have a real `Content-Length`
  (Path A from the original file, Path B from the rendered part's `size`), so progress no
  longer needs estimation. Removed; `OfflineLibraryView.displayProgress` simplifies to the
  server-reported `record.progress` only.
- **`DownloadQuality` cap logic** folds into the two real choices. The enum's *labels* are no
  longer needed for download selection; the offline UI shows resolution/size from the snapshot
  instead. The `DownloadQuality` type and its `metadata.quality` field are removed (the
  offline metadata gains a `resolutionLabel` for the caption instead), OR the enum is retained
  only as a frozen label helper if removing it churns too much — the plan picks the minimal
  change. **Decision:** remove the cap-based selection; replace the persisted `quality` marker
  with a `resolutionLabel` string captured from the chosen `Media`.

### 6.1 What is KEPT (orthogonal jitter fixes — do not regress)

- The **speed-smoothing EMA** in `refreshRecords()` (the `0.5 * prev + 0.5 * instant`
  bytes/sec smoothing and ≥0.5s resample gate).
- The **`.monospacedDigit()`** on the progress captions (prevents width jitter).
- The 400-body diagnostic logging in `BackgroundDownloadSession` (HTTP status + MIME on
  finish), and the sanitized path-only logging (never the token/full URL).

> Merge note: the EMA, `.monospacedDigit()`, and 400-body logging are part of the
> uncommitted **wave1** download fixes that are NOT in this worktree's base commit. See §10.

## 7. Phase 0 — live discovery (WRITE IT, DO NOT RUN IT)

The optimizer rewrite's server-specific bits (background-processing key, real target tag IDs,
the POST grammar PMS accepts, how the finished part appears) cannot be reached from this
environment. Phase 0 is an **instrumented, log-only discovery probe** — a gated PMSKit
integration test the **USER runs live later**, following the `headless-pmskit-probe` skill.

It logs (at `print` `>>> LIVE` lines, mirroring `LiveDecisionProbeTests`; the in-app
optimizer logging uses os.log `.error` so it persists — `.info` is memory-only and evicted):

1. `backgroundProcessing.key` from `GET /playlists?type=42`.
2. The server's real `mediaProcessingTarget` tag IDs + names.
3. The result (status + body) of `POST` to `{backgroundProcessing.key}` /`…/items` with the
   `Item[...]` grammar.
4. How the finished optimized Part appears on the item metadata (a new `Media`/`Part`).
5. Confirmation that `?download=1` on a static part returns a real `Content-Length`
   (an `HTTP HEAD`/ranged GET, status + `Content-Length`).

It is **opt-in** (env-gated, no-op without `PLEX_LIVE_*`), so plain `swift test` and CI stay
hermetic and no secret is committed. The plan's Task 1 writes it; the user runs it via a new
`scripts/live-optimize-probe.sh` and reads back the `>>> LIVE` lines.

## 8. Architecture summary

```
DownloadOptionsSheet.onAppear
   └─ probe: TranscodeRequest(maxKbps=200_000).directPlayProbeRequest()  ──► /decision
        ├─ playsWholeFileDirectly == true  ──► offer "Download original — <size> · <res>"
        │      └─ DownloadManager.download(item, choice: .original, mediaIndex, partIndex)
        │            └─ OptimizeRequest.downloadURL(partKey: originalPart.key)  [STATIC GET]
        │                  └─ BackgroundDownloadSession.start(expectedBytes: Part.size)
        └─ else / probe failed  ──► offer server optimize presets
               └─ DownloadManager.download(item, choice: .optimize(target), …)
                     └─ triggerOptimize  [Phase-0-gated contract, isolated]
                           ├─ GET /playlists?type=42  → backgroundProcessing.key
                           ├─ resolve targetTagID from server targets
                           ├─ POST {key}/items  (Item[...] grammar)
                           └─ pollForOptimizedPart → OptimizeRequest.downloadURL(renderedPart.key)
                                 └─ BackgroundDownloadSession.start(expectedBytes: renderedPart.size)
```

Both branches end at the same `BackgroundDownloadSession.start(...)` + validation pipeline.

## 9. Testing strategy

- **PMSKit (Swift Testing, hermetic):**
  - `playsWholeFileDirectly`: direct-play (mde 1000 / part "directplay" / general 1000) →
    true; Direct Stream (video "copy", audio "transcode") → **false**; full transcode →
    false; `savesVideoEncode` unchanged on the same fixtures (regression guard).
  - `OptimizeRequest.backgroundProcessingRequest` / `mediaProcessingTargetsRequest`: path,
    method, JSON Accept header, token.
  - `OptimizeRequest.createOnPlaylist`: POSTs to the given key, carries `Item[...]` grammar,
    uses the *passed* `targetTagID` (not a hardcoded enum), identity + token.
  - Decoders for the two GET responses against captured/synthetic JSON.
  - `OptimizeRequest.downloadURL` reused for the original part (existing tests still pass).
- **App:** compile-only via `xcodebuild` (no simulator — wave1 live tests are running). The
  download-routing decision logic is factored into a pure helper where unit-testable.
- **Live (Phase 0, user-run):** the gated optimize discovery probe; not part of CI.

## 10. Status & honesty

- **Path A (direct download):** verifiable now via unit tests + app compile. Honest status:
  *implemented and unit-tested; end-to-end live behavior is high-confidence because it is a
  plain static GET, but not yet exercised on-device in this work.*
- **Path B (optimizer):** rewritten to the best-known contract, isolated behind
  `triggerOptimize`, flagged `// TODO(live, Phase 0)`. Honest status: **NOT live-verified.**
  The server-specific key/targetTagID/POST grammar are confirmed only after the user runs
  Phase 0.
- **Merge reconciliation:** the speed EMA, `.monospacedDigit()` captions, and 400-body
  logging are wave1 download fixes not present in this worktree's base commit. This redesign
  preserves their intent; on merge, keep both (they are orthogonal to the path rewrite).
