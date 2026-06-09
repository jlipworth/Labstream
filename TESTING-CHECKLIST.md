# Testing Checklist — batched verification pass

_All items below were implemented + build-verified (app builds green; 61 PlexKit tests pass) but NOT yet
live-tested in the headset/sim. Work through these in one pass. Nothing here is committed yet._

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
- [ ] **Quality-reload keeps playhead (#9)** — Mid-playback, open the **Quality** info tab, pick a different
      Mbps cap. Brief rebuffer expected, then it resumes **at the same playhead** (not from 0).
      _Also verify: a NORMAL resume (open a half-watched title → Resume) lands at the right offset and does
      NOT do a redundant double-seek._
- [ ] **Failed-playback error UI + retry (#8)** — Force a bad stream (e.g. kill network briefly at start, or
      a known-bad title). After one silent auto-retry, a **"Playback failed"** overlay appears with **Retry**
      (re-runs from last playhead) + **Close**. Confirm Retry recovers when the server is back.
      _Note: a genuinely fatal error shows ~1 retry's delay before the overlay (by design)._
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

---

## C. NOT built yet — need your decision/testing before I implement

- **#2 KEYSTONE — custom SwiftUI control overlay** (replaces AVKit info-tabs with our own transport/controls).
  Big UX refactor that needs visual iteration with you. **Unblocks #6, #7, #3.**
- **#6 Quality menu polish** (granular Mbps+resolution labels, fix sticky scroll, clarify "Maximum") — folds
  into #2.
- **#7 Stats as an on-video overlay** (Emby-style, not a modal tab) — folds into #2.
- **#3 Audio soundtrack / language picker** (remember language) — needs #2 + an accurate device profile (#13).
- **#13 Accurate AVP DeviceProfile + Direct Play within cap** — touches the CORE transcode decision (and the
  `Safari` profile constraint); high value but risky to change without you testing each step. Held deliberately.
- **#4 Scrubbing trick-play thumbnails** — server-dependent (needs PMS I-frame playlist); held.
- **#19 RealityKit theater**, **#20 multi-track offline (.movpkg)** — optional / later.
