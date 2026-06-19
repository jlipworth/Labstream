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


## Issue #42 repeatable load-time spans

The profiling log summarizer is Python stdlib-only, but it is intentionally pinned through the repo
`pyproject.toml`/`uv.lock` so repeated local and CI runs use a known Python toolchain. Use `uv run`
for committed profiling commands and `uv run python -m unittest discover -s scripts/tests -v` for its
tests.

Only Debug builds emit the privacy-preserving `perf.span` lines and matching Points of Interest
signposts; Release/TestFlight/App Store builds use no-op instrumentation. Debug profiling covers the
focused #42 matrix: Home, Libraries list, library grid first/page loads, artwork requests, detail
metadata refresh, playback negotiation, player-item load, and tap-to-playing startup. The
fields are generic counts, backend labels, dimensions, path modes, quality caps, byte counts, HTTP
status codes, and durations only; do not add media titles, server URLs, usernames, tokens, client
identifiers, image paths, or local file paths.

Run one cold and one warm pass for each backend/scenario, then summarize the local logs:

```sh
# Simulator example. Start this right after the scenario, while the relevant log window is fresh.
xcrun simctl spawn booted log show --style json --last 15m \
  --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
  | uv run scripts/perf-log-summary.py --markdown

# If you launched via XcodeBuildMCP, the returned osLogPath is also parseable:
uv run scripts/perf-log-summary.py --markdown < /path/to/com.jlipworth.VisionPlex_oslog_*.log
```

Useful narrow summaries:

```sh
# Home, Libraries, and artwork first-load / warm-load comparison.
xcrun simctl spawn booted log show --style json --last 15m \
  --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
  | uv run scripts/perf-log-summary.py --phase home.load --phase libraries.load --phase artwork.load --markdown

# Artwork split by requested backend image size. Useful for finding oversized decorative art.
xcrun simctl spawn booted log show --style json --last 15m \
  --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
  | uv run scripts/perf-log-summary.py --phase artwork.load --group-field pixel_width --group-field pixel_height --markdown

# Playback startup comparison across Plex/Jellyfin and original/transcoded quality choices.
xcrun simctl spawn booted log show --style json --last 15m \
  --predicate 'subsystem == "com.jlipworth.VisionPlex" && category == "Performance"' \
  | uv run scripts/perf-log-summary.py --phase playback.resolve --phase playback.item_load --phase playback.startup --group-field path_mode --markdown
```

Interpret the key spans as:

| Span | Start | End | Use |
| --- | --- | --- | --- |
| `home.load` | Home task starts a backend fetch | first home content state is marked loaded/failed | cold/warm homepage latency, rail counts |
| `libraries.load` | Libraries tab starts section/view fetch | Libraries list is loaded/failed | Movies/TV/Music entry-list latency |
| `library_grid.initial_page` | library grid starts page 0 fetch | initial slots are populated/failed | first visible listing content latency |
| `library_grid.page` | lazy placeholder triggers a later page | page items are patched/failed | pagination latency while scrolling |
| `detail.metadata` | detail screen starts full metadata refresh | detail model is refreshed/failed | pre-play metadata latency |
| `artwork.load` | a `PosterImage` starts a backend image request | image data is decoded/failed/cancelled | poster/chapter/artwork fetch + decode latency; aggregate by backend and screen scenario because per-image logs are noisy |
| `playback.resolve` | user taps Play | app presents player after backend negotiation | backend playback-info/URL resolution latency |
| `playback.item_load` | `AVPlayerItem` is installed | item reaches `readyToPlay`/failed | AVFoundation item readiness |
| `playback.startup` | `PlaybackController.start()` begins | time control first reaches `.playing`/failed/cancelled | tap/player startup to useful playback |


What we intentionally do not get from these spans:

- SwiftUI render/recomposition cost for a submenu opening after state changes. Use SwiftUI/Hangs Instruments if
  the Quality/Subs/Audio/Chapters/Stats panels feel sluggish.
- true scroll FPS/frame pacing. Use Hangs, SwiftUI, and RealityKit/compositor templates on device.
- memory growth/leaks. Use Allocations/Leaks.
- server network time vs JSON decode split inside a page-load span. Add narrower spans only after a broad
  span proves that path is slow.

Recommended #42 run matrix:

1. Plex Home cold launch, then Home pull-to-refresh warm pass.
2. Jellyfin Home cold launch, then Home pull-to-refresh warm pass.
3. Plex Movies, TV, and Music listings: first grid load, one lazy page, warm reopen.
4. Jellyfin Movies, TV, and Music listings: first grid load, one lazy page, warm reopen.
5. Plex playback startup: one Original/Maximum path and one capped transcode path.
6. Jellyfin playback startup: one DirectPlay/DirectStream-like path and one transcoded path.

These log summaries are not a substitute for Instruments. Use them to make the scenarios repeatable
and to identify which interval deserves a Time Profiler, Hangs, SwiftUI, or Points of Interest trace.
Any product claim about smoothness or first frame still needs a physical Vision Pro pass.


### Baseline-driven improvement from the first simulator pass

Grouping `artwork.load` by image dimensions showed that decorative 900×600 backdrops were requesting
1800×1200 backend transcodes and landing in the slowest artwork bucket in the initial simulator log.
Those blurred/low-opacity backdrops now request @1x images while normal posters remain @2x. This is
the intended workflow for the profiling rails: identify a specific slow bucket, make a narrow change,
and re-measure rather than adding broad speculative caching.

## Storing profiling results over time

Raw `.trace` bundles, simulator logs, screenshots, and media-specific notes stay outside git. For quick
one-off checks, paste the reviewed `perf-log-summary.py` table into the relevant GitHub issue. When a
result is useful as a long-term comparison point, commit a small privacy-reviewed Markdown summary under
[`docs/profiling/baselines/`](profiling/baselines/) and keep the raw artifact only in local scratch storage.

This gives us three tiers:

1. **Raw evidence**: local-only traces/logs, never committed.
2. **Issue comments**: most ad-hoc pass/fail summaries and surprising findings.
3. **Repo baselines**: curated, redacted summaries worth comparing across releases or major refactors.

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
