# Plex AVP App — Status / Handoff

_Last updated: 2026-06-08. Safe stopping point before a computer restart._

A personal-use native **visionOS (Apple Vision Pro)** Plex client. Sideload-only (no paid
Apple Developer account). Goal: reliable **bitrate-capped HLS transcoding**, **theater/cinema
playback**, and **offline downloads** of capped copies.

---

## ✅ Where we are (working, committed)

End-to-end playback works: browse → transcode decision → HLS → render → scrub.
Then a large feature build-out landed (all build-gated green; **53 PlexKit tests pass**).

**Confirmed working in the simulator:**
- Sign-in (Plex PIN OAuth, in-app web sheet that auto-closes)
- Browsing Home / Libraries / Search
- Video playback (transcoded 4K HEVC → H.264 1080p, ~7.5 Mbps cap)
- Scrubbing

**Built but needs your live testing (this session's work):**
- **In-player controls** (player info-panel tabs): Quality switch, Subtitles, Chapters, Stats for Nerds
- **Resume fix** — PMS now primes the transcoder at the resume offset (`offset` param + `#EXT-X-START`); no more cold deep-seek stall
- **Detail submenu**: download-with-quality, mark watched/unwatched, version/media selection, richer metadata
- **Downloads**: quality picker + background/persistent transfers
- **Visual polish**: shimmer skeletons, hover-lift, redesigned login, art backdrop
- **Home-load race fix** (no more false "Couldn't load Home" on first launch)

---

## 🧪 What to test next (in priority order)

1. **Resume** — open the title you scrubbed ~31 min into, hit **Resume**. Should start quickly at the offset (previously stalled "forever"). Fresh title from 0 = unchanged.
2. **Media stress testing** — resume, fast-forward, reverse, scrub, **scrubbing thumbnails**, chapter jumps, quality-switch mid-playback, subtitle toggle. Note where it stalls vs buffers gracefully.
3. **In-player Quality** — switch bitrate mid-playback; confirm it reloads + resumes at the playhead (brief rebuffer is expected — PMS can't change cap mid-session).
4. **Subtitles tab** — confirm soft tracks actually appear (depends on PMS muxing them into the HLS).
5. **Detail submenu** — download-with-quality sheet, mark watched/unwatched, version picker (needs a title with multiple versions).

---

## ⚠️ Outstanding / known caveats (need live verification or follow-up)

- **Scrubbing thumbnails**: likely NOT working yet — needs PMS to expose an I-frame-only playlist (`EXT-X-I-FRAME-STREAM-INF`); our transcode request doesn't ask for trick-play. May be a feature to add, not just verify.
- **Mark-watched** uses GET `/:/scrobble` (legacy-compatible). If the server ignores it, flip TimelineRequest's method knob to PUT.
- **Quality downloads** use a progressive-MP4 transcode path (`protocol=http&download=1`) not verified against the live server for every source codec. If a download fails, this is the first suspect.
- **Subtitles burn-in fallback** is unwired (would need a `Stream` model in PlexKit). Only soft tracks are offered.
- **Legacy optimize-queue** download path (`optimizeAndDownload(_:)` + `triggerOptimize` TODO(live)) is untouched/unverified; the new quality path doesn't depend on it.
- **Background-transfer pause while headset off** is surfaced in copy only; real visionOS pause/resume behavior unconfirmed on-device.

---

## 🔧 Key technical facts (so we don't re-learn them)

- **Build:** `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- **PlexKit tests:** `cd PlexKit && swift test`
- **App bundle id:** `com.personal.PlexAVPApp`
- **Sim:** "Apple Vision Pro" (visionOS 26.5)
- **Install + launch:**
  ```
  APP="$HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-fwinnyyxpqgoebfddswbmpufzmfl/Build/Products/Debug-xrsimulator/PlexAVPApp.app"
  xcrun simctl install booted "$APP" && xcrun simctl launch booted com.personal.PlexAVPApp
  ```
- **Logs (crash-safe, after the fact):**
  `xcrun simctl spawn booted log show --last 5m --predicate 'process == "PlexAVPApp"' --style compact`
- **CRITICAL — do not revert:** `TranscodeRequest` sends `X-Plex-Client-Profile-Name="Safari"`. An unknown profile name (e.g. "visionOS") makes PMS return a bare **HTTP 400** and playback breaks. The bitrate cap is enforced by `maxVideoBitrate`.
- **Reinstall wipes the app container** (keychain + Application Support) → **re-login is required after every reinstall**. Token persists across plain relaunches via a file fallback in `KeychainStore` (the unsigned-sim keychain fails with `errSecMissingEntitlement -34018`).
- **New Swift files** are auto-included (Xcode file-system-synchronized groups) — no `project.pbxproj` edits needed.
- **Server:** `plex.example.internal:443` (Cloudflare-fronted but relays Plex responses fine). Direct LAN `192.0.2.10` is unreachable from this Mac.
- **NEVER commit** Plex tokens or client identifiers. Never `NSLog` a raw string containing `%` (format-string crash) — use `NSLog("%@", str)`.

---

## ▶️ Resuming after restart

1. Boot the sim (or open Simulator.app): `xcrun simctl boot "Apple Vision Pro"` if needed.
2. Build + install + launch (commands above). DerivedData survives the restart, so the build is cached.
3. **Log in again** (reinstall wiped the session).
4. Start with the **Resume** test, then media stress testing.
