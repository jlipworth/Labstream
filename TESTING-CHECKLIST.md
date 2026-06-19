# Testing Checklist — live verification pass

_Everything below is implemented + build-verified on `main` (app builds green; the full `PMSKit`
suite passes — run `cd PMSKit && swift test`) but the unchecked items are NOT yet human-verified
in the headset/simulator. Work through them in one pass._

**Numbering = GitHub issue numbers** ([issues](https://github.com/jlipworth/VisionPlex/issues)).
Items without a number shipped without a dedicated issue. Build/install/launch commands live in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — reminder: **reinstalling wipes the container → re-login
required**.

---

## A. Sign-in & player fundamentals

- [x] **Sign-in linking code (GH #16, closed)** ✅ verified — login shows a typeable 4-char code for
      plex.tv/link plus an "Open Plex sign-in in this headset instead" fallback; consent page says
      **VisionPlay**. Both paths land in the library.
- [ ] **Welcome screen polish (GH #18)** — at the next natural sign-out, before signing back in:
      logo tile shows the real artwork with a blue/amber two-tone glow (no flat circle); title reads
      "Vision**Plex**" with amber "Plex"; tagline "Your whole Plex library, in your space."; the
      sign-in state shows a hint line about the code; after tapping Sign in, the 4-char code renders
      as four glass cells with "plex.tv/link" highlighted in amber; an auth failure shows the new
      glass error banner (red icon + hairline, readable text). Flow itself unchanged (#16 semantics).
- [x] **Player opens straight into Expanded** ✅ verified — opening any title skips the
      windowed/embedded player and lands in the fullscreen/cinema experience (where Quality/
      Subtitles/Audio tabs live). User can still manually shrink to a window afterwards.
      Known: the system's ~1s embedded→expanded transition animation is briefly visible on open —
      AVKit has no "present directly into Expanded" API, so this is inherent.
- [x] **Player close (GH #1 + #11, closed)** — the **contextualActions "✕ Close"** pill dismisses
      cleanly back to detail in BOTH windowed and expanded states; no app exit, no stuck cover, no
      audio bleed. The pill is hidden during hands-off playback; in the EXPANDED experience the
      system shows/hides it together with its own chrome (Close joins the actions 0.5s after the
      expand transition — taps there never reach the app process, so no app-side heuristic is
      possible); in the WINDOWED state a single tap shows it for the chrome's ~5s auto-hide
      window. Pause/failure keep it up in both. No extra pause step needed.
      - [x] ✅ re-verified after the chrome-sync changes: no pill at first render, tap → chrome +
            Close together in expanded and windowed, pause keeps it up, Close works.
      **⚠️ KNOWN COSMETIC (deferred):** closing from fullscreen briefly shows a faded "ghost" frame
      during the system's expanded→embedded collapse animation (collapse-first is required to dodge
      the empty-window bug). Suppressing the cover fade was tried and reverted — the artifact is the
      system's collapse animation itself. Next angle if it ever matters: blank the player view before
      collapsing.
- [x] **Quality-reload keeps playhead** ✅ verified in sim — switching the Mbps cap mid-playback
      rebuffers briefly then resumes at the same playhead; a normal Resume lands at the right offset
      with no double-seek.
- [ ] **Failed-playback error UI + explicit retry (GH #8/#33 reset)** — RETEST after the retry-loop
      removal: a real network/PMS failure should surface the Retry pill/dialog after the stall
      watchdog, with **no silent auto-retry** and no repeated hidden `start.m3u8` requests. Tapping
      Retry is the only rebuild; if the server is still down, the overlay reappears rather than
      entering retry/restart hell. The windowed dialog should still avoid flashing during the
      expanded-state collapse.
- [~] **Progress scrobble / mark-watched** — watch past ~90% → marked watched and leaves/refreshes
      Continue Watching; stop mid-way → reopening offers Resume at that offset.
- [~] **Download integrity + progress** — ⏸️ awaiting final human check. Fresh download progresses
      (no instant "unknown error"), %/bar climb with live speed + resolution caption, completes, plays
      offline. Both paths now serve a STATIC file with a real Content-Length, so the % is server-
      reported (no estimate/ETA). (Simulator uses a foreground URLSession — `nsurlsessiond` is
      unavailable there; device keeps the background session.) Logs:
      `xcrun simctl spawn booted log show --last 10m --info --debug --predicate 'subsystem == "com.jlipworth.VisionPlex"'`
- [ ] **Download dual path — DIRECT (offline-download redesign)** — open the download sheet on a
      known-compatible title (the player would direct-play it): the sheet shows a single
      "Download original — <size> · <res>" action (no quality picker). Downloading fetches the
      original `Part.key` byte-for-byte; the row shows a real % and plays offline.
- [ ] **Download dual path — OPTIMIZER (offline-download redesign, Phase-0-gated)** — open the sheet
      on a known-incompatible title (forces a transcode): the sheet lists the server's real optimize
      presets ("Optimized for TV", etc.). Choosing one triggers a server-side optimize, polls for the
      rendered Part, then downloads it. ⚠️ The optimizer POST contract is NOT live-verified — run
      `./scripts/live-optimize-probe.sh` (Phase 0) FIRST and reconcile `OptimizeRequest` to the real
      shape before trusting this path. Optimizer logs persist at os.log `.error`:
      `log show --predicate 'subsystem == "com.jlipworth.VisionPlex" AND category == "Downloads"'`
- [ ] **Download sheet probe-failure fallback** — with the server briefly unreachable when the sheet
      opens, it still offers the optimize presets (it must never dead-end on a probe failure).

## B. Player features

- [x] **Subtitle language names** ✅ verified — Subtitles tab lists the muxed renditions by name
      ("CC (SDH)") plus Off, selection applies live. (Only the PMS-selected tracks are muxed into
      the stream, so the list is short by design.) Cross-session persistence not yet re-checked.
- [ ] **Skip Intro / Skip Credits** — on an episode with server-detected markers, the bottom-trailing
      skip button appears during the window and seeks past it.
- [ ] **Up Next + autoplay** — near an episode's end, the Up Next card shows the next episode +
      countdown; autoplay advances at 0; Play Now is immediate; Cancel suppresses it; the finishing
      episode scrobbles before the swap; crosses season boundaries; last episode just stops.
- [ ] **Offline metadata + poster + resume** — Offline library shows title/year/runtime/poster with
      the network off; retry of a failed download keeps real metadata and re-probes to pick the
      correct path (direct vs optimize); kill the app mid-download → relaunch reconnects or
      reconciles to failed/retryable.
- [ ] **Audio session / interruptions (device-only)** — call/Siri pauses then resumes (only if it was
      playing); unplugging headphones pauses; backgrounding pauses and does NOT auto-resume; a manual
      pause is never overridden.
- [x] **Playback speed + Now Playing metadata** ✅ verified — Speed tab changes rate and survives
      a Quality reload. (Control Center metadata not separately re-checked.)
- [ ] **Buffering indicator** — centered spinner on a real stall, NOT on manual pause.
- [ ] **Bandwidth mismatch toast (GH #32)** — on a real stall where AVFoundation's
      AccessLog observed throughput is materially below the selected quality/source bitrate, a
      short non-blocking toast appears above the buffering spinner (debounced; no automatic
      quality change). Verify it does NOT appear for a manual pause or a normal healthy initial
      prime.
- [~] **Forward buffer depth** — on a direct-play title, Stats ▸ buffered-ahead climbs well past
      ~60s (deep 600s `preferredForwardBufferDuration` hint) and memory stays bounded — AVPlayer
      self-limits the actual window against resources (observed ~540 MB footprint, flat, no jetsam
      on a 4K H.264 direct play). On a capped transcode the buffer fills only as fast as PMS
      produces segments, so the deep hint mostly benefits direct play. _(Sim-verified 2026-06-14;
      device pass still wanted — sim doesn't enforce device jetsam limits.)_
- [ ] **Audio soundtrack picker (GH #3)** — 🔁 RETEST (fix shipped): the Audio tab on streaming
      sessions is now metadata-driven (Plex `Stream` streamType=2, not the HLS group — PMS only
      muxes the active track, which caused the old "No alternate audio tracks"). Verify: tab
      lists at least the active track ("English …" ✓); on a multi-track title, switching PUTs
      `audioStreamID` + rebuilds the transcode and resumes at the same playhead. Local files
      keep the old AVMediaSelection path.
- [x] **Quality menu polish (GH #5)** ✅ verified — "quality seems to work as intended" (ladder,
      live switch + same-playhead resume).
- [x] **Stats for Nerds (GH #6)** — ✅ final form: an inline **"Stats" info-panel tab** (live
      diagnostics grid inside the system ⓘ panel). Third approach after two dead ends: a
      floated SwiftUI overlay and `contentOverlayView` both never composite in the EXPANDED
      cinema scene (system chrome is the only surface that renders there — see
      docs/DEVELOPMENT.md). Verified visible by user. A floating overlay remains possible in
      windowed mode only, if ever wanted as an addition.
- [x] **ⓘ Info card year (was "2026")** — ✅ VERIFIED: card now shows the release year. Fix:
      `externalMetadata` `.commonIdentifierCreationDate` with an **NSDate** value — string
      values are ignored under every date identifier (proven live, see docs/DEVELOPMENT.md).
- [x] **Platter ✕ closes the player** — ✅ VERIFIED ("takes me back to the content menu").
      The system ✕ under the expanded screen only collapses to embedded (system scene, can't
      quit the app); an unflagged completed expanded→embedded transition is treated as Close
      (`appInitiatedCollapse`). Known trade-off: the chrome's shrink-to-window control also
      closes the player (TransitionContext has no initiator field).
- [x] **Chapter thumbnail scroller (GH #10)** — ✅ VERIFIED end-to-end: real thumbnails +
      titles + timestamps, tap seeks, the orange ring + auto-scroll follow the tapped card,
      and the panel auto-dismisses after a pick — in EXPANDED the panel is an in-process
      platter ornament window with no presentation/close API, so dismissal hides the
      backing window and the next tab appearance un-hides it (see docs/DEVELOPMENT.md).
      Chapters tab also no longer vanishes on a fast Play: the player backfills
      chapters/markers itself (`loadChaptersIfNeeded`) instead of racing DetailView's
      metadata refresh.
- [x] **Card clicks route to the right card (was: leftmost-poster misrouting)** — ✅ VERIFIED
      (Home rail, tap-log instrumented): taps across the leftmost card's full extent open THAT
      card. Root cause: ANY custom SwiftUI `ButtonStyle` gets the link's gaze region registered
      displaced (~1.35× about the window center) — see the gotcha in docs/DEVELOPMENT.md. Fix:
      every card/row link now uses `.cardLink()` (built-in `.plain` + a `contentShape` that
      shapes its automatic highlight); `CardButtonStyle`/`.gazeHighlight()` are deleted.
      - [ ] Spot-check routing on the migrated surfaces: season grid + episode rows (Detail),
            library grid, search rails, chapter cards (player ⓘ Chapters), music rails/grids,
            album/artist/Now Playing track rows — first/last items especially.
      - [ ] **Highlight regression eyeball (supersedes GH #20's old mechanism):** `.plain`'s
            highlight reads bigger than the old inset one, "workable for now" on Home posters
            (user-accepted). Check it isn't unbearable on track/episode rows, where the old
            chip highlight sat inset inside the material card.
- [ ] **Direct play via "Direct Play / Maximum" (GH #7 Step 3; quality-picker driven, replaces the
      old Direct Stream toggle + #31 headroom gate)** — set Default Quality (Settings or the
      in-player Quality tab) to **"Direct Play / Maximum"**, then play an HEVC/AC3-or-AAC title and
      read the log: it logs `Direct Play / Maximum — PMS will copy video; committing direct-play
      start.m3u8` — then verify on the server that NO software video transcode is running
      (`ps` shows no `Plex Transcoder` re-encode / EAE for the session, or Plex dashboard shows
      Direct Stream). Then:
      - [ ] A source PMS can't copy logs `Direct Play / Maximum — PMS cannot copy video; using
            maximum transcode` and plays via the maximum transcode (no stall).
      - [ ] **Playback-time fallback** — a source PMS *agrees* to copy (`PMS will copy video`) but
            whose direct-play HLS rendition AVFoundation can't load (the HEVC-in-TS "resource
            unavailable" / "buffers forever" symptom) must NOT surface the Retry/Close failure card.
            It logs `direct-play stream failed to load (...); falling back to maximum transcode`,
            silently rebuilds on the maximum transcode at the same playhead, and plays. Exactly
            ONE fallback per pick: if the transcode rebuild itself fails, the failure card DOES
            surface (no silent loop).
      - [ ] Any capped rung (incl. "Maximum (transcoded)") never probes — it transcodes directly,
            byte-identical to today.
      - [ ] On a committed direct-play: resume offset lands, subtitles tab still populates,
            seek/quality switch/audio switch still work (each rebuild re-probes).
      - [ ] EAC3-only audio sources: audio still transcodes to AAC (audio=transcode is fine);
            video must still be copy.
- [ ] **Transcode session lifecycle / server-OOM guards (GH #27/#33 reset)** — fix shipped after
      the Plex pod OOM (docs/PLEX_AVP_TRANSCODE_OOM_REPORT.md); needs a live pass against real PMS
      while watching the pod (`kubectl -n media exec <pod> -- ps … | grep "Plex Transcoder"`):
      - [ ] **Stop-before-restart** — quality switch, audio switch, in-player Retry, and a
            final-target deep-seek rebuild each log `transcode: stopping previous job before
            in-place restart` (Playback category — `xcrun simctl spawn booted log show --last 5m
            --predicate 'subsystem == "com.jlipworth.VisionPlex" AND category == "Playback"'`) and
            the server never shows more than ONE `Plex Transcoder` for the session.
      - [ ] **Final-target coalescing** — scrub repeatedly into unbuffered territory on a heavy
            (4K HEVC/EAC3 MKV) title. During one drag, PMS sees only the settled final target, not
            a burst of intermediate targets.
      - [ ] **Burst budget escalation** — keep forcing deep out-of-buffer rebuilds: after 3 starts
            within 60s the error overlay appears ("Playback keeps falling behind…") instead of
            another restart. Retry clears it only because it is explicit user intent.
      - [ ] **No silent retry budget** — after a failing stream, the overlay appears without an
            automatic retry; only a user tap on Retry starts a new generation.
- [ ] **Poisoned pooled connection recovery — CONTROL plane (GH #33)** — after reproducing a
      heavy-stream stall (4K/high bitrate + rapid deep seeks), wait for the failure overlay, then
      tap Retry. Expected: logs show `switched Retry control-plane requests to a fresh recovery
      URLSession`, control requests fail fast or recover instead of hanging ~30s, and a healthy PMS
      can be reached on the first explicit Retry without waiting for the OS to evict the old pooled
      socket.
- [~] **Final-target deep seek rebuild (GH #33 reset)** — PARTIAL / WRAP-UP: Stage-3 proxy-owned
      segment splicing is abandoned/removed from the app path. The player loads direct PMS
      `start.m3u8` URLs; out-of-buffer seeks debounce for the final target and rebuild one
      `AVPlayerItem` there. **Manual result after `9ed4569`: single drag OK; double-drag still
      shows behavior very similar to the pre-reset failure, so do not mark #33 solved.** Claude
      self-serves screenshots/logs (`xcrun simctl io booted screenshot`,
      `log show --predicate 'process == "PlexAVPApp"'`).
      - [ ] **Normal playback uses direct PMS URL.** Open any title; no `media proxy open ok` or
            `proxy re-prime` log appears. Playback starts normally and Stats still show the PMS
            decision/probe data.
      - [ ] **Small in-buffer scrub is instant.** Drag a few seconds within already-buffered
            content. It seeks natively — no transcode restart (no `transcode: stopping previous
            job` entry in the Playback log; the `[VP] seek:` debug probes were removed in Wave 2).
      - [x] **Single deep drag rebuilds once.** Manual user test after `9ed4569`: single drag is OK.
      - [ ] **Drag twice in quick succession — the original bug.** Manual user test after `9ed4569`:
            still behaves very similarly to before. Treat this as the remaining blocker if/when
            playback work resumes; do not assume final-target rebuild solved double-drag.
      - [ ] **Resume doesn't self-trigger a rebuild.** Open an item with a saved deep resume point.
            It resumes once and keeps playing — no spurious final-target rebuild from the resume
            seek echo.
      - [ ] **Repeated PMS failures surface once.** Force PMS/network failures during rebuilds; the
            overlay appears and pending background rebuild work stops.
      - [ ] **Close during rebuild.** Start a deep rebuild and close the player before it finishes:
            returns cleanly to detail, no black screen/audio bleed, no continued rebuild loop.
      - [ ] **Quality reload / audio switch still resume at the playhead** (regression — these
            share the same direct rebuild path and reset the rebuild budget).
- [ ] **Default streaming quality in Settings (GH #21)** — Settings now has a Playback section
      with a "Default Quality" picker (same ladder as the in-player Quality tab, same
      persisted key). Verify: pick e.g. 4 Mbps in Settings → open a title → player's Quality
      tab shows 4 Mbps checked; change quality in-player → Settings reflects it.
- [~] **Library A–Z rail + true-length scroll (GH #23)** — Wave 5 video-library pass:
      ✅ sim-confirmed scrollbar reaches the true bottom and the A–Z rail is visible. Remaining
      spot checks before closing: placeholders fill as they appear, tapping letters jumps near
      that initial, and returning from detail preserves position. Implementation pages Movies/TV
      grids 200 items at a time and pre-sizes placeholders from PMS `totalSize`; the rail uses
      PMS `/firstCharacter` counts.
- [ ] **Settings expansion (GH #26, Phase 1+2)** — spot checks:
  - About: Version matches the bundle marketing version; Build shows CFBundleVersion; Build ID is a source slug when built via `scripts/xcodebuild-versioned.sh` or the args from `scripts/build-version-args.sh`; visionOS row sane;
    Client row says "VisionPlay on Apple Vision Pro" (NO client identifier shown).
  - Copy diagnostics: pasted text has app/build/OS versions, server name+version, and
    the connection scheme only — no token, client identifier, hostname, or full URL.
  - Server section: Version row shows the PMS version; Status row says "Tap to check",
    tap → green dot + "Checked <time>" when reachable (try with sim networking cut for red).
  - Re-discover servers resets the status row back to "Tap to check".
  - Sign Out now confirms (dialog mentions plex.tv re-auth); Cancel keeps the session.
  - Maintenance → Clear image cache: row flips to "Cache cleared"; artwork re-loads on
    next browse (no crash, no blank-forever posters).
  - Playback → Reset playback preferences: after setting a 1.5× speed + a subtitle/audio
    language in the player, reset, then play something — speed back to 1×, no auto
    subtitle/audio language; streaming-quality pick is UNCHANGED.
  - X-Plex-Version sanity: requests now carry the bundle version (was hardcoded 0.1.0) —
    login/browse still work.

## C. Music (GH #17 — Plexamp-style module)

- [ ] **Music tab appears** — a Music tab shows when the server has a music library. Music now
      also surfaces in Search (C3) and Home (C6); the Libraries tab alone still omits music
      SECTIONS (deliberate — the Music tab is their entry point, MUSIC-DESIGN §2).
- [ ] **Browse: Artists → Albums → Tracks** — Music tab shows a Recently Added albums rail + artists
      grid (square art); artist → albums grid; album → blurred-art header with Play / Shuffle + track
      list (disc/track order, durations).
- [ ] **Track playback (direct play)** — tapping a track starts audio immediately (no transcode);
      the playing row is highlighted in the album list.
- [ ] **Mini player bar** — a floating bar (art, title/artist, play/pause, next) appears at the
      bottom once something plays and persists across tabs; tapping it opens Now Playing.
- [ ] **Now Playing** — blurred album-art backdrop, large square art, scrubber (drag seeks),
      transport (previous restarts the track if >3s in), shuffle + repeat (off/all/one) toggles, and
      an Up Next queue list where tapping a row jumps to it.
- [ ] **Queue end behavior** — repeat-off stops at the queue end (bar stays, paused); repeat-all
      wraps; repeat-one loops the track.
- [ ] **System integration** — Control Center / Now Playing shows track title, artist, album +
      album art; play/pause/next/previous remote commands work; music keeps playing when the app
      backgrounds (unlike video); unplugging headphones pauses.
- [ ] **Video regression check** — after the audio-session change, video playback still pauses on
      backgrounding and resumes after interruptions exactly as before.

### C2. Music redesign Phase 2 (pivot + Home rails — docs/MUSIC-DESIGN.md §3.1)

- [ ] **Pivot shell** — Music tab shows a Home | Artists | Albums segmented control; switching
      pivots keeps the library Picker working; switching libraries resets to Home.
- [ ] **Home rails** — server hubs render as rails in server order (Recently Added / Most
      Played / etc. as the PMS provides); artist cells are CIRCULAR, albums square. NOTE: v1
      deliberately drops track-level hub items — a hub vanishing may just mean it only had
      tracks, not a bug.
- [ ] **Recently Played = SONGS rail** — Home's first rail shows recently played TRACKS
      (newest first, from play history; replaces the server's artist-typed played hub).
      Tapping a song REPLAYS it (queues the rail from that song) — it does not navigate.
      Play a track, pull-to-refresh Home: the rail should lead with it.
- [ ] **Shuffle Library** — bottom pill queues ~200 random tracks and starts playback shuffled.
- [ ] **Artists/Albums pivots** — sorted grids; sort menu works; scrolling to the bottom loads
      the next page (200/page) without duplicates.
- [x] **#4 probe (video)** — ✅ answered: `iframe-variant=NO` — PMS does not advertise an
      I-frame variant on transcode sessions; no free trick-play thumbnails (#4 parked).
- [ ] **Artist page shelves (Plexamp-style)** — an artist page shows, in order: Popular
      (ranked top tracks on a card — tap plays from that row), Albums, any PMS-categorized
      shelves (Singles & EPs / Compilations / …), **Appears On** (albums by OTHER artists
      containing their tracks — e.g. Wolfgang Lohr → the Bart&Baker compilation), Similar
      Artists (circular cells). KNOWN LIMIT: "Artist feat. X" track credits don't surface
      in Appears On (PMS exact-match only).
- [x] **Artist discography completeness** — ✅ verified live: Wolfgang Lohr shows both
      singles + Appears On; Yazoo believed working (3 albums incl. "In Your Room").
- [ ] **Music art everywhere** — Recently Played song cells, mini bar and Now Playing show
      ALBUM art (track-level thumbs 404 on this PMS; `…/thumb/-1` = no art). A fast drag
      down the Artists grid no longer strands a page of film-glyph placeholders (the
      loader now retries transient failures).
- [x] **Mini bar vs Now Playing** — ✅ verified live: bar disappears while the Now Playing
      sheet is up and returns on dismissal.
- [x] **Go to artist / album** — ✅ verified live: in Now Playing, tapping the artist line
      opens the artist page and the album line opens the album page (sheet closes, Music
      tab pushes).
- [x] **Now Playing fits unscrolled** — ✅ verified live: fitted 620×700 sheet, 300pt art,
      title/scrubber/transport visible without scrolling. TWO live-bitten traps recorded
      in MiniPlayerBar: content taller than the sheet's grant gets CLIPPED top+bottom
      (760 ate the art and the close X), and the close X must overlay the sheet wrapper's
      frame, not NowPlayingView's ZStack (the 900pt backdrop's overflow carries an inner
      overlay into the clipped margin).
- [x] **Scrollbar spans the full library** — ✅ verified live: Artists/Albums grids
      pre-size to totalSize; drag-to-bottom lands on the true end, placeholders fill in
      (#23 part 2; A–Z rail still open).
- [x] **Back returns to where you were** — ✅ verified live (spot checks): root cause was
      every view's `.task` re-firing on pop-back and reloading (resetting pivot/scroll).
      All load()s now no-op when already loaded; pull-to-refresh, sort changes and server
      changes still refetch. Applies to Music root/pivots/artist/album AND Home,
      Libraries, library grid, season browser, Search.
- [x] **Album page artist link** — ✅ verified live: artist name under the album title
      pushes the artist page (falls back to track metadata when the album item lacks
      parent linkage).
- [x] **Episode page show link** — ✅ verified live: show name above an episode title
      pushes the show's season browser.
- [x] **Stop controls** — ✅ verified live: mini-bar ✕ and Now Playing ⏹ end the session
      (full teardown: stopped scrobble, session deactivated, queue cleared, bar gone);
      playing again afterward re-prepares the session cleanly.

### C3. Music redesign Phase 3 (search faceting — docs/MUSIC-DESIGN.md §5, GH #22)

- [ ] **Music appears in Search** — searching an artist/album/song name in the Search tab
      now returns music (previously stripped by `hidingMusic`). Faceted order: Artists rail
      (CIRCULAR art) → Albums rail (square, artist subtitle) → Songs list → video hubs.
- [ ] **Artist/album results navigate** — tapping an artist or album cell pushes the same
      ArtistDetailView / AlbumDetailView as the Music tab (no music sectionKey from search —
      the artist page uses its children fallback and should still list albums).
- [ ] **Song rows PLAY, never navigate** — tapping a Songs row starts playback immediately
      (mini bar appears) with the rest of the song results queued behind it (capped at 20);
      the currently playing song's row shows a tinted title + waveform glyph.
- [ ] **Songs expander** — more than 5 song results shows "Show all N songs"; expanding and
      collapsing works; rows past 5 still play correctly.
- [ ] **Song row metadata** — 44-pt ALBUM art (track thumbs 404 on this PMS), title,
      "artist · album" subtitle, duration.
- [ ] **Video search unchanged** — movie/show/episode results still render as poster rails
      and open DetailView; a mixed query (e.g. a name matching both a film and a band)
      shows both music facets and video hubs without crashes or duplicates.
- [ ] **Search errors** — a song-play failure shows a yellow inline error capsule under the
      Songs card (friendly message, not a raw error).

### C4. Music redesign Phase 4 (queue management — docs/MUSIC-DESIGN.md §4.3, GH #17)

- [ ] **Context menu vs .card hover (the §3.6 risk — verify FIRST)** — long-press/pinch-hold an
      AlbumDetailView track row: a context menu appears with Play Next / Add to Queue, and after
      dismissing it the row's gaze highlight + tap-to-play still behave (no stuck hover chrome,
      no oversized system capsule). If the menu fights the custom `.card` chrome, the documented
      fallback is a trailing `…` Menu button — record the finding in docs/DEVELOPMENT.md.
- [ ] **Play Next** — while a queue plays, Play Next on an album track inserts it as the row
      DIRECTLY below the current one in Up Next, and it plays after the current track ends
      (works from album rows, artist Popular rows, and search Songs rows — search rows fetch
      metadata first, so allow a beat).
- [ ] **Add to Queue** — appends to the BOTTOM of Up Next; with shuffle ON it still plays last
      (append-to-traversal-tail is deliberate, not a bug).
- [ ] **Play Next under shuffle** — with shuffle on, a Play Next track is still the very next
      to play (traversal honors the insert even though display order ≠ play order).
- [ ] **Queue actions while idle** — Play Next / Add to Queue with nothing playing just starts
      playing the track (mini bar appears).
- [ ] **Up Next: remove** — long-press a queue row → Remove from Queue: the row vanishes,
      indices/highlight stay correct. Removing the PLAYING row advances to the next track;
      removing the playing row when it's last stops playback (bar/sheet show nothing playing)
      but the remaining rows stay tappable. Removing the only row clears everything.
- [ ] **Up Next: reorder** — Move Up / Move Down in the row menu reorders the display list;
      with shuffle OFF playback then follows the new order; Move Up on the first row and
      Move Down on the last are disabled.
- [ ] **Clear queue** — the Up Next header's Clear button leaves only the current track
      (button hidden when the queue is a single track); playback continues uninterrupted.
- [ ] **Scrobble/timeline regression** — after queue surgery (insert/remove/reorder), track
      ends still advance correctly and the next track reports/scrobbles (the per-track
      reporter lifecycle is untouched).

### C5. Music redesign Phase 5 (playlists — docs/MUSIC-DESIGN.md §3.4, GH #17)

- [ ] **Playlists pivot** — the Music tab pivot now shows Home | Artists | Albums | Playlists;
      Playlists lists the server's AUDIO playlists as card rows (56-pt composite mosaic art,
      title, "N tracks"); video/photo playlists do NOT appear. Note: playlists are server-wide
      (`/playlists` has no section scope), so the toolbar library Picker deliberately does not
      filter this pivot.
- [ ] **Empty/error states** — a server with no audio playlists shows the "No Playlists"
      empty state (not a spinner forever); network failure shows the friendly error.
- [ ] **PlaylistDetailView** — tapping a row pushes the detail page: blurred composite
      backdrop, 300-pt art, title, "N tracks · X hr Y min" credits, Play + Shuffle. Track
      rows carry 44-pt per-row album art (artwork varies across a playlist), title,
      "artist · album", duration.
- [ ] **Playlist order preserved** — rows appear in the playlist's own order (compare with
      Plex Web), NOT re-sorted by disc/track/title.
- [ ] **Play / row tap / Shuffle** — Play starts at row 1 with the whole playlist queued;
      tapping any row starts THERE with the rest following; Shuffle starts a shuffled pass.
      Playing row shows the tinted waveform; mini bar appears.
- [ ] **Queue actions** — long-press a playlist track row → Play Next / Add to Queue work
      (playlist items are full tracks; no metadata re-fetch beat like search rows).
- [ ] **Duplicate tracks in one playlist** — a playlist containing the same track twice still
      renders both rows and tapping the second plays from the second (rows are identified by
      ratingKey — duplicates share one; verify no crash/skip).
- [ ] **Compilation credits** — on a mixed/compilation playlist, rows show the performing
      artist (`originalTitle`) over "Various Artists".

### C6. Music redesign Phases 6–7 (mini-bar polish + app-wide un-hide — MUSIC-DESIGN §4.1, §8)

- [ ] **Mini bar: previous** — the bar now shows ⏮ ⏯ ⏭: previous restarts/steps back exactly
      like the Now Playing sheet's previous; all bar buttons still win the tap over the
      open-sheet gesture.
- [ ] **Mini bar: queue button** — the ☰ button opens Now Playing PRE-SCROLLED so the Up Next
      card is at the top (no animation fighting the sheet transition); a plain bar tap still
      opens at the top (art/scrubber). After dismissing a queue-opened sheet, a plain tap
      opens unscrolled again.
- [ ] **Mini bar: progress hairline** — a thin sliver along the bar's bottom edge fills with
      elapsed time. It is PASSIVE: dragging it must not seek (scrubbing lives in the sheet).
      Check it stays inside the glass platter's rounded corners at both ends.
- [ ] **Mini bar: width / hide-on-sheet regression** — the bar may grow to ~560 pt (longer
      titles fit); it still disappears while the Now Playing sheet is up and returns on
      dismissal (the ZStack sheet host — do not regress).
- [ ] **Artist Play / Shuffle** — the artist header shows Play (prominent) + Shuffle: Play
      queues the FULL discography (allLeaves, album order) from track 1; Shuffle starts a
      shuffled pass over all of it; both disabled while the fetch is in flight; failure shows
      a yellow inline message. (No Radio button — v2, Pass-gated.)
- [ ] **Home shows music (Phase 7)** — server hubs on the Home tab now include music
      artists/albums (2:3 poster cells are acceptable here); TRACK items are still dropped
      from Home rails (no play affordance in poster rails — v2). A wholly-track music hub
      vanishing from Home is therefore expected, not a bug.
- [ ] **Home music routing** — tapping an artist/album (or playlist) in a Home rail pushes the
      music views (ArtistDetailView via the no-sectionKey children fallback / AlbumDetailView),
      NEVER the video DetailView or AVKit player.
- [ ] **Video playlists stay video** — a VIDEO playlist reached from Home/Search routes to the
      video path, never the music PlaylistDetailView (routing checks `playlistType`; only
      audio playlists enter the music module).
- [ ] **DetailView music redirect** — if a music item ever reaches DetailView (stale link),
      artist/album/playlist render their music pages and a track opens its parent ALBUM page;
      no Play/Download/Mark-Watched video actions appear for music.
- [ ] **Video regression pass (Phase 7 touched Home)** — movie/show Home rails unchanged:
      posters, continue-watching slivers, episode subtitles, tap → DetailView → playback all
      behave; Search video hubs likewise (music stripped from video hubs is dedup — facets
      above carry it).
- [ ] **Libraries tab unchanged** — music sections still do NOT appear in Libraries
      (deliberate #17-checklist exception per MUSIC-DESIGN §2; the Music tab owns them).

### C7. Post-rebase spot-checks (cardLink migration onto main, 2026-06-12)

The rebase onto main replaced every branch-added `.buttonStyle(.card)`/`gazeHighlight` with
main's `.cardLink()` (PlaylistDetailView, SearchView, MusicLibraryView) and merged the
mini-bar with main's fitted-sheet chrome. None of it has rendered on a simulator yet:

- [ ] **Track-row context menus over cardLink chrome** — long-press/secondary-click a queue or
      album track row: the Play Next / Add to Queue menu renders cleanly over the hover
      highlight (the pre-rebase risk in MUSIC-DESIGN §3.6, now on a different button idiom),
      and a plain tap still plays the row — no gaze-region misrouting (the bug class
      cardLink exists to fix).
- [ ] **Mini bar: five-control density** — the bar now carries ⏮ ⏯ ⏭ ☰ ⏹ (branch transport +
      queue shortcut, main's stop). At max width (~560 pt) and with a long title, controls
      stay tappable and don't crowd the progress hairline or the open-sheet tap target.
- [ ] **Migrated surfaces render** — Playlists pivot grid, Search facet results, and Music
      library cells (the three views whose card links were migrated post-rebase) hover and
      route correctly.

---

## Wave 1 — Custom player is the sole player

_Build-verified on branch `wave1/custom-player-sole-player` (not yet merged to `main`).
These are the in-headset checks gating that merge: the custom player is now the ONLY
player (all AVKit code deleted). The custom Cinema ImmersiveSpace is hidden/deferred after
device testing showed it is not equivalent to Apple's AVKit Cinema Environment._

### Streaming (windowed)
- [x] Play a movie from DetailView → custom player opens (no AVKit transport bar).
- [x] Play/pause, scrubber drag-to-seek, and skip ±10/±30 all work.
- [x] Each menu opens and applies: Quality, Subtitles, Audio, Chapters, Speed, Stats.
- [x] Close (✕) dismisses back to DetailView.
- [x] Up Next autoplay advances to the next episode (controller rebuilds cleanly).

### Offline / downloaded
- [x] Play a completed download from the Offline tab → custom player opens and plays the local file.
- [x] Play a downloaded copy from DetailView (offline) → custom player opens and plays.
- [x] Scrubber + skip work on a local file (no network).

### Cinema / theater
- [x] Custom Cinema button is hidden (`CustomCinemaMode.isUserVisible = false`) because the
      custom ImmersiveSpace is not equivalent to Apple's AVKit Cinema Environment on device.
- [x] No visible Cinema affordance appears in the windowed player chrome.

### Settings
- [x] Settings → Playback no longer shows the "Custom player fallback" toggle.
- [x] Default Quality picker present and functional; it lists both "Maximum (transcoded)" and "Direct Play / Maximum" at the top (no separate Direct Stream toggle).

### Regression
- [x] No reference to the old AVKit player anywhere in the UI.
- [x] Reconnect/failure: kill the server mid-stream → failure card with Retry appears in the windowed player. _(Previously verified during #8/#33 reset testing — failure card + Retry path unchanged by the sole-player switch.)_

---

## Wave 2 — Plex bar (re-applied onto the custom player)

_Build-verified on `wave2/plex-bar` (stacked on `wave1/...`). In-headset checks before merge._

### #30 — failure card layout
- [x] Trigger a playback failure (kill the server mid-stream): the failure card is a **compact centered dialog** (capped at 360pt) with **Retry stacked ABOVE Close**, both buttons equal width; a long server message **wraps onto multiple centered lines** rather than stretching the card wide.

### #34 — reconnecting overlay (verify, then close issue)
- [x] Trigger a transient reconnect: the "Reconnecting…" card is a **compact centered dialog** (≈260pt), not full-window-width. (Already satisfied by the custom rewrite — confirm and close #34.)
- [x] While "Reconnecting…" is shown, the "Buffering…" pill does **NOT** also appear — only one status at a time.

### #31 — superseded by quality-picker direct play
- [x] Settings ▸ Playback has NO "Direct Stream" or "Require bandwidth headroom" toggles — both are gone. Direct play is now driven entirely by picking "Direct Play / Maximum" (verified under the #7 item above). The pre-flight bandwidth-headroom gate was removed (the throughput sample it relied on was measured during a capped transcode, so it could never clear the full-source bar).

### #26 — expanded Settings
- [x] Server section shows the PMS **Version**; the **Status** row says "Tap to check", and tapping shows a green/red dot + "Checked <time>".
- [x] "Reset playback preferences" lives in the **Account** section (just above Sign Out), shows a **confirmation dialog**, and on confirm clears remembered speed + subtitle/audio language (NOT streaming quality), showing "Preferences reset".
- [x] Maintenance ▸ "Clear image cache" shows "Cache cleared"; artwork re-downloads on next view.
- [x] About shows app version (build), visionOS, client (product on device — never the identifier); "Copy diagnostics" copies a blob containing NO token/identifier/hostname (scheme only).
- [x] Sign Out now shows a confirmation dialog; Cancel keeps you signed in, Sign Out returns to login.

### Device-only bugs found on Apple Vision Pro hardware (2026-06-14/15)

These reproduced on the headset but NOT in the simulator, so sim verification is insufficient.
(Repro details below avoid the real title name per the public-repo scrub rule.)

- [x] **Chapter/scrub/resume reset to ~0:00 on capped transcodes — FIXED on device.** Repro:
      on a **capped** quality rung (3 Mbps), start/resume a title at a non-zero position or pick a
      chapter/deep scrub target. Actual before fix: the stream requested the correct offset, then
      playback rebuilt back at ~0:00. Device console proof showed AVFoundation emits early
      `timeJumpedNotification`s at/near 0 after loading a non-zero primed `start.m3u8`; the app
      incorrectly treated those as user seek intent and rebuilt at 0. Fix: when the current item was
      just primed at a non-zero offset, `PlaybackController.handleSeekJump()` ignores transient
      near-zero jumps. Device retest: resume reached the primed offset; chapter/scrub no longer
      bounced to 0:00.
- [x] **Cinema mode botched when already in a full Environment — HIDDEN / DEFERRED.** With a full
      Environment at 100% immersion, entering the custom Cinema ImmersiveSpace takes the viewer OUT
      of that environment and does NOT provide expected system screen placement/scale. Since the
      custom player cannot reuse AVKit's system Cinema Environment, the player chrome now hides the
      custom Cinema button (`CustomCinemaMode.isUserVisible = false`). Future theater work should be
      scoped as a RealityKit/immersive-player feature, not a Wave 2 merge blocker.

### #12 — hidden RealityKit theater prototype

- [ ] No visible player-chrome theater affordance appears by default; `CustomCinemaMode.isUserVisible`
      remains false and the new `RealityTheaterFeature.isShippingEntryPointVisible` gate is false.
- [ ] Device-only once a developer entry point exists: open the RealityKit theater prototype from
      Windowed, Mixed, and 100% full Environment states; verify it does not unexpectedly pull the
      viewer out of their chosen Environment or strand an immersive space on dismissal.
- [ ] Device-only once video is wired: verify screen scale/distance, front/center/back seat presets,
      controls reachability, playback continuity, scrub/retry/Close, and long-play comfort.

---

## D. System integration (GH #24 — App Intents + Spotlight slice)

**Simulator limitation (2026-06-16):** Vision Pro simulator build/run works, but we could not
reliably reach a usable system search / Shortcuts invocation surface from the simulator. Treat
these as hardware/manual-system tests, not simulator merge blockers. Simulator validation for
this slice is: app builds, App Intents metadata extraction succeeds, app launches, Settings/About
shows the stamped Build ID, and normal in-app browsing still works.

- [ ] **Shortcuts: Play Media (GH #24)** — Shortcuts app → new shortcut → search "VisionPlay" →
      **Play Media**. Tapping the "Title" parameter should suggest the On Deck list and allow
      free-text search of the library (music never appears, per #15). Running the shortcut
      foregrounds the app, lands on Home, pushes the item's DetailView, and starts playback
      (resume point honored). For a SHOW, playback starts at the first unwatched-ordered episode
      (first leaf); if episode resolution fails it falls back to opening the season browser.
- [ ] **Shortcuts: Open Media (GH #24)** — same as above but only opens the DetailView, no
      autoplay.
- [ ] **Shortcuts: Continue Watching (GH #24)** — zero-parameter intent resumes the top On Deck
      item; with an empty On Deck it errors with "There's nothing in Continue Watching right now."
- [ ] **Intent while signed out (GH #24)** — after sign-out, any intent fails with the
      "VisionPlay isn't signed in to a Plex server…" dialog; no crash, no half-open UI.
- [ ] **Spotlight indexing (GH #24)** — browse Home + a library grid, then system search
      (Home View search field): browsed titles appear (episodes under "Show · SxEy · Title").
      Tapping a result opens the app and pushes that item's DetailView (no autoplay, no second
      window). Sign-out removes the entries from system search.

---

## E. Deferred / optional (tracked in issues)

- **GH #7 — DeviceProfile + direct play:** shipped — the app-side half now loads the
  direct-play `start.m3u8` when Default Quality is "Direct Play / Maximum" and PMS can copy the
  source (see the "Direct play via Direct Play / Maximum" item in §A). Still subject to the
  **CRITICAL `Safari` client-profile constraint** — needs the live headset pass to confirm no
  regression in resume-priming / `subtitles=auto`.
- **GH #4 — trick-play scrub thumbnails:** server-dependent (PMS I-frame playlist); held.
- **GH #12 — RealityKit theater:** hidden prototype scaffold only; no visible entry point until
  the device-only checks above pass. **GH #13 — multi-track offline (.movpkg):** optional / later.
- **GH #18 — welcome screen branding**, **GH #19 — app icon alignment:** visual polish, untested.
