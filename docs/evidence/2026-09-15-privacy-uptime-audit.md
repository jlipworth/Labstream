# Required-reason uptime audit — 2026-09-15

Scope: [#326](https://github.com/jlipworth/Labstream/issues/326), based on merged
source `e9344f63`. This change adds a declaration and packaging regression checks;
there is no runtime/playback change. Collection disclosures, project-operated
review/demo services, and [#325](https://github.com/jlipworth/Labstream/issues/325)
are separate; this audit does not approve App Store Connect answers or privacy policy.

## Reason and information flow

Apple's [required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
lists `systemUptime` and `mach_absolute_time()` under SystemBootTime. Reviewed on
2026-09-15: `35F9.1` covers elapsed time between app events and timer calculations.
It prohibits off-device raw/derived uptime, with an exception for information about
elapsed time between in-app events. This supports the uses below. Neither absolute
event timestamp conversion (`8FFB.1`) nor prominently displayed, individually
submitted boot-time bug reports (`3D61.1`) is the purpose of these calls, so neither
additional reason is declared.

Search of app and PMSKit Swift sources found 14 `systemUptime` call sites in
`PlaybackController`, one in `PlaybackDiagnostics`, and two default closures in
`MediaSessionProxy` (production and test-injection initializers). No direct
`mach_absolute_time` or `clock_gettime` call was found. The debug-only frame capture
uses `CACurrentMediaTime()` to select an AVPlayer frame, not to export host uptime.

| Consumer | Purpose and downstream fields |
| --- | --- |
| `PlaybackController.setSeeking` / `PlaybackSeekHold` | Seek-hold timer and maximum-duration comparison; raw start stays in memory. |
| `PlaybackPositionSample` / resolver | Monotonic sample ordering for restart/resume selection. `capturedAt` is not Codable or exported. `positionSnapshotDiagnosticFields` exports media positions, source labels and state, not capture uptime. |
| Zombie/stall watchdogs | Compare elapsed no-progress/waiting intervals to timeout limits. `stuck_seconds` and its log message describe the interval between app observations, not uptime. Other watchdog fields describe playback state. |
| Adaptive bitrate policy | In-app stall windows, healthy-playback windows and cooldown timers. Selected bitrate/state may influence ordinary media requests; clock baselines are not serialized into those requests. |
| Final-target rebuild / `SeekRestartBudget` | Cooldown and burst-window calculations. Exported `remaining_seconds` is the fixed cooldown minus elapsed time since an in-app restart: information about that interval, not a boot epoch. |
| Diagnostic snapshot throttle | In-memory comparison against last snapshot uptime; only the runtime snapshot fields are recorded. |
| `PlaybackDiagnostics.sample` | Local bitrate-idle grace interval; private `lastObservedProgressUptime` is not a report field. |
| PMSKit `MediaSessionProxy` → `UpstreamConnection` | Injects monotonic clock into restart budget; request headers, URL and body do not contain that clock. Status contains generation/open/rotate count, not raw timestamps. |

`AppDiagnostics` sends redacted events to its local store, file sink and unified
logging; the user report renders those events. `DiagnosticLogStore` event timestamps
and report generation dates use `Date`, not uptime conversion. Media timeline and
Now Playing elapsed positions are playback positions, not device uptime. The audited
uptime-derived exported intervals fit the exception above; there is no justification
here for exporting raw baselines. Future field changes need a fresh data-flow review.

## Dependencies and packaging

PMSKit is an app-owned local package linked into all four app targets. Its required
API use is covered by the shared app manifest. The resolved external graph is Apple
swift-crypto 4.5.1 and swift-asn1 1.7.1. Checked-out sources contained no direct
`systemUptime` or `mach_absolute_time` call. Crypto ships privacy resources; inspect
what the actual product includes rather than assuming every package target is linked.

The source regression verifies the shared category/reason and membership in all four
app targets. The product checker requires all four app bundles, checks the real
platform-specific resource locations against the source plist, and parses nested
privacy manifests. Neither check is an Apple aggregate privacy report.

Exact signed Release archives
and their Xcode aggregate privacy reports remain an explicit release gate: no signing
changes, archive upload, account changes, version bumps or release tags are part of
this work.

## Executed verification

- Xcode 27.0 (`27A5237l`): clean, previously nonexistent worktree-local DerivedData
  roots; unsigned **Release** builds of Labstream (visionOS Simulator), LabstreamMobile
  (iOS Simulator), LabstreamTV (tvOS Simulator), and LabstreamMac (arm64 host) all
  exited zero. Each newly linked executable had a modification time after its build
  started. Compiler warnings were present; these were not warning-free builds.
- Four-product packaging checker passed. Every app contains exactly two privacy
  manifests: the app's shared plist and `swift-crypto_Crypto.bundle`'s plist. All four
  app plists match the source, including SystemBootTime `35F9.1`; Crypto's plist has
  empty accessed/collected arrays and tracking false. No additional dependency
  manifest appeared in these products. This inventory is not an Xcode aggregate report.
- Hermetic PMSKit: 121 XCTest tests and 1,707 Swift Testing tests passed; live probes
  excluded with the canonical command.
- Privacy regression tests: four passed, covering the real source/four-target
  contract and negative cases for absent/wrong/duplicate reasons, missing target,
  incomplete product sets, missing resources, wrong platform and changed content.
- Strict MkDocs, rendered links/anchors, Mermaid and repository hygiene passed.
- Passive iPhone Release install/launch passed on the worktree's fresh simulator:
  installed/build UUID matched, process remained alive, screenshot inspected and
  showed the expected unauthenticated server-selection screen; bounded app logs had
  no fatal-error/assertion/uncaught-exception markers. No authentication or media
  playback was performed. Simulator was shut down and deleted afterward.
- `native-test-matrix.py affected` selected all four builds plus hosted/UI lanes
  conservatively for a shared resource. Builds were exercised as Release packaging
  checks; broad hosted/UI suites were not run for this declaration-only change.
  No visionOS passive launch was claimed: golden simulator provisioning was blocked
  by the main worktree's missing simulator-id file. No Mac app was staged/launched;
  worktree host cleanup confirmed no staged app remained. Private build and smoke
  artifacts remain in the worktree, not in Git or GitHub.

**Remaining release gate:** inspect the exact signed Release archive manifests and
Xcode aggregate privacy reports for all four platforms. These unsigned simulator/host
products cannot close that gate or establish hardware, live-backend, App Review, or
collection-disclosure acceptance.
