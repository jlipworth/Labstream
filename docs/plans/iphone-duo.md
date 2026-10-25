# iPhone Duo support for LabstreamMobile

**Status (2026-10-25):** plan approved for implementation on `duo/support`, based on
`downloads/overhaul`. The worktree Duo simulator platform is done (`c8cbbf5f`). Part 1 (toolchain,
shell and non-player layout: Steps 1, 6, 7, 9 and the Step 8 hero sizing) is done; see the
journal. The player steps (2 to 5), the Step 8 rail metrics, Step 10 and Step 11 are open. The physical iPhone Duo gate and the Duo App Store screenshot gate stay open until
a person performs them. Simulator evidence does not close either one.

**Tracking:** [#419](https://github.com/jlipworth/Labstream/issues/419).

**Scope:** `LabstreamMobile` layout, player and test adaptation for both iPhone Duo displays, for
fold/unfold during a session (including during playback), and for the iOS 27.1 vertical
tab bar and toolbars. It also covers moving every target onto the Xcode 27.1 toolchain. The
visionOS, tvOS and macOS sources need no Duo-specific changes. Their only part in this work is
toolchain regression coverage.

**Out of scope:** physical-device acceptance, App Store Connect screenshot upload, and any change to
`TranscodeRequest`. The hard constraint `X-Plex-Client-Profile-Name=Generic` is untouched, and no
stream parameter is screen-derived.

## Platform facts verified on Xcode 27.1 (27A9275)

| Fact | Evidence | Consequence |
| --- | --- | --- |
| Xcode 27.1 ships the 27.1 SDK for **iOS only**. visionOS, tvOS, macOS, watchOS and DriverKit stay on 27.0 SDKs. | `xcodebuild -showsdks` | The "SDK bump" has a real effect only on LabstreamMobile. The other three targets are rebuilt on the 27.0 SDKs bundled with 27.1. |
| Every target uses an unversioned `SDKROOT` (`iphoneos`, `xros`, `appletvos`, `macosx`). | `project.pbxproj` | The bump is a toolchain change. The pbxproj does not change. Deployment targets stay as they are (iOS 26.1, visionOS/tvOS/macOS 26.0). |
| The Duo device type is `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo` (iPhone19,4), minimum runtime iOS 27.1. | `simctl list devicetypes` | `scripts/worktree-sim.sh --platform duo` (already landed) never falls back to a regular iPhone. |
| Outer display: 466×678 pt (1398×2034 px). Inner display: 669×951 pt (2007×2853 px). | `simctl io enumerate`, baseline screenshots | **Both displays are about 1.45:1.** Neither is a tall 19.5:9 phone viewport. The outer display is compact width. The inner display (tested via appResize) gets the regular-width layout. |
| Folded, the status bar runs vertically along the right edge of the 466×678 scene. | baseline `initial-display1-LCD.png` | Trailing-edge chrome (the A–Z rail, player top-trailing buttons) must respect the trailing inset in **both** states, not only on the inner display. |
| UIKit 27.1 **does** have a hinge API: `UIHinge.Status` via `UIHingeInteraction`, plus `UIView.reservedRegions`, `UIVerticalBarEdge`, `UIArrangementViewController` and `UISplitArrangement`/`UIOverlayArrangement`. | `UIHinge.h` in the 27.1 SDK | This corrects the issue text, which said there is no hinge API. Layout still keys on geometry and size class. Hinge status is used only for diagnostics. `reservedRegions`/`UIVerticalBarEdge` are the supported way to find the vertical bar. |
| Folding cannot be driven headlessly. Device Hub's Poses/hinge control is GUI-only, backed by private CoreDevice, and no `simctl`, `devicectl` or XCUIAutomation API exists for it. | toolchain investigation | Automated runs cover the folded state plus `devicectl device appResize` at the inner size. A real fold or unfold, especially during playback, is a manual Device Hub step or a physical-device step. |
| Apple's "get my app ready for iPhone Duo" skill: `xcrun agent skills export` hung waiting on Xcode. A fallback copy was taken from `Xcode.app/…/IDEIntelligenceChat.framework/…/app-resizability*` (prompt template plus uiscreen, orientation, idiom, safe-area and scene-lifecycle task references). | toolchain investigation | Use it as a checklist during implementation. Do not commit it, because it is Apple content. |

Baseline (unchanged source, iOS 27.1 SDK): clean build with exit 0, about 18 pre-existing
concurrency/unused-value warnings and no SDK deprecations, matching install UUID, no crash. The
new Duo simulator is not signed in, so live browse and playback on the Duo need the user to sign
in. The credential-free XCUITest fixtures (`--ui-testing-fixture browse`, `MobilePlayerFixture`)
do not.

## Audit triage

Two read-only audits (layout and player) produced the findings below. Kept findings map to
steps. Dropped or reframed findings and the reasons:

| Finding | Disposition | Why |
| --- | --- | --- |
| `PlatformClientIdentity` idiom → "iPhone"/"iPad" | **Dropped.** | Not a layout hazard. The Duo is truthfully an iPhone and the value is stable across a fold. |
| Orientation lock gated on aspect > ~1.6 | **Reframed.** | Both Duo displays are about 1.45:1, so an aspect gate would also unlock the folded outer display, which is still a phone-class viewport (short side 466 pt). Gate on short side < 500 pt (the same cap `isPhoneLandscape` already uses), and only then if the scene honours the request (Step 3). |
| Per-aspect-class Fill auto-revert ("Fill on the narrow outer display crops badly on the square inner display") | **Mostly dropped.** | The premise is wrong. Both displays have the same aspect, so a fold does not change the Fill crop fraction materially. The preference is per-device, so the user's choice stays. What remains: gravity changes and layer resizes must not animate jankily during a fold (Step 4). |
| Inner display might report compact width, giving 110 pt posters at 700 pt | **Dropped.** | appResize at 669×951 renders the regular-width layout. Measured-width metrics stay as an improvement (Step 8), not as a defect fix. |
| `UISupportedInterfaceOrientations` excludes upside-down | **Verify only.** | Speculative. Change it only if the 27.1 Duo simulator shows letterboxing or rotation refusal (Step 11). Never add `UIRequiresFullScreen`. |
| Trick-play card 190×107 `.fill` | **Deferred.** | This affects every device, not just the Duo (scope-ratio previews crop everywhere). Track it separately and keep it out of this branch. |
| PiP bound to the first layer only | **Kept as a defensive low item** (Step 4). | It is latent, because iOS never recreates `PlayerLayerView` today. The restore-UI delegate gap is real. |
| `isPhoneLandscape` includes `idiom == .phone` | **Kept, unchanged.** | Otherwise geometry-driven with a 500 pt short-side cap, so it is correct on the Duo. |

## Fold-during-playback design

A fold is a **layout event only**. The invariants below add to the ones in
[PLAYBACK-ARCHITECTURE.md](../PLAYBACK-ARCHITECTURE.md):

1. **No playback authority change.** The same `PlaybackController` generation and the same
   `AVPlayer`/`AVPlayerLayer` survive the fold. There is no `stop`, `load`, reopen, quality change,
   transcode-session renegotiation, seek-hold reset or restart-budget spend. `videoGravity` is
   only ever mutated in place.
2. **The presenter survives.** The `.fullScreenCover` presenter (`DetailView.leafDetailScroll`,
   `OfflineLibraryView.offlineNavigationContent`) is attached to size-class-independent roots.
   Step 2 proves this on the Duo and with iPad Stage Manager resizes. If the `.sidebarAdaptable`
   restructure or the compact/regular tab-set swap drops the presenter, presentation state
   (`presentingPlayer`, `playingItem`, `remotePlayback`) and the cover move above the `TabView` into
   `PlatformRootShell`, owned per window scene.
3. **A transient inactive phase is not background.** Video pauses only on `didEnterBackground` or
   scene `.background`. A `willResignActive` pause, if it is kept at all, is deferred by about
   400 ms, cancelled by `didBecomeActive`, and skipped when PiP or AirPlay/external playback is
   active. Auto-PiP from inline is suppressed for a short window around geometry changes if the
   simulator shows a fold passing through background.
4. **Orientation follows geometry.** The landscape lock applies only while the hosting scene is
   phone-class (short side < 500 pt). It is re-evaluated on every effective-geometry change:
   unfolding releases it (`.allButUpsideDown` plus
   `setNeedsUpdateOfSupportedInterfaceOrientations`, with no forced rotation), and folding
   re-applies it. Restore at close is skipped when the display class changed since entry; only the
   mask is widened. The pre-presentation and pre-dismissal 500 ms polls exit immediately when no
   forced rotation is pending. The scene comes from the player's own window, not
   `connectedScenes.first`.
5. **Chrome re-derives everything from measured geometry.** Compact, phone-landscape and regular
   chrome come from `chromeViewportSize` and size classes, never from idiom. The top chrome pads by
   a latched top safe inset, reset on viewport-size change. Menus are width-clamped in every
   branch. A branch change during a scrub cancels the scrub cleanly. The transport-status timers
   stay in the controller, so their staged timing is not reset by layout.

Probe: `player.view_disappear`, `player.controller_stop`, `player.lifecycle_pause` (reason:
`resign`/`background`) and `player.geometry_change` (bounds, size classes, hinge status from a
read-only `UIHingeInteraction`, orientation-lock decision) are recorded through `AppDiagnostics`/
`PlayerGeometryProbe` so that a fold run can be judged from bounded evidence.

## iOS 27.1 vertical tab bar and toolbar adoption

- Build LabstreamMobile on the 27.1 SDK, which opts it into the full inner display and the vertical
  bars. There is no opt-out key, and none should be added.
- Find the bar from the supported API (`UIView.reservedRegions` / `UIVerticalBarEdge`) or from the
  trailing safe-area inset. Never from idiom or size class.
- `MobileRootShell`: verify where `tabViewBottomAccessory` (MiniPlayerBar) and
  `tabBarMinimizeBehavior(.onScrollDown)` end up when the bar is vertical. If the accessory is
  unsupported or awkward, host MiniPlayerBar via `safeAreaInset(edge: .bottom)` while the bar is
  vertical, and keep the minimize behaviour only for a bottom bar.
- Compact↔regular tab-set swap: on compact→regular with `showsSettingsSheet == true`, dismiss
  the sheet and select `.settings`. Keep the existing regular→compact handling. Fix the
  "iPad sidebar" comment: `.sidebarAdaptable` with a phone idiom gives a tab bar.
- Trailing-edge consumers (the A–Z rail in `LibraryGridView`/`MusicPagedGrid`, the player top-trailing
  buttons, toolbar items) respect the bar's reserved region.

## Implementation steps

Each step is one or more logical local commits. Hermetic policy logic goes in PMSKit with unit
tests. App-side wiring stays thin.

### Step 1: toolchain and lanes (SDK move, no source change)

- Confirm that all four schemes build clean on Xcode 27.1 with worktree-local DerivedData:
  `Labstream` (xros 27.0 SDK), `LabstreamMobile` (iphonesimulator 27.1), `LabstreamTV`
  (appletvos 27.0) and `LabstreamMac` (macosx 27.0, through `scripts/deploy-macos-to-host.sh`). Record
  the warning delta against the baseline log.
- Leave deployment targets unchanged unless a 27.1 build demands otherwise. None is expected.
- `scripts/native-test-matrix.py`: add a `duo` lane (affected by `Labstream/Shared/**`,
  `Labstream/Platforms/Mobile/**`, `LabstreamMobileUITests/**`) that resolves its simulator via
  `scripts/worktree-sim.sh --platform duo id`, with tests in `scripts/tests/`.
- Docs: record "Xcode 27.1 required for the Duo lane; the iOS SDK is 27.1 and the other platform
  SDKs are 27.0" in `docs/DEVELOPMENT.md` and in the Xcode prerequisite of `docs/MACOS-CI.md`.

### Step 2: instrument, then establish the fold facts (decides Steps 3–5)

- Add the diagnostics listed in the design section:
  - `CustomPlayerView.swift`, in `.onDisappear` and on controller stop;
  - `AudioSessionCoordinator.swift`, in the pause observers;
  - a geometry observer in `MobilePlayerOrientationCoordinator.swift`;
  - a read-only `UIHingeInteraction` probe attached to the player host view.
- On the Duo simulator, run the player fixture. A person drives Device Hub to fold, unfold and
  fold again. Record scene phase, resign/background notifications, cover persistence,
  `requestGeometryUpdate` outcome and trailing reserved regions in each state. Proxy without a
  person: `devicectl device appResize start/set` between 466×678 and 669×951 during playback, plus
  iPad Stage Manager compact↔regular resizes.
- Write the observed answers to these three questions into this plan's journal:
  1. Does a fold emit resign-active?
  2. Does the cover survive the TabView restructure?
  3. Does the 27.1 inner display honour orientation requests?

### Step 3: geometry-driven orientation lock

- New PMSKit policy `MobilePlayerOrientationLockPolicy`, next to the existing
  `PMSKit/Sources/PMSKit/Playback/MobilePlayerOrientationRestorePolicy.swift`. Inputs: scene
  bounds, size classes, and whether the scene honoured the last request. Outputs: lock/unlock/none
  and whether to wait. The existing restore policy gains an "entry display class differs → widen
  mask only" branch.
- `Labstream/Platforms/Mobile/Player/MobilePlayerOrientationCoordinator.swift`:
  - replace the `idiom == .phone` gate with the policy;
  - observe effective-geometry changes while active;
  - store the display class alongside `previousOrientation`;
  - resolve the scene from the player's window (a small `UIViewRepresentable` window reader);
  - short-circuit both 500 ms polls when no rotation is pending.
- Tests: `PMSKit/Tests/PMSKitTests/MobilePlayerOrientationLockPolicyTests.swift`, covering iPhone 18
  Pro portrait and landscape, Duo outer 466×678 / 678×466, Duo inner 669×951 / 951×669, iPad, and
  the declined-request case. Extend `MobilePlayerOrientationRestorePolicyTests.swift`.

### Step 4: player chrome, safe area, gravity, lifecycle and PiP

- `Labstream/Platforms/Mobile/Player/MobilePlayerChrome.swift`: move
  `MobilePlayerChromeLayoutPolicy` (pure) into PMSKit. Drop the idiom term from `usesCompactChrome`
  so the decision comes from measured viewport and size class (short side < 500 or a compact class).
  Remove `idiom:` from `mobileChromeLayout`, except where `isPhoneLandscape` uses it. Add
  `MobilePlayerChromeLayoutPolicyTests` with Duo folded and unfolded viewports in both
  orientations.
- `Labstream/Shared/Player/CustomPlayerChrome.swift`:
  - clamp `adaptiveMenuWidth` and menu heights to available width in every branch (Stats 470 + insets
    must not overflow a medium viewport);
  - add `.onChange(of:)` on the derived control branch, and on a branch change mid-drag, cancel the
    scrub, clear the trick-play preview, reset `scrubEditingSessionActive` and reschedule
    chrome hide (the same path as tvOS focus exit);
  - replace the `idiom == .pad` hover guard (around line 1279) with a check for a non-compact
    viewport. `onContinuousHover` already fires only for indirect pointers.
- `Labstream/Shared/Player/CustomPlayerView.swift`: keep the full-bleed `.ignoresSafeArea(.container,
  edges: .top)` envelope. Pad `topChrome` by `max(current inset, latched top safe inset)`, measured
  from a view that does not ignore the safe area and reset when viewport size changes. Rewrite
  the "iPhone playback is landscape-only" comment. Apply `videoGravity` updates inside a
  `CATransaction` with implicit actions disabled, so that a resize or fold does not animate the
  crop.
- `Labstream/Shared/Player/AudioSessionCoordinator.swift`: pause video on `didEnterBackground` only,
  or use the deferred, cancellable resign-active pause if Step 2 shows resign-active without
  background. Respect `shouldContinueOnBackground` and external playback first. This also
  covers the suspected race with `canStartPictureInPictureAutomaticallyFromInline`.
- `Labstream/Platforms/Mobile/Player/MobilePlayerSystemCoordinator.swift`: rebind PiP `contentSource`
  when a different layer attaches and PiP is inactive. Implement
  `restoreUserInterfaceForPictureInPictureStop` so it completes `true` while the cover is presented.
  Suppress auto-PiP around geometry changes only if Step 2 shows a fold passing through background.
- Docs: add the fold invariants to `docs/PLAYBACK-ARCHITECTURE.md`, including updating any Mermaid
  diagram whose depicted ownership changes.

### Step 5: presenter ownership (only if Step 2 shows the cover is dropped)

- Move `presentingPlayer`/`playingItem`/`remotePlayback` and the `.fullScreenCover` from
  `DetailView`/`OfflineLibraryView` into the iOS `PlatformRootShell`
  (`Labstream/Platforms/Mobile/UI/MobileRootShell.swift`), owned per scene. If Step 2 shows the cover survives, skip this step and record that in the journal.

### Step 6: shell and 27.1 vertical bars

- `Labstream/Platforms/Mobile/UI/MobileRootShell.swift`: apply the adoption rules above (MiniPlayerBar
  hosting, minimize behaviour, compact→regular Settings sheet hand-off, comment fix).
- `Labstream/Shared/UI/LibraryGridView.swift` and `Labstream/Shared/Music/MusicPagedGrid.swift`: reserve the A–Z rail strip
  whenever the rail is visible, not only in compact width, and inset it by the vertical bar's
  reserved region or trailing safe inset. Compute the rail's `ViewThatFits` thinning against the
  height that remains after the bar.

### Step 7: idiom-as-size removal in browse

- `Labstream/Shared/UI/DetailView.swift`: replace `isCompactPhoneLayout` (idiom plus size class)
  with a measured-width decision: phone composition below ~500 pt, stacked below ~700 pt,
  side-by-side above. Cap `compactPhoneArtwork` height at about 40% of the viewport, and keep the
  scroll anchor across the flip.
- `Labstream/Shared/UI/HomeView.swift` (around line 618): gate dense spacing on measured height, or keep
  regular/regular if Duo screenshots look right. Either way, rewrite the comment to say "large
  two-dimensional viewport", not iPad.

### Step 8: measured-width browse metrics

- `Labstream/Shared/UI/DesignSystem.swift`: rail poster width and detail hero size come from measured
  container width (target visible count, clamped min/max), following
  `PMSKit/Sources/PMSKit/UI/MobileLibraryGridLayout.swift`. Pure math goes in PMSKit with tests that
  include 466, 669, 678 and 951 pt widths. `labstreamCompactWidth` stays as a coarse fallback.
- Preserve horizontal rail offsets across the transition (`scrollPosition(id:)`) on Home shelves; move
  `Labstream/Shared/Music/NowPlayingView.swift` art sizing to measured width too.

### Step 9: sign-in screens

- `Labstream/Shared/UI/LoginChromeComponents.swift` (compact branch): the baseline folded screenshot
  shows the brand wash ending at about 376×417 pt in the top-left instead of spanning the width.
  The fixed `frame(height: 430)` overlay is intentional, but the width truncation is not.
  Reproduce it on the Duo outer display and make the wash span the full width with a
  height relative to the container. Also check `LoginView`, `BackendSignInComponents` and
  `PairingCodeView` in both states.

### Step 10: Duo XCUITest smoke and regression lanes

- New `LabstreamMobileUITests/LabstreamMobileDuoUITests.swift`. It skips unless the device is a Duo,
  detected from `ProcessInfo` `SIMULATOR_MODEL_IDENTIFIER` or measured window size, not idiom.
  - **Folded (default boot):** fixture browse → detail → player. Assert the same `playback.surface`
    element, an advancing playhead, the chrome envelope inside the safe area, top chrome clearing
    the top inset, trailing controls clearing the vertical bar, and a `videoRect` inside the layer
    bounds with `resizeAspect`. Attach screenshots.
  - **Inner size:** the same flow with the app resized to 669×951 via a host-side
    `devicectl device appResize` wrapper (`scripts/duo-appresize.sh`, written for this step) started
    before the test.
  - **Transition proxy:** during playback, the host wrapper flips appResize between the two sizes.
    The test asserts one controller generation, no `player.view_disappear`/`player.controller_stop`/
    restart diagnostics, no `player.orientation_request_failed`, and an advancing playhead. Run
    the same flow with Settings selected and with the Settings sheet open.
- Rework `testPlayerChromeFramesAreStableAcrossSourceAspects`
  (`LabstreamMobileFixtureUITests.swift`), which assumes iPhone means forced landscape, so that it
  chooses the expected orientation from measured geometry.
- Regression lanes, required green before handoff:
  - hermetic PMSKit tests (`swift test --package-path PMSKit --no-parallel --skip
    'Live.*ProbeTests'`);
  - mobile fixture XCUITests on iPhone 18 Pro and iPad (including a Stage Manager resize), plus the Duo
    suite;
  - visionOS install/launch smoke;
  - tvOS build plus fixture tests;
  - macOS host build/launch;
  - strict MkDocs, `check-doc-links.py`, `check-docs-mermaid.py`, `scripts/ci-hygiene.sh`.
- Simulator turns are strictly one at a time, and each simulator is shut down at the end of its
  turn.

### Step 11: verification sweep and docs

- Manual Device Hub pass (user): sign in to Plex on the Duo simulator. Do browse → detail →
  playback folded, unfold mid-playback, fold back, open PiP, close the player in the other state.
  Collect screenshots and bounded diagnostics with the `diagnostic-triage` skill.
- Confirm whether the Info.plist orientation list needs changing. Default: no change.
- Docs:
  - `docs/MOBILE-IOS.md`: a Duo section covering the geometry contract and the vertical bars;
  - `docs/TESTING-STRATEGY.md`: the Duo runner, its appResize proxy, and the gaps that remain manual;
  - `TESTING-CHECKLIST.md`: Duo folded, unfolded and transition rows;
  - `docs/APP-STORE-SCREENSHOTS.md`: the Duo screenshot sizes and the open gate;
  - `docs/DEVELOPMENT.md`: verified findings such as "no headless fold" and "both displays ~1.45:1".

## Test plan summary

| Lane | Covers | Automation |
| --- | --- | --- |
| PMSKit unit | Orientation-lock, restore, chrome-layout and rail-metric policies at Duo/iPhone/iPad viewports | Hermetic, headless |
| Duo XCUITest, folded | Browse → detail → playback on the outer display, safe area, vertical status bar | Headless, `.simid-duo` |
| Duo XCUITest, inner size | The same flow at 669×951 via appResize | Headless (host wrapper) |
| Duo XCUITest, transition proxy | Resize during playback and with Settings open: no stop, no restart, advancing playhead | Headless proxy. **Not** a real fold |
| iPad Stage Manager resize | Compact↔regular trait path, cover survival | Headless |
| Real fold/unfold | Display switch, scene phase, hinge status, PiP | Manual Device Hub (user) |
| Regression | iPhone 18 Pro, iPad, visionOS, tvOS, macOS lanes; docs checks | Per `scripts/native-test-matrix.py affected` |

## Open gates

- **Physical iPhone Duo:** real fold during playback, PiP and AirPlay across a fold, HDR/DV on
  both panels, trackpad hover on the inner display. This is the user's hardware gate and stays
  open until performed.
- **Duo App Store screenshots:** the release gate for the iPhone Duo product-page badge. Capture
  follows `docs/APP-STORE-SCREENSHOTS.md` and the store-demo plan. Upload needs explicit user
  approval.
- **Real fold in the simulator:** Device Hub only. Automated runs prove the folded state and
  resize proxies, not the display switch.
- **Cross-backend playback:** if Step 4 touches shared player behaviour, Plex, Jellyfin and Emby
  each need a recorded pass. The Duo simulator is Plex-only once signed in. The other backends
  stay blocked or untested until they are configured.
- **Merge:** the user merges `duo/support` into `downloads/overhaul`. Agents do not push, open a PR
  or merge.

## Journal

- 2026-10-25: toolchain ready (Xcode 27.1, iOS 27.1 runtime, Duo simulator
  `.simid-duo`). Baseline build and launch are clean on unchanged source. Both audits were
  triaged into this plan.
- 2026-10-25, Part 1 (toolchain and non-player layout):
  - Step 1: all four schemes build clean on Xcode 27.1 with worktree-local DerivedData. The
    warning sets are identical to the unchanged-source baseline for every scheme (mobile 16,
    visionOS 16, tvOS 8, macOS 18 unique warnings). `duo-ui-smoke` was added to the native
    matrix (`--duo-sim-id`, `.simid-duo`) with topology tests, and the toolchain is recorded in
    `docs/DEVELOPMENT.md`, `docs/MACOS-CI.md` and `docs/TESTING-STRATEGY.md`.
  - Observed on the folded Duo simulator (fixture browse): the 27.1 SDK puts the tab bar and the
    toolbar items (Settings gear, back button) in a vertical bar on the trailing edge below the
    vertical status bar. Content and the detail page stay inside the safe area; horizontal
    rails scroll under the floating bar like vertical content under a bottom bar. The appResize
    proxy at 669×951 shows the regular tab set (Settings is a tab) with a bottom bar, so the
    proxy does not exercise the inner display's vertical bar.
  - Step 6: compact→regular now hands an open Settings sheet back to the Settings tab
    (`MobileSettingsPresentationPolicy`, hosted tests pass on the Duo simulator). The shell
    comment no longer calls `.sidebarAdaptable` an iPad sidebar. The A–Z rail reserves its strip
    in regular width (iOS video grid and iOS music grid); it is laid out inside the safe area,
    so it clears the vertical bar without a separate inset. MiniPlayerBar stays on
    `tabViewBottomAccessory` and minimize-on-scroll is unchanged: neither could be observed
    beside the vertical bar without music playing, so that check stays open.
  - Step 7: `DetailView` composition comes from PMSKit `MobileDetailLayoutPolicy` (measured
    viewport: phone below 500 pt or a compact viewport with a short side under 500 pt, stacked
    below 700 pt, side by side above). The compact key art is capped at 40% of the viewport
    height. `HomeView` dense spacing keeps regular/regular with a corrected comment.
  - Step 8 (partial): the Now Playing hero is bounded by the measured sheet on iOS. Rail poster
    widths stay on the size-class constants: both Duo displays already land on the authored
    values (466 pt compact → 110 pt posters, about 3.9 visible; 669 pt regular → 184 pt, about
    3.4 visible), so plumbing measured width through every rail was deferred. Rail scroll
    positions across a fold were not changed (no reset was observed; needs a real fold).
  - Step 9: the compact login brand wash now ignores the horizontal safe area too, so it spans
    the folded display instead of stopping at the vertical status bar (screenshot verified).
  - Evidence (gitignored): `artifacts/duo-builds/{baseline,r2}/`, `artifacts/duo-part1/`.

