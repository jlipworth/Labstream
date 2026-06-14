# Wave 2 — Plex-Bar Changes Re-Applied onto the Custom Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the four outstanding "Plex bar" issues (#30, #31, #26, and the #34 close-out) on top of the Wave 1 custom-player branch by **re-applying** each feature's semantic diff to the current code — the source branches sit on a pre-custom-player base and must NOT be merged/rebased directly.

**Architecture:** One stacked branch off `wave1/custom-player-sole-player`. Each issue is re-applied and committed independently. The three Wave-2 branches (`ui/30-retry-above-close`, `playback/31-direct-stream-headroom`, `settings/26-expanded-surface`) diverged from an ancient `main` (merge-base `8f23631`, pre-custom-player, pre-media-session-removal); a `git merge`/`rebase` would resurrect ~7,000 lines of deleted AVKit/proxy code. We therefore port only each branch's own feature hunks (isolated via `git diff $(git merge-base main <branch>)..<branch>`).

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, PMSKit (Swift Testing). PMSKit has unit tests (`cd PMSKit && swift test`); the app layer has no UI test harness → build-clean gate + live-sim checklist (owner runs).

---

## Testing model (read first)

- **PMSKit changes** (the #31 headroom gate, the #26 `productVersion` field) ship with Swift Testing unit tests — run `cd PMSKit && swift test` and expect all green.
- **App-layer changes** get the build-clean gate after each task (delete the `.app` first so a skipped `Ld` can't masquerade as success):
  ```sh
  rm -rf $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app
  xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
    -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
  ```
  Expected: `** BUILD SUCCEEDED **` + a fresh `PlexAVPApp.app` (mtime newer than build start).
- **Live-sim verification** is the owner's; behaviors that can only be confirmed in-headset go into `TESTING-CHECKLIST.md` (Task 2e). #27/#7/#33 are verification-only this wave (no code) — their checklist items already exist.

## Branch

Wave 2 **stacks on Wave 1** (it edits `CustomPlayerChrome.swift` and the post-Wave-1 `SettingsView`):

```sh
git switch -c wave2/plex-bar wave1/custom-player-sole-player
```

Commit after each task. Do **not** push or merge — the owner merges Wave 1 then Wave 2 in order after the live-sim checklist passes.

## File structure

| File | Disposition in Wave 2 |
|---|---|
| `PlexAVPApp/Player/CustomPlayerChrome.swift` | Modify (2a: `failureCard` HStack→VStack, Retry-above-Close) |
| `PMSKit/Sources/PMSKit/Transcode/DirectStreamHeadroomGate.swift` | **Create** (2b: #31 gate, verbatim) |
| `PMSKit/Tests/PMSKitTests/DirectStreamHeadroomGateTests.swift` | **Create** (2b: #31 tests, verbatim) |
| `docs/superpowers/specs/2026-06-13-direct-stream-headroom-gate-design.md` | **Create** (2b: #31 design doc, verbatim) |
| `PlexAVPApp/Player/PlaybackController.swift` | Modify (2b: headroom key + gate at the direct-stream commit; 2c: `persistedPreferenceKeys`) |
| `PlexAVPApp/Player/PlaybackDiagnostics.swift` | Modify (2b: persist observed-throughput sample) |
| `PMSKit/Sources/PMSKit/Auth/ResourceDiscovery.swift` | Modify (2c: `productVersion` on `PlexDevice`) |
| `PMSKit/Tests/PMSKitTests/ResourceDiscoveryTests.swift` | Modify (2c: decode test) |
| `PlexAVPApp/Auth/AuthManager.swift` | Modify (2c: `probeSelectedServer()`) |
| `PlexAVPApp/App/ContentView.swift` | Modify (2c: version from bundle) |
| `PlexAVPApp/UI/SettingsView.swift` | Modify (2b: headroom toggle; 2c: server version+status, reset-prefs, maintenance, About, sign-out confirm) — **3-way hotspot, land 2b then 2c, one commit each** |
| `TESTING-CHECKLIST.md` | Modify (2e: Wave 2 live-sim section) |

`PlaybackController.persistedPreferenceKeys` / `directStreamHeadroomEnabledKey` and `PlaybackDiagnostics.observedThroughputEstimateKey` are internal `static let`s in the app target; `SettingsView` (same target) reads them directly.

---

## Wave 2a — #30 Retry-above-Close on the custom failure card (and #34 close-out)

**Why:** #30 ("stack windowed Retry above Close") and #34 ("cap the Reconnecting overlay width") were written against the deleted `PlayerView.swift` overlays. **#34 needs NO code change** — the custom rewrite's `CustomReconnectingOverlay` already uses `.frame(width: 260)` with a width-capped (`.frame(width: 150)`) Close button, so the edge-to-edge bug never existed here. **#30 still applies**: the custom `failureCard` currently uses an `HStack`.

### Task 2a.1: Stack Retry above Close in `failureCard`

**Files:**
- Modify: `PlexAVPApp/Player/CustomPlayerChrome.swift:313-325`

- [ ] **Step 1: Replace the button `HStack` with a `VStack`**

Replace (lines 313-325):

```swift
            HStack {
                Button(action: {
                    revealChrome()
                    onRetry()
                }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                if let onClose {
                    Button("Close", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
```

with:

```swift
            VStack(spacing: 8) {
                Button(action: {
                    revealChrome()
                    onRetry()
                }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                if let onClose {
                    Button(action: onClose) {
                        Text("Close")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 2)
```

- [ ] **Step 2: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/Player/CustomPlayerChrome.swift
git commit -m "Stack Retry above Close on the custom failure card (#30)"
```

- [ ] **Step 4: Note #34 in the commit trail** — no code change; record in the Wave 2 checklist that the custom `CustomReconnectingOverlay` already satisfies #34 (width-capped at 260) so the issue can be closed after the owner eyeballs it.

---

## Wave 2b — #31 Direct Stream bandwidth-headroom gate (default OFF)

**Why:** Adds a conservative, opt-in throughput check before committing to a single-rendition Direct Stream. Default OFF so #7's existing experimental behavior is unchanged. Pure additions in PMSKit (with tests) + two small app-layer wiring hunks + one Settings toggle.

### Task 2b.1: Add the PMSKit gate + tests + design doc (verbatim)

**Files:**
- Create: `PMSKit/Sources/PMSKit/Transcode/DirectStreamHeadroomGate.swift`
- Create: `PMSKit/Tests/PMSKitTests/DirectStreamHeadroomGateTests.swift`
- Create: `docs/superpowers/specs/2026-06-13-direct-stream-headroom-gate-design.md`

- [ ] **Step 1: Restore the three files verbatim from the source branch**

```sh
git checkout playback/31-direct-stream-headroom -- \
  PMSKit/Sources/PMSKit/Transcode/DirectStreamHeadroomGate.swift \
  PMSKit/Tests/PMSKitTests/DirectStreamHeadroomGateTests.swift \
  docs/superpowers/specs/2026-06-13-direct-stream-headroom-gate-design.md
```

(These three paths are new on `main`, so the checkout cannot clobber existing work.)

- [ ] **Step 2: Run PMSKit tests.** Run `cd PMSKit && swift test`. Expected: all tests pass, including the six `headroomGate*` / `sourceBitrate*` tests.

- [ ] **Step 3: Commit**

```sh
git add PMSKit/Sources/PMSKit/Transcode/DirectStreamHeadroomGate.swift \
        PMSKit/Tests/PMSKitTests/DirectStreamHeadroomGateTests.swift \
        docs/superpowers/specs/2026-06-13-direct-stream-headroom-gate-design.md
git commit -m "PMSKit: add Direct Stream bandwidth-headroom gate + tests (#31)"
```

### Task 2b.2: Persist the observed-throughput sample (`PlaybackDiagnostics`)

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackDiagnostics.swift` (key near line 16; write at line 106)

- [ ] **Step 1: Add the key** — immediately after the `@Observable @MainActor final class PlaybackDiagnostics {` opening line, add:

```swift
    /// Last observed AVFoundation throughput sample, persisted so the next Direct Stream
    /// startup can conservatively decide whether a single source rendition is likely to fit
    /// the current link (#31). This is intentionally just a heuristic; the experimental
    /// headroom toggle stays default-off.
    static let observedThroughputEstimateKey = "directStreamObservedThroughputKbps"
```

- [ ] **Step 2: Persist on each observed-bitrate update** — replace the line:

```swift
        if event.observedBitrate > 0 { observedBitrateKbps = event.observedBitrate / 1000 }
```

with:

```swift
        if event.observedBitrate > 0 {
            observedBitrateKbps = event.observedBitrate / 1000
            UserDefaults.standard.set(observedBitrateKbps, forKey: Self.observedThroughputEstimateKey)
        }
```

- [ ] **Step 3: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/Player/PlaybackDiagnostics.swift
git commit -m "Persist observed throughput for the Direct Stream headroom gate (#31)"
```

### Task 2b.3: Gate the direct-stream commit in `PlaybackController`

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift` (key near line 102; commit point at 1136-1140)

- [ ] **Step 1: Add the key** — immediately after `static let directStreamEnabledKey = "directStreamEnabled"` (line 102), add:

```swift

    /// `@AppStorage`-style key for #31's experimental Direct Stream headroom gate.
    /// Default OFF: existing Direct Stream behavior is unchanged unless the user explicitly
    /// asks for the additional conservative throughput check.
    static let directStreamHeadroomEnabledKey = "directStreamHeadroomEnabled"
```

- [ ] **Step 2: Apply the gate at the commit point** — replace (lines 1136-1140):

```swift
                if probe.savesVideoEncode {
                    NSLog("PlaybackController: Direct Stream — PMS will copy video; committing direct-play start.m3u8")
                    decision = probe
                    streamURL = transcode.directPlayStartM3U8URL()
                }
```

with:

```swift
                let headroomGate = DirectStreamHeadroomGate(
                    isEnabled: UserDefaults.standard.bool(forKey: Self.directStreamHeadroomEnabledKey),
                    observedThroughputKbps: UserDefaults.standard.object(forKey: PlaybackDiagnostics.observedThroughputEstimateKey) as? Double
                )
                let headroomVerdict = headroomGate.verdict(
                    sourceBitrateKbps: DirectStreamHeadroomGate.sourceBitrateKbps(for: item, mediaIndex: mediaIndex)
                )
                if probe.savesVideoEncode, headroomVerdict.allowsDirectStream {
                    NSLog("PlaybackController: Direct Stream — PMS will copy video; committing direct-play start.m3u8")
                    decision = probe
                    streamURL = transcode.directPlayStartM3U8URL()
                } else if probe.savesVideoEncode {
                    NSLog("PlaybackController: Direct Stream headroom gate blocked copy start (%@); using transcode path",
                          String(describing: headroomVerdict))
                }
```

(`item` and `mediaIndex` are instance properties at lines 66/87, in scope here.)

- [ ] **Step 3: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/Player/PlaybackController.swift
git commit -m "Apply the Direct Stream headroom gate at the copy-commit point (#31)"
```

### Task 2b.4: Add the headroom toggle in Settings (hotspot edit #1 — land alone)

**Files:**
- Modify: `PlexAVPApp/UI/SettingsView.swift` (`@AppStorage` block ~line 29; `playbackSection` toggles ~line 52; footer ~line 58)

- [ ] **Step 1: Add the `@AppStorage`** — after the `directStreamEnabled` `@AppStorage` (line 29), add:

```swift
    /// Optional #31 guard for Direct Stream. Default OFF so the original #7 experimental
    /// behavior stays available for testing unless the user asks for the safer heuristic.
    @AppStorage(PlaybackController.directStreamHeadroomEnabledKey) private var directStreamHeadroomEnabled = false
```

- [ ] **Step 2: Add the toggle** — immediately after the existing `Direct Stream (experimental)` toggle's closing `}` (line 54), add:

```swift
            Toggle(isOn: $directStreamHeadroomEnabled) {
                Label("Require bandwidth headroom", systemImage: "speedometer")
            }
            .disabled(!directStreamEnabled)
```

- [ ] **Step 3: Extend the footer** — replace the footer text (line 58) with the #31-augmented version (keeps the current first three sentences, appends the headroom sentence):

```swift
            Text("The quality new streams start at. Changing quality inside the player updates this too. Direct Stream plays compatible video without re-encoding on the server. The headroom gate is stricter: when enabled, Direct Stream only starts after a recent throughput sample exceeds the source bitrate by 25%.")
```

- [ ] **Step 4: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```sh
git add PlexAVPApp/UI/SettingsView.swift
git commit -m "Settings: experimental Direct Stream headroom toggle (#31)"
```

---

## Wave 2c — #26 Expanded Settings surface

**Why:** Adds server version + on-tap reachability status, a "Reset playback preferences" action, a Maintenance section (clear image cache), an About section (versions, client, copy-diagnostics), and a sign-out confirmation. Supported by a new `productVersion` field on `PlexDevice`, a one-shot `probeSelectedServer()`, bundle-derived app version, and `PlaybackController.persistedPreferenceKeys`.

### Task 2c.1: Add `productVersion` to `PlexDevice` (PMSKit) + test

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Auth/ResourceDiscovery.swift`
- Modify: `PMSKit/Tests/PMSKitTests/ResourceDiscoveryTests.swift`

- [ ] **Step 1: Add the stored property, coding key, memberwise-init param (defaulted), and decode**

In `PlexDevice`:
- After `public let accessToken: String?` add:
  ```swift
    /// PMS version string (e.g. "1.40.2.8395-abcdef123"), as advertised in the
    /// resources payload. Display-only (#26 Settings); absent for non-server devices.
    public let productVersion: String?
  ```
- In `enum CodingKeys`, after `case accessToken` add `case productVersion`.
- In the memberwise `init`, change the signature to add `productVersion: String? = nil` before `connections:` and assign `self.productVersion = productVersion`.
- In the `Decodable` init, after the `accessToken` decode add:
  ```swift
        self.productVersion = try c.decodeIfPresent(String.self, forKey: .productVersion)
  ```

(The `= nil` default keeps every existing positional call site — including tests — compiling.)

- [ ] **Step 2: Add a decode test** — append the verbatim test from the source branch:

```sh
git diff $(git merge-base main settings/26-expanded-surface)..settings/26-expanded-surface -- PMSKit/Tests/PMSKitTests/ResourceDiscoveryTests.swift
```

Apply that +20-line hunk (a test that decodes a resources payload containing `productVersion` and asserts the field is populated). If the surrounding test file has drifted, adapt the insertion point but keep the assertion identical.

- [ ] **Step 3: Run PMSKit tests.** Run `cd PMSKit && swift test`. Expected: all pass.

- [ ] **Step 4: Commit**

```sh
git add PMSKit/Sources/PMSKit/Auth/ResourceDiscovery.swift PMSKit/Tests/PMSKitTests/ResourceDiscoveryTests.swift
git commit -m "PMSKit: decode productVersion on PlexDevice for Settings display (#26)"
```

### Task 2c.2: Derive the app version from the bundle (`ContentView`)

**Files:**
- Modify: `PlexAVPApp/App/ContentView.swift`

- [ ] **Step 1: Replace the hardcoded `version: "0.1.0"`** in the `ClientIdentity(...)` construction with the bundle value:

```swift
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
```

and add the rationale comment above the `ClientIdentity(` call:

```swift
        // Version comes from the bundle (#26) so the X-Plex-Version header can't
        // silently drift from the real marketing version.
```

- [ ] **Step 2: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/App/ContentView.swift
git commit -m "Derive X-Plex-Version from the bundle, not a hardcoded string (#26)"
```

### Task 2c.3: One-shot `probeSelectedServer()` (`AuthManager`)

**Files:**
- Modify: `PlexAVPApp/Auth/AuthManager.swift` (insert before `func signOut()`)

- [ ] **Step 1: Add the method** (verbatim from #26):

```swift
    /// One-shot reachability check of the CURRENTLY selected connection, for the Settings
    /// connection-status row (#26). Same `<uri>/identity` probe as `firstReachable`, but
    /// against the single resolved `serverBaseURL` — no re-discovery, no state changes.
    func probeSelectedServer() async -> Bool {
        guard let base = appModel.serverBaseURL, let token = appModel.serverToken else {
            return false
        }
        var req = URLRequest(url: base.appendingPathComponent("identity"))
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, resp) = try await Self.probeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
```

(`appModel`, `Self.probeSession` confirmed present at AuthManager.swift:28/169.)

- [ ] **Step 2: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/Auth/AuthManager.swift
git commit -m "Auth: one-shot probeSelectedServer() reachability check for Settings (#26)"
```

### Task 2c.4: `persistedPreferenceKeys` (`PlaybackController`)

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift` (after the `AudioPrefKey` enum, ~line 230)

- [ ] **Step 1: Add the array** — after the closing `}` of `enum AudioPrefKey`, add:

```swift

    /// Every UserDefaults key this controller persists across sessions, for the Settings
    /// "Reset playback preferences" row (#26). Deliberately EXCLUDES `maxVideoBitrateKbps`,
    /// which has its own Streaming-quality picker. Keep in sync with the key enums above.
    static let persistedPreferenceKeys: [String] = [
        playbackSpeedKey,
        SubtitlePrefKey.language,
        SubtitlePrefKey.off,
        AudioPrefKey.language,
    ]
```

- [ ] **Step 2: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/Player/PlaybackController.swift
git commit -m "Player: expose persistedPreferenceKeys for the Settings reset row (#26)"
```

### Task 2c.5: Expand `SettingsView` (hotspot edit #2 — land alone, after 2b.4)

**Files:**
- Modify: `PlexAVPApp/UI/SettingsView.swift`

This is the large surface from #26. Re-apply onto the current section-structured view. The current view already has `serverSection`/`playbackSection`/`storageSection`/`accountSection` computed properties — same structure the #26 branch expanded.

- [ ] **Step 1: Imports + state** — add `import UIKit` after `import SwiftUI`; update the doc comment to the #26 wording; add the new `@State` vars:

```swift
    @State private var confirmingSignOut = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    /// Transient "done" feedback for the one-shot maintenance/About actions.
    @State private var clearedImageCache = false
    @State private var resetPlaybackPrefs = false
    @State private var copiedDiagnostics = false
```

- [ ] **Step 2: Body section order** — insert `maintenanceSection` and `aboutSection` between `storageSection` and `accountSection`:

```swift
            serverSection
            playbackSection
            storageSection
            maintenanceSection
            aboutSection
            accountSection
```

- [ ] **Step 3: `playbackSection` — add the reset-prefs button + extend footer.** After the headroom toggle added in 2b.4, add the reset button:

```swift
            Button {
                // Clears speed + subtitle/audio-language keys (single source of truth in
                // PlaybackController). Deliberately leaves `maxVideoBitrateKbps` alone —
                // the picker above owns it.
                let defaults = UserDefaults.standard
                for key in PlaybackController.persistedPreferenceKeys {
                    defaults.removeObject(forKey: key)
                }
                resetPlaybackPrefs = true
            } label: {
                if resetPlaybackPrefs {
                    Label("Preferences reset", systemImage: "checkmark")
                } else {
                    Label("Reset playback preferences", systemImage: "arrow.counterclockwise")
                }
            }
            .disabled(resetPlaybackPrefs)
```

Then replace the footer with the fully combined text (current + #31 headroom + #26 reset):

```swift
            Text("The quality new streams start at. Changing quality inside the player updates this too. Direct Stream plays compatible video without re-encoding on the server. The headroom gate is stricter: when enabled, Direct Stream only starts after a recent throughput sample exceeds the source bitrate by 25%. Reset clears the remembered playback speed and subtitle/audio language; streaming quality is unaffected.")
```

- [ ] **Step 4: `serverSection` — add `ConnectionStatus` enum, version row, status row, re-arm on re-discover.** Add the enum + helpers and the rows exactly as in the #26 diff:
  - Add the `private enum ConnectionStatus { case unknown, checking, reachable(Date), unreachable(Date) }` above `serverSection`.
  - In `serverSection`, after the `LabeledContent("Name", …)` add the conditional `Version` row; after the `Connection` `LabeledContent` add `connectionStatusRow`; in the re-discover `Task`, append `connectionStatus = .unknown` after `rediscovering = false`.
  - Add the `connectionStatusRow` computed property and the `checkedAt(_:)` helper (verbatim from the #26 diff).

- [ ] **Step 5: Add `maintenanceSection` and `aboutSection`** (verbatim from the #26 diff — clear-image-cache button + footer; About with app version/build, visionOS, client, copy-diagnostics; `appVersion`/`appBuild` statics; `diagnosticsText`). The diagnostics blob includes only versions, server name/version, and the connection **scheme** — never token/clientIdentifier/full URL (privacy constraint).

- [ ] **Step 6: `accountSection` — sign-out confirmation.** Change the Sign Out button action from `authManager.signOut()` to `confirmingSignOut = true`, and attach the `.confirmationDialog(...)` (verbatim from the #26 diff) that calls `authManager.signOut()` on confirm.

To recover any exact block, read it from the source branch:
```sh
git diff $(git merge-base main settings/26-expanded-surface)..settings/26-expanded-surface -- PlexAVPApp/UI/SettingsView.swift
```

- [ ] **Step 7: Build-clean gate.** Expected: `** BUILD SUCCEEDED **`. Watch for: missing `import UIKit` (UIPasteboard), and the privacy check — confirm `diagnosticsText` contains no token/identifier/host.

- [ ] **Step 8: Commit**

```sh
git add PlexAVPApp/UI/SettingsView.swift
git commit -m "Settings: server version+status, pref reset, maintenance, About, sign-out confirm (#26)"
```

---

## Wave 2d — #27 / #7 / #33 verification (no code this wave)

**Why:** #27 (transcode session lifecycle / OOM guards), #7 (Direct Stream within cap), and #33 (final-target rebuild) are **open and verification-gated** — their live-tests in `TESTING-CHECKLIST.md` instruct the owner to read the `[VP]` NSLog instrumentation (`[VP] transcode: stopping…`, `[VP] seek: rebuilding…`, `[VP] decision:`). **Do NOT strip those `[VP]` logs this wave** — they are the verification signal. The strip is deferred to after the owner closes #27/#33/#7 (tracked under the docs/log-hygiene work, not here).

- [ ] **Step 1:** Confirm the existing checklist items for #7 (Direct Stream), #27/#33 (transcode lifecycle, final-target rebuild) are present and accurate (they are, at TESTING-CHECKLIST.md §B). No code change. The #31 headroom toggle adds one new sub-case under #7 — captured in Task 2e.

---

## Wave 2e — Wave 2 live-sim checklist

**Files:**
- Modify: `TESTING-CHECKLIST.md`

- [ ] **Step 1: Append a "Wave 2 — Plex bar" section** with these items:

```markdown
## Wave 2 — Plex bar (re-applied onto the custom player)

_Build-verified on `wave2/plex-bar` (stacked on `wave1/...`). In-headset checks before merge._

### #30 — failure card layout
- [ ] Trigger a playback failure (kill the server mid-stream): the failure card shows **Retry stacked ABOVE Close**, both buttons equal width, centered (not a wide edge-to-edge row).

### #34 — reconnecting overlay (verify, then close issue)
- [ ] Trigger a transient reconnect: the "Reconnecting…" card is a **compact centered dialog** (≈260pt), not full-window-width. (Already satisfied by the custom rewrite — confirm and close #34.)

### #31 — Direct Stream headroom gate (default OFF)
- [ ] Settings ▸ Playback shows "Require bandwidth headroom", **disabled** until "Direct Stream (experimental)" is ON.
- [ ] With BOTH on, play an in-cap copy-eligible title on a fast link: log shows the direct-play commit (gate allowed).
- [ ] With BOTH on, on a constrained link (or low recent throughput sample): log shows `headroom gate blocked copy start (...)` and playback falls back to transcode — no stall.
- [ ] With the headroom toggle OFF, behavior is identical to today's #7 Direct Stream.

### #26 — expanded Settings
- [ ] Server section shows the PMS **Version**; the **Status** row says "Tap to check", and tapping shows a green/red dot + "Checked <time>".
- [ ] "Reset playback preferences" clears remembered speed + subtitle/audio language (NOT streaming quality), shows "Preferences reset".
- [ ] Maintenance ▸ "Clear image cache" shows "Cache cleared"; artwork re-downloads on next view.
- [ ] About shows app version (build), visionOS, client (product on device — never the identifier); "Copy diagnostics" copies a blob containing NO token/identifier/hostname (scheme only).
- [ ] Sign Out now shows a confirmation dialog; Cancel keeps you signed in, Sign Out returns to login.
```

- [ ] **Step 2: Commit**

```sh
git add TESTING-CHECKLIST.md
git commit -m "Add Wave 2 live-sim checklist"
```

---

## Self-review against the roadmap (spec coverage)

- **#30 (Retry above Close):** Task 2a.1 re-applies the VStack/minWidth layout to the custom `failureCard`. ✅
- **#34 (Reconnecting width):** Verified already satisfied by the custom `CustomReconnectingOverlay` (`.frame(width: 260)`) — no code, close after owner eyeball (Task 2a.4 / 2e). ✅
- **#31 (headroom gate, default OFF):** PMSKit gate+tests verbatim (2b.1), throughput persistence (2b.2), commit-point gate (2b.3), opt-in toggle disabled unless Direct Stream is on (2b.4). ✅
- **#26 (expanded Settings):** `productVersion` decode + test (2c.1), bundle version (2c.2), `probeSelectedServer` (2c.3), `persistedPreferenceKeys` (2c.4), full Settings surface (2c.5). ✅
- **SettingsView 3-way hotspot:** edited in exactly two commits — #31 toggle (2b.4) then #26 expansion (2c.5) — never interleaved; footer reconciled to a single combined string in 2c.5. ✅
- **#27/#7/#33:** verification-only; `[VP]` logs preserved as live-test signal (2d). ✅
- **Do-not-merge constraint:** every branch feature is re-applied hunk-by-hunk (or `git checkout -- <new-path>` for files absent on main); no `git merge`/`rebase` of the ancient-base branches. ✅
- **Privacy:** diagnostics blob audited to exclude token/clientIdentifier/host (2c.5 Step 7). ✅
