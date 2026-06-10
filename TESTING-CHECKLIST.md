# Testing Checklist — live verification pass

_Everything below is implemented + build-verified on `main` (app builds green; the full `PlexKit`
suite passes — run `cd PlexKit && swift test`) but the unchecked items are NOT yet human-verified
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
- [~] **Failed-playback error UI + retry (GH #8)** — ⏸️ live test tracked in the issue. Force a bad
      stream (kill network) → one silent auto-retry, then a "Playback failed" overlay with Retry
      (resumes at last playhead) + Close; no spinner/controls stacked over the dialog; works in the
      expanded state too.
- [~] **Progress scrobble / mark-watched** — watch past ~90% → marked watched and leaves/refreshes
      Continue Watching; stop mid-way → reopening offers Resume at that offset.
- [~] **Download integrity + progress** — ⏸️ awaiting final human check. Fresh download progresses
      (no instant "unknown error"), %/bar climb with live speed/ETA/quality caption, completes, plays
      offline. (Simulator uses a foreground URLSession — `nsurlsessiond` is unavailable there; device
      keeps the background session.) Logs:
      `xcrun simctl spawn booted log show --last 10m --info --debug --predicate 'subsystem == "com.personal.PlexAVPApp"'`

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
- [ ] **Audio soundtrack picker (GH #3)** ❌ FAILED live test — shows "No alternate audio tracks"
      even on titles with an English track: PMS only muxes the active track into the stream, so
      the HLS media-selection group is empty. Needs a metadata-driven picker (`streamType=2` +
      `audioStreamID` reload) — see the issue comment.
- [x] **Quality menu polish (GH #5)** ✅ verified — "quality seems to work as intended" (ladder,
      live switch + same-playhead resume).
- [~] **Stats overlay (GH #6)** — ⚠️ partial: works in the windowed state (panel, live numbers,
      tappable ✕) but NEVER renders in the expanded experience (floated SwiftUI sibling — same
      expanded-scene limitation as #8); launcher-tab UX + hover-bubble artifact also flagged.
      See the issue comment for the `contentOverlayView` fix idea.
- [x] **Chapter thumbnail scroller (GH #10)** ✅ verified — real thumbnails + timestamps, tap
      seeks. GH #9 (all entries "Chapter 1 / 0:00") did NOT reproduce. Polish tracked in #10:
      panel too tall, prefer real chapter titles when PMS provides them.

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

---

## D. Deferred / optional (tracked in issues)

- **GH #7 — DeviceProfile + Direct Stream within cap:** PlexKit probe groundwork
  (`directPlayProbeDecisionURL()`) shipped with unit coverage; the app-side half (actually loading
  direct-play instead of `start.m3u8`) is deferred — it touches resume-priming, `subtitles=auto`,
  and the **CRITICAL `Safari` client-profile constraint** (see docs/DEVELOPMENT.md), so it needs its
  own branch + step-by-step headset testing.
- **GH #4 — trick-play scrub thumbnails:** server-dependent (PMS I-frame playlist); held.
- **GH #12 — RealityKit theater**, **GH #13 — multi-track offline (.movpkg):** optional / later.
- **GH #18 — welcome screen branding**, **GH #19 — app icon alignment:** visual polish, untested.
