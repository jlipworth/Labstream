# Plex Client Library / SDK Catalog — Transcode/Streaming Reference Survey

**Date:** June 2026
**Purpose:** Catalog every notable Plex client library/SDK across languages to identify the best reference implementation(s) for porting **transcode-decision + streaming URL building** logic into a hand-rolled Swift visionOS client. The Swift generated SDK (`plexswift`) is archived and insufficient for transcoding, so we need a behavioral reference for the universal transcoder request flow.

---

## TL;DR — Best References for Transcode/Streaming

1. **`plexinc/plex-for-kodi` (maintained fork: `pannal/plex-for-kodi`)** — its bundled `plexnet` library (`plexplayer.py`, `plexstream.py`, `plexserver.py`) is **Plex's own first-party client code**. It builds the *full* universal transcode request including the two-phase **decision → start** flow, direct-play/direct-stream/transcode selection, subtitle burn vs. soft, audio codec profile extras, and MKV-vs-HLS protocol negotiation. This is the single most accurate, real-world reference. **Caveat: GPL-2.0.** Use as a behavioral spec to re-implement, not copy verbatim, given license + Swift relicensing concerns.
2. **`pkkid/python-plexapi`** — the "gold standard" behavioral library. `getStreamURL()` (in `plexapi/base.py`, `Playable` mixin) cleanly shows the canonical query-param set and endpoint paths. **BSD-3-Clause** — friendliest license for porting. Less complete than plex-for-kodi (no decision-endpoint round trip) but far easier to read and legally safe.

The LukeHagar Speakeasy SDKs are **not a safe v1 foundation**. Some generated SDKs expose low-level operations (`startUniversalTranscode`, `makeDecision`, `startTranscodeSession`), but `plexswift` is archived/older and lacks the HLS/bitrate coverage this app needs. None provide a high-level helper that assembles the correct bitrate/resolution/profile params for you. Use the official portal plus reference clients, then hand-roll the small Swift REST layer.

---

## Comparison Table

| Library | Lang | Repo | Maintained? (last commit / stars / open issues) | License | Auth | Discovery | Browse | **Transcode-decision & streaming** | Sync/Download | PlayQueues | WS/Notifications | Transcode-reference quality |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **python-plexapi** | Python | [pkkid/python-plexapi](https://github.com/pkkid/python-plexapi) | **Active** — Mar 2026 / 1.3k★ / 51 | **BSD-3** | ✅ | ✅ | ✅ | ✅ `getStreamURL()` builds universal start URL; `TranscodeSession` tracking | ✅ `Sync`/`download()` | ✅ | ✅ (alert listener) | **Very good** — clean, readable, the canonical param set. No decision round-trip. |
| **plex-for-kodi** (`plexnet`) | Python | [plexinc/plex-for-kodi](https://github.com/plexinc/plex-for-kodi) · maintained fork [pannal/plex-for-kodi](https://github.com/pannal/plex-for-kodi) | upstream **dormant** (last release 2018); **fork ACTIVE** — Mar 2026 / 440★ / 22 | **GPL-2.0** | ✅ | ✅ | ✅ | ✅✅ **Full decision→start flow**, direct-play/stream/transcode logic, subtitle burn/soft, audio profile extras, MKV/HLS | ✅ | ✅ | ✅ | **Best (first-party real client).** License = GPL, re-implement not copy. |
| **plex-mpv-shim** | Python | [iwalton3/plex-mpv-shim](https://github.com/iwalton3/plex-mpv-shim) | mostly active (1.10.x) | MIT | ✅ | ✅ | ✅ | ✅ `media.py` `get_playback_url()`, `is_transcode_suggested()`, server decision codes 1000/1001 | partial | ✅ | ✅ | **Good** — compact, MIT, shows decision codes + LAN/WAN logic. |
| **@ctrl/plex** (scttcper) | TS | [scttcper/plex](https://github.com/scttcper/plex) | **Active** — 2026 / 32★ / 3 | MIT | ✅ | ✅ | ✅ search/playlists | ❌ no stream-URL / transcode | ❌ | partial | ❌ | Poor for transcode (port of python-plexapi but omits streaming). |
| **plexjs** (LukeHagar) | TS | [lukehagar/plexjs](https://github.com/lukehagar/plexjs) | Active — Dec 2025 / 51★ / 11 | MIT | ✅ | ✅ | ✅ | ⚠️ generated ops only: `startTranscodeSession`, `makeDecision`, `transcodeImage/Subtitles` — **no param-assembly helper** | DownloadQueue ops | ✅ | Events | Low — same Speakeasy limit as plexswift. |
| **plexgo** (LukeHagar) | Go | [lukehagar/plexgo](https://github.com/LukeHagar/plexgo) | Active — May 2026 / 35★ / 4 | MIT | ✅ | ✅ | ✅ | ⚠️ `StartTranscodeSession`, `MakeDecision`, `TriggerFallback`, `TranscodeSubtitles/Image` — low-level only | partial | ✅ | ✅ | Low — generated, no decision logic. |
| **plexpy / plexruby / plexphp / plexcsharp / plexjava** (LukeHagar) | Py/Rb/PHP/C#/Java | [lukehagar](https://github.com/lukehagar) | Active (same monorepo cadence) | MIT | ✅ | ✅ | ✅ | ⚠️ identical generated Transcoder group across all langs | partial | ✅ | ✅ | Low — **same generator = same limit as plexswift.** |
| **plexswift** (LukeHagar) | Swift | [lukehagar/plexswift](https://github.com/LukeHagar/plexswift) | **ARCHIVED** Mar 2026 / 15★ | MIT | ✅ | ✅ | ✅ | ⚠️ `startUniversalTranscode`, `getTranscodeSessions`, `stopTranscodeSession` — DASH-oriented, no bitrate param surface / no decision helper | — | ✅ | ✅ | **Insufficient** (the reason for this survey). |
| **go-plex-client** (jrudio) | Go | [jrudio/go-plex-client](https://github.com/jrudio/go-plex-client) | minimally maintained / 138★ / 11 | Apache-2.0 | ✅ | ✅ | ✅ | ❌ only `GetTranscodeSessions` / `KillTranscodeSession` (monitor, not build) | ❌ | partial | ✅ webhooks | Poor — does not build the start URL. |
| **bdowden/ts-plexapi** | TS | [bdowden/ts-plexapi](https://github.com/bdowden/ts-plexapi) | low activity | MIT | ✅ | ✅ | ✅ | ❌ minimal | ❌ | ❌ | ❌ | Poor. |

---

## Deep Dive: How the Transcode/Stream URL Is Built

### python-plexapi — `getStreamURL()` (`plexapi/base.py`, `Playable` mixin)
- **Endpoints:**
  - Video HLS: `/video/:/transcode/universal/start.m3u8`
  - Video DASH: `/video/:/transcode/universal/start.mpd`
  - Audio: `/audio/:/transcode/universal/start.m3u8`
  - `ext = 'mpd' if protocol == 'dash' else 'm3u8'`; `streamtype = 'audio'` for track/album else `'video'`.
- **Params accepted:** `maxVideoBitrate`, `videoResolution` (validated `^\d+x\d+$`), `protocol`, `mediaIndex` (0), `fastSeek` (1), `copyts` (1), `offset` (0), `platform` ('Chrome'). `None` values filtered, then URL-encoded.
- **Session tracking:** `plexapi.media.TranscodeSession`; `PlexServer.transcodeSessions()` lists active sessions. `Video.transcodeSession` is populated when an item is transcoding.
- **Note:** This is a single-shot URL builder — it does **not** make the `/decision` round-trip; it trusts your params. Good for the *param vocabulary*, simpler than a full client's negotiation.

### plex-for-kodi `plexnet` — `plexplayer.py` (first-party, most complete)
- **Two-phase flow:** builds metadata, then calls `getServerDecision()` against **`/video/:/transcode/universal/decision`** so the server can validate/override the client's chosen mode before requesting the start URL.
- **Start endpoints (protocol-negotiated):**
  - `/video/:/transcode/universal/start.mkv` when `server.supportsFeature("mkvTranscode")`
  - else `/video/:/transcode/universal/start.m3u8` (HLS)
- **Decision logic:** picks **direct play → direct stream → transcode**. `directPlay = directPlay or self.choice.isDirectPlayable`; forced transcode or a disabled-direct-play setting flips to transcode.
- **Param set:** `protocol`, `directPlay`, `directStream`, `videoQuality`, `videoResolution`, `maxVideoBitrate`, `session`, `path`, `partIndex`, `mediaIndex`, `offset` (capped to avoid transcoder seek bugs), `subtitles=burn` (+ `subtitleSize`) vs. soft-subs decision, and audio passthrough via **`X-Plex-Client-Profile-Extra`** (append AC3/EAC3/DTS support).
- This mirrors what Plex's own apps send on the wire — the highest-fidelity reference.

### plex-mpv-shim — `media.py`
- `is_transcode_suggested()`: forces transcode on `always_transcode`/`force_transcode`, or when remote file bitrate exceeds `transcode_kbps`; otherwise relies on the **server decision** returning **`1000` (direct play OK)** vs **`1001` (transcode needed)**.
- `get_playback_url()` → `/video/:/transcode/universal/start.m3u8`, params via `get_plex_url()`: `protocol=hls`, `directPlay`, `directStream`, `mediaIndex`/`partIndex`, `maxVideoBitrate`, `location=lan|wan`, `subtitles`, `X-Plex-Client-Profile-Extra`, `X-Plex-Client-Capabilities`, `session`. A concise, MIT-licensed middle ground.

### LukeHagar Speakeasy SDKs (plexswift/plexjs/plexgo/plexpy/plexruby/plexphp/plexcsharp/plexjava)
- All generated from the **same OpenAPI spec via Speakeasy**, but outputs are not equally current or equally useful. The newer/generated operation surface may include `startTranscodeSession` / `startUniversalTranscode`, `makeDecision`, `transcodeImage`, `transcodeSubtitles`, `triggerFallback`, `getTranscodeSessions`, `stopTranscodeSession`; the archived Swift output remains insufficient for this app's HLS/bitrate path.
- **Limitation (confirms the premise):** these are thin typed wrappers over endpoints. There is **no high-level helper** that computes the correct `maxVideoBitrate`/`videoResolution`/profile-extra/direct-play decision for you. plexswift's surface is DASH-leaning and lacks the rich bitrate ergonomics. The non-Swift siblings are **not** more capable for transcode — same generator, same gap. Useful only as a typed model of request/response shapes (handy to cross-check field names), not as transcode logic.

---

## Recommendation for the Swift visionOS Client

- **Primary behavioral spec:** `pannal/plex-for-kodi` → `lib/_included_packages/plexnet/plexplayer.py` (+ `plexstream.py`, `plexserver.py`). Re-implement the **decision→start** flow and param assembly. Treat as spec only (GPL-2.0).
- **License-safe canonical reference to port directly:** `pkkid/python-plexapi` `getStreamURL()` (BSD-3) for the clean param vocabulary, plus `media/TranscodeSession` for session tracking.
- **Tie-breaker / compact cross-check:** `iwalton3/plex-mpv-shim` `media.py` (MIT) for the decision-code (1000/1001) handling and LAN/WAN bitrate gating.
- **For typed request/response field names only:** keep `plexjs` or the Plex OpenAPI spec open as a schema sanity-check; do **not** expect transcode logic from any LukeHagar SDK.

---

### Sources
- https://github.com/pkkid/python-plexapi · https://python-plexapi.readthedocs.io/en/latest/modules/base.html
- https://github.com/plexinc/plex-for-kodi · https://github.com/plexinc/plex-for-kodi/blob/master/lib/_included_packages/plexnet/plexplayer.py
- https://github.com/pannal/plex-for-kodi
- https://github.com/iwalton3/plex-mpv-shim · https://github.com/iwalton3/plex-mpv-shim/blob/master/plex_mpv_shim/media.py
- https://github.com/scttcper/plex · https://www.npmjs.com/package/@ctrl/plex
- https://github.com/lukehagar/plexjs · https://github.com/LukeHagar/plexgo · https://github.com/LukeHagar/plexswift · https://github.com/lukehagar
- https://github.com/jrudio/go-plex-client · https://github.com/bdowden/ts-plexapi
