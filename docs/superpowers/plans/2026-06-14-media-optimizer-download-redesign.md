# Media Optimizer / Offline Download Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken single progressive-transcode download with a probe-driven dual
path — DIRECT-DOWNLOAD the original file when it plays as-is, MEDIA OPTIMIZER (server-rendered
static MP4) when a transcode is required — both converging on a static file with a real
`Content-Length`.

**Architecture:** A download-time direct-play probe (`/video/:/transcode/universal/decision`
with a 200_000 kbps ceiling) decides the path. Path A downloads the original `Part.key` via the
existing `OptimizeRequest.downloadURL`. Path B rewrites the optimizer to the real
`{backgroundProcessing.key}/items` contract (gated behind a live discovery probe, Phase 0) and
reuses the existing poll-for-rendered-part + background-`URLSession` machinery. Both end at the
same MIME/size/playability validation pipeline.

**Tech Stack:** Swift, Swift Testing (PMSKit package), SwiftUI + Observation (app),
`URLSession` background downloads, os.log.

---

## File Structure

**PMSKit (pure, tested):**
- `PMSKit/Sources/PMSKit/Transcode/DecisionResponse.swift` — add `playsWholeFileDirectly`.
- `PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift` — add background-processing /
  targets / playlist-create builders + decoders; retire flat `create` from the live path.
- `PMSKit/Tests/PMSKitTests/DecisionResponse+DownloadTests.swift` — new test file for
  `playsWholeFileDirectly`.
- `PMSKit/Tests/PMSKitTests/OptimizePlaylistTests.swift` — new test file for the new builders.
- `PMSKit/Tests/PMSKitTests/LiveOptimizeProbeTests.swift` — Phase 0 gated discovery probe.
- `scripts/live-optimize-probe.sh` — Phase 0 runner.

**App:**
- `PlexAVPApp/Downloads/DownloadManager.swift` — new `download(_:choice:…)` entry point,
  rewrite `triggerOptimize` to the playlist contract, retire progressive path +
  `estimatedTranscodeBytes`, retire `DownloadQuality` cap selection.
- `PlexAVPApp/Downloads/DownloadStore.swift` — replace `OfflineMetadata.quality` with
  `resolutionLabel`.
- `PlexAVPApp/UI/DownloadOptionsSheet.swift` — probe-first branching.
- `PlexAVPApp/Downloads/OfflineLibraryView.swift` — simplify progress to real
  `Content-Length`; keep EMA + `.monospacedDigit()`.

---

## Conventions for every task

- PMSKit tests run with `cd PMSKit && swift test`. Filter a file's tests with
  `swift test --filter <TestTypeOrFreeFuncName>`. Free `@Test func` functions are filtered by
  their function name.
- New Swift files are auto-detected (file-system-synchronized groups). **NEVER** edit the
  `.pbxproj`.
- App verification is **compile-only** (`xcodebuild`). The simulator is OFF-LIMITS — do not run
  any `simctl` subcommand.
- Never log a token or full URL. Use the existing `downloadLog` os.log `Logger` with sanitized
  path/query only.
- `X-Plex-Client-Profile-Name=Safari` must never change.
- Commit after each task with the shown message. Do NOT push, merge, or touch other branches.
- Repo goes public: never write a real host/IP/token/path. Use `192.0.2.10` /
  `plex.example.internal` placeholders only.

---

## Task 1: Phase 0 — instrumented optimize discovery probe (WRITE, DO NOT RUN)

**Files:**
- Create: `PMSKit/Tests/PMSKitTests/LiveOptimizeProbeTests.swift`
- Create: `scripts/live-optimize-probe.sh`

This is a gated integration test mirroring `LiveDecisionProbeTests` + the
`headless-pmskit-probe` skill. It is a **no-op** without `PLEX_LIVE_*` env vars, so plain
`swift test` and CI stay hermetic. It uses only `OptimizeRequest` builders that exist *after*
Task 6; to keep Task 1 self-contained and compilable now, it builds the discovery requests
**inline** (raw `URLRequest`/`PlexRequest`) and does NOT depend on Task-6 symbols. The user
runs it live LATER to fill in the server-specific contract.

- [ ] **Step 1: Write the probe test file**

```swift
import Testing
import Foundation
@testable import PMSKit

/// Phase 0 — LIVE optimize/background-processing DISCOVERY probe (offline-download
/// redesign). OPT-IN: runs only when PLEX_LIVE_* env vars are present, otherwise a no-op,
/// so plain `swift test` and CI stay hermetic and no secret is committed.
///
/// PURPOSE: discover the server-specific Media Optimizer contract that cannot be reached
/// from CI — the background-processing playlist key, the real target tag IDs, the POST
/// grammar PMS accepts, how a finished optimized Part appears, and that a static part's
/// `?download=1` carries a real Content-Length. It only LOGS (`>>> LIVE` lines); it does not
/// assert a contract, because the contract is exactly what we're discovering.
///
/// Run it (creds live in a gitignored env file — reuse scripts/plex-live.env):
///   ./scripts/live-optimize-probe.sh
/// or directly:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveOptimizeProbe
///
/// Faithful to the app: requests go through `URLSession.shared.data(for:)` exactly like
/// `PlexClient.send`, so the wire shape matches the visionOS app.
struct LiveOptimizeProbeTests {

    private struct LiveConfig {
        let server: URL
        let token: String
        let metadataKey: String          // /library/metadata/<ratingKey>
        let ratingKey: String
        let title: String
        let identity: ClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
                  let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty,
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.metadataKey = metadataKey
            self.ratingKey = (metadataKey as NSString).lastPathComponent
            self.title = env["PLEX_LIVE_TITLE"] ?? "VisionPlay Probe Optimize"
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
                product: "VisionPlay",
                version: "0.1.0",
                deviceName: "VisionPlay Live Probe")
        }
    }

    /// Build a request the way the app does: standard identity headers + token, query items.
    private func request(_ cfg: LiveConfig, path: String, method: String = "GET",
                         query: [URLQueryItem] = []) -> PlexRequest {
        PlexRequest(url: cfg.server.appendingPathComponent(path),
                    method: method,
                    queryItems: query,
                    headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
    }

    /// Send + dump status, headers of interest, and raw body.
    @discardableResult
    private func dump(_ label: String, _ req: PlexRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-utf8>"
            print("""
            >>> LIVE [\(label)] HTTP \(status), Content-Length=\(contentLength), \(data.count) bytes
            >>> LIVE [\(label)] body:
            \(body)
            >>> LIVE [\(label)] end body
            """)
            return data
        } catch {
            print(">>> LIVE [\(label)] ERROR: \(error)")
            return nil
        }
    }

    @Test func liveOptimizeDiscoveryDump() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }

        // 1. Background-processing playlist: GET /playlists?type=42 → read its `key`.
        await dump("playlists.type42",
                   request(cfg, path: "/playlists", query: [.init(name: "type", value: "42")]))

        // 2. Server's real media-processing targets (name + targetTagID). The exact path is
        //    what we're confirming; try the best-known endpoint and log whatever comes back.
        await dump("mediaProcessingTargets", request(cfg, path: "/media/processing/targets"))

        // 3. Item metadata BEFORE optimize — snapshot existing Media/Part ids.
        await dump("metadata.before", request(cfg, path: cfg.metadataKey))

        // 4. Attempt to enqueue an optimize via the playlist `items` grammar. We POST to the
        //    conventional background-processing items path; READ THE STATUS/BODY to learn the
        //    accepted shape. (If step 1 reported a different `key`, re-run with that path.)
        let optimizeItems: [URLQueryItem] = [
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: cfg.title),
            .init(name: "Item[target]", value: "Optimized for TV"),
            // targetTagID is SERVER-SPECIFIC — substitute the id from step 2 when re-running.
            .init(name: "Item[targetTagID]", value: "2"),
            .init(name: "Item[Location][uri]",
                  value: "server://\(cfg.identity.clientIdentifier)/com.plexapp.plugins.library\(cfg.metadataKey)"),
            .init(name: "Item[MediaSettings][videoQuality]", value: "100"),
            .init(name: "Item[MediaSettings][maxVideoBitrate]", value: "8000"),
            .init(name: "Item[MediaSettings][videoResolution]", value: "1920x1080"),
        ]
        await dump("optimize.post",
                   request(cfg, path: "/playlists/items", method: "POST", query: optimizeItems))

        // 5. Item metadata AFTER optimize — show how the new optimized Media/Part appears
        //    (diff its ids against step 3). May need a delay before the part materializes.
        await dump("metadata.after", request(cfg, path: cfg.metadataKey))

        // 6. Static-part Content-Length: HEAD the FIRST existing part with ?download=1 and
        //    confirm a real Content-Length (proves the static-file download premise).
        if let data = await dump("metadata.forParts", request(cfg, path: cfg.metadataKey)),
           let decoded = try? JSONDecoder().decode(MetadataResponse.self, from: data),
           let partKey = decoded.mediaContainer.metadata.first?.media?.first?.part.first?.key {
            var headReq = request(cfg, path: partKey,
                                  query: [.init(name: "download", value: "1"),
                                          .init(name: "X-Plex-Token", value: cfg.token)])
            headReq = PlexRequest(url: headReq.url, method: "HEAD",
                                  queryItems: headReq.queryItems, headers: headReq.headers)
            await dump("part.download.head", headReq)
        }

        print(">>> LIVE optimize discovery complete — read the lines above for the contract.")
    }
}
```

- [ ] **Step 2: Verify it compiles and is a hermetic no-op**

Run: `cd PMSKit && swift test --filter LiveOptimizeProbe`
Expected: builds clean; one test runs and prints
`>>> LIVE skipped: set PLEX_LIVE_SERVER …` then passes (no network, no secret).

- [ ] **Step 3: Write the Phase 0 runner**

```bash
#!/usr/bin/env bash
# Phase 0 — live Media Optimizer DISCOVERY probe (offline-download redesign). Sources creds
# from the gitignored scripts/plex-live.env and runs the opt-in PMSKit discovery test, which
# logs the server-specific optimize contract (background-processing key, target tag IDs, the
# POST grammar PMS accepts, the rendered Part, static-part Content-Length). No secrets are
# committed: the env file is gitignored; this script is not.
#
# Setup once (shared with the decision probe):
#   cp scripts/plex-live.env.example scripts/plex-live.env
#   # edit scripts/plex-live.env with your server / token / metadata key
# Then:
#   ./scripts/live-optimize-probe.sh
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not in a git repo" >&2; exit 1; }
cd "$repo_root"

env_file="${PLEX_LIVE_ENV:-scripts/plex-live.env}"
if [[ ! -f "$env_file" ]]; then
  echo "ERROR: $env_file not found. Copy scripts/plex-live.env.example to it and fill in creds." >&2
  exit 1
fi
if git ls-files --error-unmatch -- "$env_file" >/dev/null 2>&1; then
  echo "ERROR: $env_file is TRACKED by git — it holds secrets and must be gitignored." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd PMSKit
# Print the full body lines too (not just >>> LIVE) so the discovered JSON is visible.
swift test --filter LiveOptimizeProbe 2>&1 | grep -E '^>>> LIVE|^\{|error:|Test run' || true
```

- [ ] **Step 4: Make the runner executable**

Run: `chmod +x scripts/live-optimize-probe.sh`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add PMSKit/Tests/PMSKitTests/LiveOptimizeProbeTests.swift scripts/live-optimize-probe.sh
git commit -m "Add Phase 0 live optimize discovery probe (gated, log-only)"
```

---

## Task 2: `DecisionResponse.playsWholeFileDirectly`

**Files:**
- Create: `PMSKit/Tests/PMSKitTests/DecisionResponseDownloadTests.swift`
- Modify: `PMSKit/Sources/PMSKit/Transcode/DecisionResponse.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PMSKit

// `playsWholeFileDirectly` (offline-download redesign): STRICTER than `savesVideoEncode`.
// True only when PMS plays the WHOLE file as-is (so the original file can be downloaded).
// Direct Stream (copy video / transcode audio) is NOT enough — it would need a rendered file.

@Test func wholeFileDirectViaMdeCode1000() throws {
    // Live shape: mdeDecisionCode 1000 + Part decision "directplay", per-stream nil.
    let json = """
    {"MediaContainer":{"mdeDecisionCode":1000,"mdeDecisionText":"Direct play OK.",
       "Metadata":[{"Media":[{"Part":[{"decision":"directplay","Stream":[
         {"streamType":1},{"streamType":2}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == true)
    #expect(r.savesVideoEncode == true)        // regression guard: unchanged
}

@Test func wholeFileDirectViaGeneralCode1000() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1000,"generalDecisionText":"Direct Play"}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.decision == .directPlay)
    #expect(r.playsWholeFileDirectly == true)
}

@Test func wholeFileDirectViaPartDirectplayWithSpaces() throws {
    let json = """
    {"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"decision":"Direct Play"}]}]}]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == true)
}

@Test func directStreamDoesNotPlayWholeFileDirectly() throws {
    // Copy video / transcode audio: savesVideoEncode true, but NOT a whole-file direct play,
    // so a download must render a file (optimizer), not pull the original.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "mdeDecisionText":"Convert to HLS, copy video, transcode audio",
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"copy"},
         {"streamType":2,"decision":"transcode"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.savesVideoEncode == true)            // unchanged
    #expect(r.playsWholeFileDirectly == false)     // stricter
}

@Test func partLevelCopyDoesNotPlayWholeFileDirectly() throws {
    // Remux (part "copy"): saves the video encode, but is NOT a byte-for-byte original.
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"decision":"copy"}]}]}]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.savesVideoEncode == true)
    #expect(r.playsWholeFileDirectly == false)
}

@Test func fullTranscodeDoesNotPlayWholeFileDirectly() throws {
    let json = """
    {"MediaContainer":{"generalDecisionCode":1001,
       "Metadata":[{"Media":[{"Part":[{"decision":"transcode","Stream":[
         {"streamType":1,"decision":"transcode"},
         {"streamType":2,"decision":"transcode"}
       ]}]}]}]
    }}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(DecisionResponse.self, from: json)
    #expect(r.playsWholeFileDirectly == false)
    #expect(r.savesVideoEncode == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd PMSKit && swift test --filter wholeFileDirectViaMdeCode1000`
Expected: FAIL — `value of type 'DecisionResponse' has no member 'playsWholeFileDirectly'`.

- [ ] **Step 3: Add the property**

In `DecisionResponse.swift`, after `savesVideoEncode` (the closing `}` near line 114),
add:

```swift
    /// True ONLY when PMS will play the WHOLE file as-is (container + every stream), so the
    /// original file can be downloaded byte-for-byte for offline use (offline-download
    /// redesign). STRICTER than `savesVideoEncode`, which is also true for Direct Stream
    /// (copy video / transcode audio) and remux (part "copy") — neither of which yields a
    /// downloadable original file; those route to the Media Optimizer instead. Structured
    /// signals only, never the English `mdeDecisionText`:
    ///   1. `mdeDecisionCode == 1000` — MDE whole-file direct play, OR
    ///   2. `decision == .directPlay` (generalDecisionCode 1000), OR
    ///   3. Part-level `decision` (lowercased, spaces removed) == "directplay".
    /// A part/stream "copy" is deliberately NOT sufficient. Conservative: false without
    /// one of these signals.
    public var playsWholeFileDirectly: Bool {
        if mdeDecisionCode == 1000 { return true }
        if decision == .directPlay { return true }
        let normalizedPart = partDecision?.lowercased().replacingOccurrences(of: " ", with: "")
        return normalizedPart == "directplay"
    }
```

- [ ] **Step 4: Run the new tests + the existing decision tests**

Run: `cd PMSKit && swift test --filter wholeFileDirect && swift test --filter DownloadTests`
Then the regression guard for the old property:
Run: `cd PMSKit && swift test --filter SavesVideoEncode 2>/dev/null; swift test --filter DecodingTests`
Expected: PASS. (If a filter matches nothing, run the full `swift test` in Step 5 instead.)

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `cd PMSKit && swift test`
Expected: all tests pass, including the existing `savesVideoEncode` cases.

- [ ] **Step 6: Commit**

```bash
git add PMSKit/Sources/PMSKit/Transcode/DecisionResponse.swift \
        PMSKit/Tests/PMSKitTests/DecisionResponseDownloadTests.swift
git commit -m "Add DecisionResponse.playsWholeFileDirectly (strict whole-file direct-play)"
```

---

## Task 3: Optimizer playlist-contract builders + decoders (PMSKit)

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift`
- Create: `PMSKit/Tests/PMSKitTests/OptimizePlaylistTests.swift`

Add the real-contract builders. These are pure builders; the runtime sequencing lives in the
app (Task 6) and is flagged for Phase 0 live confirmation.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "VisionPlay",
                               version: "0.1.0", deviceName: "AVP")

@Test func backgroundProcessingRequestTargetsType42Playlists() {
    let r = OptimizeRequest.backgroundProcessingRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/playlists")
    #expect(r.method == "GET")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "42")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func mediaProcessingTargetsRequestAsksForJSON() {
    let r = OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/media/processing/targets")
    #expect(r.method == "GET")
    #expect(r.headers["Accept"] == "application/json")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistPostsToKeyWithItemGrammar() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", title: "Blade Runner",
        targetTagID: 7,
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: 8000,
                             videoResolution: "1920x1080"))
    #expect(r.url.path == "/playlists/9/items")
    #expect(r.method == "POST")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("Item[type]") == "42")
    #expect(v("Item[title]") == "Blade Runner")
    // targetTagID is the SERVER-RESOLVED id passed in — NOT a hardcoded enum default.
    #expect(v("Item[targetTagID]") == "7")
    #expect(v("Item[MediaSettings][maxVideoBitrate]") == "8000")
    #expect(v("Item[MediaSettings][videoResolution]") == "1920x1080")
    #expect(v("Item[Location][uri]")?.contains("/library/metadata/101") == true)
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func createOnPlaylistOmitsAbsentMediaSettings() {
    let r = OptimizeRequest.createOnPlaylist(
        server: server, token: "tok", identity: id,
        backgroundProcessingKey: "/playlists/9/items",
        ratingKey: "101", title: "T", targetTagID: 3,
        mediaSettings: .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil))
    func names() -> [String] { r.queryItems.map(\.name) }
    #expect(!names().contains("Item[MediaSettings][maxVideoBitrate]"))
    #expect(!names().contains("Item[MediaSettings][videoResolution]"))
}

@Test func decodesBackgroundProcessingPlaylistKey() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"playlistType":"42","key":"/playlists/9/items","title":"Background Processing"}
    ]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(BackgroundProcessingPlaylist.self, from: json)
    #expect(r.key == "/playlists/9/items")
}

@Test func decodesMediaProcessingTargets() throws {
    // Best-known shape; Phase 0 confirms the real element/field names against live PMS.
    let json = """
    {"MediaContainer":{"MediaProcessingTarget":[
      {"id":7,"tag":"Optimized for TV"},
      {"id":8,"tag":"Optimized for Mobile"}
    ]}}
    """.data(using: .utf8)!
    let r = try JSONDecoder().decode(MediaProcessingTargets.self, from: json)
    #expect(r.targets.count == 2)
    #expect(r.targets.first?.id == 7)
    #expect(r.targets.first?.name == "Optimized for TV")
    // Case-insensitive name lookup helper used by the manager to resolve a chosen preset.
    #expect(r.tagID(forName: "optimized for tv") == 7)
    #expect(r.tagID(forName: "nonexistent") == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd PMSKit && swift test --filter backgroundProcessingRequestTargetsType42Playlists`
Expected: FAIL — `type 'OptimizeRequest' has no member 'backgroundProcessingRequest'`.

- [ ] **Step 3: Add the builders + decoders**

In `OptimizeRequest.swift`, add these members inside the `enum OptimizeRequest` (after the
existing `statusRequest`, before `downloadURL`). Add a JSON `Accept` header explicitly on the
GETs (Plex defaults to XML otherwise — same trap as the decision call):

```swift
    // MARK: - Real optimize contract (Phase-0-gated; see the redesign spec/plan)

    /// Settings for an optimize job's rendered output. `nil` fields are omitted from the
    /// request so PMS uses the preset's defaults.
    public struct MediaSettings: Sendable, Equatable {
        public let videoQuality: Int?
        public let maxVideoBitrateKbps: Int?
        public let videoResolution: String?
        public init(videoQuality: Int? = 100, maxVideoBitrateKbps: Int? = nil,
                    videoResolution: String? = nil) {
            self.videoQuality = videoQuality
            self.maxVideoBitrateKbps = maxVideoBitrateKbps
            self.videoResolution = videoResolution
        }
    }

    /// `GET /playlists?type=42` — the background-processing playlist that owns optimize jobs.
    /// Decode with `BackgroundProcessingPlaylist` and read its `key` (e.g. `/playlists/9/items`).
    /// Accept JSON explicitly (PMS returns XML by default and the decode would fail).
    public static func backgroundProcessingRequest(server: URL, token: String,
                                                   identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/playlists"),
                    method: "GET",
                    queryItems: [.init(name: "type", value: "42")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /media/processing/targets` — the server's real optimize presets (name + id).
    /// SERVER-SPECIFIC: the exact path/field names are confirmed by Phase 0; this is the
    /// best-known endpoint. Decode with `MediaProcessingTargets`.
    public static func mediaProcessingTargetsRequest(server: URL, token: String,
                                                    identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/media/processing/targets"),
                    method: "GET",
                    queryItems: [],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `POST {backgroundProcessingKey}` — enqueue an optimize job using the nested `Item[...]`
    /// grammar python-plexapi sends. `targetTagID` is the SERVER-RESOLVED id (from the targets
    /// list), NOT a hardcoded enum default. SERVER-SPECIFIC: the accepted key + grammar are
    /// confirmed by Phase 0.
    public static func createOnPlaylist(server: URL, token: String, identity: ClientIdentity,
                                        backgroundProcessingKey: String,
                                        ratingKey: String, title: String,
                                        targetTagID: Int,
                                        mediaSettings: MediaSettings) -> PlexRequest {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let url = server.appendingPathComponent(trimmed)
        var items: [URLQueryItem] = [
            .init(name: "Item[type]", value: "42"),
            .init(name: "Item[title]", value: title),
            .init(name: "Item[targetTagID]", value: String(targetTagID)),
            .init(name: "Item[Location][uri]",
                  value: "server://\(identity.clientIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"),
        ]
        if let q = mediaSettings.videoQuality {
            items.append(.init(name: "Item[MediaSettings][videoQuality]", value: String(q)))
        }
        if let b = mediaSettings.maxVideoBitrateKbps {
            items.append(.init(name: "Item[MediaSettings][maxVideoBitrate]", value: String(b)))
        }
        if let res = mediaSettings.videoResolution {
            items.append(.init(name: "Item[MediaSettings][videoResolution]", value: res))
        }
        return PlexRequest(url: url, method: "POST", queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
```

Then, at the **end of the file** (after the closing `}` of `enum OptimizeRequest`), add the
decoders:

```swift
/// The background-processing playlist (`GET /playlists?type=42`). We only need its `key`
/// (e.g. `/playlists/9/items`) to POST optimize jobs against. Lenient: server shapes vary.
public struct BackgroundProcessingPlaylist: Decodable, Sendable, Equatable {
    public let key: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case metadata = "Metadata" }
    private struct Entry: Decodable { let key: String?; let playlistType: String? }

    public init(key: String?) { self.key = key }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        let entries = try container.decodeIfPresent([Entry].self, forKey: .metadata) ?? []
        // Prefer the type-42 entry; fall back to the first with a key.
        self.key = entries.first(where: { $0.playlistType == "42" })?.key
            ?? entries.first(where: { $0.key != nil })?.key
    }
}

/// The server's media-processing (optimize) targets (`GET /media/processing/targets`).
/// SERVER-SPECIFIC shape — Phase 0 confirms the element + field names. Lenient.
public struct MediaProcessingTargets: Decodable, Sendable, Equatable {
    public struct Target: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        public init(id: Int, name: String) { self.id = id; self.name = name }

        enum CodingKeys: String, CodingKey { case id; case tag; case title }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? c.decode(Int.self, forKey: .id)) ?? -1
            self.name = (try? c.decodeIfPresent(String.self, forKey: .tag))
                ?? (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        }
    }

    public let targets: [Target]

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey { case target = "MediaProcessingTarget" }

    public init(targets: [Target]) { self.targets = targets }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        self.targets = (try container.decodeIfPresent([Target].self, forKey: .target)) ?? []
    }

    /// Case-insensitive name → targetTagID lookup (used to resolve a chosen preset name).
    public func tagID(forName name: String) -> Int? {
        targets.first { $0.name.lowercased() == name.lowercased() }?.id
    }
}
```

- [ ] **Step 4: Run the new tests**

Run: `cd PMSKit && swift test --filter OptimizePlaylistTests 2>/dev/null || cd PMSKit && swift test`
Expected: the new tests pass. (Free `@Test` funcs are in the new file; if the type filter
matches nothing, the full `swift test` covers them.)

- [ ] **Step 5: Run the full suite**

Run: `cd PMSKit && swift test`
Expected: all pass (existing `OptimizeTests` still green — we only ADDED members).

- [ ] **Step 6: Commit**

```bash
git add PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift \
        PMSKit/Tests/PMSKitTests/OptimizePlaylistTests.swift
git commit -m "Add real optimize contract builders + decoders (playlist items, targets)"
```

---

## Task 4: Replace `OfflineMetadata.quality` with `resolutionLabel`

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadStore.swift`

The cap-based `DownloadQuality` is being retired (Task 7). The offline UI caption needs the
chosen file's resolution label instead. This task changes the persisted snapshot only; the
manager + views update in later tasks. (No PMSKit test — this is app code; verified by the
app compile in Task 8.)

- [ ] **Step 1: Change the stored field**

In `DownloadStore.swift`, in `struct OfflineMetadata`, replace the `quality` field:

```swift
    public var quality: String?
```

with:

```swift
    /// Human resolution label of the downloaded file (e.g. "1080p", "4K", "1920×1080"),
    /// captured from the chosen `Media` at download time. Drives the offline caption.
    /// Replaces the retired bitrate-cap `quality` marker (offline-download redesign).
    public var resolutionLabel: String?
```

- [ ] **Step 2: Update the memberwise init + decoder + any `CodingKeys`**

Find the `OfflineMetadata` initializer parameter `quality: String? = nil` and the
`self.quality = quality` assignment; rename both to `resolutionLabel`. In the `CodingKeys`
enum (if present) rename `case quality` to `case resolutionLabel`. In `init(from:)` change:

```swift
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
```
to:
```swift
        resolutionLabel = try c.decodeIfPresent(String.self, forKey: .resolutionLabel)
```

(If a custom `encode(to:)` exists, rename the corresponding `encode` line too.)

- [ ] **Step 3: Build PMSKit to confirm the model still compiles in isolation**

Run: `cd PMSKit && swift build`
Expected: succeeds (PMSKit doesn't depend on the app; this is a sanity check that nothing in
the package broke).

- [ ] **Step 4: Commit**

```bash
git add PlexAVPApp/Downloads/DownloadStore.swift
git commit -m "OfflineMetadata: replace bitrate-cap quality with resolutionLabel"
```

> Note: the app won't fully compile until Task 7 updates the references to `quality`. That's
> expected; the single app compile gate is Task 8.

---

## Task 5: `DownloadManager.download(_:choice:…)` — new probe-driven entry + direct path

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadManager.swift`

Introduce the new public entry point and the **direct-download** path (Path A). The optimizer
path is wired in Task 6. This task also defines the `DownloadChoice` the sheet passes.

- [ ] **Step 1: Add the `DownloadChoice` type**

In `DownloadManager`, near `DownloadError` (after the enum, before `records`), add:

```swift
    /// What the user chose in the download sheet, resolved from the direct-play probe.
    public enum DownloadChoice: Sendable, Equatable {
        /// Direct-download the original file (probe said whole-file direct play).
        case original
        /// Server-side optimize to a named preset (the server's real target name).
        case optimize(targetName: String)
    }
```

- [ ] **Step 2: Add the probe helper**

Add a method that runs the download-mode direct-play probe (200_000 kbps ceiling — never let a
cap force transcode) and returns whether the whole file direct-plays, plus the chosen part:

```swift
    /// Run the download-time direct-play probe for `item` at the given media/part. Advertises
    /// the `.original` 200_000 kbps ceiling so a high-bitrate-but-compatible file still
    /// qualifies for a direct download — a cap must NEVER force a transcode verdict for
    /// downloads. Returns `(playsWholeFileDirectly, originalPart)`; on any probe failure
    /// returns `(false, part?)` so the caller falls back to the optimizer.
    public func directPlayProbe(for item: MediaItem, server: URL, token: String,
                                mediaIndex: Int, partIndex: Int)
        async -> (direct: Bool, part: Part?) {
        let part = item.media?[safe: mediaIndex]?.part[safe: partIndex]
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"
        let transcode = TranscodeRequest(server: server, token: token,
                                         identity: appModel.identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: 200_000,
                                         sessionID: "plex-avp-dl-probe-" + UUID().uuidString,
                                         mediaIndex: mediaIndex, partIndex: partIndex)
        do {
            let decision = try await appModel.client.send(transcode.directPlayProbeRequest(),
                                                          as: DecisionResponse.self)
            return (decision.playsWholeFileDirectly, part)
        } catch {
            downloadLog.error("download-probe-failed ratingKey=\(item.ratingKey, privacy: .public) err=\(String(describing: error), privacy: .public)")
            return (false, part)
        }
    }
```

Add the safe-subscript helper at the bottom of the file (after the registry class), if not
already present elsewhere — guard against duplicate definition:

```swift
private extension Array {
    /// Bounds-checked subscript: `self[safe: i]` is nil when `i` is out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 3: Add the new `download(_:choice:…)` entry point (direct path only for now)**

Add this method (the optimizer branch calls `triggerOptimizeAndDownload`, added in Task 6):

```swift
    /// Probe-driven download entry point (offline-download redesign). `choice` comes from the
    /// sheet, which already ran the direct-play probe: `.original` direct-downloads the source
    /// file; `.optimize` renders a compatible MP4 server-side then downloads it. Both converge
    /// on the same background-`URLSession` + validation pipeline. Records state rather than
    /// throwing.
    public func download(_ item: MediaItem, choice: DownloadChoice,
                         mediaIndex: Int = 0, partIndex: Int = 0) async {
        let ratingKey = item.ratingKey
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            lastError[ratingKey] = .notAuthenticated
            return
        }
        guard !activeJobs.contains(ratingKey) else { return }
        activeJobs.insert(ratingKey)
        lastError[ratingKey] = nil
        defer { activeJobs.remove(ratingKey) }

        let chosenMedia = item.media?[safe: mediaIndex]
        let resolutionLabel = Self.resolutionLabel(for: chosenMedia)
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex)
        cachePoster(ratingKey: ratingKey, thumb: item.thumb ?? item.art,
                    server: server, token: token)

        switch choice {
        case .original:
            guard let part = chosenMedia?.part[safe: partIndex] else {
                lastError[ratingKey] = .transferFailed("No media part to download.")
                return
            }
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0,
                                        metadata: metadata))
            refreshRecords()
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            do {
                try session.start(ratingKey: ratingKey, from: url, to: destination,
                                  expectedBytes: part.size)
                refreshRecords()
            } catch let error as DownloadError {
                lastError[ratingKey] = error
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            } catch {
                lastError[ratingKey] = .transferFailed(String(describing: error))
                store.setStatus(ratingKey: ratingKey, .failed)
                refreshRecords()
            }

        case .optimize(let targetName):
            await triggerOptimizeAndDownload(item: item, targetName: targetName,
                                             metadata: metadata, server: server, token: token)
        }
    }
```

- [ ] **Step 4: Add the metadata/resolution helpers**

Replace the existing `offlineMetadata(from:quality:mediaIndex:partIndex:)` helper signature to
take `resolutionLabel` instead of `quality`, and add a resolution-label builder:

```swift
    private static func offlineMetadata(from item: MediaItem,
                                        resolutionLabel: String?,
                                        mediaIndex: Int,
                                        partIndex: Int) -> OfflineMetadata {
        OfflineMetadata(ratingKey: item.ratingKey,
                        key: item.key,
                        title: item.title,
                        type: item.type,
                        year: item.year,
                        duration: item.duration,
                        viewOffset: item.viewOffset,
                        viewCount: item.viewCount,
                        summary: item.summary,
                        contentRating: item.contentRating,
                        tagline: item.tagline,
                        thumb: item.thumb,
                        art: item.art,
                        resolutionLabel: resolutionLabel,
                        mediaIndex: mediaIndex,
                        partIndex: partIndex,
                        posterRelativePath: nil)
    }

    /// Human resolution label from a `Media`'s dimensions, e.g. "1080p" / "4K" / "1920×1080".
    static func resolutionLabel(for media: Media?) -> String? {
        guard let media else { return nil }
        switch (media.width, media.height) {
        case let (_, h?) where h >= 2160: return "4K"
        case let (_, h?) where h >= 1080: return "1080p"
        case let (_, h?) where h >= 720:  return "720p"
        case let (_, h?) where h >= 480:  return "480p"
        case let (w?, h?):                return "\(w)×\(h)"
        default:                          return nil
        }
    }
```

> Note: this references `OfflineMetadata(... resolutionLabel: ...)` — the field renamed in
> Task 4. The memberwise init's argument label changes accordingly; if `OfflineMetadata` has a
> hand-written `init`, confirm Task 4 renamed its `quality:` parameter to `resolutionLabel:`.

- [ ] **Step 5: Commit (compiles fully only after Task 6+7; gate is Task 8)**

```bash
git add PlexAVPApp/Downloads/DownloadManager.swift
git commit -m "DownloadManager: add probe-driven download entry + direct-download path"
```

---

## Task 6: Rewrite `triggerOptimize` to the playlist contract (Phase-0-gated)

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadManager.swift`

Replace the legacy flat-PUT optimize with the real runtime sequence, isolated behind one
method. Keep `pollForOptimizedPart`.

- [ ] **Step 1: Replace `triggerOptimize` with `triggerOptimizeAndDownload`**

Delete the old private `triggerOptimize(item:server:token:identity:)` method and the legacy
`optimizeAndDownload(_ item:)` (the no-quality one, ~line 167) — both are superseded. Add:

```swift
    // MARK: - Optimize path (HIGH UNCERTAINTY — isolated; Phase 0 confirms the contract)

    /// Render a compatible MP4 server-side, poll for the rendered Part, then download it.
    ///
    /// Real contract (python-plexapi `Video.optimize`), implemented to the best-known shape:
    ///   1. GET /playlists?type=42  → read `backgroundProcessing.key` (e.g. /playlists/9/items)
    ///   2. GET /media/processing/targets → resolve the chosen preset NAME to its server
    ///      `targetTagID` (NOT a hardcoded 2/1/3; those are version-specific)
    ///   3. POST {key}  with the Item[...] grammar
    ///   4. poll item metadata for the new Part, then download it (static file, real size).
    ///
    /// // TODO(live, Phase 0): the background-processing key, the targets endpoint/shape, and
    /// the accepted POST grammar are confirmed by `scripts/live-optimize-probe.sh`. Until then
    /// this is the best-known contract and is NOT live-verified. Failures are recorded as
    /// `.optimizeFailed`; we still poll metadata so an out-of-band optimized part is picked up.
    private func triggerOptimizeAndDownload(item: MediaItem, targetName: String,
                                            metadata: OfflineMetadata,
                                            server: URL, token: String) async {
        let ratingKey = item.ratingKey
        let identity = appModel.identity
        // Seed a 0% record so the UI shows the job immediately while we set up the optimize.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, metadata: metadata))
        refreshRecords()

        do {
            try await triggerOptimize(item: item, targetName: targetName,
                                      server: server, token: token, identity: identity)
            let part = try await pollForOptimizedPart(ratingKey: ratingKey, server: server,
                                                      token: token, identity: identity)
            let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
            let destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                        localURL: destination, bytes: 0, progress: 0,
                                        metadata: metadata))
            refreshRecords()
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            try session.start(ratingKey: ratingKey, from: url, to: destination,
                              expectedBytes: part.size)
            refreshRecords()
        } catch let error as DownloadError {
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        } catch {
            lastError[ratingKey] = .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            refreshRecords()
        }
    }

    /// Steps 1–3 of the optimize contract: fetch the background-processing key, resolve the
    /// target tag id from the server's targets, POST the optimize job. Isolated so the live
    /// (server-specific) path is the only thing Phase 0 needs to confirm.
    private func triggerOptimize(item: MediaItem, targetName: String,
                                 server: URL, token: String,
                                 identity: ClientIdentity) async throws {
        // 1. Background-processing playlist key.
        let bgKey: String
        do {
            let pl = try await appModel.client.send(
                OptimizeRequest.backgroundProcessingRequest(server: server, token: token, identity: identity),
                as: BackgroundProcessingPlaylist.self)
            guard let key = pl.key else {
                throw DownloadError.optimizeFailed("No background-processing playlist key.")
            }
            bgKey = key
        } catch let e as DownloadError {
            throw e
        } catch {
            throw DownloadError.optimizeFailed("playlists?type=42: \(String(describing: error))")
        }

        // 2. Resolve the chosen preset NAME to the server's targetTagID. If the targets
        //    endpoint isn't available, fall back to the conventional id so the POST still
        //    has a value (Phase 0 will confirm whether that's accepted).
        var targetTagID = Self.conventionalTagID(forName: targetName)
        if let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token, identity: identity),
            as: MediaProcessingTargets.self),
           let resolved = targets.tagID(forName: targetName) {
            targetTagID = resolved
        }

        // 3. POST the optimize job to the background-processing playlist.
        let settings = Self.mediaSettings(forTargetName: targetName)
        let create = OptimizeRequest.createOnPlaylist(
            server: server, token: token, identity: identity,
            backgroundProcessingKey: bgKey, ratingKey: item.ratingKey,
            title: item.title, targetTagID: targetTagID, mediaSettings: settings)
        do {
            try await appModel.client.send(create)
        } catch {
            throw DownloadError.optimizeFailed("optimize POST: \(String(describing: error))")
        }
    }

    /// Conventional Plex target tag ids (fallback only — the live server's ids win when the
    /// targets endpoint resolves them). Phase 0 confirms the real ids.
    private static func conventionalTagID(forName name: String) -> Int {
        switch name.lowercased() {
        case "optimized for mobile": return 1
        case "original quality":     return 3
        default:                     return 2   // "Optimized for TV"
        }
    }

    /// Best-known render settings per preset name (fallback caps; the server preset governs).
    private static func mediaSettings(forTargetName name: String) -> OptimizeRequest.MediaSettings {
        switch name.lowercased() {
        case "optimized for mobile":
            return .init(videoQuality: 100, maxVideoBitrateKbps: 2000, videoResolution: "1280x720")
        case "original quality":
            return .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil)
        default:
            return .init(videoQuality: 100, maxVideoBitrateKbps: 8000, videoResolution: "1920x1080")
        }
    }
```

- [ ] **Step 2: Update `retry` to the new entry point**

Replace the `retry(ratingKey:)` body's tail (the part that rebuilds the item + quality + calls
`optimizeAndDownload`) with a probe-driven re-run. Replace:

```swift
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let quality = metadata?.quality.flatMap(DownloadQuality.init(rawValue:)) ?? .default
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        Task { await optimizeAndDownload(item, quality: quality,
                                         mediaIndex: mediaIndex, partIndex: partIndex) }
```

with:

```swift
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Re-probe so the retry takes the correct path: a now-compatible file goes direct,
        // otherwise re-render via the optimizer (default "Optimized for TV" preset).
        Task { [weak self] in
            guard let self,
                  let token = self.appModel.serverToken,
                  let server = self.appModel.serverBaseURL else { return }
            let probe = await self.directPlayProbe(for: item, server: server, token: token,
                                                   mediaIndex: mediaIndex, partIndex: partIndex)
            let choice: DownloadChoice = probe.direct ? .original
                : .optimize(targetName: "Optimized for TV")
            await self.download(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex)
        }
```

- [ ] **Step 3: Commit**

```bash
git add PlexAVPApp/Downloads/DownloadManager.swift
git commit -m "DownloadManager: rewrite optimize path to real playlist contract (Phase-0-gated)"
```

---

## Task 7: Retire the progressive path + estimation; update the sheet + offline view

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadManager.swift`
- Modify: `PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift`
- Modify: `PMSKit/Tests/PMSKitTests/TranscodeRequestTests.swift`
- Modify: `PlexAVPApp/UI/DownloadOptionsSheet.swift`
- Modify: `PlexAVPApp/Downloads/OfflineLibraryView.swift`

- [ ] **Step 1: Remove the progressive `optimizeAndDownload(_:quality:…)` + `estimatedTranscodeBytes` + `DownloadQuality`**

In `DownloadManager.swift`:
- Delete the `public enum DownloadQuality` (lines ~53–104).
- Delete `public func optimizeAndDownload(_ item:quality:mediaIndex:partIndex:)` (the
  progressive method, ~234–294).
- Delete `public static func estimatedTranscodeBytes(quality:durationMs:)` (~366–372).

(The legacy `optimizeAndDownload(_ item:)` was already removed in Task 6 Step 1. After this,
the only public download entry point is `download(_:choice:mediaIndex:partIndex:)`.)

- [ ] **Step 2: Retire `TranscodeRequest.downloadURL()` and its test**

In `TranscodeRequest.swift`, delete the `downloadURL()` method (the `protocol=http`
progressive builder, ~lines 193–225, including its doc comment).

In `TranscodeRequestTests.swift`, delete the test `downloadURLUsesProgressiveHTTPAndDownloadFlag`
(~line 33) and the `resumeOffsetIsSentToPMSOnStreamButStrippedFromDownload` test's
download-half assertions — or simplify that test to only assert the stream-side offset.
Concretely, replace `resumeOffsetIsSentToPMSOnStreamButStrippedFromDownload` with:

```swift
@Test func resumeOffsetIsSentToPMSOnStream() {
    let req = TranscodeRequest(server: URL(string: "https://192.0.2.10:32400")!,
                               token: "tok", identity: id, metadataKey: "/library/metadata/1",
                               maxVideoBitrateKbps: 8000, sessionID: "S",
                               mediaIndex: 0, partIndex: 0, startOffsetSeconds: 120)
    let q = queryItems(req.startM3U8URL())
    #expect(q.first { $0.name == "offset" }?.value == "120")
}
```

(Confirm the `id` / `queryItems` helpers exist at the top of that test file; reuse them. If the
original test used a different server literal, keep the file's existing one.)

- [ ] **Step 3: Run the PMSKit suite (confirms the retirement is clean)**

Run: `cd PMSKit && swift test`
Expected: all pass; no reference to the removed `downloadURL()` remains.

- [ ] **Step 4: Commit the retirement**

```bash
git add PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift \
        PMSKit/Tests/PMSKitTests/TranscodeRequestTests.swift \
        PlexAVPApp/Downloads/DownloadManager.swift
git commit -m "Retire progressive transcode download + bitrate-cap estimation"
```

- [ ] **Step 5: Rewrite `DownloadOptionsSheet` to probe-first branching**

Replace the body of `DownloadOptionsSheet.swift` with probe-driven content. Key changes:
add `@Environment(AppModel.self)`, run the probe in `.task`, and present either the single
"Download original" action or the server preset list. Full file:

```swift
import SwiftUI
import PMSKit

/// Probe-first download sheet (offline-download redesign). On appear it runs the direct-play
/// probe: if the WHOLE file direct-plays it offers a single "Download original — <size> · <res>"
/// action (no quality picker); otherwise it offers the server's real optimize presets. If the
/// probe fails / the server is unreachable, it falls back to offering the optimizer presets.
/// Both routes converge on the same background-`URLSession` + validation pipeline.
struct DownloadOptionsSheet: View {
    let item: MediaItem
    var mediaIndex: Int = 0
    var partIndex: Int = 0

    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum ProbeState: Equatable {
        case checking
        case direct(sizeBytes: Int?, resolution: String?)
        case optimize(presets: [String], probeFailed: Bool)
    }

    @State private var probeState: ProbeState = .checking
    /// Chosen optimizer preset name (when not direct).
    @State private var selectedPreset: String = "Optimized for TV"

    private var existingRecord: DownloadRecord? {
        downloadManager.records.first { $0.ratingKey == item.ratingKey }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let record = existingRecord {
                    existingSection(record)
                } else {
                    switch probeState {
                    case .checking:
                        SwiftUI.Section { Label("Checking compatibility…", systemImage: "wifi") }
                    case let .direct(sizeBytes, resolution):
                        directSection(sizeBytes: sizeBytes, resolution: resolution)
                        infoSection
                    case let .optimize(presets, probeFailed):
                        optimizeSection(presets: presets, probeFailed: probeFailed)
                        infoSection
                    }
                }
            }
            .navigationTitle("Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if existingRecord == nil, probeState != .checking {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download") { startDownload() }
                    }
                }
            }
        }
        .task { await runProbe() }
    }

    // MARK: - Probe

    private func runProbe() async {
        guard existingRecord == nil else { return }
        guard let token = appModel.serverToken, let server = appModel.serverBaseURL else {
            probeState = .optimize(presets: defaultPresets, probeFailed: true)
            return
        }
        let result = await downloadManager.directPlayProbe(
            for: item, server: server, token: token,
            mediaIndex: mediaIndex, partIndex: partIndex)
        if result.direct {
            let media = item.media?[safe: mediaIndex]
            probeState = .direct(sizeBytes: result.part?.size,
                                 resolution: DownloadManager.resolutionLabel(for: media))
        } else {
            // Try the server's real presets; fall back to the built-in names if unavailable.
            let presets = await downloadManager.optimizePresetNames(server: server, token: token)
            probeState = .optimize(presets: presets.isEmpty ? defaultPresets : presets,
                                   probeFailed: false)
        }
    }

    private var defaultPresets: [String] {
        ["Optimized for TV", "Optimized for Mobile", "Original Quality"]
    }

    // MARK: - Sections

    @ViewBuilder
    private func directSection(sizeBytes: Int?, resolution: String?) -> some View {
        SwiftUI.Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download original")
                    Text(directDetail(sizeBytes: sizeBytes, resolution: resolution))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.seal") }
        } header: {
            Text("Compatible")
        } footer: {
            Text("This file plays as-is on your headset, so it downloads at full original "
                 + "quality without server transcoding.")
        }
    }

    private func directDetail(sizeBytes: Int?, resolution: String?) -> String {
        var parts: [String] = []
        if let sizeBytes, sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
        }
        if let resolution { parts.append(resolution) }
        return parts.isEmpty ? "Original file" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func optimizeSection(presets: [String], probeFailed: Bool) -> some View {
        SwiftUI.Section {
            ForEach(presets, id: \.self) { preset in
                Button {
                    selectedPreset = preset
                } label: {
                    HStack {
                        Text(preset).foregroundStyle(.primary)
                        Spacer()
                        if preset == selectedPreset {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Optimize on server")
        } footer: {
            Text(probeFailed
                 ? "Couldn't check compatibility, so your server will render a compatible "
                   + "version. Pick a preset."
                 : "This file needs converting, so your server renders a compatible version. "
                   + "Pick a preset.")
        }
        .onAppear {
            if !presets.contains(selectedPreset), let first = presets.first {
                selectedPreset = first
            }
        }
    }

    private var infoSection: some View {
        SwiftUI.Section {
            Label {
                Text("Transfers continue in the background and pause while the headset "
                     + "is off, resuming when it's worn again.")
                    .font(.footnote).foregroundStyle(.secondary)
            } icon: { Image(systemName: "wifi") }
        }
    }

    // MARK: - Already-downloaded state

    @ViewBuilder
    private func existingSection(_ record: DownloadRecord) -> some View {
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        SwiftUI.Section {
            if isComplete {
                Label("Downloaded for offline viewing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            } else if isFailed {
                Label("Download failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Button {
                    downloadManager.retry(ratingKey: item.ratingKey)
                    dismiss()
                } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            } else {
                Label("Downloading…", systemImage: "arrow.down.circle")
                ProgressView(value: record.progress)
                Text("\(Int(record.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                downloadManager.delete(ratingKey: item.ratingKey)
                dismiss()
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    // MARK: - Action

    private func startDownload() {
        let choice: DownloadManager.DownloadChoice
        switch probeState {
        case .direct: choice = .original
        case .optimize: choice = .optimize(targetName: selectedPreset)
        case .checking: return
        }
        Task { await downloadManager.download(item, choice: choice,
                                              mediaIndex: mediaIndex, partIndex: partIndex) }
        dismiss()
    }
}
```

- [ ] **Step 6: Add `optimizePresetNames` to `DownloadManager`**

The sheet calls `downloadManager.optimizePresetNames(server:token:)`. Add it near
`directPlayProbe`:

```swift
    /// The server's real optimize preset names (`/media/processing/targets`), for the sheet.
    /// Returns [] on any failure so the sheet falls back to the built-in preset names.
    /// SERVER-SPECIFIC — confirmed by Phase 0.
    public func optimizePresetNames(server: URL, token: String) async -> [String] {
        guard let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token,
                                                          identity: appModel.identity),
            as: MediaProcessingTargets.self)
        else { return [] }
        return targets.targets.map(\.name).filter { !$0.isEmpty }
    }
```

Also make the `[safe:]` Array extension used by the sheet `internal` (drop `private`) so the
sheet file can use it, OR add a separate copy. Simplest: change the extension added in Task 5
from `private extension Array` to `extension Array` (still file-local to the module is not
possible across files unless non-private). Use:

```swift
extension Array {
    /// Bounds-checked subscript: `self[safe: i]` is nil when `i` is out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

(If another `[safe:]` already exists in the app target, delete this one to avoid a duplicate —
search first: `grep -rn "subscript(safe" PlexAVPApp`.)

- [ ] **Step 7: Simplify `OfflineLibraryView` progress to real Content-Length; keep EMA + monospaced**

In `OfflineLibraryView.swift`:

Replace `displayProgress(for:)` with the server-reported value only:

```swift
    /// Progress fraction for the bar. Both download paths now serve a STATIC file with a real
    /// Content-Length, so the server-reported `record.progress` is authoritative — no estimate
    /// needed (the bitrate-cap estimation was retired with the progressive path). nil → the
    /// server hasn't reported yet (show an indeterminate bar).
    private func displayProgress(for record: DownloadRecord) -> Double? {
        record.progress > 0 ? record.progress : nil
    }
```

Replace `quality(for:)` (which read `metadata.quality`) with a resolution-label reader:

```swift
    /// The downloaded file's resolution label, if captured (offline-download redesign).
    private func resolutionLabel(for record: DownloadRecord) -> String? {
        record.metadata?.resolutionLabel
    }
```

In `progressCaption(for:progress:)`, remove the ETA branch that used
`estimatedTranscodeBytes`, and use the resolution label. Replace the method with:

```swift
    /// Caption under the in-progress bar, e.g. "23% • 106.5 MB • 12 MB/s • 1080p".
    /// Each piece is included only when known. Speed comes from the smoothed EMA in
    /// `DownloadManager.refreshRecords` (kept — orthogonal jitter fix).
    private func progressCaption(for record: DownloadRecord, progress: Double?) -> String {
        let isActive = manager.activeJobs.contains(record.ratingKey)
        if record.bytes == 0 { return isActive ? "Preparing on server…" : "Queued…" }

        var pieces: [String] = []
        if let progress { pieces.append("\(Int(progress * 100))%") }
        pieces.append(byteString(record.bytes))
        if let speed = manager.downloadSpeed[record.ratingKey], speed > 0 {
            pieces.append("\(byteString(Int(speed)))/s")
        }
        if let r = resolutionLabel(for: record) { pieces.append(r) }
        return pieces.joined(separator: " • ")
    }
```

Replace `completeCaption(for:)` to use the resolution label:

```swift
    /// Caption for a completed row: file size + resolution, e.g. "1.2 GB • 1080p".
    private func completeCaption(for record: DownloadRecord) -> String {
        var parts = [byteString(record.bytes)]
        if let r = resolutionLabel(for: record) { parts.append(r) }
        return parts.joined(separator: " • ")
    }
```

Delete the now-unused `etaString(_:)` helper (no estimate → no ETA), AND verify the comment
block above the in-progress branch (~lines 86–89) no longer claims a Content-Length is absent;
replace that comment with:

```swift
                    // Both download paths serve a static file with a real Content-Length, so
                    // `record.progress` drives the bar directly. See `displayProgress(for:)`.
```

> KEEP: any `.monospacedDigit()` modifier already on these `Text` captions (wave1 jitter fix).
> If present in the base, leave it; this redesign must not remove it.

- [ ] **Step 8: Confirm DetailView still compiles against the sheet's unchanged init**

The sheet's public surface (`DownloadOptionsSheet(item:mediaIndex:partIndex:)`) is unchanged,
so `DetailView`'s call site needs no edit. Verify no caller still references the removed
`optimizeAndDownload(_:quality:)` or `DownloadQuality`:

Run: `grep -rn "optimizeAndDownload\|DownloadQuality\|estimatedTranscodeBytes\|\.quality\b" PlexAVPApp | grep -i download`
Expected: no remaining references to the removed symbols (matches only the new code/comments).

- [ ] **Step 9: Commit**

```bash
git add PlexAVPApp/UI/DownloadOptionsSheet.swift \
        PlexAVPApp/Downloads/OfflineLibraryView.swift \
        PlexAVPApp/Downloads/DownloadManager.swift
git commit -m "Probe-first download sheet + simplify offline progress to real Content-Length"
```

---

## Task 8: Verify — PMSKit tests + single app compile

**Files:** none (verification only).

- [ ] **Step 1: PMSKit full suite**

Run: `cd PMSKit && swift test`
Expected: all tests pass (new `playsWholeFileDirectly`, optimize playlist builders, decoders;
existing suites green; the live probes are no-ops).

- [ ] **Step 2: App compile (delete the .app product first to defeat the LINK-SKIP trap)**

Run:
```bash
rm -rf $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app
xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
  -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
```
Expected: `** BUILD SUCCEEDED **`. (Do NOT install/launch on the simulator — wave1 live tests
are running. SourceKit "No such module" noise is irrelevant; xcodebuild is the truth.)

- [ ] **Step 3: Fix any compile errors surfaced**

Common ones to expect from the refactor: a lingering reference to `DownloadQuality`,
`metadata.quality`, or `optimizeAndDownload(_:quality:)`; a duplicate `[safe:]` subscript; a
mismatched `OfflineMetadata` init label (`quality:` vs `resolutionLabel:`). Fix in place and
re-run Step 2.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "Fix compile after download path rewrite"
```

---

## Task 9: Update TESTING-CHECKLIST.md + final self-review

**Files:**
- Modify: `TESTING-CHECKLIST.md`

- [ ] **Step 1: Add the manual download test items**

Append a section to `TESTING-CHECKLIST.md` describing the two paths to verify live:
- Open the download sheet on a known-compatible title → it shows "Download original — <size> ·
  <res>"; downloading produces a playable offline file with a real progress %.
- Open it on a known-incompatible title → it shows the server's optimize presets; choosing one
  triggers the optimize job (Phase 0 must have confirmed the contract first).
- Probe-failure fallback: with the server briefly unreachable, the sheet still offers presets.

- [ ] **Step 2: Self-review against the spec**

Re-read `docs/superpowers/specs/2026-06-14-media-optimizer-download-redesign-design.md` and
confirm every section maps to a task: decision rule + no-cap nuance (Tasks 2, 5);
`playsWholeFileDirectly` (Task 2); direct path (Task 5); optimizer rewrite (Tasks 3, 6); sheet
behavior + probe-failure fallback (Task 7); retirements (Task 7); Phase 0 (Task 1); kept jitter
fixes (Task 7 Step 7). Fix any gap.

- [ ] **Step 3: Commit**

```bash
git add TESTING-CHECKLIST.md
git commit -m "Document offline-download dual-path manual test plan"
```

---

## Phase 0 — how the USER runs the live discovery (after this plan lands)

1. `cp scripts/plex-live.env.example scripts/plex-live.env` (gitignored), fill in
   `PLEX_LIVE_SERVER` (prefer the `*.plex.direct` https host), `PLEX_LIVE_TOKEN`,
   `PLEX_LIVE_METADATA_KEY` (a title whose download you want to optimize). Optionally
   `PLEX_LIVE_TITLE`.
2. `./scripts/live-optimize-probe.sh`
3. Read the `>>> LIVE` lines for: the real `backgroundProcessing.key` (`playlists.type42`),
   the real target ids+names (`mediaProcessingTargets`), the accepted POST status/body
   (`optimize.post`), the rendered Part on `metadata.after`, and the static-part
   `Content-Length` (`part.download.head`).
4. If the discovered contract differs from the best-known shape in `OptimizeRequest`
   (different playlist `key` path, different targets endpoint/field names, different accepted
   POST grammar/targetTagID), update `OptimizeRequest.createOnPlaylist` /
   `mediaProcessingTargetsRequest` / the decoders and their tests to the real shape, then
   re-run `cd PMSKit && swift test`.
5. The in-app optimizer path logs at os.log `.error` so it persists; read it with
   `log show --predicate 'subsystem == "com.jlipworth.VisionPlay" AND category == "Downloads"'`.

---

## Self-Review (completed by plan author)

- **Spec coverage:** decision rule (T2 property, T5 probe), no-cap 200_000 nuance (T5
  `directPlayProbe`), `playsWholeFileDirectly` not weakening `savesVideoEncode` (T2 regression
  guards), direct path reuse of `OptimizeRequest.downloadURL` (T5), optimizer real contract
  (T3 builders, T6 sequencing), sheet probe-first + failure fallback (T7), retirements (T7),
  kept EMA/monospaced/400-logging (T7 S7 + preserved in manager), Phase 0 written-not-run (T1).
- **Type consistency:** `DownloadChoice` (T5) used by sheet (T7) + retry (T6);
  `download(_:choice:mediaIndex:partIndex:)` is the single entry; `resolutionLabel` renamed in
  T4 and consumed in T5/T7; `OptimizeRequest.MediaSettings` defined in T3 used in T6;
  `BackgroundProcessingPlaylist`/`MediaProcessingTargets` defined T3 used T6/T7; `[safe:]`
  subscript made non-private in T7 (dedup check included).
- **Placeholders:** none — every code step is complete. Server-specific bits are explicitly
  flagged `// TODO(live, Phase 0)`, which is a real, intentional gate, not a placeholder.
