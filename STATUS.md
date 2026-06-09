# Plex AVP App — Status / Handoff

_Last updated: 2026-06-09. Pushed to **private** GitHub repo `jlipworth/plex-avp-app` (`main`)._

A personal-use native **visionOS 26.5 (Apple Vision Pro)** Plex client. Sideload-only (no paid
Apple Developer account; bundle id `com.personal.PlexAVPApp`). Goal: reliable **bitrate-capped HLS
transcoding**, **theater/cinema playback**, and **offline downloads** of capped copies.

> **Task / bug tracking now lives in [GitHub Issues](https://github.com/jlipworth/plex-avp-app/issues)**, not this file.
> This doc is kept only as a handoff for the durable technical facts + build/run commands below.

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

## 📋 Open work

Tracked in **[GitHub Issues](https://github.com/jlipworth/plex-avp-app/issues)**. Highlights:
the Close-button placement decision (branches `close-A/B/C-*`), the keystone custom control
overlay, the device-profile/Direct-Stream work, the chapter-parsing bug, and scrubbing the server
hostname before the repo goes public.

---

## 🌿 Branches

- `main` — integrated, green, pushed to `origin` (private).
- `close-A-inline-float` / `close-B-custom-transport` / `close-C-ornament` — the three Close-button
  prototypes (pushed; A rejected in testing). Winner gets ported into `main`.
- `worktree-agent-a9b170cc342ef7ab5` — `contextualActions` Retry/Skip/Play-Next prototype (local;
  needs adaptation — see the cinema-overlay issue).

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

## ▶️ Resuming

1. Boot the sim / open Simulator.app (user runs `xcrun simctl boot "Apple Vision Pro"` if needed).
2. Build + install + launch (commands above). DerivedData is cached.
3. **Log in again** if the app was reinstalled.
4. Pick up open work from [GitHub Issues](https://github.com/jlipworth/plex-avp-app/issues).
