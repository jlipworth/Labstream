# tvOS session report — 2026-07-21

Status: **session record** for [GitHub issue #246](https://github.com/jlipworth/Labstream/issues/246)
(first-class native tvOS target for the Apple-platform Plex/Jellyfin/Emby client). This report
captures one working session on branch `codex/issue-246-tvos`. It is evidence-first and does not
claim parity completion; it complements the durable
[implementation plan](../plans/2026-07-20-tvos-implementation.md) and the
[exhaustive screen audit](2026-07-20-tvos-screen-audit.md).

The video player is app-owned by hard requirement of the backends (Plex/Jellyfin/Emby). The retired
`AVPlayerViewController` path was not and will not be reintroduced; every player fix below adapts the
shared `CustomPlayerView`/`CustomPlayerChrome` for tvOS focus and Siri Remote input.

## Executive summary

This session concentrated on tvOS focus and remote-input correctness across two surfaces the audit
had left open: the custom player chrome (TVUI-024/025) and the persistent browse shell's focus entry
(Home and the Libraries root grid). Five defects were found and fixed, each verified against logged
focus/event evidence rather than a green compile:

- Player chrome: an unreachable trailing skip cluster, a diagonal-move double-hop, and an auto-hide
  race that fought remote navigation.
- Browse shell: cards drew no focus indication, and directional entry from the tab bar landed on the
  wrong card.

One defect remains **parked and unresolved**: on the Search surface (TVUI-004), pressing Select on a
system-keyboard letter inserts nothing. Systematic fixture bisection exonerated every reconstructed
layer and points at either a live-only composition layer or an Apple tvOS-beta framework defect; a
decisive live-repro test is committed but was not yet executed.

Several behaviors observed this session appear to be Apple tvOS-beta defects rather than app bugs;
they are listed with the evidence available.

## Defects found → root cause → fix

### 1. Player chrome — unreachable trailing skip cluster (`207d4464`)

- **Symptom:** With the chrome visible, a Down press from the trailing menu strip (Quality /
  Subtitles / Audio / Chapters / Speed / Stats) reached nothing.
- **Root cause:** The menu strip's vertical beam contains only the timeline, which is a
  non-interactive `ProgressView` — there was no focusable target directly below it, so the focus
  engine had nowhere to send the press.
- **Fix:** Wrapped the transport row in `.focusSection()` so the whole section (not just the column
  under the strip) is treated as the Down target, routing the press into the leading skip cluster.
  The `onMoveCommand` handler was also restructured so a visible-chrome move is dispatched to a new
  `tvHandleUnresolvedMove(_:)` diagonal router instead of being dropped.

### 2. Player chrome — diagonal moves double-hopped (`2b57eec0`, following `207d4464`)

- **Symptom:** The first diagonal-routing attempt (`207d4464`) moved focus twice per press — e.g. one
  Right press jumped `playPause → skip(10) → Quality`.
- **Root cause:** `onMoveCommand` fires for **every** dpad press, engine-resolved or not, and its
  ordering against the focus engine's own update is inconsistent. Logged evidence on 2026-07-21
  showed the engine's focus update **preceding** the command by roughly 80–105 ms on some presses and
  **trailing** it by about 5 ms on others. Acting on every command therefore hijacked ordinary in-row
  moves that the engine had already handled.
- **Fix:** The diagonal fallback in `tvHandleUnresolvedMove(_:)` is now restricted to genuinely dead
  presses by two guards: (a) the focused item must be the row's **edge item** in the pressed
  direction (so the engine has no in-row target), and (b) focus must not have changed within the last
  **0.15 s** (a new `tvPlayerFocusChangedAt` timestamp, set from the `tvPlayerFocus` `onChange`),
  which rejects a trailing command for a press the engine already resolved. The switch was narrowed to
  the concrete edge cases (`.menu` == `availableMenus.first`, `.skip(30)`, and `.playPause` only when
  there is no scrubbable duration).

### 3. Player chrome — auto-hide fought navigation (`2f7e8f69`)

- **Symptom:** During rapid remote traversal the chrome could auto-hide mid-navigation, which reset
  focus and interrupted the user.
- **Root cause:** The auto-hide countdown was not being renewed by ongoing navigation input.
- **Fix:** The auto-hide countdown now restarts on **every** dpad press while the chrome is visible,
  so continuous traversal cannot let the chrome hide out from under the user. (Three-line change.)

### 4. Invisible focus on browse cards (`68b6a3da`, earlier `8db66a67`)

- **Symptom:** Focused cards showed no visible focus state on tvOS.
- **Root cause:** The cards use a bare custom `ButtonStyle` that draws no system focus platter, so
  without the app's own focus ring there is no focus indication at all. This is a recurring regression
  class: any new card that omits the owned ring reintroduces it.
- **Fix:** Reapplied the owned `tvFocusHighlight` ring to the regressed card types —
  `LibrarySectionCard`, the music `SquareArtCell` (`MusicLibraryView`), and the `EpisodeRow`
  (`ContainerBrowserView`). `8db66a67` earlier established the explicit ring and hardened lazy-rail
  traversal; `68b6a3da` closed the newly-regressed instances.

### 5. Tab-bar entry landed on card 2, not card 1 (`eb12403c`; failed attempt `076af88e`)

- **Symptom:** Pressing Down from the persistent tab bar into the Home / Libraries-root content
  landed focus on the second card rather than the first.
- **Root cause:** Directional entry is resolved **geometrically** — the focused tab button's column
  overlaps card 2, so a Down press lands there.
- **Failed attempt (`076af88e`):** Adding `focusScope` + `prefersDefaultFocus` preferring the first
  card did nothing live. **Verified discovery:** `prefersDefaultFocus` governs only initial and
  programmatic focus resolution; it does **not** influence directional dpad entry. This is recorded so
  the approach is not retried.
- **Working fix (`eb12403c`):** Home and the Libraries root grid now track per-card focus with an
  explicit `@FocusState`. When focus enters the grid from outside (a `nil → card` transition), it is
  redirected to the last remembered entry card, or the first card on first entry. In-grid moves and
  pop-back focus restores pass through untouched.
- **Supporting change (`cd54d1de`):** Every horizontal media rail (`HubRail`, the search hub/music
  rails, and the music library/browser rails) was made a `.focusSection()` so vertical dpad moves
  treat the whole rail as a target instead of requiring column overlap. The Libraries root grid also
  received the same first-card entry preference as Home.

## Evidence highlights

- **Focus/event ordering (defect 2):** the 80–105 ms-ahead / ~5 ms-behind timing spread between the
  engine's focus update and `onMoveCommand` was captured live on 2026-07-21 and is what motivated the
  0.15 s recent-change guard; it is documented inline in `tvHandleUnresolvedMove(_:)` in
  `CustomPlayerChrome.swift`.
- **`prefersDefaultFocus` scope (defect 5):** proven live to have no effect on directional entry —
  only the explicit `@FocusState` redirect changed the landing card.
- **Search teardown (parked, below):** on Select over a keyboard letter, UIKit reloads input views
  with `responder:(nil)` and logs `_teardownExistingDelegate:<SwiftUI.TVTextField>` — the character
  never reaches the SwiftUI binding.
- **Prior player-pass evidence** for chrome sizing and the hidden-owner white-out fix
  (`3850580e`, `929a0f2b`, `f0f09933`, `846462d8`) predates this session's focus-routing work and is
  retained in the audit; the AVKit-link playback crash fix and Plex live-playback proof are recorded
  in the screen audit under TVUI-022/023.

## Search (TVUI-004) — parked, unresolved

Pressing Select on a highlighted system-keyboard letter inserts nothing into the query. Typing with a
**hardware keyboard works**, which is a diagnostic aid only and not the remote-input acceptance gate.

- **Live evidence:** on Select, UIKit reloads input views with `responder:(nil)` and
  `_teardownExistingDelegate:<SwiftUI.TVTextField>`; the character never reaches the binding.
- **Systematic bisection exonerated** (all reconstructed via launch-argument fixtures): a bare
  `TextField`, a styled field, a focus-binding replica, and a full generic `TabView` +
  `NavigationStack` shell. The shell replica's `testSystemKeyboardInsertsLetterInsideTabViewShell`
  **passes** — letters insert — so the defect is not in that reconstructed composition.
- **Remaining suspects are live-only layers** not present in the passing replica: the
  `NavigationStack` `.id(session key)`, environment injections, `.onExitCommand` at the `TabView`
  level, `.task(id:)`, and the `MiniPlayerBar` `safeAreaInset`.
- **Decisive test ran — and PASSED:** `testLiveSearchTabSystemKeyboardInsertsLetter` (`b515e616`)
  drives the **real** Search tab (production `RootView`/`SearchView` under the Plex browse fixture,
  `The Long Orbit` fixture asserted present) with the exact failing remote sequence — focus field,
  Select to raise the keyboard, Select on a letter. It was part of the full 16-test suite run at
  `eb12403c` (correcting an earlier draft of this report that claimed it postdated that run) and
  **passed in 13.97 s**: synthetic `XCUIRemote` input inserts the letter into the live search field.
  The user-visible failure therefore does not reproduce under harness-driven remote input — the
  remaining suspect surface shifts to the physical input path (DeviceHub key routing on this
  simulator setup, or real-remote-specific keyboard behavior), not the app's view composition.
- `.searchable` exhibited the **identical** defect when tried earlier, which is consistent with a
  possible Apple framework bug rather than an app-owned responder defect. The system keyboard is being
  kept; no app-owned custom keyboard is being introduced.

Supporting fixtures for the bisection landed in `2e6fe130` (TabView-shell keyboard fixture) and
`5dc38c03` (start that fixture on its Search tab).

## Suspected Apple tvOS beta defects

These were observed during the session and appear to originate below the app. Where noted, no
detailed record exists in git history or docs beyond this session's observation, so they are reported
with that caveat and should be re-confirmed against a newer beta before any bug report.

1. **Search input-session teardown** (see TVUI-004 above): Select on a keyboard letter triggers an
   input-view reload with `responder:(nil)` and delegate teardown instead of inserting the character.
   Reproduces with both `.searchable` and an explicit `TextField`; a native `TabView`+`NavigationStack`
   replica does **not** reproduce it. Best-evidenced of the four.
2. **SwiftUI `DynamicContainer` crash:** observed in-session during tvOS UI work. No dedicated commit
   or doc record was found for it this session; described here as observed-only, cause not isolated.
3. **Repeated `tvremoted` daemon crashes on the host:** the tvOS remote daemon crashed repeatedly on
   the development host during the session. Observed-only; no recorded root cause, and it is a host/OS
   daemon rather than app code.
4. **Simulator reboots detaching DeviceHub key input:** this Xcode beta ships no `Simulator.app` —
   `DeviceHub.app` is the simulator GUI — and simulator reboots temporarily detach DeviceHub key
   input until reattached. This matches prior session experience and is a known-in-project quirk of
   the current beta tooling.

## Remote-driven timeline scrubbing (`12d0613e`)

The tvOS player gained real remote-driven timeline scrubbing this session, shipped as
`12d0613e` ("Add remote-driven timeline scrubbing to the tvOS player"). The timeline moved out of
its previous position into its own **full-width focusable row** that acts as the scrubber.

The design reuses the same focus-engine behavior established by the diagonal-fallback bug (defect 2):
`onMoveCommand` does **not** consume presses — the focus engine still resolves them geometrically —
so by placing no other focusable in the scrubber row, Left/Right presses there are focus-dead and the
move handler is the sole actor on them. Left/Right open or extend a scrub draft with press-streak
acceleration (10 s / 30 s / 60 s strides); Select commits the draft through the shared
`PlaybackScrubState.commit()` → `performUserSeek` path; moving focus away abandons the draft; a
trick-play preview floats above the thumb while scrubbing; and chrome auto-hide is suppressed while a
draft is open. **Manually verified live and approved.**

With the scrubber proven, the on-screen transport buttons became redundant and were removed
(`e02a4d07`, user-approved): the remote is the transport. Chrome reduces to title/menu strip over the
full-width timeline; a side press while chrome is hidden performs an instant ±10 s skip plus a brief
reveal (the tvOS platform standard — the skip amount is the single `tvRemoteSkipSeconds` constant);
hardware Play/Pause (or Select on the timeline) toggles playback; and the timeline is the chrome's
default focus through the verified-write path (`tvEnsureFocus` — the raw appear-time write was racing
view insertion and dropping, re-confirming the TVUI-024 evidence). Player UI tests were retargeted
from the removed Play/Pause label to `tv.player.timeline`, proving pause via the paused-chrome
pin-visible behavior instead.

Separately, the tvOS target previously shipped **no app icon** — the app appeared on the tvOS home
screen as a blank white tile, indistinguishable from the UI-test runner (the catalog had visionOS/
macOS/mobile icons only, and the target had no `ASSETCATALOG_COMPILER_APPICON_NAME`). Fixed with a
generated `TVAppIcon.brandassets` (two-layer parallax home-screen and App Store image stacks plus Top
Shelf images, composed from the existing Labstream glyph over a brand-teal gradient).

## Open items

- **Search (TVUI-004):** parked. The committed live-repro test
  `testLiveSearchTabSystemKeyboardInsertsLetter` (`b515e616`) ran in the full suite below and
  **passed** — synthetic remote input inserts letters into the real Search field — so the app's view
  composition is exonerated end-to-end and the remaining suspects are the physical input path
  (DeviceHub key routing to this simulator, or real-remote keyboard behavior). Next step is live
  characterization on that input path, not further app-side bisection. Do not accept
  hardware-keyboard typing as the acceptance gate.
- The timeline scrubber (`12d0613e`) was verified live and approved; the transport-button removal
  (`e02a4d07`) re-ran the five player-chrome UI tests (see suite note below).

## Full UI-test-suite results

Full `LabstreamTVUITests` run on 2026-07-21 17:51 local against the tvOS simulator, at commit
`eb12403c` (before the scrubber commit `12d0613e`): **all 16 tests passed, 0 failures, 228.6 s**.

Notable results:

- `testSystemKeyboardInsertsLetterInsideTabViewShell` — the generic `TabView`+`NavigationStack`
  exoneration fixture — **passed**, confirming the TVUI-004 defect does not reproduce in the
  reconstructed shell (consistent with the search-teardown analysis above).
- `testBackendLaunchFixturesAreDeterministic` — which had **flaked earlier** on this branch — **passed
  cleanly** this run, resolving the flake flagged in the open items.

The 16 tests **include** `testLiveSearchTabSystemKeyboardInsertsLetter` (`b515e616`), which passed
(13.97 s) — see the TVUI-004 analysis above; an earlier draft of this report wrongly stated it was
excluded and unrun. What this run does **not** cover: it predates the timeline-scrubber commit
`12d0613e` and the transport-row removal `e02a4d07`, whose five rewritten player-chrome tests were
re-run separately afterwards.

## Post-review fixes (2026-07-21, later session)

A three-lane external review (player/focus, application UI, target/tooling/docs) of the committed
branch produced the following confirmed-and-fixed findings:

- **Menu-strip traversal auto-hide (found by the rewritten player tests):** the timeline's own
  `onMoveCommand` consumes Up/Down, so the chrome-root handler never saw those presses and could not
  restart the 5 s auto-hide countdown — the chrome hid mid-traversal ~3 s after focus reached the
  strip. The timeline handler now restarts the countdown for the presses it consumes;
  `testRevealedChromeReachesMenusAndRestoresFocus` passes.
- **Music A–Z rail on tvOS:** `MusicPagedGrid` still rendered the persistent edge index on tvOS
  (video grids had already switched to the Jump button there). tvOS now matches the video grid: no
  rail, `LibraryAlphabetJumpButton` in the browse controls.
- **Root Back handling:** the tvOS shell's unconditional `.onExitCommand` swallowed Back inside
  Settings (whose internal `NavigationStack` it cannot pop) and at tab roots. The handler is now
  attached only while a lifted navigation path is non-empty.
- **Rapid second scrub:** a new drag seeded from `controller.currentResumeMs`, which can still be the
  pre-seek clock during a stream rebuild; it now seeds from `scrubState.displayedPositionMs` (held
  committed target), with a PMSKit regression test.
- **Chrome pinned after scrub abandon:** abandoning a drag by moving focus off the timeline cancelled
  the scrub but could leave no hide timer scheduled; the abandon path now restarts the countdown.
- **Submenu close focus race:** `closeMenu` restored strip focus with a raw `tvPlayerFocus` write —
  the same droppable-write class `tvEnsureFocus` exists for; it now uses `tvEnsureFocus`.
- **Search Clear:** the persistent tvOS Search tab no longer exits to the prior tab on Clear.
- **Dead tvOS sign-in controls:** the "Open Plex sign-in on this device" button (a no-op on tvOS —
  `WebAuthSession` cancels immediately) is hidden, and the Plex/Emby pairing URLs render as
  instructional text instead of dead focusable `Link`s.
- **CI framework allowlist:** `ci-hygiene.sh` exempted any `*.framework` churn; it now allowlists
  only AVKit, with a negative test in `test_tooling_hardening.py` (15/15 pass).
- **Report provenance:** corrected the live-search-test claims in this report (it ran and passed in
  the 16-test suite; see above).

Known remaining test gaps (accepted, not blocking this branch): exact-once Play/Pause dispatch is
not proven by an end-state assertion; no automated coverage for rapid consecutive scrubs at the UI
layer, scrub acceleration tiers, or the hidden ±10 s side skips; submenu tests prove shell
open/close rather than row selection and omit Quality (absent from the fixture); search keyboard
insertion under physical input remains the TVUI-004 acceptance gap; physical Apple TV validation
remains open.
