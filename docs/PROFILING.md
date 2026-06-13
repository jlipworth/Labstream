# Profiling VisionPlex

This is the baseline profiling workflow for VisionPlex on visionOS. Keep traces, screenshots, and
exported logs out of git unless they have been scrubbed: Instruments captures can include app state,
URLs, media titles, account identifiers, and local machine details.

## When to use each instrument

| Question | First instrument | Capture |
| --- | --- | --- |
| Library grid scrolling hitches or image decode cost | Hangs + SwiftUI | One cold scroll from Home into a large library, then one warm repeat. Record hitch stacks, recomposition spikes, image allocation bursts, and FPS/hang intervals. |
| Player memory growth over time | Allocations, then Leaks | Start playback, wait for first stable playback, mark a generation, run 10-15 minutes, close player, mark another generation. Capture net object growth, retained `AVPlayer`/`AVPlayerItem`/SwiftUI view objects, and any leaked cycles. |
| Playback start / time to first frame | Time Profiler + Points of Interest | Tap Play, profile through first visible frame and first stable playback. Capture app-side startup work, Plex transcode request timing, player item readiness, and first-frame latency. |
| App launch | Time Profiler + SwiftUI | Launch from a terminated app. Capture main-thread launch work, sign-in/session restoration, first Home render, and any synchronous network/image work. |
| Music playback crash (#22) | Allocations + Zombies/Leaks if needed | Reproduce the shortest crash path. Capture the object that is messaged after free, retained audio-player/controller graph, and the final app log window. |

Other templates:

- **Time Profiler**: CPU-heavy code and main-thread stalls. Use this before optimizing code paths.
- **Allocations**: object growth, churn, and generation comparisons. Use `Mark Generation` before and
after the scenario.
- **Leaks**: confirmed leaks after Allocations shows growth that should have been released.
- **Hangs**: user-visible stalls and blocked main-thread intervals.
- **SwiftUI**: body recomputation and update/render hot spots in the Home/library/detail UI.
- **RealityKit Trace**: visionOS compositor/frame-pacing template. It is mostly a future tool for a
custom RealityKit theater (#12). The shipping video path is now the app-owned custom player; its
placeholder custom Cinema ImmersiveSpace is hidden after device testing showed it is not equivalent
to Apple's AVKit Cinema Environment. Use RealityKit Trace only when actively working on #12.

## Simulator vs physical Vision Pro

Use the simulator for workflow checks, logic regressions, leak hunting, and repeatable UI paths. Do
not treat simulator CPU, GPU, frame pacing, thermal behavior, network timing, or media decode cost as
representative. Any performance claim about smoothness, time-to-first-frame, or long playback memory
must be repeated on a physical Vision Pro before filing it as a product finding.

## Exact Xcode / Instruments workflow

1. Open `PlexAVPApp.xcodeproj` in Xcode.
2. Choose the `PlexAVPApp` scheme.
3. Select either:
   - `Apple Vision Pro` simulator for a repeatable local pass, or
   - a paired Apple Vision Pro for representative performance.
4. Start profiling with **Product → Profile** (`⌘I`). Xcode builds and opens Instruments.
5. Pick the template from the table above.
6. Before pressing Record, set a short run goal in the trace notes, for example
   `Library grid cold scroll, 30 seconds, simulator`.
7. Press **Record**, perform only the target scenario, then stop immediately after the end condition.
8. Save the `.trace` outside the repo or in a local ignored scratch directory. Do not commit raw traces.
9. Write down the finding in the issue or PR using the baseline template below.

Command-line build sanity before profiling:

```sh
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

If a source edit was made before profiling, avoid profiling an old simulator product: delete the built
`.app` from DerivedData, rebuild, then install/relaunch the fresh app as described in
[`DEVELOPMENT.md`](DEVELOPMENT.md).

## Optional low-risk instrumentation

Prefer Instruments-only runs first. If a measurement needs app-side intervals, add temporary or
permanent `os_signpost` points using non-sensitive names only. Suggested subsystem/category names:

- subsystem: `com.jlipworth.VisionPlex`
- categories: `Launch`, `LibraryGrid`, `Playback`, `MusicPlayback`
- intervals/events:
  - `app_launch_to_home_visible`
  - `library_grid_scroll_pass`
  - `play_tap_to_player_item_ready`
  - `player_item_ready_to_first_frame`
  - `player_close_to_transcode_stop_requested`
  - `music_play_tap_to_audio_started`

Keep signpost payloads numeric or generic. Do not signpost media titles, server names, account names,
URLs, tokens, client identifiers, or local paths.

## MetricKit follow-up

MetricKit is for aggregate real-device field metrics after the app is running on hardware. It is not a
substitute for the first Instruments baseline. If we add it later, create a small `MXMetricManager`
subscriber that records launch, hang, memory, and crash diagnostics without uploading private payloads
or logging raw user/library data.

## First baseline pass plan

Record one pass per target, in this order. File each confirmed regression or surprising result as its
own issue; if there is no confirmed problem, leave a concise note on the profiling issue.

1. **Library grid scroll baseline**
   - Device: simulator first, physical Vision Pro before product claims.
   - Template: Hangs + SwiftUI.
   - Scenario: launch signed-in app, open a large video library, scroll top-to-bottom once, then repeat
     the same scroll warm.
   - Capture: largest hang intervals, main-thread stacks, SwiftUI body/update spikes, image allocation
     bursts, and whether warm scroll improves.
2. **Playback memory baseline**
   - Template: Allocations, then Leaks if growth remains after close.
   - Scenario: play one transcoded item for 10-15 minutes, close the player, wait 30 seconds.
   - Capture: generation delta after first stable playback vs after close, retained player/controller
     objects, leaked references, and whether PMS transcode stop was requested.
3. **Playback start baseline**
   - Template: Time Profiler + Points of Interest if signposts exist.
   - Scenario: tap Play from a detail screen and stop after first visible frame / stable playback.
   - Capture: tap-to-first-frame time, transcode request duration, item-ready latency, and main-thread
     work before the player appears.
4. **App launch baseline**
   - Template: Time Profiler + SwiftUI.
   - Scenario: terminate app, record from launch through Home becoming usable.
   - Capture: launch time, first Home render time, synchronous network/keychain/image work, and any
     main-thread stalls over 100 ms.
5. **Music crash baseline (#22)**
   - Template: Allocations, Zombies/Leaks if the first pass points at lifetime issues.
   - Scenario: shortest known path to the crash.
   - Capture: final app log window, exception/crash type, owning object graph, and whether the crash is
     reproducible on simulator, device, or both.

## Finding note template

```md
### Profiling finding: <short title>

- Target: <library grid | playback memory | playback start | launch | music #22>
- Date / build: <date, branch, commit>
- Device: <simulator runtime or physical Vision Pro model/OS; no serials or user paths>
- Instrument(s): <template names>
- Scenario: <exact user path, no private media titles>
- Result: <numbers and short interpretation>
- Evidence kept locally: <trace filename/location outside repo, if any>
- Follow-up: <new issue number or "none; baseline only">
```
