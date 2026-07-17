# Manual validation checklist

Use this matrix for current hands-on validation of Labstream. It records behavior that
requires a simulator, live server, host UI session, or physical Apple device; it is not a
release history or a substitute for automated checks.

Run the automated gates and platform smoke loops in
[`docs/TESTING-STRATEGY.md`](docs/TESTING-STRATEGY.md) before beginning this pass.
Do not copy server URLs, tokens, usernames, media titles, device identifiers, or private
library screenshots into committed evidence.

## 1. Prepare the matrix

### Platform prerequisites

| Lane | Minimum setup | What this lane can prove |
| --- | --- | --- |
| visionOS simulator | Worktree simulator selected explicitly; signed-in test session or planned fresh-login pass | Shared compile/UI flow, routing, settings, browse, deterministic simulator checks; not headset rendering or durable off-head background behavior |
| Apple Vision Pro | Signed device build, awake/paired headset, same network as the server | Real video/audio rendering, Custom Cinema, immersive transitions, off-head lifecycle, background download continuation |
| iPhone simulator | `LabstreamMobile` on a compact-width simulator | Phone tab shell, login/browse/detail layout, player controls, orientation code paths; not PiP/AirPlay/cellular/background-device guarantees |
| iPad simulator | `LabstreamMobile` on an iPad simulator | Adaptive sidebar, regular-width grids/sheets, shared player UI; not physical background transfer or external-route behavior |
| Physical iPhone/iPad | Signed mobile build with required trust/Developer Mode | PiP, AirPlay, Control Center/lock screen, audio routes, cellular policy, background transfers, Spotlight and App Intents |
| macOS preview | `LabstreamMac` host build under the worktree development identity | Native split view, menus, Settings window, keyboard/full-screen/media-key behavior, live playback and download reconciliation; record as preview evidence |

- [ ] Record the exact target/scheme, configuration, OS/runtime, app marketing/build ID,
      and whether this is an upgrade install or a fresh container.
- [ ] Ensure only the intended simulator/device is in use and that the backend server is
      reachable over the network path being tested.
- [ ] Prepare non-sensitive samples that cover a movie, a multi-season show, an episode
      with resume progress, music, multiple audio/subtitle tracks, and each required
      download/playback route.
- [ ] For background and failure tests, prepare controlled network interruption, device
      lock/background, and process-termination steps before starting.

### Backend prerequisites

| Backend | Required account/server state | Backend-specific coverage |
| --- | --- | --- |
| Plex | Account sign-in plus at least one reachable discovered server | PIN/link and on-device web auth, server selection, native hubs/search/music, direct/transcode playback, original/optimizer downloads |
| Jellyfin | Reachable server and user; Quick Connect enabled if that method is under test | Credentials/Quick Connect, MediaBrowser Home/search/music, PlaybackInfo/reopen/progress, original and transcode/remux downloads |
| Emby | Reachable server and user; linked Connect account if that method is under test | Credentials/Connect PIN and multi-server choice, MediaBrowser Home/search/music, PlaybackInfo/reopen/progress, original/remux/Convert downloads |

Run shared rows once per affected backend, not only against Plex. When a behavior is
backend-specific, mark the other backend cells not applicable rather than silently
skipping them.

## 2. Authentication, restore, and backend switching

| Check | Plex | Jellyfin | Emby |
| --- | :---: | :---: | :---: |
| Fresh sign-in reaches a browse-ready server without exposing credentials | [ ] | [ ] | [ ] |
| Saved session restores through the neutral Connecting screen without flashing login | [ ] | [ ] | [ ] |
| Invalid/revoked credentials return to a clear sign-in state | [ ] | [ ] | [ ] |
| Explicit sign-out clears the active runtime lane and stops stale music | [ ] | [ ] | [ ] |
| Reauthentication to the same server refreshes browse state and navigation identity | [ ] | [ ] | [ ] |

- [ ] Plex linking shows a usable code and on-device sign-in fallback; discovered server
      selection and reachability reporting agree with the server actually used.
- [ ] On two physical devices using the same iCloud account, verify the intended Plex-token
      synchronization policy while device/client identifiers remain distinct. Confirm
      Jellyfin and Emby sessions remain per-device.
- [ ] Jellyfin credentials and Quick Connect both handle success, cancellation, timeout,
      disabled Quick Connect, and bad credentials without leaving a polling task active.
- [ ] Emby credentials and Connect PIN both handle success, cancellation, timeout, and bad
      credentials. If Connect returns multiple servers, only the chosen server is exchanged
      and applied.
- [ ] Switching to a backend with saved credentials restores it without bouncing an already
      mounted browse UI to Home/login; switching to an unconfigured backend presents login.
- [ ] Switch repeatedly among all configured backends. Online navigation/search/music state
      must reset to the new browse session, while cross-backend Offline rows remain present.
- [ ] Leave queued work for an inactive backend, relaunch, and confirm restore hydrates that
      saved lane sufficiently for its own download recovery without changing the visible
      active backend.

## 3. Browse, search, and detail

Run these rows for every configured backend and in both compact and regular-width UI when
layout code changed.

- [ ] Home loads the correct shape: Plex native hubs, or Jellyfin/Emby Continue Watching,
      Next Up, and per-library latest rails. One failed MediaBrowser rail degrades the page
      without blanking successful rails.
- [ ] Hidden-library preferences affect Libraries and MediaBrowser Home consistently and
      remain scoped to the stable backend/server/user identity after reauthentication.
- [ ] Library roots open the correct backend, paging fills sparse grids without duplicate or
      missing cells, prefetch does not reorder content, and pull-to-refresh retains a valid
      state.
- [ ] With alphabetical sorting, the A–Z rail lands near the requested section and does not
      cover or steal taps from the last poster column. Nonalphabetical sorts hide it.
- [ ] Shows open seasons and seasons open numerically ordered episodes. Multiple physical
      versions of the same visible episode produce one understandable row rather than
      indistinguishable duplicates.
- [ ] Search cancellation and rapid query changes do not show stale results from an earlier
      query or backend. Results are grouped sensibly by library/media type and deduplicated.
- [ ] Music search results route to music detail/playback; video results route to video detail.
- [ ] Detail refreshes authoritative metadata, keeps the selected media version valid, and
      applies watched/unwatched changes to subsequent browse state.
- [ ] Play and Download operate on the leaf/version shown in detail, not its show/season
      container or a stale item from a previous backend session.
- [ ] Poster/artwork requests authenticate correctly for the active backend and fail to a
      privacy-safe placeholder without logging a token-bearing URL.

## 4. Shared video playback

### Common player matrix

Run the applicable rows for Plex, Jellyfin, Emby, and a local offline file. The app-owned
`CustomPlayerView`/`CustomPlayerChrome` is the only expected shipping player surface.

| Behavior | Plex | Jellyfin | Emby | Offline |
| --- | :---: | :---: | :---: | :---: |
| Starts with visible preparation/buffering status, then renders video and audio | [ ] | [ ] | [ ] | [ ] |
| Resume begins at the expected offset and respects resume-rewind preference | [ ] | [ ] | [ ] | [ ] |
| Play/pause, relative seek, scrub-to-final-target, and Close are deterministic | [ ] | [ ] | [ ] | [ ] |
| Audio/subtitle selection matches the running stream and survives applicable reopen | [ ] | [ ] | [ ] | [ ] |
| Chapters and trick-play thumbnails use the correct remote/local provider | [ ] | [ ] | [ ] | [ ] |
| Playback failure becomes a stable error with an explicit working Retry | [ ] | [ ] | [ ] | [ ] |
| End of playback advances Up Next or closes cleanly when no next item exists | [ ] | [ ] | [ ] | [ ] |

- [ ] Changing quality rebuilds at the current final playhead, stops superseded server
      sessions/encoders, and does not create a hidden retry or transcode loop.
- [ ] Jellyfin/Emby reopen sends the selected quality, audio, subtitle, play-session, and
      media-source state; progress start/update/stop reaches the correct backend.
- [ ] Plex timeline updates on play/pause/stop and near-end watched state. Jellyfin/Emby
      video progress likewise updates Continue Watching after reopen.
- [ ] Skip Intro/Credits appears only inside valid marker ranges and automatic/manual
      preferences behave as configured.
- [ ] Network loss or a starved stream shows buffering/reconnecting/failure status instead
      of a black surface with no explanation. Recovery never revives a superseded player.
- [ ] Stats for Nerds reports source, decision/play method, rendered stream, bitrate, audio,
      and HDR facts without private server or media identifiers.
- [ ] Validate SDR, HDR10/HLG, supported Dolby Vision with fallback, and no-fallback Dolby
      Vision policy using appropriate samples. Treat visual HDR/DV correctness as a physical
      display gate, especially on Apple Vision Pro.

### Platform-specific video behavior

- [ ] **visionOS:** Windowed playback remains interactive; entering user-visible Custom
      Cinema keeps the same controller/playhead/chrome, dismisses/reopens the main window
      cleanly, and returns to the originating detail or Offline row. The hidden RealityKit
      Theater prototype must not appear as a normal user option.
- [ ] **iPhone:** Full-screen video requests the intended landscape orientation and restores
      the prior orientation policy on close. Ordinary backgrounding pauses, while active PiP
      or AirPlay is allowed to continue.
- [ ] **iPadOS:** Player layout and menus work in regular and compact multitasking widths;
      PiP, AirPlay, keyboard controls, and the adaptive sidebar do not strand presentation.
- [ ] **iOS/iPadOS hardware:** Control Center, lock screen, headphones, route changes, and
      interruptions control the active video rather than resuming suspended music underneath.
- [ ] **macOS preview:** overlay/full-screen presentation, Escape/Close, toolbar visibility,
      menu commands, media keys, Now Playing ownership, and restoration to the prior split-view
      state all behave natively.

## 5. Downloads and Offline

### Route and presentation matrix

| Route class | Expected behavior |
| --- | --- |
| Original/existing/prepared static file | Exact source size when known; durable byte progress; validator-protected Range continuation; eligible for checkpoint resume |
| Plex optimizer output | Server preparation is polled until a real compatible part exists, then handed to the static transfer engine |
| Emby Convert output/reused converted source | Convert or reuse completes first, then the resulting stable file uses the static transfer engine |
| Jellyfin/Emby live remux or transcode | Forward-only encoder stream; size/progress may be estimated; no promise of durable range resume after process death |

- [ ] The download sheet shows only routes valid for the selected backend, item, version,
      media source, and storage policy; a probe failure offers a safe fallback rather than a
      dead end.
- [ ] On Emby, the compatible-remux row discloses its possible 1080p Convert fallback. For a
      source above 1920×1080, Download requires confirmation and identifies the 4K preset as the
      resolution-preserving converted alternative; 1080p-or-lower and non-Emby choices do not
      show that confirmation.
- [ ] An Emby compatible-remux download runs for at least two minutes without truncating near the
      server's one-minute idle boundary. Diagnostics show `downloads.emby_keepalive_start`; token
      rotation/rejection produces bounded degraded/auth-dead evidence, and no download keepalive
      changes watch progress because the lane sends Ping only—not Playing/Progress.
- [ ] Kill the app immediately after a new Emby Convert POST is accepted but before the returned job
      id is persisted. Relaunch recovers exactly one job from the durable full-list baseline and
      continues it without a duplicate POST; zero/multiple differences fail closed and Retry does
      not create another job while ownership remains ambiguous.
- [ ] A job records and continues against its own backend session through active-backend
      switches. Simultaneous jobs from different backends progress independently and display
      unambiguous backend badges.
- [ ] Pause/Resume, Pause All/Resume All, Retry, Delete, completed-only deletion, queue pause,
      cellular permission, and storage-limit rejection leave coherent durable rows.
- [ ] Server-side encoders/optimizer/Convert jobs are stopped or reconciled when their row
      completes, fails, is canceled, or is recovered after relaunch.

### Static segment train

Both visionOS and non-visionOS currently use the closed-segment train. Each segment is
512 MiB segments are used, with at most two live or newly planned segments per download (the
durable head plus one look-ahead). Validate on physical devices
when claiming background durability.

- [ ] Background/lock/off-head continuation appends completed segments in order and advances
      only the durable partial checkpoint; optimistic URLSession temp bytes are not persisted
      as completed data.
- [ ] Force-quit/relaunch adopts matching live or already-finished marker-bearing tasks and
      resumes from the durable checkpoint without duplicating, gapping, or restarting all
      accumulated bytes.
- [ ] Pause/Resume mid-train cancels or adopts every task safely and replans from the durable
      checkpoint without a progress jump.
- [ ] Cancel, immediately re-download the same item, and relaunch: stale tasks from the prior
      attempt are rejected rather than appended to the new file.
- [ ] A changed validator, malformed/misaligned Range response, 416, network loss, and low
      storage fail or retry without marking an incomplete file complete.
- [ ] Long locked/off-head soak loses at most current non-durable work after interruption;
      previously assembled checkpoints remain monotonic.

### Forward-only and offline behavior

- [ ] Live-forward remux/transcode rows clearly communicate estimated or indeterminate
      progress. On interruption without a stable validator, they restart/retry cleanly rather
      than claiming resumability from unsafe resume data.
- [ ] Simulator evidence is labeled correctly: its normal foreground URLSession substitute
      does not prove device background relaunch/continuation.
- [ ] Completed rows retain backend, resolution/route, poster, subtitles, chapters, and
      trick-play side assets when available; missing optional side assets do not fail the media.
- [ ] Offline playback works with the server unreachable, persists a local playhead, uses local
      side assets only, and never attempts online timeline reporting.
- [ ] Relaunch reconciliation demotes missing, truncated, or unplayable files and preserves
      genuinely complete files. Storage totals distinguish indexed content, temporary data,
      and conservative orphan candidates.

### Physical-device background and failure cells

These cells are **physical-device only**. A simulator foreground session cannot establish an
OS background relaunch, off-head/locked continuation, network-path handoff, or real disk-pressure
result. Run the static-transfer cells with a file large enough to keep the 512 MiB segment train
active; run the Emby cell with a Convert route rather than an already reusable file.

Before each cell, enable App Diagnostics, clear old diagnostics, start exactly one new download,
and retain the resulting `app-diagnostics.jsonl` plus its rotations. Find that row's
`fields.download_id` in `downloads.enqueue` and use the complete value (for example,
`id=0123456789abcdef`) to correlate every later event. This is a deterministic FNV-1a hash of the
backend-scoped download key, not the raw key; do not put the raw media/server identifier in test
notes. A missing named event is evidence only when diagnostics stayed enabled and all rotated files
were collected. Every event also carries a hashed `process_run_id` plus the OS `process_id`; use
those with `app.process_launch` and `app.scene_phase` to distinguish a relaunched process from an
ordinary foreground transition. Background-session lifecycle events have no `download_id`, so join
them by `process_run_id` and the bounded test interval, then require row-specific events alongside
them.

| Device-only cell | Procedure and pass condition | Currently instrumented evidence in `app-diagnostics.jsonl` | Known evidence gap |
| --- | --- | --- | --- |
| Process kill mid-train + background completion delivery | While a static train is active, let the OS terminate/suspend the app (do not swipe-force-quit), leave the device locked/off-head until at least one segment finishes, then relaunch if the OS has not already done so. Pass only if the same row continues from a monotonic durable checkpoint, reaches Complete/Unverified, and no duplicate/gap appears. | For the same hashed ID: `downloads.range_segment_train_adopted` or `downloads.range_dead_finish_adopted`, then `downloads.range_segment_assembled`/`downloads.range_request_rebuild_needed`, and eventually `downloads.complete` plus `downloads.finalize_finished`. OS callback delivery is separately bracketed by `downloads.background_completion_stored`, `downloads.background_session_registered`, `downloads.background_events_finished`, and `downloads.background_completion_fired`; `process_run_id` joins those events to the relaunch. | The OS does not tell the app whether a prior process ended from pressure, a test kill, or a user force-quit. Record the termination method externally; diagnostics now prove the process boundary and lifecycle ordering. |
| Resume-blob availability: force-quit versus OS kill | Use two otherwise identical static downloads. In one run swipe-force-quit; in the other induce an OS termination without user force-quit. Relaunch and Resume if offered. Record whether a blob is accepted, rejected as stale, or absent and the durable checkpoint is used. Pass means neither path resets already durable bytes or corrupts the file; do **not** require the two termination modes to preserve equal OS background privileges. | On every launch, `downloads.range_launch_checkpoint` explicitly records `resume_manifest_recorded`, `resume_blob_present`, blob bytes, durable bytes, and held-body count for each nonterminal static row. A user Pause also records `downloads.range_pause_resume_data`; actual adoption/rejection records `downloads.range_blob_resume` / `downloads.range_blob_resume_stale`, while checkpoint recovery records `downloads.range_auto_resume`, `downloads.range_resume_ready`, or `downloads.range_resume_deferred`. | Termination mode remains external, but blob presence/absence at launch is now directly evidenced rather than inferred. |
| Wake-time silent retry with an active train | With a train active, lock/remove the device and interrupt reachability long enough for a task to wait or fail; restore reachability while it remains locked/off-head. Pass if retry/continuation advances the same durable checkpoint without user interaction and the train ultimately validates. | `app.scene_phase` brackets active/inactive/background state in the same `process_run_id`. `downloads.task_waiting_for_connectivity`, `downloads.range_retry`, `downloads.range_http_retry`, or `downloads.range_blob_resume` identifies the retry path; follow with `downloads.range_segment_assembled`/`downloads.range_progress` and terminal `downloads.finalize_finished`, all on the same hash. | SwiftUI scene phase cannot distinguish locked from off-head or prove the precise hardware wake instant. Preserve lock/off-head and network-change timestamps externally. |
| Token revoked while asleep | Start a static authenticated download, lock/remove the device, revoke its backend token, and allow the next segment/continuation to run before waking. Pass if stale authorization never produces a Complete row, the durable checkpoint is retained, and the UI ultimately asks for sign-in/retry rather than looping forever. | `app.scene_phase` brackets UI lifecycle state. A rejected Range records `downloads.range_http_rehydrate` with `status_code` 401/403; exhausted handling records `downloads.range_failed` with that status and then `downloads.transfer_auth_dead` for the same hash. If rejection lands in the opaque lane, `downloads.transfer_finished` exposes the HTTP status and the following `downloads.validation_failed` identifies the same row. Emby polling rejection instead uses `downloads.convert_failed` with `status_code` and `phase`. | Token revocation is an external server/account action and scene phase cannot distinguish locked from off-head. Preserve the revocation timestamp externally. |
| LAN to WAN switch mid-download | Start on local Wi-Fi, move the physical device onto a genuinely remote path (cellular on iPhone/iPad, or another routed Wi-Fi for Vision Pro), and keep the same train active. Pass if policy permits the new path and bytes remain monotonic, or if policy forbids it the row waits clearly and continues after an allowed path returns. | `downloads.task_network_metrics` records whether the task's actual transactions observed cellular, expensive, or constrained networking (plus protocol and transaction count), keyed to the download hash. Combine it with `downloads.task_waiting_for_connectivity`, retry events, subsequent progress/assembly, and finalization. | Metrics distinguish cellular/expensive/constrained service but not local-versus-remote routed Wi-Fi. Record the Wi-Fi route change externally for Vision Pro. |
| Device disk pressure | Fill the device enough to exhaust space during an active static train, without deleting the app/container. Pass if the row fails with the storage-full affordance, keeps only its durable checkpoint, does not finalize a truncated file, and can continue after space is freed and Retry is tapped. | `downloads.transfer_start_failed`, `downloads.range_start_failed`, and `downloads.range_storage_full` now include exact and bucketed free bytes; preflight/start events also include exact required bytes. A task-completion ENOSPC carries the hash/context and durable checkpoint. A move-stage failure instead records `downloads.move_failed`; final success must still end in `downloads.finalize_finished`. | URLSession may wrap an ENOSPC as a generic move error before the app can classify it; retain device storage screenshots when only `downloads.move_failed` appears. |
| Play while downloading | While the row is active, confirm the Offline row has no partial-file Play action. From the online detail, Play must start the normal remote stream while the download continues; after validated completion, Play Offline becomes available and uses the local file. | The active download is evidenced by `downloads.range_progress`/`downloads.progress_milestone` on its hash. Local launch after completion records `playback.offline_launch` with that same hash; it must not occur for the partial row. Remote playback emits `playback.start_path`/`playback.session_start`, but those events do not carry the download hash. | There is no shared correlation field between a remote playback session and the simultaneous download. The “remote play continued while this row downloaded” portion still needs screen recording/timestamps; diagnostics can prove only the two independent activities and that partial offline launch did not occur. |
| Emby Convert finishes while asleep | Start a new Emby Convert job, lock/background the device before server completion, and leave it asleep until the server reports completion. On wake/relaunch, pass if the persisted job is resumed, the newly converted file is selected, the row hands off to the static transfer lane, and it eventually validates without creating a duplicate Convert job. | For the same hash: initial `downloads.convert_start`; after recovery `downloads.convert_resume`; then `downloads.convert_finalizing`, `downloads.convert_completed`, and a new `downloads.transfer_start`/`downloads.range_start`, ending in `downloads.finalize_finished`. `downloads.convert_poll_error` or `downloads.convert_failed` documents a real failure branch. | Convert polling is app-driven and there is no server-completion timestamp or sleep/wake event. Diagnostics establish discovery/handoff after recovery, not that the server finished specifically while the device slept; retain server-side job timestamps for that claim. |

### Physical evidence recorded 2026-07-11

- [x] **Ordinary off-head static transfer continued at the transport layer.** During two same-process
      Vision Pro background intervals (about 34 and 45 minutes), URLSession-owned temp bytes grew by
      1,543,398,509 and 2,351,788,230 bytes respectively. Deferred callbacks arrived at wake, including
      a completed 512 MiB held segment. No process death, auth failure, or connectivity-wait event was
      recorded; task metrics reported HTTP/3 over a constrained, non-cellular path.
- [ ] **Retest user-visible/durable off-head progress after the follow-up fix.** The first run exposed
      34 simultaneous 512 MiB tasks across five rows, stale live-overlay expiry, held-stash omission
      from the aggregate, and zero-checkpoint paused rows reconciling to failed/red. The follow-up uses
      64 MiB segments at depth two, keeps active overlays monotonic, counts held bodies, and preserves
      static paused intent without an opaque resume blob. Require another off-head interval before
      checking this presentation/durable-checkpoint cell.
- The first collector attempt selected a connected iPad because of a loose `vision` substring match;
  it is invalid evidence. Headset collection now requires exact visionOS/realityDevice identity and is
  regression-tested with mixed iPad/Vision Pro inventory.

## 6. Music

Run the common music rows against Plex and at least one Jellyfin and Emby library.

- [ ] Libraries, artists, albums, tracks, playlists, sorting, paging, and A–Z behavior use the
      active provider without cross-backend IDs leaking into navigation.
- [ ] Plex richer artist shelves render when returned; their absence on Jellyfin/Emby is a
      supported capability difference, not a loading failure.
- [ ] Play album/artist/playlist, shuffle, repeat, Play Next, Add to Queue, reorder, remove,
      clear, next/previous, and seek preserve the intended display and traversal order.
- [ ] Mini Player and Now Playing survive normal navigation and route artist/album taps back
      into the Music stack.
- [ ] Background audio, interruptions, route changes, Control Center/media keys, and artwork
      work on the physical platform. Starting video pauses music and hands system transport
      ownership to video; returning to music reclaims it.
- [ ] Changing backend/server/user/auth session clears the old queue before any stale track ID
      can resolve against the new session.
- [ ] Plex music timeline/scrobble updates server progress. Record the current limitation for
      Jellyfin/Emby: audio plays, but MediaBrowser music progress/scrobble is not implemented
      and must not be reported as passing.

## 7. System integration

Use physical iPhone/iPad, Apple Vision Pro, or a signed-in Mac host as applicable; simulator
navigation alone does not prove the external system invocation.

- [ ] Browsed video items become discoverable in Spotlight without thumbnails or tokens;
      music and never-browsed full-library content are not expected to be indexed.
- [ ] A Spotlight result cold-launches or foregrounds the app, waits for restore, validates the
      backend/server-scoped identifier, refetches metadata, and opens the correct detail.
- [ ] Play and Open App Intents resolve typed/spoken search and saved entities against the active
      backend. Continue Watching selects the expected Plex On Deck or Jellyfin/Emby resume/next
      item.
- [ ] Container autoplay resolves a show/season to an episode leaf; video playback begins once,
      and a stale/wrong-backend identifier is rejected rather than misrouted.
- [ ] Backend switch, sign-out, disabled system suggestions, and manual index cleanup remove or
      suppress stale results. System errors are complete user-facing messages without private data.

## 8. Diagnostics and privacy

- [ ] With app diagnostics disabled, new structured events are not retained or written to the
      rotating diagnostic file. Enabling/disabling updates the persisted preference predictably.
- [ ] Generated reports are bounded and useful, include aggregate download/storage and recent
      redacted MetricKit summaries when present, and contain no secrets or private library/server
      values.
- [ ] Clear Diagnostics removes both in-memory and file-backed app events. MetricKit remains a
      separate passive bounded channel and nothing is uploaded automatically.
- [ ] Feedback preview/export/share works on each affected platform and uses the expected
      filename/content type.
- [ ] Debug performance signposts appear for instrumented flows; Release behavior remains a
      no-op and does not emit profiling detail.
- [ ] Intentionally trigger representative auth, browse, playback, download, and timeline errors
      and inspect unified logs plus exported diagnostics for raw URL, query token, host, username,
      client/device ID, path, filename, and media-title leakage.

## 9. Lifecycle and background matrix

- [ ] Cold launch with saved sessions, cold launch signed out, ordinary foreground/background,
      memory pressure, and force-quit/relaunch all land in a coherent UI without duplicate restore,
      polling, observers, or playback controllers.
- [ ] Enter/exit Custom Cinema repeatedly: app-lifetime services survive window teardown, server
      discovery does not rerun unnecessarily, and downloads/music retain correct ownership.
- [ ] Device background URLSession completion invokes the system completion handler only after
      matching session events and required finalization operations drain.
- [ ] Foreground recovery coalesces reattach/revalidation work; repeated scene-phase changes do
      not start duplicate static ranges or server-prep pollers.
- [ ] Sign-out or backend-session change during playback/music/download work stops only stale or
      unauthorized work and never uses credentials from a newly active backend for an old row.
- [ ] Upgrade-install preserves intended Keychain/container/download state. Fresh install or app
      deletion is recorded separately and is not treated as an upgrade regression.

## 10. Pass criteria and evidence record

A row passes only when its expected user-visible result and relevant lifecycle/server side
effects were observed on a lane capable of proving them. “Build succeeded,” an old screenshot,
or simulator-only evidence for a hardware behavior is not a manual pass.

For each pass or failure, record:

| Field | Required content |
| --- | --- |
| Date/build | Date, commit, marketing version, internal build ID, Debug/Release |
| Lane | Target/scheme, device or simulator model, OS/runtime, upgrade or fresh install |
| Backend | Plex/Jellyfin/Emby, server version if relevant, local/remote network class; no URL or account name |
| Sample class | Non-identifying codec/container/HDR, duration/size class, route, subtitle/audio traits |
| Steps | Minimal reproducible actions and timing, including background/lock/network transitions |
| Expected/actual | Precise behavior and any server-side consequence |
| Result | Pass, fail, blocked, or not applicable, with the limitation stated |
| Evidence | Privacy-reviewed screenshot, screen recording, diagnostic event names, or artifact path |

- [ ] Review captured material before sharing or committing it.
- [ ] File failures with the smallest reproduction, affected platform/backend matrix, and
      redacted evidence; do not turn this checklist into an issue chronology.
- [ ] Mark blocked rows with the missing device, server capability, sample, or external state.
- [ ] Before declaring the manual pass complete, verify every required platform/backend cell has
      an explicit Pass, Not applicable, or Blocked result and that automated gates from the testing
      strategy are also green.
