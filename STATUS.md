# Plex AVP App — Status / Handoff

_Last updated: 2026-06-09. Reflects current working-tree state. **Everything below is uncommitted** (working at HEAD `b30c81f`)._

A personal-use native **visionOS 26.5 (Apple Vision Pro)** Plex client. Sideload-only (no paid
Apple Developer account; bundle id `com.personal.PlexAVPApp`). Goal: reliable **bitrate-capped HLS
transcoding**, **theater/cinema playback**, and **offline downloads** of capped copies.

---

## ✅ Confirmed working (live-tested in sim/headset)

End-to-end playback works: browse → transcode decision → HLS → render → scrub.

- Sign-in (Plex PIN OAuth, in-app web sheet that auto-closes)
- Browsing Home / Libraries / Search
- Video playback (transcoded 4K HEVC → H.264 1080p, ~7.5 Mbps cap)
- Scrubbing, Resume (PMS primed at offset, no cold deep-seek stall)
- **Player Close** via AVKit `contextualActions` — renders + is tappable in BOTH inline and
  expanded/cinema states (the old floated ✕ vanished in expanded; this is the fix)
- **Failed-playback recovery (#8 / #25)** — a 15s stall watchdog surfaces a "Playback failed"
  overlay even when HLS network loss never flips the item to `.failed` (it presents as
  `waitingToPlayAtSpecifiedRate`). **Retry rebuilds the whole `AVPlayerViewController`** (SwiftUI
  `.id()` bump) and resumes at the captured live playhead. A fresh vc clears BOTH the wedged AVKit
  control layer AND the black/dimmed cinema room — no app relaunch needed. _User-validated inline:
  overlay fires, room restored, Retry resumes with a minor (last-buffered) rewind._

---

## 🟡 Built + build-green, NOT yet live-tested

See `TESTING-CHECKLIST.md` for the per-item walkthrough (one at a time). Highlights:

- In-player info tabs: Quality switch (keeps playhead, #9), Subtitles by language name (#5),
  Chapters, Stats, Speed 0.5×–2× (#18)
- Skip Intro / Skip Credits (#14); Up Next + autoplay (#15)
- Downloads: quality picker + persistent transfers; download integrity rejection (#10)
- Offline metadata + poster + resume (#16); audio session / interruptions (#17, device-only);
  buffering spinner (#21); progress scrobble / mark-watched (#11)
- **TV show hierarchy drill-down (#24)** — Show → Seasons → Episodes (integrated this session from
  worktree; new `ChildrenRequest` + `MediaItem+Hierarchy`; covered by `TVHierarchyTests`). **Needs
  live drill-down test.**

---

## 🔧 In progress / not yet integrated

- **#23 — `contextualActions` driver for Retry / Skip / Play-Next** (worktree
  `agent-a9b170cc342ef7ab5`, NOT merged). Mirrors `controller.playbackError` / `skipMarker` /
  `upNext` into `playerVC.contextualActions` via `withObservationTracking`. **Adaptation required
  before merge:** (1) re-route its Retry to the **rebuild** path (`PlayerView.rebuildPlayer`), NOT
  `controller.retry()` (in-place item swap inherits the wedge); (2) ALWAYS include Close;
  (3) remove the static `closeAction` from `PlayerView.makeUIViewController` so the driver solely
  owns `contextualActions`.

---

## ⛔ Not built yet — need decision/testing before implementing

- **#2 KEYSTONE — custom SwiftUI control overlay** (replaces AVKit info-tabs). Big UX refactor;
  needs visual iteration. **Unblocks #6, #7, #3, and folds in #4.**
- **#6** Quality menu polish · **#7** Stats on-video overlay — both fold into #2.
- **#3** Audio soundtrack / language picker — needs #2 + accurate device profile (#13).
- **#13** Accurate AVP DeviceProfile + Direct Stream within cap — research done
  (`research/13-device-profile.md`). Touches the CORE transcode decision and the `Safari` profile
  constraint; safest first step is a decision-only probe keeping `X-Plex-Client-Profile-Name=Safari`.
  Held until live-tested step by step.
- **#4** Trick-play scrubbing thumbnails — server-gated (Plex live universal transcode emits no
  `EXT-X-I-FRAME-STREAM-INF`); needs a custom scrubber + Plex BIF index. Folds into #2.
- **#19** RealityKit theater · **#20** multi-track offline (.movpkg) — optional / later.

---

## 🔑 Key technical facts (so we don't re-learn them)

- **Build:** `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- **PlexKit tests:** `cd PlexKit && swift test` — **74 tests pass**.
- **App bundle id:** `com.personal.PlexAVPApp` · **Sim:** "Apple Vision Pro" (visionOS 26.5)
- **Install + launch** (sim must be booted by the user — `simctl` from this shell often returns
  "No devices are booted"; hand these to the user to run):
  ```
  APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-fwinnyyxpqgoebfddswbmpufzmfl/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
  xcrun simctl install booted "$APP" && xcrun simctl launch booted com.personal.PlexAVPApp
  ```
- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Safari"`. An
  unknown profile name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks.
  The bitrate cap is enforced by `maxVideoBitrate`.
- **AVKit `contextualActions`** (`visionos(1.0)`) is the ONLY affordance that renders over video in
  BOTH inline and expanded cinema states and stays tappable. That's why Close (and #23's
  Retry/Skip/Play-Next) live there, not in a floated overlay or the ⓘ panel.
- **HLS network loss = stall, not `.failed`** — `timeControlStatus == .waitingToPlayAtSpecifiedRate`
  with empty buffer; `AVPlayerItem.status` never flips. Hence the 15s stall watchdog.
- **Wedge recovery requires a brand-new vc** — an in-place `retry()` (item swap) inherits the wedged
  control layer + dimmed room. Rebuild via `.id()` bump is the only thing that clears both.
- **Reinstall wipes the app container** (keychain + Application Support) → **re-login required after
  every reinstall.** Token persists across plain relaunches via a file fallback in `KeychainStore`
  (unsigned-sim keychain fails with `errSecMissingEntitlement -34018`).
- **New Swift files** auto-included (Xcode file-system-synchronized groups + SPM
  `PlexKit/Sources`,`PlexKit/Tests`) — no `project.pbxproj` edits needed.
- **Server:** `plex.example.internal:443` (Cloudflare-fronted, relays Plex fine). Direct LAN
  `192.0.2.10` is unreachable from this Mac.
- **Single-window constraint:** no `openWindow` / second `WindowGroup` — player is a
  `.fullScreenCover`, like other native players.
- **NEVER commit** Plex tokens or client identifiers. Never `NSLog` a raw string containing `%`
  (format-string crash) — use `NSLog("%@", str)`. Commit/push only when the user asks.

---

## 🌳 Worktrees

Agents made uncommitted changes on branches based at HEAD `b30c81f`.

- `agent-a9b170cc342ef7ab5` — **#23 contextualActions driver. KEEP** (pending adaptation above).
- `agent-a30a4e355f7a94e05` — #24 TV hierarchy. **Integrated → removable.**
- `agent-ad73d4c4d2cecd184` — #13 research doc. **Integrated → removable.**
- `agent-aeaa024f23602fc8b`, `agent-a22bf03a0ab74276f`, `agent-a4b155890ae181cbb` — close-button
  variants, **redundant** vs. the shipped `contextualActions` Close. **Removable.**

---

## ▶️ Resuming

1. Boot the sim / open Simulator.app (user runs `xcrun simctl boot "Apple Vision Pro"` if needed).
2. Build + install + launch (commands above). DerivedData is cached.
3. **Log in again** if the app was reinstalled.
4. Continue `TESTING-CHECKLIST.md` one item at a time; live-test #24 drill-down; decide on #23
   adaptation + whether to commit a checkpoint.
