# VisionPlex Music — Final Design (issues #17, #22)

Status: approved design, 2026-06-10. Synthesized from three design explorations
("pragmatic" base, with judge-endorsed grafts from "apple-native" and
"plexamp-faithful"). Companion docs: `docs/DEVELOPMENT.md` (platform findings),
`TESTING-CHECKLIST.md` Section C.

**Thesis:** Plexamp's perceived quality is ~80% home-screen composition + queue
visibility + blurred-art player chrome — all reachable against plain PMS hub
endpoints by *evolving* the existing music code. We do not touch the proven
`MusicPlayerController` playback core, the ornament mounting, the SIGTRAP
(`nonisolated static makeArtwork`) fix, or the gaze-highlight patterns. Server
playQueues, gapless, transcode fallback, and all Plex-Pass sonic features are
deferred to v2 behind feature detection.

---

## 1. Goals

1. **Kill "feels like an afterthought" (#22):** a hub-driven Music Home with a
   Recently Played rail that is never blank, and music restored to Search.
2. **Faceted music search (#22):** artist/album/song sections that route into
   the music views instead of being stripped (`hidingMusic`).
3. **First-class queue (#17):** Play Next / Add to Queue everywhere a track or
   album appears; visible, editable Up Next in NowPlayingView.
4. **Plexamp-grade library browsing (#17):** Artists / Albums / Playlists
   pivots, artist actions (Play / Shuffle / Popular), playlists read+play.
5. **Zero regression** to the verified platform findings and to video playback.
   Every v1 phase is independently shippable and simulator-testable.

### Non-goals for v1 (explicit scope fence — "skip indefinitely" unless re-litigated)

Visualizers, EQ/preamp, immersive album wall, music universal transcode
(opus/ogg only — direct play covers mp3/aac/alac/flac), bar volume control
(visionOS Digital Crown + system volume own this; an AVPlayer-level volume
slider would diverge from system volume — record this rationale in
`docs/DEVELOPMENT.md`), lyrics (v2, feature-detected), server-side playQueues
(v2), gapless/AVQueuePlayer (v2 spike), playlist editing (v2), alphabet index
(26 one-character gaze targets violate the 60-pt rule; a sort menu suffices),
home-row customization, TIDAL.

### Hard constraints (unchanged, load-bearing)

- `X-Plex-Client-Profile-Name=Safari` in `TranscodeRequest` is video-only and
  is touched by **nothing** in this design.
- No Plex tokens/client identifiers committed; placeholders
  `plex.example.internal` / `192.0.2.10` only.
- MiniPlayerBar stays a **bottom scene ornament** with `.glassBackgroundEffect`
  (safeAreaInset never renders on a visionOS TabView — verified).
- `MPMediaItemArtwork` request handler stays `nonisolated` (SIGTRAP fix).
- Built-in button styles are banned on music surfaces — `.card` +
  `.gazeHighlight(cornerRadius:)` matched to visual bounds only.

---

## 2. Information architecture

**Keep the app-level TabView exactly as is** (Home · Libraries · Search ·
Music · Offline · Settings). VisionPlex is a video-first client; music is one
tab, not a music-first restructure. Inside the Music tab:

```
Music tab (NavigationStack, unchanged shell)
└─ MusicHomeView (replaces MusicSectionBrowseView — the one real rewrite)
   ├─ [toolbar library Picker, unchanged, if 2+ music sections]
   ├─ Pivot (top): Home | Artists | Albums | Playlists   (+ Genres in v2)
   │   ├─ Home      → server-driven hub rails + Shuffle Library
   │   ├─ Artists   → existing adaptive grid (paged, sorted)
   │   ├─ Albums    → NEW adaptive grid (MusicRequest.albums — exists, unused)
   │   └─ Playlists → NEW list → PlaylistDetailView
   ├─ navigationDestination(MediaItem): artist / album (existing)
   │   + "playlist" case; the dead-end EmptyView() track case is DELETED
   │   (tracks never navigate — they play)
   └─ ArtistDetailView → AlbumDetailView → tracks
```

**Why a pivot, not a sidebar.** A `NavigationSplitView` sidebar inside one tab
of an existing TabView is the Apple Music shape, but it is heavy chrome for
four pivots, restructures `MusicLibraryView`'s nav-destination ownership, and
is unverified-in-this-app on visionOS. The pivot is one control + a `switch` —
near-zero regression surface. Judge-acknowledged trade-off and the answer to
"least native IA": render the pivot as a **toolbar segmented control / top
chip row sized to 60-pt gaze targets**, designed with room for a fifth
**Genres** pivot (v2). If pivots ever exceed five, the sidebar-in-tab shape is
the documented evolution path — the pivot views are self-contained, so the
shell swap is cheap later.

**Routing consolidation.** Extract `MusicLibraryView`'s destination body into a
shared `@ViewBuilder musicDestination(for: MediaItem)` so SearchView (and
later HomeView) reuses it. `MediaItem.Kind` gains `.artist/.album/.track/.playlist`
cases; routing switches on `kind`, finally using the orphaned
`isMusicContainer`.

**Where music reappears outside the Music tab:**
- **Search tab (v1):** `hidingMusic` deleted; faceted music sections route via
  `musicDestination`. (§5)
- **App Home tab (deliberately deferred to a late v1 phase / early v2):**
  relaxing `hidingMusic` to a track-only filter touches a working video
  surface — it ships as its own phase after Search proves the shared routing,
  not bundled with the headline work. `LibrariesView`'s music-section filter
  **stays** (Music has its own tab; listing the section twice is noise).

---

## 3. Screen-by-screen spec

### 3.1 MusicHomeView — Home pivot (new; replaces MusicSectionBrowseView)

```
┌──────────────────────────────────────────────────────────┐
│  [toolbar: library Picker]                               │
│  ( Home | Artists | Albums | Playlists )                 │
│                                                          │
│  Recently Played                              ⟶ rail     │
│  ▭184 ▭184 ▭184 …  (SquareArtCell; artists circular)     │
│                                                          │
│  Recently Added                               ⟶ rail     │
│  Most Played / [any other hub PMS returns]    ⟶ rails    │
│                                                          │
│  [🔀 Shuffle Library]   ← bordered pill, bottom          │
└──────────────────────────────────────────────────────────┘
```

- Hubs from `GET /hubs/sections/{key}?count=20&excludeFields=summary`,
  rendered **generically in server order**. Match `hubIdentifier` by **prefix
  only** (e.g. `music.recent.played*`) for ordering/iconography — never exact
  ids (MED-confidence, drift across PMS versions). Empty hubs dropped.
- v1 filters hub items to artist/album types (track-level hub items return in
  v2 once track rows have context menus + a play affordance in rails). This is
  deliberate; note it in TESTING-CHECKLIST so vanishing hubs aren't mistaken
  for bugs.
- **Never-a-blank-screen degradation ladder (v1, not v2):**
  1. Hubs present → render them.
  2. Recently-Played hub missing/empty → synthesize the rail from
     `GET /status/sessions/history/all?sort=viewedAt:desc&librarySectionID={id}`,
     deduped to albums (map track rows → `parentRatingKey`), same rail UI.
  3. All hubs fail → fall back to exactly today's layout: Recently Added rail
     (existing `MusicRequest.recentlyAddedAlbums`) + nudge to the Artists
     pivot. `MusicSkeleton` shimmer kept for loading.
- **Shuffle Library:** ONE un-paged request
  `all?type=10&sort=random&X-Plex-Container-Size=200` → `player.play(tracks:)`
  with shuffle on. Do **not** page `sort=random` — PMS re-randomizes per
  container page, producing duplicates. 200 tracks is hours of audio; cap and
  move on. Cheap, zero-Pass Plexamp-feel win.

### 3.2 Artists pivot

Existing adaptive grid (`SquareArtCell`, `MusicArt.gridMin/Max`), now with
explicit `sort=titleSort` and container paging (size 200, load-more on
scroll-end). Sort menu: Name / Recently Added. Keep the unpaged path behind a
constant as fallback if paging misbehaves on the user's PMS. Alphabet index:
deferred (see scope fence).

### 3.3 Albums pivot (new, trivial)

Same grid; `SquareArtCell(subtitle: parentTitle · year)`; fed by the
already-written `MusicRequest.albums`, paged; sort menu: Recently Added /
Title / Year (`addedAt:desc`, `titleSort`, `originallyAvailableAt:desc`).

### 3.4 Playlists pivot + PlaylistDetailView (new, read-only v1)

- Pivot: card rows — 56-pt composite art, title, "N tracks". 60-pt targets,
  `.card` + `.gazeHighlight`.
- `PlaylistDetailView`: structural clone of AlbumDetailView minus year header
  and disc sort (**preserve playlist order**; items via
  `/playlists/{rk}/items`). Play / Shuffle buttons. Per-row art 44-pt (art
  varies across a playlist). No create/edit/reorder in v1.

### 3.5 ArtistDetailView (evolve in place — keep skeleton)

```
│ (○ 160 art)  ARTIST NAME                     │
│              bio, 3 lines                    │
│              [▶ Play]  [🔀 Shuffle]          │  ← NEW
│  Popular ──────────────────────────────────  │  ← NEW, hidden if empty
│   1  Track title                     3:42    │  (top 5, material card,
│   …                                          │   same TrackRow pattern)
│  Albums ───────────────────────────────────  │  (existing grid, year)
```

- Play/Shuffle artist: `GET /library/metadata/{rk}/allLeaves` →
  `player.play(tracks:)` / `playAlbumShuffled(tracks:)` — zero controller
  changes.
- Popular: section search
  `type=10&artist.id={rk}&group=title&ratingCount>>=0&sort=ratingCount:desc&limit=5`.
  **MED-confidence query** (reverse-engineered from python-plexapi; the `>>=`
  operator lives in the *param name* and needs careful URL encoding) — verify
  against live PMS before building UI; hide the section if it errors/empties.
  Tapping a popular track plays the popular list as the queue.
- Similar-artists / Radio: v2, probe-gated (§6).

### 3.6 AlbumDetailView — keep wholesale

The backdrop/header/track-card treatment is already the Plexamp-signature
look; the `.card` + inset `.gazeHighlight(cornerRadius: DS.Radius.chip)` row
pattern (the #20 fix) is untouchable. Only additions:

- Per-row **context menu**: Play Next / Add to Queue / Go to Artist.
  ⚠️ Prototype `.contextMenu` on ONE TrackRow first — it may interact badly
  with the custom `.card` hover chrome (risk §10.4). If it misbehaves, the
  fallback is a trailing `…` ellipsis button with a `Menu`.
- "Go to Artist" in the header (push `parentRatingKey` metadata via the shared
  `musicDestination`).

---

## 4. Now Playing: bar + screen

### 4.1 MiniPlayerBar (evolve in place)

```
╭──────────────────────────────────────────────────────────╮
│ ▭44 Title           ⏮   ⏯   ⏭        ☰ queue            │
│     Artist                                               │
│ ▁▁▁▁▁▁▁▁▔▔▔▔▔▔▔▔▔▔▔▔▔  ← 3-pt passive progress hairline  │
╰──────────────────────────────────────────────────────────╯
```

- **Keep:** ornament mounting (`.ornament(attachmentAnchor: .scene(.bottom))`
  on the TabView, RootView), `.glassBackgroundEffect(in:)`, EmptyView when
  idle, tap-anywhere → NowPlaying sheet. **Delete** the debug NSLog at
  MiniPlayerBar.swift:17.
- **Add:** ⏮ previous (controller already has it); ☰ queue button that opens
  NowPlayingView **pre-scrolled to Up Next** (ScrollViewReader anchor); a
  **passive** 3-pt progress hairline along the bottom edge — explicitly NOT a
  scrub target (a 3-pt drag target violates the 60-pt rule; scrubbing lives in
  the sheet). A hover-growing thin scrubber may be trialed in v2; the passive
  hairline is the documented fallback. Max width 480 → 560. All targets ≥60 pt
  total space, ≥8-pt gaps.
- **No volume control, no shuffle/repeat in the bar** (state visible in the
  sheet; bar stays glanceable). Volume rationale → `docs/DEVELOPMENT.md`.

### 4.2 NowPlayingView (evolve — keep scrub-state pattern + explicit ✕)

Keep everything: blurred-art backdrop, 420-pt hero art, local
`isScrubbing`/`scrubSeconds` scrub pattern, transport row, repeat-icon
cycling, error capsule, topTrailing ✕. Additions to the Up Next card:

- **Reorder**: `List` + `.onMove` drag handles (display-order move; controller
  rebuilds `playOrder` respecting shuffle).
- **Remove**: swipe-to-delete → `player.remove(at:)`.
- **Clear queue** footer button → `player.clearUpcoming()`.
- Row tap → existing `jump(to:)`. Current row keeps the tinted waveform.
- If `.onMove` drag handles prove finicky under gaze input, fallback is
  context-menu Move Up/Down actions.

Lyrics pane, history-on-swipe-down, output picker: v2 or never (scope fence).
v2 flourish (judge-endorsed, server-side, no client shaders): backdrop tint
via `/photo/:/transcode` `blur`/`blendColor` params.

### 4.3 MusicPlayerController — the ONLY controller surgery (additive)

Kept untouched: queue/playOrder model, per-track `TimelineReporter` lifecycle,
failure auto-advance without wrap, `pauseForVideo`/reclaim handshake, `stop()`
teardown, remote commands, `nonisolated static makeArtwork`,
`AudioSessionCoordinator(.default, pausesOnBackground: false)`, direct-play
`trackStreamURL`. New API:

```swift
func playNext(_ tracks: [MediaItem])   // insert after currentIndex in queue + after current in playOrder
func addToQueue(_ tracks: [MediaItem]) // append to queue + playOrder tail
func remove(at queueIndex: Int)        // fix up currentIndex/playOrder; removing current → advance
func move(from: IndexSet, to: Int)     // display-order reorder; rebuild playOrder respecting shuffle
func clearUpcoming()
```

**Gate (judge-mandated):** the queue/playOrder/currentIndex index math is
extracted into a **pure, unit-testable helper** (e.g. `struct QueueMutation`
with value-in/value-out functions) BEFORE wiring into the controller. The
AVPlayer/observer code paths are never touched. Semantics stay dead simple:
Play Next = immediately after current; Add to Queue = append (no Plexamp
"after the previously added block" subtlety).

Surfaced via context menu (with the §3.6 prototype caveat) on every track row
(album, playlist, popular, search) and on album cells (Play / Shuffle /
Play Next / Add to Queue).

---

## 5. Search faceting

`SearchView` changes from "strip music" to "facet everything":

```
[ search field ]
( All | Video | Music )            ← scope segmented control
─ Artists ─────────  ⟶ horizontal rail (circular SquareArtCells)
─ Albums ──────────  ⟶ horizontal rail
─ Songs ───────────  ⟶ vertical list ≤5 + "More"; row = 44pt art · title · artist · ▶
─ Movies / Shows ──  ⟶ existing PosterCell rails (unchanged)
```

- Endpoint: existing `BrowseAPI.search` (`/hubs/search?limit=30`) — PMS
  already returns per-type hubs; the UI stops calling `.hidingMusic`. Music
  scope adds `searchTypes=artist,album,track,playlist` (+ `sectionId` when a
  music section is selectable).
- **Pre-build verification (judge-mandated):** curl `/hubs/search` against the
  live PMS and confirm the music-hub decode shape (artist/album/track hubs
  separate cleanly through the existing `Hub` model) before building rails.
- Routing: artist/album/playlist results push via the shared
  `musicDestination(for:)` (`isMusicContainer` finally earns its keep);
  everything else keeps `DetailView`. Track tap = **play immediately**
  (single-hub-results queue); context menu: Play Next / Add to Queue /
  Go to Album.
- Recent searches: last 10 queries, UserDefaults-backed chip row in the empty
  state. Cheap, Plexamp-flavored.
- Video search paths are purely additive-guarded (`kind`/`isMusicContainer`
  checks) — zero change to non-music routing.

---

## 6. Data layer (endpoints → PMSKit)

Living artifact — keep this table updated as builders land. All new builders
are pure URL constructors with unit tests in PMSKit (`MusicRequestTests`
style). Confidence: ✅ = confirmed (python-plexapi source or already proven in
this repo), ⚠️ = verify against live PMS before building UI on it.

| Surface | Endpoint | PMSKit status | Conf. |
|---|---|---|---|
| Home rails | `GET /hubs/sections/{key}?count=20&excludeFields=summary` | **new** `MusicRequest.sectionHubs` (`Hub` decodes already) | ✅ path, ⚠️ hub ids → prefix-match only |
| Recently-Played fallback | `GET /status/sessions/history/all?sort=viewedAt:desc&librarySectionID={id}` | **new** `MusicRequest.playHistory` | ✅ |
| Artists pivot | `all?type=8&sort=titleSort` + `X-Plex-Container-Start/Size` | extend `MusicRequest.artists` (sort+paging) | ✅ |
| Albums pivot | `all?type=9&sort=…` + paging | extend `MusicRequest.albums` | ✅ |
| Shuffle Library | `all?type=10&sort=random&Size=200` — **single request, never paged** | **new** `MusicRequest.randomTracks` | ✅ (re-randomizes per page) |
| Artist Play/Shuffle | `GET /library/metadata/{rk}/allLeaves` | **new** `MusicRequest.allLeaves` | ✅ |
| Artist Popular | `type=10&artist.id={rk}&group=title&ratingCount>>=0&sort=ratingCount:desc&limit=5` | **new** `MusicRequest.popularTracks` | ⚠️ query shape + `>>=` encoding |
| Playlists | `GET /playlists?playlistType=audio` / `GET /playlists/{rk}/items` | **new** `PlaylistRequest` (read-only) | ✅ |
| Search facets | `/hubs/search` + `searchTypes=` for music scope | exists (`BrowseAPI.search`); add params | ✅ path, ⚠️ decode shape |
| Genres (v2) | `/library/sections/{key}/genre?type=9` → browse via `fastKey` | new, v2 | ✅ |
| Sonic similar / stations (v2, Pass) | `/library/metadata/{rk}/nearest`, `?includeStations=1` | new, v2, **probe-gated**: one cached probe per ratingKey; 404/empty → UI absent | ⚠️ |
| Track stream | `MusicRequest.trackStreamURL` (raw part, no `download=1`) | **keep untouched** | ✅ proven |
| Artwork | `/photo/:/transcode` (+ `blur`/`blendColor` v2 tint) | existing; extend v2 | ✅ |
| Scrobble/timeline | `TimelineRequest` (`/:/timeline`, `/:/scrobble`) | keep | ✅ proven |

`MediaItem` additive optional decodes (PMSKit, unit-tested):
`originalTitle` (compilation track artist), `lastViewedAt`, `parentYear`,
`ratingCount`. `MediaItem.Kind` gains `.artist/.album/.track/.playlist`.

**Deferred data work (v2):** server playQueues (`POST /playQueues?type=audio`)
+ `playQueueItemID` on timelines (first-class history/cross-device), music
universal transcode (`/music/:/transcode/universal/start.m3u8` — note `music`
prefix; only needed for opus/ogg), lyrics (Stream type-4 detection), `/:/rate`.

---

## 7. Existing code: keep / change / delete

**Keep untouched (verified, hard-won, or load-bearing):**
- `MusicPlayerController` core (extend-only per §4.3).
- MiniPlayerBar ornament mounting + `.glassBackgroundEffect`
  (PlexAVPApp/UI/RootView.swift ornament mount).
- AlbumDetailView treatment + the #20 inset-gazeHighlight row pattern.
- NowPlayingView scrub-state pattern + explicit ✕.
- `SquareArtCell`/`MusicArt`, all existing `MusicRequest` builders,
  `trackStreamURL` (no-`download=1` rationale), disc/track sort, library
  Picker, all four `pauseForVideo` call sites + `stop()` on sign-out.
- `LibrariesView` music-section filter (stays — see §2).

**Change:**
- `MusicSectionBrowseView` → `MusicHomeView` with pivots (the one rewrite; one
  file in MusicLibraryView.swift).
- `MusicLibraryView`: extract shared `musicDestination(for:)`; add
  `"playlist"` case; **delete** the `EmptyView()` track-destination dead end.
- `ArtistDetailView`: + Play/Shuffle/Popular.
- `SearchView` (SearchView.swift:57): drop `hidingMusic`, add scope + music
  routing + recent searches.
- `HomeView` (HomeView.swift:231): relax `hidingMusic` →
  `hidingMusicTracks` — **its own late phase**, after Search proves routing.
- `NowPlayingView`: queue reorder/remove/clear + pre-scroll anchor.
- `MiniPlayerBar`: + previous, + queue button, + passive hairline, − NSLog
  (MiniPlayerBar.swift:17), width 560.
- `MediaItem.Kind` (PMSKit MediaItem+Hierarchy.swift): music cases.
- `docs/DEVELOPMENT.md`: record the no-bar-volume rationale and any new
  verified findings (contextMenu-on-card behavior, onMove-under-gaze).

**Delete:** `Array<Hub>.hidingMusic` (replaced by track-only filter, in its
phase), the MiniPlayerBar debug NSLog, the EmptyView() track destination.

---

## 8. Implementation plan — ordered, independently-buildable phases

Each phase builds, ships, and is simulator-testable on its own;
TESTING-CHECKLIST.md Section C is extended as part of every phase, not at the
end. **v1 = phases 0–7.**

- **Phase 0 — Live-PMS verification spike (½ day, no app code).**
  curl against the real server: (a) `/hubs/sections/{key}` — which hubs exist,
  their identifiers and item types; (b) does Recently Played advance from our
  existing timeline/scrobble reports (play a track, re-check), or do we need
  the history fallback as primary; (c) `/hubs/search` music-hub decode shape;
  (d) the popular-tracks query incl. `>>=` encoding. Findings recorded here
  and in DEVELOPMENT.md. *This de-risks the only design-shaping unknowns.*

  **Phase-0 FINDINGS (live PMS, June 2026):**
  - Section hubs returned: `music.recent.played.1` (type=ARTIST, not album/track),
    `music.recent.added.1` (album), `music.recent.artist.1`, `music.top.period.1`,
    `music.recent.genre.1`, `music.popular.1` ("Most Played in April", album),
    `music.vault.1`, `music.recent.label.1`, `music.touring.1`, `music.videos.new.1`
    (clip). Several size=0. → prefix-match works; the played hub is artists, so
    the app renders its own Recently Played SONGS rail from `playHistory` instead.
  - **`/library/metadata/{rk}/children` UNDER-LISTS artist discographies**:
    returned size=0 for an artist owning two singles (both with parentRatingKey
    pointing at him), and dropped an appears-on album for another. Own albums
    must come from `…/all?type=9&artist.id={rk}` (plexapi shape). Children stays
    only as the no-sectionKey fallback.
  - **Appears On**: compilation tracks carry the performing artist as the track's
    `originalTitle` TEXT, NOT linked to the artist node (every artist-scoped hub
    showed 0 while the tracks existed). Query: `…/all?type=9&
    track.originalTitle={artist title}` — EXACT match only; PMS has no contains
    operator on the wire (`~=` is silently ignored), so "Artist feat. X" credit
    strings are missed (known v1 limitation).
  - **`/library/metadata/{rk}/related`** provides Plexamp's artist-page shelf
    taxonomy as hubs: `artist.albums.singles` "Singles & EPs", `.live`,
    `.soundtrack`, `.compilation`, `.demo`, `.remix`, plus `artist.similar`.
  - **popularTracks verified**: sensible `ratingCount:desc` ordering, rows carry
    Media/Part (directly playable), `album.subformat!` exclusion honored.
  - **#4 probe**: transcode master playlist has NO `EXT-X-I-FRAME-STREAM-INF`
    (only `#EXT-X-STREAM-INF`) — no free trick-play thumbnails on this PMS.
- **Phase 1 — PMSKit builders + tests.** `sectionHubs`, `playHistory`,
  `randomTracks`, `allLeaves`, `popularTracks`, `PlaylistRequest`,
  paging/sort params on `artists`/`albums`, `MediaItem` field + `Kind`
  additions. Pure URL builders + decodes; zero app risk.
- **Phase 2 — MusicHomeView.** Pivot shell + Home rails with the full
  degradation ladder (hubs → history fallback → recently-added), Shuffle
  Library, Albums pivot, artists paging/sort. *Kills #22's headline gap.*
- **Phase 3 — Search faceting.** Shared `musicDestination`, scope control,
  faceted sections, track tap-to-play, recent-search chips. *Kills "weak
  faceting".*
- **Phase 4 — Queue.** Pure `QueueMutation` helpers + unit tests FIRST, then
  controller wiring, then UI: contextMenu prototype on one AlbumDetailView row
  (verify against `.card` hover chrome), fan out menus, NowPlayingView
  reorder/remove/clear + pre-scrolled queue button.
- **Phase 5 — Artist actions + Playlists.** Play/Shuffle artist, Popular
  section (gated on Phase-0 verification), Playlists pivot +
  PlaylistDetailView (read/play).
- **Phase 6 — MiniPlayerBar polish.** Previous, queue button, passive
  hairline, NSLog removal, width.
- **Phase 7 — App Home relaxation.** `hidingMusic` → `hidingMusicTracks` on
  HomeView, music hub items route via `musicDestination`. Isolated phase
  because it touches a working video surface; full video-regression pass per
  checklist.

**v2 (in rough order of value):** Genres pivot (`fastKey` browse — cheap,
confirmed), track-level hub items on Home rails, server playQueues +
`playQueueItemID` timelines, lyrics (Stream type-4 detected), gapless
AVQueuePlayer spike, audio transcode fallback, playlist editing, Pass-gated
sonic rows + artist radio behind cached probes, hover-growing bar scrubber
experiment, server-side blur/blendColor backdrop tints, poster-style detached
art window.

---

## 9. Risks & mitigations

1. **Recently Played may not advance from timeline-only reports** (history may
   key off `playQueueItemID`). → Phase 0 verifies; history-endpoint fallback
   is wired into v1 (same rail UI, different feed); server playQueues pull
   into v1.5 only if both fail.
2. **Hub identifier variance across PMS versions.** → render server-ordered
   hubs generically; prefix-match only.
3. **playOrder bookkeeping under shuffle** in remove/move/playNext. → pure
   extracted helpers + unit tests gate Phase 4; AVPlayer/observer paths
   untouched.
4. **`.contextMenu` on `.card`-styled gaze-highlighted rows** may fight the
   custom hover chrome. → prototype on one row first; `…`-button `Menu`
   fallback.
5. **Search/Home routing regressions for video.** → music branches purely
   additive behind `kind`/`isMusicContainer`; Home relaxation isolated in
   Phase 7 with its own regression pass.
6. **Artists paging changes a known-good screen.** → unpaged fallback path
   retained.
7. **`sort=random` re-randomizes per page.** → Shuffle Library is a single
   capped request, never paged.
8. **`.onMove` drag-reorder under gaze input may be finicky.** → context-menu
   Move Up/Down fallback.

---

## 10. Open questions for the maintainer

1. **Phase 0 result dependency:** if the live PMS shows Recently Played hubs
   do NOT advance from our scrobbles, is promoting the history endpoint to the
   *primary* rail source acceptable for v1, or should server playQueues jump
   the queue into v1.5?
2. **Multiple music sections:** the toolbar Picker scopes everything today.
   Should Recently Played merge across sections (history endpoint can), or
   stay per-section? (Design assumes per-section for v1.)
3. **Shuffle Library cap:** 200 tracks acceptable, or accept known duplicates
   and page deeper?
4. **Pivot vs sidebar:** comfortable with the segmented pivot for v1 given the
   documented sidebar evolution path, or is the Apple-Music sidebar shape
   worth the `NavigationSplitView`-in-TabView smoke test now?
5. **Track results in app-Home rails (Phase 7):** drop track-level hubs
   entirely, or render them with tap-to-play like Search?
6. **Recent-searches persistence:** UserDefaults fine, or should it sync via
   Plex bookmarks someday (Plexamp does)? v1 assumes local-only.
7. **Compilation track artists:** once `originalTitle` decodes, TrackRow shows
   it over `grandparentTitle` — any objection?
