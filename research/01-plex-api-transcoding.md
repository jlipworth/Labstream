# Plex API: Auth, Browsing, Server-Side Transcoded HLS, and Offline Download

Research for a personal-use Apple Vision Pro (visionOS) Plex client. Date: 2026-06-08.

Scope: how a *custom native client* authenticates, browses libraries, and — the key part — requests a **server-side transcoded HLS stream** (not direct play). Plus a verdict on the `plexswift` Swift SDK and on offline downloads.

> **Reliability note.** Plex now publishes an official PMS API reference at `developer.plex.tv/pms/` (API v1.2.2, PMS ≥ 1.43.2), including Transcoder and Timeline operations. The exact query-param recipes and some legacy endpoint forms below are still corroborated by reference clients (python-plexapi, plex-for-kodi, community SDK specs, and long-standing tools) and remain **version-dependent** — treat them as documented where the portal covers them, but still verify behavior against your live PMS.

---

## 1. Authentication

### 1.1 Client identity headers (send on every request)

Plex identifies clients by a set of `X-Plex-*` headers (or equivalent query params). The minimum useful set:

| Header | Purpose |
|---|---|
| `X-Plex-Client-Identifier` | **Stable per-install UUID.** Generate once, persist forever (Keychain). Ties tokens, sessions, and the transcode session together. **The single most important header.** |
| `X-Plex-Product` | App name, e.g. `Plex AVP` |
| `X-Plex-Version` | App version |
| `X-Plex-Platform` | e.g. `visionOS` |
| `X-Plex-Platform-Version` | OS version |
| `X-Plex-Device` | Device class |
| `X-Plex-Device-Name` | Friendly name shown in Plex's device list |
| `X-Plex-Token` | Auth token (once obtained) |

Any `X-Plex-*` header can also be passed as a query parameter — useful for media URLs handed to `AVPlayer`, which can't set custom headers easily.

### 1.2 PIN-based OAuth login (recommended; no password handling)

Source: official Plex forum dev guide "Authenticating with Plex".

1. **Create a PIN** — `POST https://plex.tv/api/v2/pins`
   Headers: `Accept: application/json`, `X-Plex-Product`, `X-Plex-Client-Identifier`.
   Body/param: `strong=true`.
   Response JSON: `{ id, code, ... }`. Store `id`; `code` is a 4-char PIN.

2. **Send the user to the Plex auth app** — open in a browser / `ASWebAuthenticationSession`:
   ```
   https://app.plex.tv/auth#?clientID=<X-Plex-Client-Identifier>
       &code=<code>
       &context[device][product]=<X-Plex-Product>     (URL-encoded as context%5Bdevice%5D%5Bproduct%5D)
       &forwardUrl=<your custom scheme/url>            (optional; for redirect instead of polling)
   ```

3. **Poll for the token** — `GET https://plex.tv/api/v2/pins/<id>?code=<code>`
   Headers: `Accept: application/json`, `X-Plex-Client-Identifier` (must match step 1).
   Poll ~1×/sec. When the user authorizes, response contains `authToken`. That string is your **`X-Plex-Token`** (the account token). Persist it in Keychain.

4. **Validate a stored token** — `GET https://plex.tv/api/v2/user` with `X-Plex-Token`. `200` = valid, `401` = re-auth.

> **JWT / short-lived tokens (forward-looking, uncertain).** Plex announced (Plex Pro Week '25) a move toward JWT device registration with public-key (JWK) upload and ~7-day refresh. As of mid-2026 the classic long-lived `X-Plex-Token` still works for PMS calls and is what all reference SDKs use. Build on `X-Plex-Token` now; watch for JWT becoming mandatory. **Flag: version-dependent.**

### 1.3 Server discovery (plex.tv resources)

`GET https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1`
Headers: `Accept: application/json`, `X-Plex-Token`, `X-Plex-Client-Identifier`.

(Legacy equivalent: `https://plex.tv/api/resources?X-Plex-Token=...`, XML.)

Returns each owned/shared resource (server = `provides` contains `server`). Each server entry includes:
- **`accessToken`** — a *per-server* token. **Use this token for that server's PMS calls**, not necessarily the account token.
- **`connections[]`** — multiple candidate URIs, each with `address`, `port`, `uri`, `local` (bool), `relay` (bool), `protocol`.

**Connection selection strategy:** try `local` LAN connections first (lowest latency, direct), then remote direct (port-forwarded, with a `*.plex.direct` hostname + cert for HTTPS), then **Relay** (`relay=true`, proxied through plex.tv, bandwidth-capped ~2 Mbps — avoid for HD transcode). Probe candidates in parallel with `GET <uri>/identity` and pick the first that responds and whose `machineIdentifier` matches.

---

## 2. Library browsing (high level)

All PMS calls take `X-Plex-Token` (the per-server `accessToken`) and return XML by default or JSON with `Accept: application/json`.

| Call | Returns |
|---|---|
| `GET /identity` | Server `machineIdentifier`, version (unauthenticated reachability check) |
| `GET /library/sections` | Libraries (sections). Each has `key`, `type` (movie/show/...), `title` |
| `GET /library/sections/<key>/all` | All items in a section (supports `X-Plex-Container-Start` / `X-Plex-Container-Size` paging, `sort`, filters) |
| `GET /library/metadata/<ratingKey>` | Full metadata for an item, including `Media` → `Part` → `Stream` tree |
| `GET /library/metadata/<ratingKey>/children` | Seasons / episodes / tracks |
| `GET /search?query=...` or `/hubs/search` | Search |

The metadata `Part` object is the unit you stream/download. Key fields: `Part.id`, `Part.key` (e.g. `/library/parts/<id>/<ts>/file.mkv`), `Part.container`, and the `Media`/`Part` array indices that become `mediaIndex` / `partIndex` below.

---

## 3. THE KEY PART — server-side transcoded HLS

### 3.1 Direct Play vs Direct Stream vs Transcode

- **Direct Play** — server sends the original file bytes untouched. Client must support container + video codec + audio codec + bitrate. No server CPU. (This is just fetching `Part.key`.)
- **Direct Stream** — server **remuxes**: same video and audio *codecs*, but rewraps into a client-friendly container (e.g. MKV → MPEG-TS/HLS). Light server CPU. Used when codecs are fine but the container/protocol isn't.
- **Transcode** — server **re-encodes** video and/or audio to a new codec/bitrate/resolution. Heavy server CPU. This is what you want for a fixed ~8 Mbps target.

The server decides per-request based on (a) the client's declared capabilities/profile and (b) the params you pass. You **force/bias** the outcome with `directPlay`/`directStream` flags and bitrate caps (below).

### 3.2 The two-step universal transcode flow

Modern Plex clients do **decision → start**:

**Step A — Decision (optional but recommended):**
```
GET /video/:/transcode/universal/decision
```
Same query params as `start` (below). Returns a `MediaContainer` describing what the server *will* do (`decision`, chosen container/protocol, whether it's directPlay/directStream/transcode, target bitrate). Lets the client decide before opening a player. A `500` here typically means the Media Decision Engine couldn't build a valid profile (often an audio-metadata edge case). Optional — you can skip straight to `start`.

**Step B — Start the HLS stream:**
```
GET /video/:/transcode/universal/start.m3u8
```
The response is an HLS **master/`index` playlist**; segments are `.ts` served under `/video/:/transcode/universal/session/<session>/.../index.m3u8` and `*.ts`. Just hand the `start.m3u8` URL (with the token as a query param) to `AVPlayer` and it follows the playlist. (There is also `start.mpd` for MPEG-DASH — see plexswift verdict.)

### 3.3 Query parameters for `start.m3u8` / `decision`

Confirmed across the official PMS Transcoder docs, python-plexapi, the community OpenAPI spec, and the kmark reverse-engineering gist:

| Param | Example | Notes |
|---|---|---|
| `path` | `/library/metadata/<ratingKey>` (URL-encoded; often the full `http://127.0.0.1:32400/library/metadata/<id>`) | The item to play. **Required.** |
| `mediaIndex` | `0` | Which `Media` entry. **Required** (use `0` unless multiple versions). |
| `partIndex` | `0` | Which `Part`. **Required.** |
| `protocol` | `hls` | **`hls` is what you want for visionOS/AVPlayer.** (`dash`, `http` also exist.) |
| `session` | `<uuid>` | Transcode session id. **Generate one per playback** (commonly = or derived from `X-Plex-Client-Identifier`). Needed for ping/stop. |
| `offset` | `0` | Resume position (seconds). |
| `fastSeek` | `1` | Allow seeking without full re-transcode from 0. |
| `directPlay` | `0` | `0` to **forbid** direct play and force transcode/remux. |
| `directStream` | `0` or `1` | `0` to forbid remux and **force full transcode**; `1` to allow remux. To *guarantee* re-encode at your bitrate, set both `directPlay=0` and `directStream=0`. |
| `maxVideoBitrate` | `8000` | **Kbps.** This is your ~8 Mbps knob → `8000`. |
| `videoQuality` | `0`–`100` | Quality bias (often paired with bitrate). |
| `videoResolution` | `1920x1080` | Target resolution cap. |
| `audioBoost` | `100` | Audio gain %. |
| `subtitleSize` | `100` | Subtitle scaling; subtitle stream selection via `subtitles=burn` or stream ids. |
| `copyts` | `1` | Keep timestamps (helps seeking/sync). |
| `X-Plex-Client-Identifier` | `<uuid>` | **Required** and must be consistent. |
| `X-Plex-Token` | `<server accessToken>` | Pass as query param so AVPlayer's segment requests carry it. |
| `X-Plex-Platform` / other `X-Plex-*` | `visionOS` | Affect default profile selection. |

**To get a forced ~8 Mbps HLS transcode**, the practical recipe:
```
/video/:/transcode/universal/start.m3u8
  ?path=%2Flibrary%2Fmetadata%2F<ratingKey>
  &mediaIndex=0&partIndex=0
  &protocol=hls
  &directPlay=0&directStream=0      # force re-encode (use directStream=1 if remux is acceptable)
  &maxVideoBitrate=8000
  &videoResolution=1920x1080
  &videoQuality=75
  &fastSeek=1&copyts=1&offset=0
  &session=<uuid>
  &X-Plex-Client-Identifier=<uuid>
  &X-Plex-Token=<accessToken>
  &X-Plex-Platform=visionOS&X-Plex-Product=Plex%20AVP&X-Plex-Version=1.0
```

### 3.4 Capability negotiation: `X-Plex-Client-Profile-Extra`

Instead of (or in addition to) the coarse `directPlay/directStream` flags, well-behaved clients send a **client profile** so the server's Media Decision Engine knows what the device can play. The ad-hoc form is the header/param `X-Plex-Client-Profile-Extra`, a string of directives joined by `+`:

```
add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)+
add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.bitrate&value=8000)+
add-direct-play-profile(type=videoProfile&container=mp4&videoCodec=h264&audioCodec=aac)
```

This is how you precisely tell Plex "I can HLS/mpegts H.264+AAC, cap bitrate at 8000 kbps." The **directive grammar is now documented** in the official PMS API portal, while the best practical directive sets remain client-derived/version-dependent; the full system profiles live on the server under `Resources/Profiles`. For a personal app, the explicit query params in 3.3 are simpler and usually sufficient; reach for `X-Plex-Client-Profile-Extra` only if the server keeps choosing a codec AVPlayer can't decode.

### 3.5 Session lifecycle

- **Keep-alive:** `GET /video/:/transcode/universal/ping?session=<session>` periodically (the server reaps idle sessions).
- **Stop/cleanup:** `GET /video/:/transcode/universal/stop?session=<session>` on stop/teardown (frees the server transcoder).
- **List active:** `GET /transcode/sessions` (a.k.a. "get transcode sessions") to inspect progress/state.

---

## 4. plexswift verdict (github.com/LukeHagar/plexswift)

**Maturity / status:**
- **Repository is ARCHIVED** (read-only). Stars ~15. Last release **v0.10.5 (2025-03-10)**; last push 2025-10-12. It is a **0.x, auto-generated (Speakeasy) SDK** built from the community `plex-api-spec` OpenAPI document. The "LukasParke" name you mentioned is the same author's other handle (they maintain `plex-api-spec`, `plexjs`, etc.); the **`LukeHagar/plexswift` Swift repo is the canonical one, and it's now archived/unmaintained.** Generated SDKs are explicitly "may not be fully tested."

**Does it expose transcode/streaming? — PARTIALLY, and with gaps that matter:**

It **does** generate a `VideoAPI` with:
- `startUniversalTranscode(...)` → but the endpoint path is **hardcoded to `/video/:/transcode/universal/start.mpd` (MPEG-DASH, not HLS)**. For a visionOS/AVPlayer client you want **HLS (`start.m3u8`)**, which this method does not target.
- `getTranscodeSessions()` and `stopTranscodeSession(...)` (session list / teardown).
- `getTimeline(...)` (playback progress reporting).

**Critical limitations:**
- **No `/video/:/transcode/universal/decision` operation at all** (confirmed: nothing matching `decision` in the repo tree).
- `StartUniversalTranscodeRequest` exposes `path`, `protocol`, `mediaIndex`, `partIndex`, `directPlay`, `directStream`, `fastSeek`, `session`, `subtitleSize`, `audioBoost`, `location`, `hasMDE`, `mediaBufferSize` — but **does NOT expose `maxVideoBitrate`, `videoQuality`, or `videoResolution`.** Inspecting the generated `_VideoAPI.swift`, only ~2 query params are actually wired in. **So you cannot set your ~8 Mbps target through this method.**
- The `Download` "operation" in the SDK is **not a media download** — it's a sync-update enum flag (`0/1`), unrelated to fetching a file.

**Verdict:** plexswift is fine as a typed model layer / reference for the **metadata-browsing and auth** endpoints, but it is **archived, 0.x, and does not usefully cover the transcode-for-HLS path**: wrong protocol target (DASH), no decision endpoint, and missing the bitrate/quality/resolution params that are the whole point. **You will hand-roll the `start.m3u8` (and optionally `decision`) requests yourself**, building the query string from §3.3. Given the SDK is archived, consider not depending on it at all and instead modeling the few endpoints you need directly (or borrow types from the actively-maintained `python-plexapi` as your behavioral reference). Alternative Swift libs exist (`lcharlick/PMSKit`, `k3zi/PlexSwift`) but evaluate their transcode coverage the same way — most cover metadata, not the universal transcoder.

---

## 5. Offline download of media

**Two distinct mechanisms:**

### 5.1 Direct part download (simple, NO Plex Pass) — recommended

This is what python-plexapi's `download()` / `tools/plex-download.py` do. To pull the **original** media file for offline playback:

```
GET <serverBaseURL><Part.key>?download=1&X-Plex-Token=<accessToken>
```
- `Part.key` comes from `/library/metadata/<ratingKey>` → `Media[].Part[].key`.
- `?download=1` tells PMS to serve it as a download (correct headers) rather than for streaming.
- Supports HTTP **range requests**, so you can resume/segment the download.
- **No Plex Pass required** — this is just authenticated file access to media you can already see. (Subject only to normal library share permissions; a server owner can disable "Allow downloads" for shared users via `Settings → Sharing`.)

**Caveat:** this downloads whichever `Part` you point at. For the original media part, that could be a 40 GB remux. **Round-3 update:** for an **8 Mbps offline copy**, the preferred path is Plex **Media Optimizer**: have the server create an "Optimized for TV – 8 Mbps 1080p" MP4 version, then download that optimized `Part.key` with the same `?download=1` flow. If Media Optimizer is not acceptable, fall back to a transcode-to-file segment walker: run a transcoded HLS session and **save the segments locally** (the kmark "Universal Transcoder Downloader" approach — request `start.m3u8`, pull the `.ts` segments, concatenate/remux). There is no single official "download me a transcoded MP4 right now" endpoint; you either pre-create an optimized file or assemble it from the transcode session. **Flag: the segment-walker is a community pattern, not an official API.**

### 5.2 Mobile Sync (official offline system, REQUIRES Plex Pass)

The formal "Downloads / Sync" feature (`plexapi.sync`): the client advertises `X-Plex-Provides: sync-target` + `X-Plex-Sync-Version: 2`, creates **`SyncItem`s** with a `Policy` (e.g. unwatched, item count) and `MediaSettings` (target video quality/bitrate), then the server prepares optimized/transcoded copies the client pulls and tracks (`markDownloaded`). This is the path the official mobile apps use for managed offline libraries.
- **Plex Pass is required** (on the *server owner's* account) for Sync/Downloads-as-a-feature, and the client must masquerade as a known sync-capable device because **transcode-for-sync profiles are hardcoded** server-side.
- Much more complex than 5.1 for little benefit in a personal single-user app.

### Download-feasibility verdict

**Feasible and easy without Plex Pass** via §5.1: fetch `Part.key?download=1` with the token, using range requests. For originals, that gives you the source file offline. For a bitrate-capped offline copy, use **Media Optimizer first** and download the optimized `Part`; use custom HLS segment capture only as the fallback. The Plex-Pass-gated Mobile Sync system (§5.2) is more "correct" as an official product feature but unnecessary for a personal client and adds significant complexity.

---

## Implementation checklist for the AVP client

1. Generate + persist a `X-Plex-Client-Identifier` (Keychain).
2. PIN OAuth (§1.2) → store account `X-Plex-Token`.
3. `clients.plex.tv/api/v2/resources` → pick a connection (LAN first) + grab the per-server `accessToken` (§1.3).
4. Browse via `/library/sections`, `/library/metadata/<id>` (§2).
5. Play: build the `start.m3u8` URL from §3.3 with `protocol=hls`, `maxVideoBitrate=8000`, `directPlay=0` (+ `directStream=0` to force re-encode), a fresh `session` UUID, and token as a query param → hand to `AVPlayer`. **Hand-roll this; don't rely on plexswift.** Ping to keep alive; `stop` on teardown.
6. Download (offline): for originals, `GET <Part.key>?download=1&X-Plex-Token=...` with range requests (no Plex Pass). For capped offline copies, trigger Media Optimizer, re-fetch metadata, pick the optimized `Part`, then use the same `download=1` fetch.

---

## Sources

- [Authenticating with Plex (official forum dev guide)](https://forums.plex.tv/t/authenticating-with-plex/609370)
- [Finding an authentication token / X-Plex-Token (Plex Support)](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
- [Using plex.tv resources to troubleshoot app connections (Plex Support)](https://support.plex.tv/articles/206721658-using-plex-tv-resources-information-to-troubleshoot-app-connections/)
- [clients.plex.tv/api/v2/resources & JWT (Plex forum)](https://forums.plex.tv/t/question-on-https-clients-plex-tv-api-v2-resources-and-jwt-authentication/934478)
- [Plex Pro Week '25: API Unlocked (JWT direction)](https://www.plex.tv/blog/plex-pro-week-25-api-unlocked/)
- [Plex Universal Transcoder Downloader (kmark gist — start.m3u8 params, ping/stop)](https://gist.github.com/kmark/6028758)
- [Start universal transcode reference (plexapi.dev)](https://plexapi.dev/api-reference/video/start-universal-transcode)
- [Streaming: Direct Play and Direct Stream (Plex Support)](https://support.plex.tv/articles/200250387-streaming-media-direct-play-and-direct-stream/)
- [Plex Client Profiles (Plexopedia)](https://www.plexopedia.com/plex-media-server/general/client-profiles/)
- [universal transcoder start.mpd 400 from custom player (Plex forum)](https://forums.plex.tv/t/universal-transcoder-start-mpd-returns-400-when-called-from-custom-player/933458)
- [python-plexapi base.py (getStreamURL, download)](https://github.com/pkkid/python-plexapi/blob/master/plexapi/base.py)
- [python-plexapi tools/plex-download.py (Part.key?download=1)](https://github.com/pkkid/python-plexapi/blob/master/tools/plex-download.py)
- [python-plexapi sync module (Mobile Sync / Plex Pass)](https://python-plexapi.readthedocs.io/en/latest/modules/sync.html)
- [LukeHagar/plexswift (archived Swift SDK)](https://github.com/LukeHagar/plexswift) — verified via repo tree: `_VideoAPI.swift` hardcodes `start.mpd`, no `decision`, `StartUniversalTranscodeRequest` lacks bitrate/quality params; repo archived, last release v0.10.5 (2025-03-10).
- [LukasParke/plex-api-spec (community OpenAPI spec behind the SDKs)](https://github.com/LukasParke/plex-api-spec)
