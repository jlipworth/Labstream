# Plex Universal Transcode / Streaming API — Deep Dive

> **Status:** Reverse-engineered. Plex publishes **no official spec** for these endpoints.
> Everything below is derived from open-source clients (`plex-for-kodi`, `python-plexapi`),
> Tautulli's schema, the canonical kmark reverse-engineering gist, and Plex forum threads.
> **It is version-dependent** — param names and decision codes have shifted across PMS
> releases. Treat every parameter as "send it, but tolerate the server ignoring it."
> Confidence is tagged per row: **[code]** = seen in OSS client source, **[gist]** =
> kmark 2013–2016 RE write-up, **[tautulli]** = Tautulli field schema, **[forum]** = forum
> report (lowest confidence).

---

## 0. The two endpoints and how they relate

| Endpoint | Purpose |
|---|---|
| `GET /video/:/transcode/universal/decision` | **Dry run.** Server returns a `MediaContainer` describing what it *would* do (direct play / direct stream / transcode) given your params + capability profile. No transcoder is spawned. **[code]** |
| `GET /video/:/transcode/universal/start.m3u8` (or `.mpd`, `.mkv`, `.ts`) | **Commit.** Same param set; server spawns the transcoder (if needed) and returns the playlist/container. **[gist][code]** |
| `GET /video/:/transcode/universal/session/{session}/base/index.m3u8` | The real variant playlist, referenced from `start.m3u8`. **[gist]** |
| `GET /video/:/transcode/universal/session/{session}/base/{segment}` | Individual MPEG-TS / fMP4 segments. **[gist]** |
| `GET /video/:/transcode/universal/ping?session={s}` and `/video/:/transcode/segmented/ping?session={s}` | Keep-alive. **[gist][forum]** |
| `GET /video/:/transcode/universal/stop?session={s}` | Tear down the transcoder, free the slot. **[gist][code]** |
| `GET /:/timeline` | Player progress / state reporting (separate subsystem; see §6). **[code]** |

The modern client flow is **decision → start → (timeline + ping loop) → stop**. The decision
call is the contract; `start.m3u8` is supposed to be called with the *identical* param set so
the server reproduces the same decision. `plex-for-kodi` literally builds the start URL first,
then does `.replace(transcodeEndpoint, DECISION_ENDPOINT)` to get the decision URL — guaranteeing
identical params. **[code: plexplayer.py]**

```python
# plex-for-kodi / plexnet / plexplayer.py
DECISION_ENDPOINT = "/video/:/transcode/universal/decision"
decisionPath = builder.getRelativeUrl().replace(obj.transcodeEndpoint, self.DECISION_ENDPOINT)
```

---

## 1. The full parameter matrix

These ride on **both** `/decision` and `/start.m3u8`. Group them mentally as:
**(a) what to play**, **(b) how to deliver it**, **(c) quality ceiling**, **(d) subtitles/audio**,
**(e) session/identity**, **(f) capability profile**.

### (a) What to play

| Param | Meaning | Example | Source / confidence |
|---|---|---|---|
| `path` | The metadata key being played, **URL-encoded**, usually the full `library/metadata/{id}` URL (or just `/library/metadata/{id}`). This is *the* item selector. | `path=%2Flibrary%2Fmetadata%2F12345` | [code][gist] |
| `mediaIndex` | Which `Media` entry on the item (a title can have multiple versions / qualities). 0-based. Default `0`. | `mediaIndex=0` | [code][gist] |
| `partIndex` | Which `Part` of that media (multi-file/multi-disc). 0-based. Default `0`. | `partIndex=0` | [code][gist] |
| `offset` | Start/seek position **in seconds**. Default `0`. On seek, clients re-issue `start.m3u8` with a new `offset` (or rely on `fastSeek`). | `offset=312` | [code][gist] |

> ⚠️ `python-plexapi`'s `getStreamURL` has a long-standing **bug**: `partIndex` is set from
> `kwargs.pop('mediaIndex', 0)` instead of `partIndex`, so partIndex always mirrors mediaIndex.
> Don't copy that. **[code: base.py]**

### (b) How to deliver it (the decision levers)

| Param | Meaning | Source / confidence |
|---|---|---|
| `protocol` | Delivery protocol: `hls` (segmented, what AVPlayer wants), `dash`, or `http` (progressive MP4/MKV mux). Drives the extension on `start.*`. | [code][gist] |
| `directPlay` | `1` = "serve the original file bytes untouched if my profile allows it"; `0` = "do not direct play." Setting `0` forces at least a remux/transcode. | [code][gist] |
| `directStream` | `1` = allow **remux** (container change, codec copy) when full direct play isn't possible but codecs are compatible; `0` = force full transcode. | [code][gist] |
| `directStreamAudio` | Independently allow audio stream-copy while video transcodes (avoids needless audio re-encode). | [forum][code-adjacent] |
| `fastSeek` | `1` = seek to nearest keyframe at/after `offset` (fast, slightly imprecise) rather than re-transcoding from 0. Default `1` in most clients. | [code][gist] |
| `copyts` | `1` = preserve original timestamps in the muxed output (matters for A/V sync, esp. progressive MKV). `python-plexapi` defaults it to `1`; Kodi sets it on the MKV path. | [code] |
| `hasMDE` | `1` = "client understands **M**edia **D**ecision **E**ngine" (the modern decision response). Tells the server to return the rich decision MediaContainer. | [code: plexplayer.py] |
| `mediaBufferSize` | Client buffer hint in **KB**. Kodi sends `20971` (~20 MB). Influences how aggressively the server transcodes ahead. | [code: plexplayer.py] |
| `location` | `lan` or `wan`. Selects which of the server's bitrate/quality *limit* policies apply (remote streams are often capped harder). Clients send `lan` for local connections. | [code] |
| `autoAdjustQuality` | `1` = client supports ABR-style quality adaptation; lets the server build a multi-rate ladder / adjust mid-stream. | [forum][code-adjacent] |
| `addDebugOverlay` | `1` = burn a debug HUD (codec, bitrate, decision) into the transcoded video. Diagnostic only. | [forum] |

### (c) Quality ceiling

| Param | Meaning | Source / confidence |
|---|---|---|
| `maxVideoBitrate` | Hard cap in **kbps**. `8000` = 8 Mbps. `python-plexapi` clamps to `max(value, 64)`. Empty string is allowed (= no explicit cap). | [code][gist] |
| `videoQuality` | Quality knob **0–100**. Plex maps quality+bitrate+resolution together via a ladder. Default ~`75` (gist) / `100` (sync defaults). | [code][gist] |
| `videoResolution` | Target frame size as `WxH`, e.g. `1920x1080`. `python-plexapi` validates against `^\d+x\d+$`. | [code][gist] |

> The **ladder** (`python-plexapi` `VideoStreamSettings`): bitrates
> `64,96,208,320,720,1500,2000,3000,4000,8000,10000,12000,20000` kbps each map to a
> resolution + `videoQuality` value. Picking `maxVideoBitrate=8000` + `videoResolution=1920x1080`
> + `videoQuality=100` is the canonical "1080p ~8 Mbps high" rung. **[code: sync.py / VideoQuality]**

### (d) Subtitles & audio

| Param | Meaning | Source / confidence |
|---|---|---|
| `subtitles` | Subtitle delivery mode: `auto`, `burn` (hardcode into video — required for image subs PGS/VOBSUB or when video must transcode), `sidecar` (deliver as separate track), `none`. Kodi rewrites this per path: forces `sidecar` on the decision call, `burn`/`auto` on transcode. | [code: plexplayer.py][forum] |
| `skipSubtitles` | `1` = HLS path with soft subs available; tells server *not* to burn (client renders the sidecar itself). | [code: plexplayer.py] |
| `advancedSubtitles` | `text` — request text-rendered subs vs image. | [code: plexplayer.py] |
| `subtitleSize` | Caption size, ~`0–300`, `100` = normal. Affects burn-in rendering. | [code][gist] |
| `audioBoost` | Volume normalization / boost, percent. `100` = none; higher boosts dialogue, used with downmix. Default `100`. | [code][gist] |

There is **no single "audio track" param** on these endpoints. Audio/subtitle *track selection*
is done out-of-band first via **`PUT /library/parts/{partID}?audioStreamID=...&subtitleStreamID=...`**
(set the selected streams on the part), and the transcoder then honors the part's selected streams.
Multichannel **downmix to stereo** is driven by the **capability profile** (an `audio.channels`
upperBound limitation, see §2) plus `audioBoost`, not a discrete `downmix=` flag. **[code][forum]**

### (e) Session & identity

| Param | Meaning | Source / confidence |
|---|---|---|
| `session` | **The transcode session key.** Client-generated; ties decision ↔ start ↔ ping ↔ stop. Conventionally the client's `X-Plex-Client-Identifier` (Kodi reuses it) or a per-play UUID. | [code][gist] |
| `X-Plex-Session-Identifier` | A **per-playback-session** UUID, distinct from `session`. The modern PMS uses this to correlate timeline + decision + transcode in the Activity/Now-Playing view. Newer clients send both. | [forum][code-adjacent] |
| `X-Plex-Client-Identifier` | Stable client/device UUID (query param or header). | [code] |
| `X-Plex-Token` | Auth. Query param or `X-Plex-Token` header. | [code] |
| `X-Plex-Platform` | Platform name (`Chrome`, `iOS`, …); influences server-side profile defaults. `python-plexapi` defaults `Chrome`. | [code] |
| `X-Plex-Product` / `X-Plex-Device` / `X-Plex-Version` | Standard Plex client headers; help the server pick a baseline server-side profile. | [code] |

> **`session` vs `X-Plex-Session-Identifier`:** `session` is the *transcoder* handle (what you
> ping/stop). `X-Plex-Session-Identifier` is the *playback* handle the dashboard/timeline keys on.
> They are not interchangeable; modern clients send both and keep them stable for the play's life.

### (f) Capability profile

| Param | Meaning | Source / confidence |
|---|---|---|
| `X-Plex-Client-Profile-Name` | Names a **server-known baseline profile** (e.g. `Chrome`, `iOS`, `Generic`). Server loads that profile XML, then applies your `-Extra` deltas on top. | [code: plexplayer.py] |
| `X-Plex-Client-Profile-Extra` | **The capability override string** — `+`-joined directives that mutate the named profile. This is the heart of the decision (see §2). | [code: plexplayer.py] |

---

## 2. The Client Capability Profile ("DeviceProfile") system

This is the single most load-bearing, least-documented mechanism. The server can only make a
correct **direct-play vs direct-stream vs transcode** decision if it knows *exactly* what your
player can decode. Plex models this as a **profile XML** (`DirectPlayProfile`, `TranscodeTarget`,
`CodecProfile`/`Limitation` elements) — but clients usually don't ship XML; they send a
**baseline profile name + a delta string**.

### 2.1 The three XML element families (conceptual model — Plexopedia)

- **`DirectPlayProfile`** — "I can play the original file untouched if it matches this
  `(container, videoCodec, audioCodec, subtitleCodec, protocol)` tuple." Match → direct play.
- **`TranscodeTarget`** — "If you must transcode, here's a *target* I can consume"
  `(protocol, container, videoCodec, audioCodec, context=streaming|static)`.
- **`CodecProfile` / `Limitation`** — fine-grained constraints scoped to a codec, e.g. "h264 only
  up to level 4.1," "8-bit only," "max 8 audio channels." A *required* limitation that the source
  violates forces a transcode even if the container/codec matched a DirectPlayProfile.

### 2.2 The `X-Plex-Client-Profile-Extra` delta language (the real wire format)

`+`-joined directives. **Verbatim examples pulled from `plex-for-kodi`:** **[code]**

```
add-direct-play-profile(type=videoProfile&container=matroska&videoCodec=*&audioCodec=ac3)

add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)

append-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=ac3)

add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=51&isRequired=true)

add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.frameRate&value=30&isRequired=false)

add-limitation(scope=videoAudioCodec&scopeName=dca&type=upperBound&name=audio.channels&value=8&isRequired=false)
```

**Directive grammar:**

| Directive | Effect |
|---|---|
| `add-direct-play-profile(...)` | Whitelist a `(type, container, videoCodec, audioCodec[, protocol])` tuple as direct-playable. `*` = wildcard. |
| `add-transcode-target(...)` | Add a transcode *output* the client accepts: `(type, context, protocol, container, videoCodec, audioCodec)`. |
| `append-transcode-target-audio-codec(...)` | Extend an existing transcode target with another acceptable audio codec (e.g. allow AC3 passthrough alongside AAC). |
| `add-limitation(...)` | Attach a codec constraint (see fields below). |

**`add-limitation` fields:**

| Field | Values | Meaning |
|---|---|---|
| `scope` | `videoCodec`, `videoAudioCodec`, `audioCodec`, `subtitleCodec` | Which decode path the limit applies to. |
| `scopeName` | e.g. `h264`, `hevc`, `aac`, `dca`, `ac3` | The specific codec the limit applies to. |
| `type` | `upperBound`, `lowerBound`, `match`, `notMatch` | Constraint kind. `upperBound` = "≤ value." |
| `name` | e.g. `video.level`, `video.bitDepth`, `video.frameRate`, `video.width`, `video.height`, `audio.channels`, `video.bitrate` | The attribute being constrained. |
| `value` | number / string | The bound. |
| `isRequired` | `true` / `false` | `true` → violating it **forces a transcode** (hard constraint). `false` → advisory hint (server *may* still direct play). |

### 2.3 Worked: "I direct-play HEVC in mp4 up to 1080p, transcode everything else"

Send `X-Plex-Client-Profile-Name=Generic` plus this `X-Plex-Client-Profile-Extra` (raw,
pre-URL-encoding; join with `+`):

```
add-direct-play-profile(type=videoProfile&container=mp4&videoCodec=hevc&audioCodec=aac,ac3)
+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.width&value=1920&isRequired=true)
+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.height&value=1080&isRequired=true)
+add-limitation(scope=videoCodec&scopeName=hevc&type=upperBound&name=video.bitDepth&value=8&isRequired=true)
+add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)
```

Reading: a 4K HEVC mp4 violates the *required* width/height upperBounds → the decision returns
**transcode**, targeting the declared HLS/h264/aac transcode target. A 1080p 8-bit HEVC mp4
matches the DirectPlayProfile and satisfies all required limitations → **direct play**.
Anything that isn't HEVC-in-mp4 has no matching DirectPlayProfile → transcode. **[code-pattern, synthesized]**

> Because there is no public schema, the safest approach (what `plex-for-kodi` does) is: start
> from a **server-known baseline** (`X-Plex-Client-Profile-Name`) and only send *deltas* for the
> things your AVPlayer build actually supports/rejects. Don't hand-author a whole profile.

---

## 3. Session lifecycle & reading the decision

### 3.1 The chain

1. **Decision:** `GET .../decision?...&session={S}&X-Plex-Session-Identifier={U}&hasMDE=1&{profile}`.
   Parse the `MediaContainer` (below) to learn direct-play vs transcode **before** committing.
2. **Start:** `GET .../start.m3u8?...&session={S}` with the *same* params. Returns a tiny playlist
   that points at `session/{S}/base/index.m3u8`. The session ID can also be recovered from that
   URL via regex `session/(?P<session>[A-Z0-9-]+)/base/index.m3u8` if you let the server mint it. **[gist]**
3. **Play loop:** AVPlayer pulls `index.m3u8` + segments. Meanwhile the client:
   - **pings** `GET .../universal/ping?session={S}` (and/or `/segmented/ping?session={S}`) on an
     interval (~every 10–30 s) so the server doesn't reap the idle transcoder; **[gist][forum]**
   - posts **timeline** updates (see §6).
4. **Stop:** `GET .../universal/stop?session={S}` on teardown to free the transcoder slot
   immediately (otherwise it lingers until a reap timeout). **[gist][code]**

> Forum gotcha: *"Got a transcode session ping without a session GUID (or with an invalid one)"* —
> emitted when you ping with a missing/stale `session`. Generate the `session` up front, keep it
> identical across decision/start/ping/stop. **[forum]**

### 3.2 Interpreting the decision `MediaContainer`

The decision response (with `hasMDE=1`) carries triplets of code+text. Authoritative names from
forum reports + Tautulli's decision vocabulary: **[forum][tautulli]**

| Field | Meaning |
|---|---|
| `generalDecisionCode` / `generalDecisionText` | Overall outcome. `1001` ≈ *"Direct play not available; Conversion OK"* (i.e. transcode/remux). `1000` ≈ direct play OK. |
| `directPlayDecisionCode` / `directPlayDecisionText` | Why direct play was/wasn't chosen. `3000` ≈ *"App cannot direct play this item"*. |
| `transcodeDecisionCode` / `transcodeDecisionText` | Details of the transcode path chosen. |
| `mdeDecisionText` | Free-text MDE explanation, e.g. "Convert to HLS, transcode video, copy audio." |

The **per-stream** decisions live on the `<Media><Part><Stream>` children and are what Tautulli
surfaces: **[tautulli]**

| Tautulli field | Values |
|---|---|
| `transcode_decision` (overall) | `direct play` \| `copy` \| `transcode` |
| `video_decision` | `direct play` \| `copy` \| `transcode` |
| `audio_decision` | `direct play` \| `copy` \| `transcode` |
| `container_decision` | `direct play` \| `copy` \| `transcode` |
| `subtitle_decision` | `direct play` \| `copy` \| `burn` \| `transcode` |

> **Practical rule:** if every per-stream decision is `direct play`/`copy`, you got direct play
> or a cheap remux. If `video_decision == transcode`, the server is spending CPU/GPU — that's
> what `maxVideoBitrate`/`videoResolution`/the profile are meant to control. Read these from the
> **`/decision`** response and only call `/start.m3u8` if the decision is acceptable; this is the
> entire point of having a separate decision endpoint.

---

## 4. Subtitles & audio in detail

- **Track selection is stateful, not a query param.** Select the desired audio/subtitle streams
  on the *part* first: `PUT /library/parts/{partID}?audioStreamID={A}&subtitleStreamID={B}`
  (token-authed). The transcode endpoints then act on the part's selected streams. **[code]**
- **`subtitles=burn`** hardcodes subs into the video — *mandatory* for image subs (PGS, VOBSUB)
  and whenever the video stream is already transcoding. Text subs (SRT/ASS) can go `sidecar`. **[forum]**
- **`subtitles=sidecar` + `skipSubtitles=1`** = server delivers a separate WebVTT/subtitle track
  and lets the client render it (no burn, no video transcode just for subs). `plex-for-kodi`
  uses `sidecar` on the decision probe and switches to `burn`/`auto` on the actual transcode when
  burn is forced. **[code]**
- **Forced-burn footnote:** when **audio** must transcode *and* subs are on, some PMS versions
  force subtitle **burn** to keep sub timing in sync — a known surprise on Shield/ATV. **[forum]**
- **Downmix / multichannel:** there's no `downmix=stereo` flag. Stereo output is induced by an
  `add-limitation(scope=videoAudioCodec&scopeName=...&type=upperBound&name=audio.channels&value=2)`
  in the profile (or a 2-channel transcode target). `audioBoost` then compensates dialogue level
  after the downmix. **[code][forum]**

---

## 5. HLS specifics & AVPlayer gotchas

- **`start.m3u8` is a *redirect-ish* stub**, not the real playlist. It contains a reference to
  `…/session/{S}/base/index.m3u8` (the actual `#EXT-X-STREAM-INF` variant playlist) plus a few
  `#EXT-X-` comment/stat lines. Don't hand `start.m3u8`'s URL to AVPlayer expecting media segments
  directly — but in practice you *can* point AVPlayer at `start.m3u8` and it'll follow through to
  `index.m3u8`. **[gist]**
- **Segments:** classic path = MPEG-TS, ~1–8 s each, H.264 + AAC/MP3. Newer PMS emits **fMP4
  (CMAF)** segments for HEVC/Atmos passthrough — required for AVPlayer to play HEVC/Atmos over
  HLS natively. **[gist][forum]** A documented ATV bug: HEVC transcode buffered forever because
  PMS handed an *MPEG-TS* container where AVPlayer needed **fMP4** — i.e., the wrong HLS container
  for the codec. So: declare HEVC transcode targets with `container=mp4`/fMP4 in your profile, not
  `mpegts`. **[forum]**
- **Segment auth:** every sub-request (`index.m3u8`, each segment, ping, stop) must carry the
  **`X-Plex-Token`** (query param), because AVPlayer's own segment fetches won't add headers.
  Easiest: ensure the token is baked into the `start.m3u8` URL query so the server propagates it
  into the playlist's relative URIs. If segments 401, that's a missing/expired token. **[gist][code]**
- **AVPlayer feeding tips:** use `AVURLAsset` with the token in the URL; set
  `AVURLAssetHTTPHeaderFieldsKey`/`AVAssetResourceLoaderDelegate` only if you must inject headers
  the server requires (Plex generally accepts token-as-query, so usually unnecessary). Live/VOD:
  Plex transcode HLS is VOD-style (`#EXT-X-PLAYLIST-TYPE:VOD` once the transcode catches up) but
  starts *event-like* while the transcoder is still ahead-buffering — AVPlayer handles this if you
  don't aggressively check duration before the playlist is complete. **[gist, general HLS]**

---

## 6. `/:/timeline` (progress reporting — separate from transcode)

`GET /:/timeline?ratingKey={rk}&key={metadataKey}&state={playing|paused|stopped|buffering}`
`&time={ms}&duration={ms}&playbackTime={ms}&X-Plex-Client-Identifier=...`
`&X-Plex-Session-Identifier={U}` — posts player position/state. This drives **Continue Watching**,
on-deck, and Now-Playing. It is **independent** of the transcode `ping`: timeline reports
*playback*, ping keeps the *transcoder* alive. Send both. The `X-Plex-Session-Identifier` here is
what links the timeline to the transcode/decision in the server's Activity view. **[code]**

---

## 7. Worked example — force 1080p ~8 Mbps HLS, burn subtitles

Item `ratingKey=12345`; client UUID `abc123`; session `sess-uuid-1`; playback session `play-uuid-1`;
LAN; subs burned in. **Decision first:**

```
GET /video/:/transcode/universal/decision
  ?path=%2Flibrary%2Fmetadata%2F12345
  &mediaIndex=0
  &partIndex=0
  &protocol=hls
  &offset=0
  &fastSeek=1
  &directPlay=0
  &directStream=1
  &copyts=1
  &videoResolution=1920x1080
  &maxVideoBitrate=8000
  &videoQuality=100
  &subtitles=burn
  &subtitleSize=100
  &audioBoost=100
  &location=lan
  &mediaBufferSize=20971
  &hasMDE=1
  &session=sess-uuid-1
  &X-Plex-Session-Identifier=play-uuid-1
  &X-Plex-Client-Identifier=abc123
  &X-Plex-Client-Profile-Name=Generic
  &X-Plex-Client-Profile-Extra=add-transcode-target(type%3DvideoProfile%26context%3Dstreaming%26protocol%3Dhls%26container%3Dmpegts%26videoCodec%3Dh264%26audioCodec%3Daac)%2Badd-limitation(scope%3DvideoCodec%26scopeName%3Dh264%26type%3DupperBound%26name%3Dvideo.height%26value%3D1080%26isRequired%3Dtrue)
  &X-Plex-Token=YOURTOKEN
```

Inspect the returned `MediaContainer`: expect `generalDecisionCode≈1001`, `video_decision=transcode`,
`subtitle_decision=burn`. If acceptable, **commit** by swapping `decision` → `start.m3u8`
(identical query), hand the resulting URL to AVPlayer, then loop:

```
GET /video/:/transcode/universal/ping?session=sess-uuid-1&X-Plex-Token=YOURTOKEN   # every ~15s
GET /:/timeline?ratingKey=12345&state=playing&time=...&duration=...&X-Plex-Session-Identifier=play-uuid-1&X-Plex-Client-Identifier=abc123&X-Plex-Token=YOURTOKEN
...
GET /video/:/transcode/universal/stop?session=sess-uuid-1&X-Plex-Token=YOURTOKEN   # on teardown
```

---

## 8. Source map / confidence

- **`plex-for-kodi` `plexnet/plexplayer.py`** — most authoritative live client: `DECISION_ENDPOINT`,
  `hasMDE`, `mediaBufferSize=20971`, `X-Plex-Client-Profile-Name`, the `add-direct-play-profile` /
  `add-transcode-target` / `append-transcode-target-audio-codec` / `add-limitation` syntax, and the
  `sidecar`↔`burn` subtitle path switching. **[high]**
- **`python-plexapi` `base.py::getStreamURL` / `sync.py` quality ladder** — `path, mediaIndex,
  partIndex, protocol, fastSeek, copyts, offset, maxVideoBitrate (clamp 64), videoResolution
  (`\d+x\d+`), X-Plex-Platform`, the bitrate/resolution/quality table, the `partIndex=mediaIndex`
  bug. **[high]**
- **kmark gist `6028758`** — the canonical RE of `start.m3u8` → `index.m3u8` → TS segments, the
  `session` regex, `ping`/`stop` endpoints, `audioBoost`, `subtitleSize`, `videoQuality 0-100`. **[high, but 2013–2016]**
- **Tautulli `plexpy/common.py`** — per-stream decision vocabulary (`direct play`/`copy`/`transcode`/`burn`)
  for video/audio/subtitle/container. **[high]**
- **Plexopedia client-profiles article** — conceptual XML model (DirectPlayProfile / TranscodeTarget
  / CodecProfile-Limitation, attributes protocol/container/codec/audioCodec/subtitleCodec/context). **[medium]**
- **Plex forum threads** — decision codes `1000/1001/3000`, ping-without-GUID warning, HEVC-needs-fMP4
  ATV bug, forced subtitle burn when audio transcodes, `X-Plex-Session-Identifier` usage. **[lower — anecdotal/version-specific]**

> **Final caveat:** Plex changes these between PMS releases without notice. Probe `/decision`
> defensively, tolerate ignored params, and prefer baseline-profile + deltas over hand-authored
> profile XML.
