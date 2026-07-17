# Mobile Media-Server Client UX Reference

> **Archived research snapshot:** retained as dated evidence, not current architecture, feature
> status, or implementation guidance. Verify any reusable detail against the active docs and
> current source; old `VisionPlay` names, issue links, branches, and paths below are historical.

**Purpose:** Catalog the feature set, menu structure, and information architecture of mature native iOS/iPadOS media-server clients (Plex, Emby, Jellyfin/Swiftfin) to serve as a UX/feature vocabulary for a planned, personal-use **Apple Vision Pro (visionOS) Plex client**. The goal is to understand what a "complete" client looks like, then deliberately choose a focused subset for an MVP.

**Date:** June 2026. All UI described below is sourced from official support docs, App Store listings, project documentation, and reviews (see Sources). Nothing here is invented; where a feature's presence on iOS specifically was uncertain, it is flagged.

---

## 1. Top-level navigation / menu structure

### Plex (official iOS/iPadOS)
Plex has shifted from a per-server browser to a content-discovery hub. The structure:

- **Bottom tab bar (primary nav):**
  - **Libraries** — your favorited Plex Media Server libraries (the "your own media" part).
  - **Live TV** — free ad-supported streaming channels + local antenna/tuner content.
  - **On Demand** — free movies & shows plus rentals.
  - **Discover** — trending/popular content, friend activity, recommendations.
- **Top header (persistent):**
  - **Search** (universal: local media, streaming services, people, watchlist).
  - **Cast** (Chromecast / AirPlay).
  - **Watchlist** (save-for-later across sources).
  - **User Menu** (top-right avatar): profile, friends list, streaming services, **Downloads**, **app settings**, and **profile/user switching**.
- **Secondary nav (horizontal scrollable tabs)** appears inside any section. Within a library: **Recommended · Browse · Collections · Categories** (Categories requires Plex Pass).

> Note: Plex's "your media" lives behind the **Libraries** tab; Downloads and Settings are buried in the **User Menu**, not the tab bar. This is a discovery-first design that a personal-use app does not need to replicate.

### Emby (official iOS)
- Startup connection wizard → server selection.
- **Home screen** with reorderable/disableable sections (e.g. **Continue Watching**, **Latest Media**, **Next Up**, plus per-library latest rows). Home sections are heavily customizable (server- and client-side).
- **My Media / Libraries** grid of all libraries (Movies, TV, Music, Photos, Live TV).
- **Live TV** with guide.
- **Settings / Playback** section.
- **Cast** icon (Chromecast) top-right.
- Downloads accessed via a **Downloads area** (and per-item "Download" / "Download to…" actions).

### Jellyfin — Swiftfin (popular third-party, de-facto official iOS client)
Deliberately minimal, native SwiftUI. As of v1.4/1.5 (early 2026):
- **Three-tab bar: Home · Search · Media** (Media = the libraries browser). (Custom/pinnable tabs are a requested feature, not yet shipped.)
- **Home tab:** carousels like **Continue Watching / Next Up**, **Recently Added**, **Latest Movies**, per-library latest.
- **Search tab.**
- **Media tab:** list of libraries → paged grid.
- **Settings** reached via a gear icon (server selection, playback, bitrate, player choice, experimental features).
- **User/server switcher** on a dedicated user-selection screen at launch (multi-server, multi-user).

### Nav structure comparison

| Aspect | Plex | Emby | Swiftfin (Jellyfin) |
|---|---|---|---|
| Primary nav | Bottom tabs: Libraries / Live TV / On Demand / Discover | Home + My Media + Live TV + Settings | Bottom tabs: Home / Search / Media |
| "Home" hub | Inside Libraries / top-level rows | Dedicated, customizable Home | Dedicated Home |
| Search | Persistent top-header, universal | In-app, scoped | Dedicated tab |
| Live TV | First-class tab | First-class | Not emphasized |
| Downloads | User Menu → Downloads | Downloads area + per-item | Roadmap / partial (see §5) |
| Settings | User Menu → Settings | Settings section | Gear icon |
| Server/user switch | User Menu (profile switch) | Connection wizard | Launch user/server screen |
| Design bias | Discovery-first (Plex content) | Self-hosted media-first, customizable | Minimal, media-first |

**Takeaway for visionOS:** The *essential* common denominator across all three is **Home (hubs) + Browse (libraries grid) + Search + Detail + Player + Settings**. Plex's Discover/On Demand/Live TV and Watchlist are Plex-ecosystem features, not core to a personal-media client.

---

## 2. Library / browse experience

**Hubs (home rows)** — consistent vocabulary across all three:
- **Continue Watching** (Plex/Emby/Swiftfin) — partially-watched resume.
- **On Deck / Next Up** — next unwatched episode in a series (Plex "On Deck"; Emby/Jellyfin "Next Up").
- **Recently Added / Latest** — newest items, often per-library.
- Plex adds Discover/On Demand/Live TV rows; these are out of scope for personal media.

**Library grid & browse:**
- Grid of poster artwork is the default; **List** and **Summary** views also offered (Plex). Swiftfin pages results (default 50/page) and supports grid/list.
- **Browse by Folder** — raw on-disk folder hierarchy (Plex offers this for all media types; sticky setting).

**Filtering & sorting:**
- **Sort** by name, date added, release date, rating, etc., with an ascending/descending toggle.
- **Filter** by genre, year, unwatched, content rating, tags, resolution, etc. Swiftfin filters by genre, tag, year, item type, with sort field + direction (pulled from the Jellyfin API).

**Organizational containers:**
- **Collections** — first-class in Plex (own secondary tab) and Emby; Swiftfin renders collections as item types.
- **Genres / Categories** — Plex "Categories" tab (Plex Pass); genre browse in all.
- **Playlists** — supported in Plex and Emby; smart playlists server-side.

---

## 3. Media detail screen

Common elements across the three clients:
- **Artwork / backdrop** (poster + fanart hero), title, year, runtime, content rating.
- **Synopsis / overview.**
- **Ratings** (critic/audience/community; Plex shows Rotten Tomatoes + your star rating).
- **Cast & crew** (tappable to people/credits view — confirmed in Swiftfin's `ItemView` and Plex/Emby).
- **Genres / tags.**
- **Play button** (resume vs. play-from-start) + **progress bar** on watched items.
- **Mark watched / unwatched** (and mark whole season/series).
- **Download button** (Plex, Emby; Swiftfin partial — see §5).
- **Version / quality / media-source picker** — when multiple files/editions exist, choose which version to play (Swiftfin "media source info"; Plex multiple versions/editions).
- **Audio & subtitle tracks** — selectable (often from detail or in-player).
- **Related items / "More like this."**
- **Extras / trailers / behind-the-scenes** (Plex and Emby surface extras; trailers).
- For series: **season/episode list** with per-episode thumbnails, synopsis, watched state.

---

## 4. Playback controls & settings

| Feature | Plex iOS | Emby iOS | Swiftfin |
|---|---|---|---|
| Play / pause, scrub bar | Yes | Yes | Yes |
| Skip forward / back | +30s / −10s | Yes | +15s / −15s |
| Resume from position | Yes | Yes | Yes |
| Quality / bitrate select | In-player quality picker; Auto bandwidth | Auto bandwidth test; manual override | Per-stream bitrate; Max/Original critical to avoid transcode |
| Audio track select | Yes | Yes | Yes |
| Subtitle select / search | Yes (incl. subtitle search) | Yes | Yes |
| Chapter selection | Yes (if embedded) | Yes | Via player |
| Skip Intro | Yes (Plex Pass) | Yes (server-detected) | Yes (Jellyfin intro-skip plugin) |
| Skip Credits | Yes (Plex Pass) | Yes | Plugin-dependent |
| Playback speed | 0.5×–2× (Plex Pass) | Yes | Yes (player-dependent) |
| Auto-play Up Next | Yes | Yes | Yes |
| Playback info overlay | Resolution/bitrate/transcode status | Yes | Yes |
| Player engine | Native + custom | Native + transcode | **Two engines:** Native AVKit (PiP/AirPlay) or VLCKit (broad codecs) |
| PiP / AirPlay | Yes | Yes | Native player only |

**Transcode vs. direct play:** All three rely on the server to transcode when the client can't direct-play a codec/container or when bitrate is capped. Swiftfin's dual-player design (AVKit for OS integration, VLCKit for codec breadth) is the key pattern — Apple platforms lack VP9 and some container support natively, so a VLC-based fallback is what makes "play anything" work.

---

## 5. Downloads / offline UI

- **Plex:** Per-item **Download** action; **Downloads** screen (User Menu) shows in-progress + completed and download settings. Download **quality** is configurable; offline playback of downloaded items. Requires Plex Pass for mobile downloads.
- **Emby:** **Download** and **Download to…** per-item context actions. A dialog selects **download quality** (presets, custom bitrate, or Original) and conversion profile. TV: restrict to unplayed, auto-download new episodes. **Downloads area** manages/removes items. Default storage = Internal; can target a custom Files-app folder.
- **Swiftfin:** Offline downloads were historically **not supported** (its most-requested feature). As of early 2026 **local downloads are landing incrementally** — offline playback via local media paths in Swiftfin Player, automatic offline routing when the network is unavailable, with `ItemView`/library download UI being built out across multiple PRs. Treat as partial/in-progress.

**Pattern:** Download = pick quality (transcode-on-download vs. original) → progress UI → dedicated Downloads/Offline view → per-item delete → storage location setting.

---

## 6. Settings

Common settings surface across the clients:
- **Server management:** add/remove servers, switch active server, sign in/out, multi-user/profile switching, remote vs. local connection handling.
- **Streaming quality:** separate **remote (cellular/WAN)** vs. **local (Wi-Fi/LAN)** bitrate caps; **Auto** uses a bandwidth test (Emby/Plex). Setting "Maximum/Original" avoids unnecessary server transcode (Swiftfin guidance).
- **Transcoding / playback prefs:** preferred player engine (Swiftfin native vs. VLC), preferred audio/subtitle language, burn-in vs. soft subtitles, direct-play toggles, auto-play next.
- **Download settings:** default download quality, storage location.
- **Misc:** theme/appearance, home-screen section customization (Emby strongly), experimental features (Swiftfin).

---

## 7. Recommended MVP feature set & menu structure for visionOS

This is a **personal-use** Plex client for one person's own server. The visionOS competitors (Theater, Aurora, Chroma, Plexi) are feature-thin relative to the mobile clients — they win on *immersive playback* (curved/cinema environments, 3D, big virtual screen) and lose on *library/feature depth*. The opportunity is a clean, focused client: solid browse + detail + a great big-screen player, not a Plex-ecosystem discovery hub.

### Menu structure (recommended)
A single **floating browse window** with a slim sidebar or top tab strip — visionOS favors one ornament/tab container over a crowded bottom bar:

```
[ Home ]  [ Libraries ]  [ Search ]            ⚙ Settings   ⏚ Server
   |           |             |
 hubs:      grid of      universal
 Continue   posters      search
 Watching   + filter/
 + Recently sort
 Added /
 On Deck
```

- **Home** — Continue Watching, On Deck/Next Up, Recently Added. (The single highest-value screen.)
- **Libraries** — pick a library → poster grid with **sort** (added/release/title) and basic **filter** (unwatched, genre). Collections optional.
- **Search** — title search across the server.
- **Detail** — artwork/backdrop, synopsis, cast, ratings, season/episode list, **Play (resume)**, **version/quality picker**, **mark watched**. Download button only if downloads are in scope.
- **Player** — big-screen window (and ideally a cinema/immersive environment): play/pause, scrub, skip ±, resume, **audio/subtitle track select**, **quality/bitrate select**, skip intro/credits if available. Use a VLC-class engine or Plex direct-play+transcode so "play anything" works.
- **Settings** — server connection, remote vs. local bitrate cap, preferred audio/subtitle language, player/transcode prefs.
- **Server/account switcher** — minimal; login + active-server pick.

### Essential (MVP — build these)
1. **Login + single-server connect** (local + remote).
2. **Home hubs:** Continue Watching, On Deck/Next Up, Recently Added.
3. **Library browse:** poster grid, basic sort + filter, TV season/episode navigation.
4. **Media detail:** artwork, synopsis, cast, ratings, Play/Resume, mark watched, version picker.
5. **Player:** resume, scrub, skip ±, **audio + subtitle selection**, **bitrate/quality selection with server transcode fallback** (critical — this is what makes arbitrary files play).
6. **Search** (title).
7. **Basic settings:** remote vs. local quality cap, preferred audio/subtitle language.
8. **Big-screen playback window** + at least one immersive/cinema environment (table-stakes differentiator on visionOS).

### Nice-to-have (post-MVP)
- Collections, genres, playlists browse.
- Skip intro / skip credits (Plex Pass markers).
- Playback speed (0.5×–2×).
- Watchlist, ratings, related/extras/trailers.
- Multi-server / multi-user switching.
- Filtering depth (year, resolution, content rating).
- Chapter selection, PiP/AirPlay handoff.
- 3D / spatial-format playback (Plexi-style).

### Skip for MVP (Plex-ecosystem or low-value for personal use)
- **Discover / On Demand / Live TV / rentals / Plex streaming content** — entire Plex content marketplace; out of scope for "watch my own server."
- **Friends / social / shared-library discovery.**
- **Music / Photos libraries** (unless trivially free) — focus on video.
- **Server administration** (none of the mature clients do real admin; viewing only).
- **Casting to other devices** — on Vision Pro the headset *is* the screen.
- **Heavy home-screen customization.**

### Where visionOS changes the design
- **Browse = a floating 2D window**, not a full-screen app. Keep the chrome light (one tab strip); rely on window resizing rather than dense bottom tabs.
- **Player = a large virtual screen or immersive environment.** This is the headline feature and where competitors compete (cinema ambience, curved screen, immersive environments). Plan player and environment first-class, not bolted on.
- **Spatial considerations:** support 3D / spatial / side-by-side formats where feasible (a known Plexi differentiator); comfortable default screen distance/size; minimal gaze-and-pinch target sizes; controls that auto-hide and reappear on look.
- **No downloads urgency:** Vision Pro is a tethered/Wi-Fi home device; offline downloads are low priority vs. mobile. Defer or skip downloads for v1 and lean on local-network direct play.
- **Transcoding still matters:** even on a fast LAN, codec/container mismatches force server transcode; a robust direct-play + transcode-fallback path is non-negotiable.

---

## Sources
- [Navigating the Mobile Apps | Plex Support](https://support.plex.tv/articles/navigating-the-mobile-apps/)
- [Using the Library View | Plex Support](https://support.plex.tv/articles/200392126-using-the-library-view/)
- [Downloads for iOS and Android Mobile | Plex Support](https://support.plex.tv/articles/download-ios-android/)
- [iOS Media Playback | Plex Support](https://support.plex.tv/articles/205671108-media-playback/)
- [Skip TV Show Intros | Plex Support](https://support.plex.tv/articles/skip-content/) · [Credits Detection | Plex Support](https://support.plex.tv/articles/credits-detection/)
- [Plex Pro Week '24: Playback Speed Controls | Plex](https://www.plex.tv/blog/plex-pro-week-24-playback-speed-controls-explained/)
- [Plex: Find Movies and TV Shows — App Store](https://apps.apple.com/us/app/plex-find-movies-and-tv-shows/id383457673)
- [iOS | Emby Documentation](https://emby.media/support/articles/iOS.html)
- [Download Options (Sync) | Emby Documentation](https://emby.media/support/articles/Sync.html)
- [Emby for iOS Updated with Home Screen Shortcuts](https://emby.media/emby-for-ios-updated-with-home-screen-shortcuts.html)
- [Emby — App Store](https://apps.apple.com/us/app/emby/id992180193)
- [Swiftfin — App Store](https://apps.apple.com/us/app/swiftfin/id1604098728) · [jellyfin/Swiftfin — GitHub](https://github.com/jellyfin/Swiftfin)
- [Swiftfin Library and Media Item Views — DeepWiki](https://deepwiki.com/jellyfin/Swiftfin/3.3-library-and-media-item-views)
- [Swiftfin Media Playback System — DeepWiki](https://deepwiki.com/jellyfin/Swiftfin/4-media-playback-system)
- [Swiftfin Setup Guide (2026) — JellyWatch](https://jellywatch.app/blog/jellyfin-swiftfin-ios-apple-tv-setup-guide-2026)
- [Downloading/Offline Mode Roadmap — Swiftfin Discussion #364](https://github.com/jellyfin/Swiftfin/discussions/364) · [Local Downloads — Issue #1789](https://github.com/jellyfin/Swiftfin/issues/1789)
- [State of the Fin 2026-01-06 | Jellyfin](https://jellyfin.org/posts/state-of-the-fin-2026-01-06/)
- [The best Plex video player for Apple Vision Pro just got way better — 9to5Mac (Theater)](https://9to5mac.com/2025/01/06/the-best-plex-video-player-for-apple-vision-pro-just-got-way-better/)
- [Plexi — App Store](https://apps.apple.com/ca/app/plexi/id6544807707) · [Aurora for Plex — App Store](https://apps.apple.com/us/app/aurora-for-plex/id6547867554) · [Chroma — Vision Directory](https://vision.directory/apps/chroma-cinema-for-plex)
