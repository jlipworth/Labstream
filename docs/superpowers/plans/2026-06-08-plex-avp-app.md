# plex-avp-app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A personal-use native visionOS Plex client that does reliable server-side transcoding, theater-mode playback, and capped-bitrate offline downloads in one app.

**Architecture:** Single visionOS SwiftUI app target (skeleton already built in Phase 0, commit `1cd41e6`). Source files live under `PlexAVPApp/` in folders that map to the six modules from the design spec; a `PBXFileSystemSynchronizedRootGroup` auto-includes any `.swift` added to those folders, so no task edits `project.pbxproj`. Networking is a hand-rolled `URLSession` REST client (no third-party Plex SDK). The pure-logic core (header/URL/param builders, response parsing) is unit-tested and runs without Xcode via `swift test` on a sibling SwiftPM package; UI/AVKit/RealityKit integration is device/simulator-verified.

**Tech Stack:** Swift 6, SwiftUI, AVKit (`AVPlayerViewController`), RealityKit (cinema environment), `URLSession` (incl. background config), Keychain Services, Swift Testing (`import Testing`). visionOS 26 deployment target.

**Reference sources (port, don't copy):** `python-plexapi` (BSD-3) for `getStreamURL()` and `Video.optimize()` param shapes; research docs `research/01`,`07`,`09`,`11`,`13` for endpoint detail. Official PMS API: developer.plex.tv/pms/.

---

## Testing strategy (read first)

The pure-logic core is split into a **local SwiftPM package** `PMSKit/` so its tests run with plain `swift test` — **no Xcode, no simulator runtime required**. The app target depends on `PMSKit` as a local package. This is what lets the workflow compile-gate and test-gate every logic task immediately.

- **`PMSKit/Sources/PMSKit/`** — pure logic: models, header builder, URL/param builders, response decoders, the transcode-decision logic. No UIKit/AVKit/SwiftUI imports.
- **`PMSKit/Tests/PMSKitTests/`** — Swift Testing unit tests. Run: `cd PMSKit && swift test`.
- **App target `PlexAVPApp/`** — SwiftUI views, AVKit player, RealityKit environment, Keychain, live `URLSession` wiring. Imports `PMSKit`. Compile-gate: `xcodebuild -scheme PlexAVPApp -destination 'generic/platform=visionOS Simulator' build CODE_SIGNING_ALLOWED=NO` (needs the platform/runtime download finished).
- **Manual/device** — auth round-trip, a forced 8 Mbps transcode play, resume, optimize+download+offline-play, theater docking. These are checklists at the end, run by the human on the headset.

**Gate per task:** logic tasks must end green on `swift test`; app-target tasks must end green on the `xcodebuild` build. Never mark a task done on a red gate.

---

## Task 0: Local PMSKit package + wire into app

**Files:**
- Create: `PMSKit/Package.swift`
- Create: `PMSKit/Sources/PMSKit/PMSKit.swift`
- Create: `PMSKit/Tests/PMSKitTests/SanityTests.swift`
- Modify: `PlexAVPApp.xcodeproj/project.pbxproj` (add local package dependency — the ONE allowed pbxproj edit)

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMSKit",
    platforms: [.visionOS(.v26), .macOS(.v15)],
    products: [.library(name: "PMSKit", targets: ["PMSKit"])],
    targets: [
        .target(name: "PMSKit"),
        .testTarget(name: "PMSKitTests", dependencies: ["PMSKit"]),
    ]
)
```

> `.macOS(.v15)` is included so `swift test` runs on the Mac host without the visionOS runtime. Keep PMSKit free of platform-specific imports.

- [ ] **Step 2: Placeholder source + sanity test**

`PMSKit.swift`:
```swift
public enum PMSKit {
    public static let version = "0.1.0"
}
```

`SanityTests.swift`:
```swift
import Testing
@testable import PMSKit

@Test func versionExists() {
    #expect(PMSKit.version == "0.1.0")
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cd PMSKit && swift test`
Expected: PASS, 1 test.

- [ ] **Step 4: Add PMSKit as a local package dependency of the app target**

In Xcode this is "Add Local Package". Headless, add to `project.pbxproj`: an `XCLocalSwiftPackageReference "PMSKit"` in the project's `packageReferences`, and a `XCSwiftPackageProductDependency` (productName `PMSKit`) in the target's `packageProductDependencies` + a `PBXBuildFile` referencing it in the Frameworks phase. (This is the only sanctioned pbxproj edit; do it carefully and re-verify the project parses.)

- [ ] **Step 5: Verify app still builds**

Run: `xcodebuild -list -project PlexAVPApp.xcodeproj` (must still parse), then once the platform is installed: `xcodebuild -scheme PlexAVPApp -destination 'generic/platform=visionOS Simulator' build CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Task 0: PMSKit local package wired into app target"
```

---

## Task 1: Identity & client headers (PMSKit)

The stable client identity and the `X-Plex-*` header set that every request carries. Pure logic → fully tested.

**Files:**
- Create: `PMSKit/Sources/PMSKit/ClientIdentity.swift`
- Create: `PMSKit/Sources/PMSKit/PlexHeaders.swift`
- Create: `PMSKit/Sources/PMSKit/PlexRequest.swift` (shared request descriptor used by all builders — defined here so Tasks 3–7 can fan out without an ordering dependency)
- Create: `PMSKit/Tests/PMSKitTests/PlexHeadersTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import PMSKit

@Test func headersIncludeRequiredPlexFields() {
    let id = ClientIdentity(clientIdentifier: "ABC-123",
                            product: "plex-avp-app",
                            version: "0.1.0",
                            deviceName: "Vision Pro")
    let h = PlexHeaders.standard(identity: id, token: "tok")
    #expect(h["X-Plex-Client-Identifier"] == "ABC-123")
    #expect(h["X-Plex-Product"] == "plex-avp-app")
    #expect(h["X-Plex-Version"] == "0.1.0")
    #expect(h["X-Plex-Platform"] == "visionOS")
    #expect(h["X-Plex-Device-Name"] == "Vision Pro")
    #expect(h["X-Plex-Token"] == "tok")
    #expect(h["Accept"] == "application/json")
}

@Test func headersOmitTokenWhenNil() {
    let id = ClientIdentity(clientIdentifier: "ABC-123", product: "p", version: "1", deviceName: "d")
    let h = PlexHeaders.standard(identity: id, token: nil)
    #expect(h["X-Plex-Token"] == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd PMSKit && swift test --filter PlexHeadersTests`
Expected: FAIL (types not defined).

- [ ] **Step 3: Implement**

`ClientIdentity.swift`:
```swift
public struct ClientIdentity: Sendable, Equatable {
    public let clientIdentifier: String
    public let product: String
    public let version: String
    public let deviceName: String
    public init(clientIdentifier: String, product: String, version: String, deviceName: String) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.deviceName = deviceName
    }
}
```

`PlexHeaders.swift`:
```swift
public enum PlexHeaders {
    /// Standard header set. Note: for streaming URLs the token is passed as a
    /// query param instead (see TranscodeRequest); these headers are for API calls.
    public static func standard(identity: ClientIdentity, token: String?) -> [String: String] {
        var h: [String: String] = [
            "X-Plex-Client-Identifier": identity.clientIdentifier,
            "X-Plex-Product": identity.product,
            "X-Plex-Version": identity.version,
            "X-Plex-Platform": "visionOS",
            "X-Plex-Device": "Apple Vision Pro",
            "X-Plex-Device-Name": identity.deviceName,
            "Accept": "application/json",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }
}
```

- [ ] **Step 4: Define the shared `PlexRequest` descriptor** in `PlexRequest.swift` (used by every request builder downstream):

```swift
import Foundation

public struct PlexRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public var queryItems: [URLQueryItem] = []
    public var headers: [String: String] = [:]
    public var body: Data? = nil
    public init(url: URL, method: String, queryItems: [URLQueryItem] = [],
                headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.queryItems = queryItems
        self.headers = headers; self.body = body
    }
}
```

- [ ] **Step 5: Run to verify pass** — `cd PMSKit && swift test --filter PlexHeadersTests` → PASS.
- [ ] **Step 6: Commit** — `git commit -am "Task 1: client identity + Plex headers + PlexRequest"`

> The actual UUID generation + persistence (Keychain) lives in the app target (Task 8); `ClientIdentity` here is the pure value type the app injects.

---

## Task 2: Core models (PMSKit)

Decodable models for the JSON the app consumes. Keep them minimal — only fields we use.

**Files:**
- Create: `PMSKit/Sources/PMSKit/Models/Resources.swift` (server discovery)
- Create: `PMSKit/Sources/PMSKit/Models/Library.swift` (sections, hubs, metadata, media/part)
- Create: `PMSKit/Sources/PMSKit/Models/TranscodeDecision.swift`
- Create: `PMSKit/Tests/PMSKitTests/DecodingTests.swift`

- [ ] **Step 1: Write failing decode tests** using captured JSON fixtures.

```swift
import Testing
import Foundation
@testable import PMSKit

@Test func decodesMediaContainerSections() throws {
    let json = """
    {"MediaContainer":{"size":2,"Directory":[
      {"key":"1","title":"Movies","type":"movie"},
      {"key":"2","title":"TV Shows","type":"show"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(SectionsResponse.self, from: json)
    #expect(c.mediaContainer.directory.count == 2)
    #expect(c.mediaContainer.directory[0].title == "Movies")
    #expect(c.mediaContainer.directory[0].type == "movie")
}

@Test func decodesMetadataWithMediaPart() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie","duration":9540000,"viewOffset":120000,
       "Media":[{"id":1,"Part":[{"id":9,"key":"/library/parts/9/file.mkv","duration":9540000}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let item = c.mediaContainer.metadata[0]
    #expect(item.ratingKey == "101")
    #expect(item.viewOffset == 120000)
    #expect(item.media?[0].part[0].key == "/library/parts/9/file.mkv")
}
```

- [ ] **Step 2: Run to verify fail.** `cd PMSKit && swift test --filter DecodingTests` → FAIL.
- [ ] **Step 3: Implement the models.** Use `CodingKeys` to map Plex's capitalized container keys (`MediaContainer`, `Directory`, `Metadata`, `Media`, `Part`, `Hub`) to Swift camelCase. Make numeric fields that Plex sometimes sends as strings tolerant where needed. Mark all `Sendable`.

```swift
import Foundation

public struct SectionsResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    public struct Container: Decodable, Sendable {
        public let directory: [Section]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }
    }
}
public struct Section: Decodable, Sendable, Identifiable {
    public let key: String
    public let title: String
    public let type: String
    public var id: String { key }
}
// ... MetadataResponse / MediaItem / Media / Part / HubsResponse / Hub analogously.
// Part: id (Int), key (String), duration (Int?), file (String?), size (Int?)
// MediaItem: ratingKey, title, type, duration?, viewOffset?, year?, summary?, thumb?, art?, media: [Media]?
```

- [ ] **Step 4: Run to verify pass.** → PASS.
- [ ] **Step 5: Commit.** `git commit -am "Task 2: core Decodable models"`

> Capture real fixtures from the live server during integration (Task 13) and add them under `Tests/PMSKitTests/Fixtures/` to harden decoding against the actual payloads.

---

## Task 3: PIN-OAuth request builders (PMSKit)

The OAuth PIN flow as pure request descriptors (URL + method + headers + body), so they're testable without networking. The app target executes them (Task 9).

**Files:**
- Create: `PMSKit/Sources/PMSKit/Auth/PinAuth.swift`
- Create: `PMSKit/Tests/PMSKitTests/PinAuthTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import PMSKit

private let id = ClientIdentity(clientIdentifier: "CID", product: "plex-avp-app", version: "0.1.0", deviceName: "AVP")

@Test func createPinRequest() {
    let r = PinAuth.createPinRequest(identity: id)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/pins")
    #expect(r.method == "POST")
    #expect(r.queryItems.contains(URLQueryItem(name: "strong", value: "true")))
    #expect(r.headers["X-Plex-Client-Identifier"] == "CID")
}

@Test func authAppURLEmbedsCodeAndClient() {
    let url = PinAuth.authAppURL(code: "WXYZ", identity: id)
    let s = url.absoluteString
    #expect(s.hasPrefix("https://app.plex.tv/auth#?"))
    #expect(s.contains("clientID=CID"))
    #expect(s.contains("code=WXYZ"))
}

@Test func pollPinRequestTargetsPinID() {
    let r = PinAuth.pollPinRequest(pinID: 42, identity: id)
    #expect(r.url.absoluteString == "https://plex.tv/api/v2/pins/42")
    #expect(r.method == "GET")
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.** Reuse the `PlexRequest` descriptor from Task 1. Implement the three functions and a `PinResponse`/`PinPollResponse` decode (`id`, `code`, `authToken?`).

```swift
public enum PinAuth {
    static let base = URL(string: "https://plex.tv/api/v2/pins")!
    public static func createPinRequest(identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base, method: "POST",
                    queryItems: [.init(name: "strong", value: "true")],
                    headers: PlexHeaders.standard(identity: identity, token: nil))
    }
    public static func authAppURL(code: String, identity: ClientIdentity) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        // Plex expects these AFTER the fragment.
        let frag = "?clientID=\(identity.clientIdentifier)&code=\(code)&context[device][product]=\(identity.product)"
        c.fragment = frag
        return c.url!
    }
    public static func pollPinRequest(pinID: Int, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base.appendingPathComponent("\(pinID)"), method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: nil))
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.** `git commit -am "Task 3: PIN-OAuth request builders"`

---

## Task 4: Server discovery + connection ranking (PMSKit)

**Files:**
- Create: `PMSKit/Sources/PMSKit/Auth/ResourceDiscovery.swift`
- Create: `PMSKit/Tests/PMSKitTests/ResourceDiscoveryTests.swift`

- [ ] **Step 1: Failing tests** — request builder targets `clients.plex.tv/api/v2/resources`, and a `bestConnection` ranker prefers local over relay.

```swift
@Test func resourcesRequestShape() {
    let r = ResourceDiscovery.resourcesRequest(token: "tok", identity: id)
    #expect(r.url.absoluteString == "https://clients.plex.tv/api/v2/resources")
    #expect(r.queryItems.contains(URLQueryItem(name: "includeHttps", value: "1")))
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func ranksLocalAboveRelay() {
    let conns = [
        PlexConnection(uri: "https://relay", local: false, relay: true),
        PlexConnection(uri: "https://192-168", local: true, relay: false),
    ]
    #expect(ResourceDiscovery.bestConnection(conns)?.uri == "https://192-168")
}
```

- [ ] **Step 2: Run → FAIL. Step 3: Implement** the request + `ResourcesResponse`/`PlexDevice`/`PlexConnection` models + `bestConnection` (sort: local desc, then non-relay desc). **Step 4: PASS. Step 5: Commit** `"Task 4: server discovery + connection ranking"`.

---

## Task 5: Transcode decision + start.m3u8 URL builder (PMSKit) — CORE

The heart of the app. Port param shapes from `python-plexapi.getStreamURL()` and `research/09`. **Do NOT replicate python-plexapi's `partIndex=mediaIndex` bug** (research/09) — `partIndex` is its own index.

**Files:**
- Create: `PMSKit/Sources/PMSKit/Transcode/DeviceProfile.swift`
- Create: `PMSKit/Sources/PMSKit/Transcode/TranscodeRequest.swift`
- Create: `PMSKit/Tests/PMSKitTests/TranscodeRequestTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import PMSKit

private let server = URL(string: "https://192.168.1.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID", product: "plex-avp-app", version: "0.1.0", deviceName: "AVP")

@Test func startURLHasRequiredTranscodeParams() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000,
                               sessionID: "SESSION-1",
                               mediaIndex: 0, partIndex: 0)
    let url = req.startM3U8URL()
    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
    #expect(url.path == "/video/:/transcode/universal/start.m3u8")
    #expect(v("protocol") == "hls")
    #expect(v("maxVideoBitrate") == "8000")
    #expect(v("directPlay") == "0")
    #expect(v("path") == "/library/metadata/101")
    #expect(v("session") == "SESSION-1")
    #expect(v("X-Plex-Token") == "tok")            // token as QUERY param
    #expect(v("partIndex") == "0")
}

@Test func decisionURLUsesDecisionPathAndHasMDE() {
    let req = TranscodeRequest(server: server, token: "tok", identity: id,
                               metadataKey: "/library/metadata/101",
                               maxVideoBitrateKbps: 8000, sessionID: "S", mediaIndex: 0, partIndex: 0)
    let url = req.decisionURL()
    #expect(url.path == "/video/:/transcode/universal/decision")
    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(q.contains(URLQueryItem(name: "hasMDE", value: "1")))
}

@Test func deviceProfileDeclaresHLSAndBitrateLimit() {
    let p = DeviceProfile.visionOS(maxVideoBitrateKbps: 8000)
    #expect(p.clientProfileExtra.contains("add-transcode-target"))
    #expect(p.clientProfileExtra.contains("protocol=hls"))
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.**
  - `DeviceProfile.visionOS(maxVideoBitrateKbps:)` builds the `X-Plex-Client-Profile-Extra` directive string: an `add-transcode-target` for `protocol=hls` container `mp4`/`ts`, video `h264`/`hevc`, audio `aac`/`ac3`, plus an `add-limitation` capping video bitrate. (Port the directive grammar from research/09's worked example.)
  - `TranscodeRequest` holds inputs and emits both URLs from one shared param set. Shared params: `path`, `protocol=hls`, `maxVideoBitrate`, `videoQuality=100`, `directPlay=0`, `directStream=1`, `subtitles=auto`, `audioBoost=100`, `mediaIndex`, `partIndex`, `session`, `X-Plex-Client-Profile-Name=visionOS`, the profile extra, plus standard `X-Plex-*` identity params and `X-Plex-Token`. `decisionURL()` = same params + `hasMDE=1` at the `/decision` path; `startM3U8URL()` = `/start.m3u8`.
  - Add `DecisionResponse` decode exposing `generalDecisionCode`/`generalDecisionText` (1000≈direct play, 1001≈transcode) and a `Decision` enum `.directPlay | .transcode | .unsupported(code:Int)`.

- [ ] **Step 4: Run → PASS. Step 5: Commit** `"Task 5: transcode decision + start.m3u8 builder (core)"`.

> This is the task most worth over-testing. Add cases for HEVC (research/09's fMP4 requirement), subtitle burn-in param, and a non-zero `partIndex` to prove the bug isn't reintroduced.

---

## Task 6: Playback-state request builders (PMSKit)

Timeline / scrobble / playQueues. **Encapsulate the HTTP method** — official Redoc says timeline=POST, scrobble/unscrobble=PUT; legacy clients use GET. Expose a `method` knob, default to the legacy GET that's known-working, and leave a live-test note (research/13).

**Files:**
- Create: `PMSKit/Sources/PMSKit/Playback/TimelineRequest.swift`
- Create: `PMSKit/Sources/PMSKit/Playback/PlayQueue.swift`
- Create: `PMSKit/Tests/PMSKitTests/PlaybackStateTests.swift`

- [ ] **Step 1: Failing tests**

```swift
@Test func timelineCarriesStateAndOffset() {
    let r = TimelineRequest.timeline(server: server, token: "tok", identity: id,
                                     ratingKey: "101", key: "/library/metadata/101",
                                     state: .playing, timeMs: 120000, durationMs: 9540000)
    #expect(r.url.path == "/:/timeline")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("state") == "playing")
    #expect(v("time") == "120000")
    #expect(v("ratingKey") == "101")
    #expect(v("key") == "/library/metadata/101")   // key is a PATH here
}

@Test func scrobbleUsesRatingKeyNumber() {
    let r = TimelineRequest.scrobble(server: server, token: "tok", identity: id, ratingKey: "101")
    #expect(r.url.path == "/:/scrobble")
    #expect(r.queryItems.first { $0.name == "key" }?.value == "101")  // key is a NUMBER here
    #expect(r.queryItems.first { $0.name == "identifier" }?.value == "com.plexapp.plugins.library")
}
```

- [ ] **Step 2 → FAIL. Step 3: Implement** timeline (`state` enum playing/paused/stopped/buffering; the `key`-is-path vs `key`-is-ratingKey gotcha from research/13), scrobble/unscrobble, and `PlayQueue.createRequest(...)` (`POST /playQueues`, params `type=video`, `uri=server://.../library/metadata/<rk>`, `continuous=1`). **Step 4 → PASS. Step 5: Commit** `"Task 6: timeline/scrobble/playQueue builders"`.

---

## Task 7: Optimize (Media Optimizer) request builder (PMSKit)

Capped offline download trigger. **Port exact params from `python-plexapi Video.optimize()` source** — read it first, then implement to match, because the endpoint/param names are easy to get subtly wrong. Target preset = "Optimized for TV – 8 Mbps 1080p".

**Files:**
- Create: `PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift`
- Create: `PMSKit/Tests/PMSKitTests/OptimizeTests.swift`

- [ ] **Step 1:** Read `python-plexapi`'s `Video.optimize`/`Library.optimize` to confirm the endpoint (`/library/optimize` family) and param names (`title`, `target`, `targetTagID`, `deviceProfile`, `videoQuality`/preset). Write the test to that confirmed shape:

```swift
@Test func optimizeRequestTargetsLibraryOptimize() {
    let r = OptimizeRequest.create(server: server, token: "tok", identity: id,
                                   ratingKey: "101", title: "Blade Runner",
                                   targetTagID: .tv1080p8Mbps)
    #expect(r.url.path.contains("optimize"))
    #expect(r.method == "PUT" || r.method == "POST")   // pin once confirmed from python-plexapi
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("title") == "Blade Runner")
}

@Test func downloadURLAppendsDownloadFlag() {
    let url = OptimizeRequest.downloadURL(server: server, token: "tok", partKey: "/library/parts/55/file.mp4")
    #expect(url.absoluteString.contains("download=1"))
    #expect(url.absoluteString.contains("X-Plex-Token=tok"))
}
```

- [ ] **Step 2 → FAIL. Step 3: Implement** to the verified shape; add a status-poll request builder (the optimized version appears as a new `Media`/`Part` on the item, or under `/library/optimize` items — confirm against python-plexapi) and `downloadURL` (`<partKey>?download=1&X-Plex-Token=...`). **Step 4 → PASS. Step 5: Commit** `"Task 7: Media Optimizer + download URL builders"`.

> If the live server's optimize behavior diverges from python-plexapi (version drift), record the actual shape in `research/11` and adjust the test — the test encodes our contract.

---

## Task 8: PlexClient — live URLSession executor (app target)

Now leave PMSKit's pure world. A thin async executor that runs a `PlexRequest`/builds the final `URLRequest`, plus a TLS note for self-signed Plex certs.

**Files:**
- Create: `PlexAVPApp/Networking/PlexClient.swift`
- Create: `PlexAVPApp/Networking/PlexRequest+URLRequest.swift`

- [ ] **Step 1:** Implement `PlexRequest.urlRequest()` (compose `URLComponents` from url+queryItems, set method/headers/body). **Step 2:** Implement `actor PlexClient` with `func send<T: Decodable>(_ r: PlexRequest, as: T.Type) async throws -> T` and `func send(_ r: PlexRequest) async throws -> Data`, using an injected `URLSession`. Map non-2xx to a typed `PlexError` (`.unauthorized`, `.serverUnreachable`, `.http(Int)`, `.decoding`). **Step 3:** Handle Plex's self-signed certs for direct LAN IP connections via a `URLSessionDelegate` that trusts the server cert **only for known Plex hosts** (document the risk; prefer the `*.plex.direct` hostnames from discovery which have valid certs). **Step 4:** Compile-gate `xcodebuild ... build`. **Step 5: Commit** `"Task 8: live PlexClient executor"`.

> No unit test here (it's I/O); it's exercised by the integration checklist (Task 13). Keep ALL logic in PMSKit so this file stays a thin, obvious shell.

---

## Task 9: Auth + Keychain + identity persistence (app target)

**Files:**
- Create: `PlexAVPApp/Auth/KeychainStore.swift`
- Create: `PlexAVPApp/Auth/AuthManager.swift`
- Create: `PlexAVPApp/App/AppModel.swift` (the `@Observable` app state)

- [ ] **Step 1:** `KeychainStore` — `save/read/delete` for `token` and `clientIdentifier` (generate a UUID once on first launch, persist forever). **Step 2:** `@MainActor @Observable final class AppModel` holding `identity: ClientIdentity`, `token: String?`, `selectedServer`, `connectionBaseURL`, and a `client: PlexClient`. **Step 3:** `AuthManager` driving the PIN flow: create pin → open `authAppURL` (via `openURL` / present web auth) → poll `pollPinRequest` every 1s until `authToken` → store in Keychain → set `AppModel.token` → run discovery (`ResourceDiscovery`) → pick `bestConnection`. **Step 4:** Compile-gate. **Step 5: Commit** `"Task 9: auth manager + keychain + app model"`.

> Manual device test (Task 13) confirms the round-trip. 401 anywhere → clear token, return to login.

---

## Task 10: LibraryUI — browse (app target)

**Files:**
- Create: `PlexAVPApp/UI/RootView.swift` (tab strip: Home · Libraries · Search + Settings/server)
- Create: `PlexAVPApp/UI/HomeView.swift` (hubs from `GET /hubs`)
- Create: `PlexAVPApp/UI/LibraryGridView.swift` (poster grid for a section)
- Create: `PlexAVPApp/UI/DetailView.swift` (artwork, summary, Play/Resume, Download, mark-watched)
- Create: `PlexAVPApp/UI/PosterImage.swift` (async thumb loader hitting `/photo/:/transcode`)
- Modify: `PlexAVPApp/App/ContentView.swift` (swap skeleton for `RootView` gated on auth)

- [ ] **Step 1:** `RootView` switches on `AppModel.token == nil` → `LoginView`, else the tab UI. **Step 2:** `HomeView` loads hubs; horizontal rails of posters. **Step 3:** `LibraryGridView` loads a section's items into a `LazyVGrid`. **Step 4:** `DetailView` shows metadata + actions; Play routes to Task 11, Download to Task 12. **Step 5:** `PosterImage` builds a sized `/photo/:/transcode` URL and loads via `AsyncImage`/a small cache. **Step 6:** Compile-gate + (once runtime present) launch in simulator and click through with a stub server. **Step 7: Commit** `"Task 10: browse UI (home/library/detail)"`.

> Follows the Swiftfin-style Home·Libraries·Search model from research/05. Views are thin; all URL building comes from PMSKit.

---

## Task 11: Player — AVPlayerViewController + cinema environment + timeline (app target)

**Files:**
- Create: `PlexAVPApp/Player/PlayerView.swift` (`UIViewControllerRepresentable` wrapping `AVPlayerViewController`)
- Create: `PlexAVPApp/Player/PlaybackController.swift` (owns `AVPlayer`, decision→start.m3u8, timeline heartbeat)
- Create: `PlexAVPApp/Player/CinemaEnvironment.swift` (RealityKit/system environment hookup)

- [ ] **Step 1:** `PlaybackController.start(item:)` — call `decisionURL()` via `PlexClient`; if `.transcode` or `.directPlay`, build `startM3U8URL()`, set as `AVPlayerItem`; seek to `viewOffset`. **Step 2:** `PlayerView` wraps `AVPlayerViewController`, sets `player`, enables the system **Cinema Environment** (visionOS `AVPlayerViewController` exposes the environment picker / docking; configure `experienceController`/preferred environment per research/02). **Step 3:** Add an `addPeriodicTimeObserver` → fire `TimelineRequest.timeline(state:time:)` every ~10s and on play/pause/stop; on completion send `scrobble`. **Step 4:** Compile-gate. **Step 5: Commit** `"Task 11: AVKit player + cinema environment + timeline"`.

> The local-file path (Task 12) feeds the same `AVPlayer` — one playback path for stream and offline. Theater docking is **device-verified** in Task 13; the simulator can't fully exercise environments (research/02, 06).

---

## Task 12: DownloadManager — optimize → poll → background download → offline (app target)

**Files:**
- Create: `PlexAVPApp/Downloads/DownloadManager.swift`
- Create: `PlexAVPApp/Downloads/DownloadStore.swift` (metadata index of local files)
- Create: `PlexAVPApp/Downloads/OfflineLibraryView.swift`

- [ ] **Step 1:** `DownloadManager.optimizeAndDownload(item:)` — send `OptimizeRequest.create` (8 Mbps 1080p preset) via `PlexClient`; poll status until the optimized `Part` exists. **Step 2:** Fetch it with a **background `URLSession`** (`URLSessionConfiguration.background`) from `OptimizeRequest.downloadURL`; store under Application Support; record in `DownloadStore` (ratingKey → local URL, title, size, progress). **Step 3:** `OfflineLibraryView` lists downloads with delete; tapping plays the local file through the Task 11 `AVPlayer` path. **Step 4:** Handle background-session delegate progress/completion; surface job-failed and storage-full states; communicate the "transfers pause while headset is off" reality (research/10). **Step 5:** Compile-gate. **Step 6: Commit** `"Task 12: optimize + background download + offline playback"`.

---

## Task 13: Search, Settings, and integration hardening (app target)

**Files:**
- Create: `PlexAVPApp/UI/SearchView.swift` (`GET /hubs/search?query=`)
- Create: `PlexAVPApp/UI/SettingsView.swift` (server picker, sign out, storage usage, default bitrate)
- Create: `PMSKit/Tests/PMSKitTests/Fixtures/` (real captured payloads)

- [ ] **Step 1:** `SearchView` queries `/hubs/search` and renders grouped results into the existing Detail flow. **Step 2:** `SettingsView` — switch server (re-rank connections), sign out (clear Keychain), show download storage, set the default `maxVideoBitrate`. **Step 3:** During live testing, capture real JSON from the server and add as fixtures; re-run `swift test` to harden the decoders (Task 2). **Step 4:** Compile-gate + full `swift test`. **Step 5: Commit** `"Task 13: search + settings + fixture hardening"`.

---

## Manual device verification checklist (human, on headset)

Not workflow-automatable — these are yours to run once the app installs on the AVP:

- [ ] PIN-OAuth login completes; server discovered; survives relaunch (token from Keychain).
- [ ] Browse Home hubs + a library grid; open a Detail.
- [ ] Play a large file: confirm via the server's **Dashboard** it's **Transcoding** (not Direct Play) and capped near 8 Mbps.
- [ ] Theater: player docks into a Cinema Environment; screen is large and stable.
- [ ] Resume: stop mid-film, reopen — resumes at `viewOffset`; appears in On Deck.
- [ ] Mark-watched via scrobble reflects on the server.
- [ ] Optimize+download a title; then in **Airplane Mode**, play it offline from the local file.
- [ ] Sign out clears token; relaunch returns to login.

---

## Self-review notes

- **Spec coverage:** transcoding (Tasks 5, 8, 11), theater (Task 11), downloads (Tasks 7, 12), auth (Tasks 3–4, 9), browse/search/settings (Tasks 10, 13), playback-state (Task 6, 11). All three headline features mapped. 3D SBS intentionally **out of v1** per spec §2.
- **Risk concentration:** Task 5 (transcode URL) and Task 7 (optimize) carry the most uncertainty (version-dependent params) — both are pure-function tested and pinned to `python-plexapi`/live captures so drift is caught by a red test, not a black screen.
- **Parallelizability for the workflow:** `PlexRequest` is defined in Task 1, so Tasks 3–7 are independent PMSKit files (sharing only that type + Task 1's headers) → safe to fan out after Tasks 0–2 land. Tasks 8–13 touch the app target and have real dependencies → pipeline in order.
- **No device dependency to write code:** every task except the final checklist completes against `swift test` + `xcodebuild build`; nothing needs the headset until verification.
