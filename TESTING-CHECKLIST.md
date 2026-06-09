# Testing Checklist — batched verification pass

_All items below were implemented + build-verified (app builds green; **97 PlexKit tests pass**) but NOT yet
live-tested in the headset/sim. Work through these in one pass. Everything here is committed to `main`._

## Build / install / launch
```sh
# Build
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Install + launch (reinstall wipes the container → re-login required)
APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-fwinnyyxpqgoebfddswbmpufzmfl/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.personal.PlexAVPApp
```

---

## A. Phase 0 correctness fixes

- [ ] **Player close button (#1)** — Close now lives in the player's **Info (ⓘ) panel** as a **Close** action
      (`infoViewActions`), NOT a floated ✕. Reveal the chrome, open the ⓘ panel, tap **Close** → the player
      dismisses cleanly back to detail; no stuck cover, no audio bleed. **Test it in BOTH states:** the inline/
      windowed player AND the expanded cinema view (the old floated ✕ vanished in expanded — this must not).
      _If Close feels too buried in the ⓘ panel, that's the signal to try the contextual-action or floated
      variant instead (we deferred that choice)._
      **⚠️ KNOWN OPEN ISSUE (cosmetic, deferred):** closing from **fullscreen/cinema** shows a brief faded
      "ghost" of the video frame during the expanded→embedded shrink animation (windowed close is clean). The
      collapse-first ordering is required to avoid the #28 empty-window bug, so we can't just dismiss directly.
      _Tried & ruled out:_ suppressing the `.fullScreenCover` dismiss fade in the collapse path (reverted — the
      ghost persisted), which means the artifact originates in the **system's collapse/docking animation
      itself**, not our cover fade. Next angle to try: blank/hide the player view (or swap to a black frame)
      *before* the collapse so there's no frame left to ghost. Left as-is for now per decision to defer.
- [x] **Quality-reload keeps playhead (#9)** ✅ verified in sim — Mid-playback, open the **Quality** info tab, pick a different
      Mbps cap. Brief rebuffer expected, then it resumes **at the same playhead** (not from 0).
      _Also verify: a NORMAL resume (open a half-watched title → Resume) lands at the right offset and does
      NOT do a redundant double-seek._
- [~] **Failed-playback error UI + retry (#8)** — ⏸️ **live-test deferred to [issue #8](https://github.com/jlipworth/plex-avp-app/issues/8).**
      Implemented + build-verified + deployed; the visual-layering fixes (pause-on-failure, BufferingOverlay
      gate, hide AVKit controls on inline failure) are documented in the issue. The remaining human checks
      (no spinner/controls over the dialog; Retry recovers; expanded-mode Retry/Close still show) are tracked
      there. Original repro: force a bad stream (kill network briefly), expect one silent auto-retry then a
      **"Playback failed"** overlay with **Retry** (re-runs from last playhead) + **Close**.
- [ ] **Progress scrobble / mark-watched (#11)** — Watch a title past ~90% (or to end). It should be marked
      **watched** and leave/refresh Continue Watching. Stop mid-way → reopening offers Resume at that offset.
      _Verify capped-HLS items report a finite duration so the 90% threshold actually fires._
- [ ] **Download integrity (#10)** — Download a normal title → completes + plays offline. If a download
      returns an error/HTML page or a tiny/truncated body, it is rejected as **failed** (NOT a fake "complete"),
      and the failed row offers **Retry**. _Very short low-bitrate clips could trip the 1 MB floor — check if
      you download any._

## B. New features

- [ ] **Subtitle language names (#5)** — In-player **Subtitles** tab shows real names ("English",
      "Spanish (Forced)", "English (SDH)") instead of "CC", and lists **all** muxed languages. Pick one; next
      session it's auto-reapplied; picking **Off** stays off. _Label quality depends on PMS emitting usable
      locale tags + muxing multiple renditions — if the server only muxes one track, only one appears._
- [ ] **Skip Intro / Skip Credits (#14)** — On an episode with markers, a bottom-trailing **Skip Intro** /
      **Skip Credits** button appears during those windows and seeks just past them. _Requires server-side
      intro/credits detection to have run; if absent the button correctly never shows._
- [ ] **Up Next + autoplay (#15)** — Near the end of an **episode**, a bottom-leading **Up Next** card shows
      the next episode + a countdown. Verify: autoplay advances at 0; **Play Now** advances immediately;
      **Cancel** suppresses autoplay for that episode; the finishing episode is **scrobbled/marked watched
      before** the swap; transition has no ugly black-flash; the new episode starts at 0 (not the old offset);
      last-episode-of-series shows no card and just stops. _(Resolution uses the PMS PlayQueue — confirm it
      returns the correct next episode and crosses season boundaries.)_
- [ ] **Offline metadata + poster + resume (#16)** — Offline library shows **title / year / runtime / poster**
      with the network off. Retry of a failed download uses the **real** metadata + originally chosen quality
      (not a generic "movie"). Kill the app mid-download → relaunch reconnects the transfer (or reconciles a
      dead one to failed/retryable; progress not silently lost). _Poster fetch hits `/photo/:/transcode` —
      confirm it loads against the live server._
- [ ] **Audio session / interruptions / background (#17)** — **(device-only)** Incoming call/Siri pauses then
      resumes (if it was playing); removing AirPods/headphones pauses; backgrounding/leaving the immersive
      screen pauses (and does NOT auto-resume on return). A manual pause is never overridden.
- [ ] **Playback speed + Now Playing (#18)** — New **Speed** info tab (0.5×–2×) changes rate, persists, and
      survives a Quality reload (doesn't snap back to 1×). Cinema chrome / Control Center shows the real
      **title + artwork** (not a filename/blank). _Confirm PMS honors the `session` param for session tracking._
- [ ] **Buffering indicator (#21)** — A centered spinner appears during a real stall/rebuffer and NOT on a
      manual pause. The ~30s forward buffer should feel smoother on a flaky network. _Real rebuffer behavior
      only visible on a throttled connection._

### Built this pass — additive AVKit info-tabs (the "additive, like chapter scroller" approach; supersedes #2)

- [ ] **Audio soundtrack / language picker (#3)** — New in-player **Audio** info tab (waveform icon). On a
      title with multiple audio tracks, it lists each soundtrack by real name ("English", "Spanish",
      "English (AD)" for audio-description). Pick one → audio switches live (soft switch, no restart). Next
      item/session it auto-reapplies your preferred **language**. _On a single-track title the tab shows a
      graceful empty state ("No alternate audio tracks") rather than a useless one-row list — gated on
      `group.options.count > 1`. Label quality depends on PMS muxing multiple audible renditions with usable
      locale tags._
- [ ] **Quality menu polish (#6)** — The **Quality** info tab now offers a granular ladder
      (2/3/4/8/10/12/20/40 Mbps with **resolution hints** — "8 Mbps · 1080p" — plus **"Maximum (original)"**).
      The list **scrolls reliably** to the bottom row inside the info panel (was clipping before). Your current
      cap shows a checkmark; picking a new one mid-playback rebuffers briefly and **keeps the playhead** (see
      #9). _All previously-used caps still resolve a checkmark even if not on the visible ladder._
- [ ] **Stats overlay (#7)** — The **Stats** info tab is now a **launcher**: tap the eye toggle and a
      stats-for-nerds panel floats at the **top-leading** corner over the video (resolution, bitrate, buffer,
      dropped frames, transcode vs direct mode…). Tap its **✕** to dismiss. Confirm the floating frame does NOT
      block player touch/transport underneath, and the ✕ is reliably tappable. _Overlay is suppressed while a
      playback error is showing (won't stack on the failure UI)._

---

## C. Status of the remaining tasks

- **#2 SUPERSEDED — custom SwiftUI control overlay.** We chose the **additive** route instead (extend the
  native AVKit info-tabs rather than rebuild the transport from scratch). #3/#6/#7 shipped this way (Section B),
  so the big keystone refactor is no longer needed. Closed as superseded, not deferred.
- **#13 Accurate AVP DeviceProfile + Direct Play within cap — PARTIALLY done; app-side half deferred.**
  - _Done + tested on `main` (PlexKit, Track B):_ `directPlayProbeDecisionURL()` + the `visionOSDirectPlayProbe`
    groundwork are committed with unit coverage.
  - _Deferred (needs your decision + device testing):_ actually loading a direct-play file instead of
    `start.m3u8`. This is the risky half — it changes resume-priming (`#EXT-X-START`), can break `subtitles=auto`
    soft-rendition muxing, and interacts with the **CRITICAL `Safari` client-profile constraint** (an unknown
    profile makes PMS return a bare 400). Merely swapping the decision URL without the rest would make the Stats
    "Mode" row lie. **→ See open question at the bottom.**
- **#4 Scrubbing trick-play thumbnails** — server-dependent (needs PMS I-frame playlist); held.
- **#19 RealityKit theater**, **#20 multi-track offline (.movpkg)** — optional / later.

---

## Open question for you

**#13 Direct Play:** Do you want me to take on the app-side direct-play integration as a separate, device-tested
work item? It's higher-risk (touches the core transcode decision + the `Safari` profile constraint) so I'd want
to do it on its own branch with you testing each step in the headset — not bundled with the safe UI features
that are already on `main`. Or leave it shelved for now?
