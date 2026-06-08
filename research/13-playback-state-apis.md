# 13 — Playback-State & Navigation APIs (timeline, scrobble, playQueues, hubs, resume)

**Research date:** 2026-06-08
**Scope:** The "plumbing" a real Plex client needs beyond decode/render: reporting playback state so the server updates resume/On Deck, marking watched/unwatched, building play queues for episode progression, fetching the Home hubs, and reading/writing resume offsets. Targeted at a personal-use visionOS client.

> **Key 2026 update:** As of Plex Pro Week '25, **all** of the endpoints below are now *officially documented* in the Plex developer portal ([developer.plex.tv/pms/](https://developer.plex.tv/pms/), **API v1.2.2, PMS ≥ 1.43.2**) — Timeline (Report media timeline / Mark played / Mark unplayed), Play Queues (Create/Retrieve/Add/Clear/Move/Shuffle), Status (List Sessions / Playback History), and Hubs (global hubs / continue watching / section hubs). Historically these were reverse-engineered; they are now first-party. **None of this is Plex-Pass-gated** — it's core playback plumbing that every free client uses. (Confidence: high — confirmed directly against the official Redoc portal.)
>
> Despite the official docs, the **richest behavioral detail** (cadence, state machine, URI construction) still comes from real client source: **python-plexapi** and **plex-for-kodi/plexnet**. Those are cited per-section and are the recommended implementation reference.

**Auth on every call:** all endpoints take `X-Plex-Token` (header or `?X-Plex-Token=` query param) plus the standard `X-Plex-Client-Identifier` and other `X-Plex-*` device headers. (Confidence: high.)

---

## TL;DR — the minimal state machine

```
User taps Play on an item
  → POST /playQueues?uri=…&type=video[&shuffle=0]   (get playQueueID + per-item playQueueItemID)
  → read viewOffset from item metadata → seek there
  → during playback: GET /:/timeline?...&state=playing every ~10s (and on every state change)
  → on pause/seek/resume: GET /:/timeline with state=paused / state=playing (immediately)
  → on stop:  GET /:/timeline?...&state=stopped&time=<offset>
  → near 100% (e.g. ≥90%): server auto-marks watched; or explicitly GET /:/scrobble?key=<rk>
Next episode: advance playQueueItemID → repeat timeline loop for the new item
```

That's the whole contract. `/:/timeline` alone keeps resume position, On Deck, and Continue Watching correct. A play queue is what makes "play next episode" and the `playQueueItemID` work; scrobble is the explicit watched-toggle.

---

## 1. Timeline / progress reporting — `/:/timeline`

**This is the single most important endpoint.** The client periodically POSTs/GETs its current playback position and state; the server uses it to write `viewOffset` (resume point), drive On Deck / Continue Watching, count plays, and auto-mark watched when you reach the end.

- **Path:** `/:/timeline`
- **Method:** `GET` in practice (python-plexapi and plex-for-kodi both issue it as a GET with query params; the official portal labels it "Report media timeline" — a query-string call with no body). (Confidence: high — both reference clients use GET; plex-for-kodi sends `body=''`.)
- **Official:** documented in the portal "Timeline" section. (Confidence: high.)

### Parameters

| Param | Required | Meaning | Source/confidence |
|---|---|---|---|
| `ratingKey` | **yes** | Numeric ratingKey of the item being played | python-plexapi + plex-for-kodi (high) |
| `key` | **yes** | The item's `key` path, e.g. `/library/metadata/12345` | python-plexapi + plex-for-kodi (high) |
| `state` | **yes** | One of `playing`, `paused`, `stopped`, `buffering`. (`error` also accepted per PMP wiki.) | python-plexapi/kodi/PMP wiki (high) |
| `time` | **yes** | Current playback offset in **milliseconds** | python-plexapi + plex-for-kodi (high) |
| `duration` | **yes** | Total item duration in **milliseconds** | python-plexapi + plex-for-kodi (high) |
| `identifier` | yes* | `com.plexapp.plugins.library` (library provider). python-plexapi always sends this. plex-for-kodi omits it but sends `guid`. Send it. | python-plexapi (high) |
| `playQueueItemID` | when using a PQ | The **per-item** id within the active play queue (NOT the playQueueID). Required for proper queue/On-Deck tracking and "next episode." | plex-for-kodi (high) |
| `containerKey` | recommended | The container/address the item was loaded from (e.g. the PQ address `/playQueues/<id>` or a hub) | plex-for-kodi (high) |
| `guid` | optional | Item GUID (plex-for-kodi sends it) | plex-for-kodi (medium) |
| `hasMDE` | optional | `1` if a media-decision was made (transcode-decision flow); reverse-engineered, appears in official/LukeHagar spec | LukeHagar SDK / portal (medium) |
| `context` | optional | Where playback was launched from, e.g. `home:hub.continueWatching`. Used for analytics/hub attribution | LukeHagar SDK (medium, reverse-engineered) |
| `playBackTime` | optional | Wall-clock playback time | LukeHagar SDK (low-medium) |
| `row` | optional | Hub row index for attribution | LukeHagar SDK (low) |
| `continuing` | optional | `1` on a `stopped` report when you're immediately starting the next item (avoids spurious "stopped" UI) | Plexopedia / PMP wiki (medium) |
| `audioStreamID`/`videoStreamID`/`subtitleStreamID` | optional | Currently selected streams | plex-for-kodi (medium) |

\* Functionally the server will accept a timeline keyed on `ratingKey`+`key`+`time`+`state`+`duration`; the rest improve fidelity (queue progression, hub attribution).

**Canonical python-plexapi call** (`Video.updateTimeline`, `plexapi/base.py`):
```python
key = (f'/:/timeline?ratingKey={self.ratingKey}&key={self.key}&'
       f'identifier=com.plexapp.plugins.library&time={int(time)}&state={state}&duration={duration}')
self._server.query(key)
```
(Confidence: high — verbatim from master.)

**plex-for-kodi** (`plexnet/nowplayingmanager.py`) builds the same `/:/timeline` with `time, duration, state, guid, ratingKey, url, key, containerKey, playQueueItemID`. It clamps `time` to `duration` (sending `time > duration` causes a **400**), and skips multi-part media that has no part duration. (Confidence: high.)

### How often to call it
- **On every state change** (play → pause, pause → play, seek, stop) — send immediately. (Confidence: high — both clients do this.)
- **Otherwise on a heartbeat.** The community/PMP guidance is **every ~10s on LAN/WAN, ~20s over cellular** ([plex-media-player wiki](https://github.com/plexinc/plex-media-player/wiki/Remote-control-API), Plexopedia). plex-for-kodi enforces this via a **`ServerTimeline` that expires after 15s** — if the item+state are unchanged and the last server timeline hasn't expired, it suppresses the send; once it expires (≥15s) the next player tick re-sends. So plex-for-kodi's effective floor is "on change, else ~every 15s." **Use 10s.** (Confidence: high — `ServerTimeline.reset(): self.expires = time.time() + 15`.)
- The player drives it from its tick loop calling `updateNowPlaying(force=True)` each frame/tick; the 15s expiry + state-change checks dedupe the actual network calls. (Confidence: high.)

### `/:/progress` (lighter alternative)
python-plexapi also exposes `Video.updateProgress(time, state)`:
```python
key = f'/:/progress?key={self.ratingKey}&identifier=com.plexapp.plugins.library&time={time}&state={state}'
```
This sets the view offset directly (`time` in ms; **note: time=0 is ignored** — use scrobble/unscrobble to zero it). It's simpler than `/:/timeline` but does **not** participate in play-queue progression or hub attribution. **Prefer `/:/timeline` for a real client; `/:/progress` is a fallback for "just set the resume point."** (Confidence: high — verbatim from base.py.)

---

## 2. Mark watched / unwatched — `/:/scrobble` & `/:/unscrobble`

- **Mark watched:** `GET /:/scrobble?key=<ratingKey>&identifier=com.plexapp.plugins.library`
- **Mark unwatched:** `GET /:/unscrobble?key=<ratingKey>&identifier=com.plexapp.plugins.library`
- **Method:** GET. **Official** (portal "Mark an item as played / unplayed"). (Confidence: high.)

**Note the param name quirk:** here `key` holds the **ratingKey** (a number), not the `/library/metadata/...` path. (In `/:/timeline`, `key` is the path and `ratingKey` is the number — they're swapped. Easy to get wrong.) (Confidence: high.)

plex-for-kodi (`plexnet/video.py`):
```python
def markWatched(self):
    self.server.query('/:/scrobble?key=%s&identifier=com.plexapp.plugins.library' % self.ratingKey)
def markUnwatched(self):
    self.server.query('/:/unscrobble?key=%s&identifier=com.plexapp.plugins.library' % self.ratingKey)
```
(Confidence: high — verbatim.)

### View-offset vs. fully-watched — they are different states
Plex tracks two things per item:
- **`viewOffset`** (ms) — a *partial* resume point. Set by `/:/timeline`/`/:/progress`. An item with a viewOffset between ~5% and ~90% shows up in **On Deck / Continue Watching** with a progress bar.
- **`viewCount`** / **watched** flag — *fully watched*. Set by `/:/scrobble`. This **clears** the viewOffset and removes the item from On Deck; `/:/unscrobble` resets viewCount to 0 (and also clears the offset).

The server **auto-scrobbles** (marks watched) when a `/:/timeline` report arrives near the end (default threshold ~90% of duration). So in normal playback you rarely call `/:/scrobble` yourself — it's for the explicit "Mark as watched/unwatched" UI affordance and for forcing the state. (Confidence: high for the mechanism; the exact 90% threshold is server-configurable and community-documented — medium.)

---

## 3. Play Queues — `POST /playQueues`

A **play queue (PQ)** is the server-side ordered list the client plays through. It's what makes "next episode," shuffle, repeat, and the `playQueueItemID` (which `/:/timeline` wants) work.

### When is a PQ required vs. playing a single item?
- **Single item, no progression needed** (e.g. play one movie, no shuffle, no auto-next): you *can* skip the PQ and just stream the item + report timeline with `ratingKey`/`key` only. On Deck/resume still works via timeline.
- **You need a PQ when:** TV episode auto-advance ("play next"), shuffle, repeat, "play all" of a season/album/playlist, or anything where the server should know what comes next. A PQ is also what gives you a stable `playQueueItemID` to report. **For a real "watch a show" experience, always create a PQ.** (Confidence: high.)

### Creating one
- **Path:** `POST /playQueues`
- **Body:** empty (`body=''`); everything is query params.
- **Params:**

| Param | Meaning | Source/confidence |
|---|---|---|
| `uri` | The source descriptor — **see URI construction below**. Required (unless `playlistID` for a playlist) | plex-for-kodi (high) |
| `type` | `video` \| `audio` \| `photo` (the content type) | plex-for-kodi (high) |
| `key` | The specific item to *start* on (e.g. the chosen episode's `/library/metadata/<id>`). Omitted when shuffling | plex-for-kodi + python-plexapi (high) |
| `shuffle` | `0` / `1` | both (high) |
| `repeat` | `0` off / `1` one / `2` all | python-plexapi/kodi (high) |
| `continuous` | `0`/`1` — keep auto-playing related content | python-plexapi (medium) |
| `includeChapters` | `1` to include chapter markers (kodi defaults to 1) | plex-for-kodi (high) |
| `includeRelated` | `1` to include related/post-play | plex-for-kodi (high) |
| `extrasPrefixCount` | number of pre-roll extras/trailers | plex-for-kodi (medium) |
| `playlistID` | use instead of `uri` when the source is a playlist | plex-for-kodi (high) |

**URI construction** (the tricky part — plex-for-kodi `createRemotePlayQueue`, high confidence):
- Base: `library://<librarySectionUUID>/`
- Then `<itemType>/<url-encoded path>` where `itemType` is `item` or `directory`.
- **For a TV episode** (so the PQ contains the whole show/season and can advance): use the **show** as the directory and the **episode** as the start `key`:
  ```
  uri  = library://<sectionUUID>/directory/<urlencoded("/library/metadata/<grandparentRatingKey>")>
  key  = /library/metadata/<episodeRatingKey>
  type = video
  ```
- **For a single movie:** `uri = library://<sectionUUID>/item/<urlencoded("/library/metadata/<ratingKey>")>`, `type=video`.
- python-plexapi's simpler form for arbitrary items: `uri = "library:///directory/<url-encoded comma-joined metadata keys>"`, or for playlist items `server://<machineIdentifier>/<libIdentifier><itemKey>`. (Confidence: high — from `playqueue.py`.)

### The response
`POST /playQueues` returns a `MediaContainer` with:
- `playQueueID` — the queue id,
- `playQueueSelectedItemID` / per-item `playQueueItemID` — the currently selected item's id (**this is what you put in `/:/timeline`**),
- `playQueueSelectedItemOffset`, `playQueueVersion`, and the ordered item list (each child has its own `playQueueItemID`).
(Confidence: high — python-plexapi `PlayQueue` parses exactly these.)

### Episode progression / queue ops (all under `/playQueues/<id>`)
- **Advance to next episode:** select the next child's `playQueueItemID` and start playing it, reporting timeline against the new id. plex-for-kodi tracks this as `selectedId` and has `next()/prev()/setCurrent()` over the item list. (Confidence: high.)
- **Refresh the window:** `GET /playQueues/<id>` (the server returns a sliding window; clients refresh to pull more upcoming items).
- **Shuffle:** `PUT /playQueues/<id>/shuffle` / `PUT /playQueues/<id>/unshuffle`.
- **Add item ("Up Next"):** `PUT /playQueues/<id>?uri=<itemUri>` (optionally `&next=1`).
- **Move:** `PUT /playQueues/<id>/items/<playQueueItemID>/move?after=<id>`.
- **Remove:** `DELETE /playQueues/<id>/items/<playQueueItemID>`.
- **Clear:** `DELETE /playQueues/<id>` (keeps current, clears rest) — Clear-a-play-queue in the official portal.
(Confidence: high — paths verbatim from plexnet `playqueue.py`; corroborated by official portal "Add/Clear/Move/Shuffle".)

---

## 4. Home hubs / On Deck / Continue Watching / Recently Added

These build the Home screen. All return a `MediaContainer` of `Hub`s (or items). Confirmed verbatim from python-plexapi `server.py` / `library.py` and the official portal Hubs section. (Confidence: high.)

| Purpose | Endpoint | Notes |
|---|---|---|
| **Global Home hubs** (the whole Home screen in one call) | `GET /hubs` | Returns multiple `Hub`s (On Deck, Continue Watching, Recently Added per section, etc.) with `hubIdentifier` like `home.ondeck`, `home.continue`, `home.television.recent`. Filter with `?identifier=…` and `?contentDirectoryID=<sectionID>`. **This is the one call to build Home.** |
| **Continue Watching (global)** | `GET /hubs/continueWatching/items` | Flat list of in-progress items across libraries. Official: "Get the continue watching hub." |
| **On Deck (global)** | `GET /library/onDeck` | Next-up items (next unwatched episode of in-progress shows + partially watched). |
| **Recently Added (global)** | `GET /library/recentlyAdded` | Newly added across libraries. Add `?X-Plex-Container-Start=0&X-Plex-Container-Size=50` to paginate. |
| **Section hubs** | `GET /hubs/sections/<sectionKey>` | Per-library hubs (`?includeStations=1` for music). |
| **Section On Deck** | `GET /library/sections/<sectionKey>/onDeck` | |
| **Section Continue Watching** | `GET /hubs/sections/<sectionKey>/continueWatching/items` | |
| **Section Recently Added** | `GET /library/sections/<sectionKey>/recentlyAdded` (or `/library/sections/<key>/all?type=…&sort=addedAt:desc`) | `recentlyAdded(maxresults, libtype)` in python-plexapi. |
| **Hub search** (search box) | `GET /hubs/search?query=<q>&limit=<n>` | Cross-library typed search. |

**How clients build Home:** one `GET /hubs` (optionally per-section) → render each returned hub as a horizontal row, in the order/visibility the server provides (the server already honors the user's "manage home" settings). Each hub's items carry `viewOffset`/`viewCount` so you draw progress bars directly. (Confidence: high.)

---

## 5. Resume — reading & writing `viewOffset`

- **Read:** every item's metadata (`GET /library/metadata/<ratingKey>`, or items embedded in hub/PQ responses) carries **`viewOffset`** (ms, present only if partially watched) and **`viewCount`** (≥1 if watched), plus `duration`. python-plexapi exposes `video.viewOffset`. (Confidence: high.)
- **Resume:** if `viewOffset` is present and not ~complete, seek the player to `viewOffset` ms on start (and pass it as the start `time` in your first timeline report / as the PQ start). plex-for-kodi deletes the cached `viewOffset` on `reload()` so it always re-reads fresh from the server. (Confidence: high.)
- **Write-back:** done **only** via `/:/timeline` (or `/:/progress`) `time=` reports during playback. There is no separate "set offset" endpoint — the heartbeat is the write path. A `stopped` report at `time=<offset>` persists the final resume point. (Confidence: high.)
- **Clearing resume:** `/:/scrobble` (watched) or `/:/unscrobble` (unwatched) both clear the offset; `time=0` on timeline/progress is ignored, so you cannot zero the offset via timeline. (Confidence: high.)

There's an older forum-documented `PUT /library/metadata/<id>?viewOffset=<ms>` style write ([forum thread](https://forums.plex.tv/t/api-set-viewoffset-cli-client-prototype/287507)) but it's non-standard/reverse-engineered — **prefer timeline.** (Confidence: medium, flagged reverse-engineered.)

---

## 6. Live state — WebSocket / EventSource (optional)

For a single playing client you do **not** need this — your own player already knows its state, and `/:/timeline` is the only thing the *server* needs from you.

You'd want it only to keep the **Home screen / library views live** (another device marks something watched, a download finishes, On Deck reshuffles) without polling:
- **WebSocket alerts:** `ws://<server>/:/websockets/notifications?X-Plex-Token=<token>` — pushes `playing`, `timeline`, `activity`, `status` notifications. Reverse-engineered but extremely stable and widely used (Tautulli is built on it). (Confidence: high that it exists/works; it's community-documented.)
- **EventSource:** `GET /:/eventsource/notifications` (SSE) — the official portal documents an **Events** section (EventSource + WebSocket). (Confidence: high it's documented; medium on exact path.)

**Recommendation for the visionOS client:** ship without it for v1 (timeline + manual refresh-on-foreground is enough). Add the WebSocket later purely as a UX nicety to live-update Home/On Deck. **Not worth it for correctness; worth it eventually for polish.** (Confidence: high — this matches how Tautulli/secondary clients use it: observation, not control.)

---

## Source reliability summary

| Area | Best source | Status |
|---|---|---|
| `/:/timeline` params + cadence | python-plexapi `base.py`, plex-for-kodi `nowplayingmanager.py` | Reference-client verbatim (high). Now also official portal. |
| `/:/scrobble`/`/:/unscrobble` | plex-for-kodi `video.py`, python-plexapi | Verbatim (high). Official. |
| `POST /playQueues` + URI rules | plex-for-kodi `playqueue.py`, python-plexapi `playqueue.py` | Verbatim (high). Official endpoint list. |
| Hubs / onDeck / continueWatching / recentlyAdded | python-plexapi `server.py`/`library.py` | Verbatim (high). Official. |
| `hasMDE`/`context`/`playBackTime`/`row` timeline params | LukeHagar community spec / SDK docs | Reverse-engineered (medium) — optional, safe to omit. |
| WebSocket/EventSource | Tautulli usage, official Events section | Community-stable (high) / officially documented (medium on path). |
| `PUT …?viewOffset=` direct write | Plex forum prototype | Reverse-engineered (medium) — avoid; use timeline. |

**Plex-Pass gating:** none. All playback-state plumbing here is free-tier core API.

---

## Sources
- [Plex developer portal — PMS API v1.2.2 (Timeline, Play Queues, Status, Hubs)](https://developer.plex.tv/pms/) — official
- [Report media timeline — plexapi.dev (LukeHagar community spec)](https://plexapi.dev/api-reference/timeline/report-media-timeline)
- [python-plexapi — `base.py` (`updateTimeline`, `updateProgress`)](https://github.com/pkkid/python-plexapi/blob/master/plexapi/base.py)
- [python-plexapi — `library.py` / `server.py` (`hubs`, `onDeck`, `recentlyAdded`, `continueWatching`)](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/library.html)
- [python-plexapi — `playqueue.py` (`PlayQueue.create`)](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/playqueue.html)
- [plex-for-kodi — `plexnet/nowplayingmanager.py`, `video.py`, `playqueue.py`](https://github.com/plexinc/plex-for-kodi/tree/master/lib/_included_packages/plexnet)
- [plex-media-player wiki — Remote control API (timeline states, cadence)](https://github.com/plexinc/plex-media-player/wiki/Remote-control-API)
- [Plexopedia — Plex API guides](https://www.plexopedia.com/plex-media-server/api/)
- [Plex forum — API: set viewOffset & CLI client prototype](https://forums.plex.tv/t/api-set-viewoffset-cli-client-prototype/287507)
