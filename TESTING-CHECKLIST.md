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
      **VisionPlex**. Both paths land in the library.
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
      (no instant "unknown error"), %/bar climb with live speed/ETA/quality caption, completes, plays
      offline. (Simulator uses a foreground URLSession — `nsurlsessiond` is unavailable there; device
      keeps the background session.) Logs:
      `xcrun simctl spawn booted log show --last 10m --info --debug --predicate 'subsystem == "com.jlipworth.VisionPlex"'`

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
      the network off; retry of a failed download keeps real metadata + chosen quality; kill the app
      mid-download → relaunch reconnects or reconciles to failed/retryable.
- [ ] **Audio session / interruptions (device-only)** — call/Siri pauses then resumes (only if it was
      playing); unplugging headphones pauses; backgrounding pauses and does NOT auto-resume; a manual
      pause is never overridden.
- [x] **Playback speed + Now Playing metadata** ✅ verified — Speed tab changes rate and survives
      a Quality reload. (Control Center metadata not separately re-checked.)
- [ ] **Buffering indicator** — centered spinner on a real stall, NOT on manual pause.
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
- [ ] **Direct play via "Maximum / Original" (GH #7 Step 3; quality-picker driven, replaces the
      old Direct Stream toggle + #31 headroom gate)** — set Streaming quality (Settings or the
      in-player Quality tab) to **"Maximum / Original"**, then play an HEVC/AC3-or-AAC title and
      read the log: it logs `Maximum/Original — PMS will copy video; committing direct-play
      start.m3u8` — then verify on the server that NO software video transcode is running
      (`ps` shows no `Plex Transcoder` re-encode / EAE for the session, or Plex dashboard shows
      Direct Stream). Watch specifically for the HEVC-in-TS "buffers forever" symptom (spinner
      never clears → drop to a capped rung, report). Then:
      - [ ] A source PMS can't copy logs `Maximum/Original — PMS cannot copy video; using maximum
            transcode` and plays via the maximum transcode (no stall).
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
      with a "Streaming quality" picker (same ladder as the in-player Quality tab, same
      persisted key). Verify: pick e.g. 4 Mbps in Settings → open a title → player's Quality
      tab shows 4 Mbps checked; change quality in-player → Settings reflects it.

## C. Music (GH #17 — Plexamp-style module)

- [ ] **Music tab appears** — a Music tab shows when the server has a music library; Libraries/Home/
      Search still hide music items (the tab is the dedicated entry point).
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

---

## Wave 1 — Custom player is the sole player

_Build-verified on branch `wave1/custom-player-sole-player` (not yet merged to `main`).
These are the in-headset checks gating that merge: the custom player is now the ONLY
player (all AVKit code deleted), and Cinema mode must replicate the full windowed control
set. Run these before merging the branch._

### Streaming (windowed)
- [ ] Play a movie from DetailView → custom player opens (no AVKit transport bar).
- [ ] Play/pause, scrubber drag-to-seek, and skip ±10/±30 all work.
- [ ] Each menu opens and applies: Quality, Subtitles, Audio, Chapters, Speed, Stats.
- [ ] Close (✕) dismisses back to DetailView.
- [ ] Up Next autoplay advances to the next episode (controller rebuilds cleanly).

### Offline / downloaded
- [ ] Play a completed download from the Offline tab → custom player opens and plays the local file.
- [ ] Play a downloaded copy from DetailView (offline) → custom player opens and plays.
- [ ] Scrubber + skip work on a local file (no network).

### Cinema parity
- [ ] From the windowed player, tap "Cinema" → immersive theater opens with the same video.
- [ ] In Cinema: play/pause, scrubber, skip ±, and ALL menus (Quality/Subtitles/Audio/Chapters/Speed/Stats) work — matching windowed mode.
- [ ] "Exit Cinema" returns to the windowed player; playback position is continuous.
- [ ] Closing the windowed player while Cinema is open tears down cleanly (no orphaned immersive space).

### Settings
- [ ] Settings → Playback no longer shows the "Custom player fallback" toggle.
- [ ] Streaming quality picker present and functional; it lists both "Maximum (transcoded)" and "Maximum / Original" at the top (no separate Direct Stream toggle).

### Regression
- [ ] No reference to the old AVKit player anywhere in the UI.
- [x] Reconnect/failure: kill the server mid-stream → failure card with Retry appears in the windowed player. _(Previously verified during #8/#33 reset testing — failure card + Retry path unchanged by the sole-player switch.)_

---

## Wave 2 — Plex bar (re-applied onto the custom player)

_Build-verified on `wave2/plex-bar` (stacked on `wave1/...`). In-headset checks before merge._

### #30 — failure card layout
- [ ] Trigger a playback failure (kill the server mid-stream): the failure card is a **compact centered dialog** (capped at 360pt) with **Retry stacked ABOVE Close**, both buttons equal width; a long server message **wraps onto multiple centered lines** rather than stretching the card wide.

### #34 — reconnecting overlay (verify, then close issue)
- [ ] Trigger a transient reconnect: the "Reconnecting…" card is a **compact centered dialog** (≈260pt), not full-window-width. (Already satisfied by the custom rewrite — confirm and close #34.)
- [ ] While "Reconnecting…" is shown, the "Buffering…" pill does **NOT** also appear — only one status at a time.

### #31 — superseded by quality-picker direct play
- [ ] Settings ▸ Playback has NO "Direct Stream" or "Require bandwidth headroom" toggles — both are gone. Direct play is now driven entirely by picking "Maximum / Original" (verified under the #7 item above). The pre-flight bandwidth-headroom gate was removed (the throughput sample it relied on was measured during a capped transcode, so it could never clear the full-source bar).

### #26 — expanded Settings
- [ ] Server section shows the PMS **Version**; the **Status** row says "Tap to check", and tapping shows a green/red dot + "Checked <time>".
- [ ] "Reset playback preferences" lives in the **Account** section (just above Sign Out), shows a **confirmation dialog**, and on confirm clears remembered speed + subtitle/audio language (NOT streaming quality), showing "Preferences reset".
- [ ] Maintenance ▸ "Clear image cache" shows "Cache cleared"; artwork re-downloads on next view.
- [ ] About shows app version (build), visionOS, client (product on device — never the identifier); "Copy diagnostics" copies a blob containing NO token/identifier/hostname (scheme only).
- [ ] Sign Out now shows a confirmation dialog; Cancel keeps you signed in, Sign Out returns to login.

---

## D. Deferred / optional (tracked in issues)

- **GH #7 — DeviceProfile + direct play:** shipped — the app-side half now loads the
  direct-play `start.m3u8` when Streaming quality is "Maximum / Original" and PMS can copy the
  source (see the "Direct play via Maximum / Original" item in §A). Still subject to the
  **CRITICAL `Safari` client-profile constraint** — needs the live headset pass to confirm no
  regression in resume-priming / `subtitles=auto`.
- **GH #4 — trick-play scrub thumbnails:** server-dependent (PMS I-frame playlist); held.
- **GH #12 — RealityKit theater**, **GH #13 — multi-track offline (.movpkg):** optional / later.
- **GH #18 — welcome screen branding**, **GH #19 — app icon alignment:** visual polish, untested.
