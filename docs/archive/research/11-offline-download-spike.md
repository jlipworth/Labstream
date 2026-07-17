# 11 — Offline Downloads Feasibility Spike (visionOS Plex client)

> **Archived research snapshot:** retained as dated evidence, not current architecture, feature
> status, or implementation guidance. Verify any reusable detail against the active docs and
> current source; old `VisionPlay` names, issue links, branches, and paths below are historical.

**Date:** 2026-06-08
**Question:** Can a third-party visionOS Plex client store a movie **offline at a capped ~8 Mbps bitrate** (not the full 80 GB original)?
**Verdict (short):** **Yes — and the best path is the server-side Media Optimizer ("Optimized for TV – 8 Mbps 1080p"), which runs in the FREE edition.** It produces a normal MP4 you then download with the free `?download=1` fetch. The custom HLS-segment transcode-walker is the fallback if you can't or don't want to write to the server's library. A true one-request capped-transcode "single file" download (`start.mkv`) is **mostly a myth** — see Option 3.

---

## TL;DR comparison

| # | Path | Plex Pass needed? | Capped bitrate? | Difficulty | Reliability | One-file result? |
|---|------|-------------------|-----------------|-----------|-------------|------------------|
| **1a** | **Media Optimizer** (server pre-makes an 8 Mbps MP4, then free `?download=1`) | **No** (free edition; Plex Pass only for *remote* triggering) | **Yes** — built-in "TV – 8 Mbps 1080p" preset or custom | **M** | **High** — it's a real file on disk | **Yes (MP4)** |
| **1b** | Official **Downloads / Sync** API (`sync_items`) | **Yes — on the CLIENT account** (or be a Managed User of a Plex Pass home) | Yes (global download-quality cap) | M–L | High | Yes |
| **2** | **Custom HLS segment downloader** (open universal transcode at 8 Mbps, walk `.ts` segments + keep-alive, remux) | **No** | Yes (`maxVideoBitrate`) | **L–XL** | Medium (session timeouts, live-style playlist, transcode-speed-bound) | Reassembled MP4/MKV |
| **3** | **Single-request `start.mkv` capped download** | No | partially | — | **Low / not reliable** | Claimed, not real for this use |

**Recommendation for this user: Option 1a (Media Optimizer) as primary, Option 2 as fallback.** Details and risk at the bottom.

---

## Option 1 — The Sync / Media Optimizer API (server makes a capped file)

There are **two distinct server-side "pre-transcode" systems**, and the Plex Pass gating differs between them. This is the most important distinction in this whole report.

### 1a. Media Optimizer (`optimize`) — **FREE on the server**

**This is the winner.** Plex's Media Optimizer pre-transcodes an item to a capped bitrate and saves it as an **additional "version" (a second `Media`/`Part`) on the same library item**. The optimized file then downloads with the *free* `Part.key?download=1` fetch you already have working — because it IS the original-file fetch, just pointed at the smaller optimized file.

**Plex Pass gating (confirmed):**
- *Creating optimized versions is fully functional in the free Plex Media Server.* The official "Creating Optimized Versions" article lists only a **server-version** requirement (`0.9.14.3+`), no Plex Pass requirement. (Confidence: high — Plex support article + multiple corroborating sources.)
- Plex Pass is only needed to **trigger** an optimize job **remotely** (from a mobile app while away from home). Triggering it locally / via API on the LAN is free.
- This is gated on the **server admin's** capability, not the client account. Since this is the user's *own* personal server, that's a non-issue.

**Built-in presets (exactly the user's target):**
- **"Optimized for TV – 8 Mbps 1080p"** — video limited to 1080p and **8 Mbps**, audio preserved or transcoded to AAC/AC3, output in **MP4**. This is *literally* the 8 Mbps cap requested.
- "Optimized for Mobile – 4 Mbps 720p"
- "Original Quality" (no cap)
- **Custom** — pick your own resolution + bitrate.

**API endpoints (via python-plexapi `Video.optimize()` / `Section.optimize()`):**
```python
def optimize(self, title='', target='', deviceProfile='', videoQuality=None,
             locationID=-1, limit=None, unwatched=False)

# e.g. Optimize for Android at 10 Mbps 1080p:
from plexapi.sync import VIDEO_QUALITY_10_MBPS_1080p
movie.optimize(target="Android", videoQuality=VIDEO_QUALITY_10_MBPS_1080p)
```
Under the hood it:
1. Fetches the background-processing playlist: `GET /playlists?type=42` (type 42 = the optimize/background-processing playlist).
2. PUTs the new job to `{backgroundProcessing.key}/items` with `MediaSettings` (`videoQuality`, `videoResolution`, `maxVideoBitrate`) derived from the `VIDEO_QUALITY_*` constants in `plexapi.sync`.
   - `MediaSettings.createVideo(videoQuality)` maps quality 0–100 onto predefined bitrate ranges (64–20,000 kbps) and resolutions (up to 1920×1080).

**Status / polling:**
- `Server.conversions()` → list of `Conversion` objects (queued / actively optimizing). Backed by the play-queue (`/playQueues/...`).
- `TranscodeJob` (the active optimize job) is exposed via `/status/sessions/background`.
- `Server.optimizedItems()` → finished `Optimized` objects; items live under `{backgroundProcessing.key}/items`.

**Where the optimized Part.key appears:** after the job completes, re-fetch the item's metadata (`/library/metadata/{id}`). The item now has an **extra `Media` element** (the optimized version) with its own `Part` whose `key` you fetch with `?download=1&X-Plex-Token=...` — the same free download you already have, now pointing at the ~8 Mbps MP4 instead of the 80 GB original.

> ⚠️ Reverse-engineered/uncertain bits: exact JSON shape of the optimized `Media`/`Part` on the metadata response, and the precise `type=42` playlist semantics, are inferred from python-plexapi source + Plex behavior rather than official API docs. Verify against your live server. The *capability* and *free-edition* status are well-established (high confidence).

**Downsides:** consumes disk on the server (a persistent second copy), and the optimize job runs on the server's transcoder (minutes, not instant). For a *personal* server with the user as admin, both are acceptable.

### 1b. Official Downloads / Sync (`sync_items`) — **Plex Pass on the CLIENT**

The polished, app-grade path. This is what the official Plex apps' "Download" button uses.

- Endpoints: `https://plex.tv/devices/{clientId}/sync_items` (create), `/sync/items/{id}` (media), `/sync/{clientIdentifier}/item/{ratingKey}/downloaded` (mark done). python-plexapi exposes `SyncItem`, `SyncList`, `MediaSettings`, `Status`, `Policy`.
- It transcodes for offline use through the **same HLS mechanism** as streaming, with a **global "download quality" bitrate cap** setting.
- **Plex Pass gating (confirmed, decisive):** *"The Downloads feature requires an active Plex Pass subscription on the user account performing the Downloads action."* Managed Users inside a Plex Home of a Plex Pass holder also qualify. The server owner separately must "Allow Downloads." (Confidence: high — Plex "Downloads Overview" support article, last modified 2025-01-09.)
- Account-cutoff nuance: legacy accounts created before **2022-08-01 UTC** may be grandfathered. Don't rely on it.

**Why 1a beats 1b for this user:** 1a needs no Plex Pass at all (user owns the server), and yields a plain MP4 you fetch with the download you already built. 1b requires Plex Pass on the *client* account and re-implementing the sync protocol.

---

## Option 2 — Custom HLS segment downloader (no-Plex-Pass path)

The classic reverse-engineered approach (kmark gist, 2013, and the PastaGringo fork). **This is the only open-source approach that produces a capped-bitrate file without Plex Pass.** All other open-source "Plex downloaders" (codedninja/plexmedia-downloader, danielhoherd/plexdl, badraxas/PlexDL) only grab the **original** file via `Part.key` — confirmed by reading their source; none cap bitrate.

**Flow (verified from the gist source):**
1. Open a universal transcode session at the target bitrate:
   ```
   GET /video/:/transcode/universal/start.m3u8
       ?path=http%3A%2F%2F127.0.0.1%3A32400%2Flibrary%2Fmetadata%2F{id}
       &protocol=hls&offset=0&fastSeek=1&directPlay=0&directStream=1
       &videoQuality={q}&videoResolution={WxH}&maxVideoBitrate={kbps}   ← 8000 for ~8 Mbps
       &subtitleSize=100&audioBoost=100&X-Plex-Platform=Chrome
       &X-Plex-Token=...
   ```
   `maxVideoBitrate` is the cap (in **kbps**).
2. Parse out the `session` id and the index playlist:
   `GET /video/:/transcode/universal/session/{session}/base/index.m3u8`
3. Pull each segment sequentially (MPEG-TS, ~1–8 s each):
   `GET /video/:/transcode/universal/session/{session}/base/{segment}.ts`
4. **Keep the session alive** after every segment:
   `GET /video/:/transcode/segmented/ping?session={session}`
5. Reassemble: `ffmpeg -y -f concat -i pieces.txt -c copy out.mkv` (must start at segment 0 or concat breaks).

**Hard parts (rate honestly: difficulty L → XL):**
- **Transcoder is playback-paced.** Plex only transcodes a little ahead of the "playhead"; you can't pull the whole file at line speed — download wall-clock ≈ a sizeable fraction of the movie's runtime. Big UX cost.
- **Live-style playlist.** The index is generated incrementally; depending on settings it may lack a clean `#EXT-X-ENDLIST` until the session finishes, so you must walk indices and know when you've reached the end.
- **Session timeouts** if you stop pinging or stall.
- **TS → MP4/MKV remux** needed for clean AVPlayer offline playback (or generate a local VOD playlist).
- **On visionOS** you'd reimplement all of this in Swift (URLSession + a ffmpeg/`VideoToolbox` remux, or `mp4box`-style muxing). No AVAssetDownloadTask shortcut — confirmed VOD-only and unreliable against session-scoped Plex HLS.
- Storage + partial-failure recovery.

This works without Plex Pass and gives an exact 8 Mbps cap, but it's the most code and the least reliable. **Good fallback, poor primary.**

---

## Option 3 — The "single-request capped transcode download" (the dream simplification)

**Investigated specifically. Verdict: not a real, reliable thing for this use case.** ⚠️

- There is **no documented `?download=1`-style endpoint that returns a capped single file via the transcoder.** The free `download=1` path is hard-wired to the **original** `Part` — it bypasses the transcoder entirely. You cannot bolt a bitrate cap onto it.
- `/video/:/transcode/universal/start.mkv` (and `start.mp4`) **do exist** as universal-transcode container outputs, but they are **session-scoped live transcode streams**, not finalized downloadable files: progressive/chunked, session-timeout-bound, no reliable `Content-Length`, and bound by the same playback-paced transcoding. Pointing AVPlayer or a downloader at them is the same fragility as Option 2 without even the segment-walk structure, and is widely reported as flaky for "save to a file." No first-party support, no stable docs.
- Plex's own apps do **not** use a one-shot transcoded download; the official Downloads feature itself rides the **HLS segment mechanism** (confirmed in the "Downloads Overview" / transcoder docs). If Plex doesn't trust a single-file transcode download, neither should we.

**Conclusion:** the "killer simplification" doesn't materialize. The closest thing to "one file, capped, reliable" is **Option 1a**, which gets you a single MP4 — just asynchronously (server makes it first) rather than in one HTTP request.

---

## Recommendation for THIS user

**Primary: Option 1a — Media Optimizer.** Risk **Low–Medium**, difficulty **M**.
- The user owns the server → no Plex Pass required.
- Built-in **"TV – 8 Mbps 1080p"** preset is exactly the target; Custom lets you dial any bitrate.
- Output is a normal MP4 `Part` you download with the **free `?download=1`** fetch already built — no HLS juggling, no AVAssetDownloadTask, plays natively offline on visionOS.
- App flow: call `optimize()` (or raw PUT to `{/playlists?type=42}/items`) → poll `conversions()` / `/status/sessions/background` → on completion, re-fetch metadata, find the new optimized `Part`, `download=1` it to the headset.

**Fallback: Option 2 — custom HLS segment downloader.** Risk **Medium–High**, difficulty **L–XL**. Use only if the user refuses to let the app write optimized versions onto the server, or wants on-the-fly capping without a persistent server copy. Budget real engineering time for session keep-alive, end-of-stream detection, and TS→MP4 remux in Swift.

**Avoid:** Option 1b (needs client-side Plex Pass) unless the user already has Plex Pass and wants official-grade sync. **Drop Option 3** — the single-request capped download is not real/reliable.

### Open items to verify on the live server before committing
1. Confirm the optimized version appears as a second `Media`/`Part` on `/library/metadata/{id}` and that `?download=1` on it returns the ~8 Mbps MP4. (High confidence, but verify shape.)
2. Confirm `optimize()` succeeds **without Plex Pass** on the user's actual server build (it should; Optimizer is free).
3. Measure optimize job wall-clock for an 80 GB 4K source → 8 Mbps 1080p on the user's hardware (sets UX expectations for "download later" UI).

---

## Sources & confidence

- **Plex "Downloads Overview"** (support.plex.tv/articles/downloads-overview/, mod. 2025-01-09) — *Downloads requires Plex Pass on the user account performing it; global bitrate cap setting exists.* **High.**
- **Plex "Creating Optimized Versions"** (support.plex.tv/articles/213095317) — *Optimizer presets incl. "TV – 8 Mbps 1080p" MP4; only a server-version requirement, no Plex Pass requirement listed.* **High.**
- **Plex "Media Optimizer Overview"** + corroborating community sources — *Optimizer functional in free edition; Plex Pass only for remote triggering.* **Medium-High.**
- **python-plexapi** `video.py` `optimize()`, `sync.py` (`SyncItem`/`MediaSettings`/`VIDEO_QUALITY_*`), `server.py` (`conversions`, `optimizedItems`, `/status/sessions/background`, `/playlists?type=42`). **High** for code; **Medium** for exact server JSON shapes.
- **kmark gist 6028758** + **PastaGringo fork 4da1b95** — Universal Transcoder Downloader: `start.m3u8` params, `maxVideoBitrate`, session ping keep-alive, ffmpeg concat. **High** for the technique.
- **codedninja/plexmedia-downloader, danielhoherd/plexdl** source — confirmed **original-file-only**, no bitrate cap. **High.**
- **Apple AVAssetDownloadTask** VOD-only constraint (prior research). **High.**
- `start.mkv`/`start.mp4` as session-scoped non-finalizable streams — **inferred/reverse-engineered, Medium confidence**; flagged as uncertain.
