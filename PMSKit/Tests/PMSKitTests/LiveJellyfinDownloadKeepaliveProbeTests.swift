import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

/// Secret-gated A/B probe: does a Jellyfin forward-only transcode download survive a long client
/// stall with (a) no keepalive and (b) Ping-only keepalive?
///
/// This decides whether the download keepalive can drop `Playing`/`Progress` reports, which mutate
/// the user's resume position and watch state. The probe never sends `Playing`, `Progress` or
/// `Stopped`; it reads the item's UserData before and after to prove it left watch state untouched.
/// Each arm builds the same PlaybackInfo + `/Videos/{id}/stream.mp4` request the app's transcode
/// download lane builds, reads until warm, suspends the task for `JELLYFIN_KEEPALIVE_STALL_SECONDS`
/// (TCP back-pressure, like a suspended app), resumes, and classifies whether the encoder survived.
/// Every arm tears its encoder down with `DELETE /Videos/ActiveEncodings`.
///
/// Auth: `JELLYFIN_ACCESS_TOKEN` + `JELLYFIN_USER_ID` when present, otherwise Quick Connect — the
/// probe prints a one-time code for the user to approve and keeps the token in memory only.
struct LiveJellyfinDownloadKeepaliveProbeTests {
    private struct Config {
        let server: URL
        let token: String?
        let userID: String?
        let itemID: String?
        let stallSeconds: Int
        let presetName: String

        init?(_ env: [String: String] = ProcessInfo.processInfo.environment) {
            guard env["JELLYFIN_KEEPALIVE_AB"] == "1",
                  let serverString = env["JELLYFIN_SERVER_URL"],
                  let server = try? JellyfinServerURL.normalized(serverString)
            else { return nil }
            self.server = server
            self.token = env["JELLYFIN_ACCESS_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
            self.userID = env["JELLYFIN_USER_ID"].flatMap { $0.isEmpty ? nil : $0 }
            self.itemID = env["JELLYFIN_LIVE_ITEM_ID"].flatMap { $0.isEmpty ? nil : $0 }
            self.stallSeconds = env["JELLYFIN_KEEPALIVE_STALL_SECONDS"].flatMap(Int.init) ?? 300
            self.presetName = env["JELLYFIN_KEEPALIVE_PRESET"] ?? "720p 2 Mbps"
        }
    }

    private enum Arm: String, CaseIterable {
        case noKeepalive = "no_keepalive"
        case pingOnly = "ping_only"
    }

    private enum ProbeFailure: Error {
        case badHTTP(String, Int)
        case quickConnectDisabled
        case quickConnectTimedOut
        case missingField(String)
    }

    private static func log(_ message: String) {
        print(">>> JF-KA \(message)")
    }

    private static func identity(_ suffix: String) -> JellyfinClientIdentity {
        JellyfinClientIdentity(client: "Labstream", device: "Labstream Keepalive Probe",
                               deviceId: "labstream-keepalive-probe-\(suffix)", version: "0.1.0")
    }

    private static func send(_ request: URLRequest, label: String) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw ProbeFailure.badHTTP(label, status) }
        return (data, status)
    }

    @Test func pingOnlyKeepaliveKeepsForwardOnlyTranscodeAlive() async throws {
        guard let config = Config() else { return }
        let authIdentity = Self.identity("auth")
        let (token, userID) = try await Self.authenticate(config: config, identity: authIdentity)
        let itemID = try await Self.resolveItem(config: config, token: token, userID: userID,
                                                identity: authIdentity)
        let before = try await Self.userData(config: config, token: token, userID: userID,
                                             itemID: itemID, identity: authIdentity)
        Self.log("item=\(String(itemID.prefix(6)))… stall_s=\(config.stallSeconds) preset=\(config.presetName)")

        var verdicts: [Arm: String] = [:]
        for arm in Arm.allCases {
            verdicts[arm] = try await Self.runArm(arm, config: config, token: token,
                                                  userID: userID, itemID: itemID)
        }

        let after = try await Self.userData(config: config, token: token, userID: userID,
                                            itemID: itemID, identity: authIdentity)
        Self.log("userdata_unchanged=\(before == after)")
        for arm in Arm.allCases { Self.log("VERDICT arm=\(arm.rawValue) result=\(verdicts[arm] ?? "missing")") }
        #expect(before == after, "probe must not mutate watch state")
    }

    // MARK: - Arms

    private static func runArm(_ arm: Arm, config: Config, token: String, userID: String,
                               itemID: String) async throws -> String {
        let identity = Self.identity(arm.rawValue)
        let profile = DownloadPresetPolicy.jellyfinTranscodeProfile(named: config.presetName)
        let infoRequest = try JellyfinPlayback.downloadPlaybackInfoRequest(
            server: config.server, token: token, identity: identity, itemId: itemID, userId: userID,
            maxStaticBitrate: max(profile.videoBitrateBps, 200_000_000))
        let (infoData, _) = try await send(infoRequest, label: "playback_info")
        let decision = try JellyfinPlayback.downloadDecision(
            response: try JellyfinPlaybackInfoResponse.decode(from: infoData),
            preferredMediaSourceId: nil)
        let request = try JellyfinLibrary.transcodedDownloadRequest(
            server: config.server, token: token, identity: identity, itemId: itemID,
            mediaSourceId: decision.mediaSourceId, playSessionId: decision.playSessionId,
            maxVideoBitrate: profile.videoBitrateBps, maxWidth: profile.maxWidth,
            maxHeight: profile.maxHeight)

        let reader = StreamReader()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = TimeInterval(config.stallSeconds + 600)
        sessionConfig.timeoutIntervalForResource = TimeInterval(config.stallSeconds + 3_600)
        let session = URLSession(configuration: sessionConfig, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)

        let server = config.server
        let playSessionId = decision.playSessionId
        let pinger: Task<[Int], Never>? = arm == .pingOnly ? Task {
            var statuses: [Int] = []
            while !Task.isCancelled {
                if let ping = try? JellyfinPlayback.pingRequest(
                    server: server, token: token, identity: identity, playSessionId: playSessionId),
                   let (_, response) = try? await URLSession.shared.data(for: ping) {
                    statuses.append((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                try? await Task.sleep(for: .seconds(JellyfinDownloadKeepalivePolicy.intervalSeconds))
            }
            return statuses
        } : nil

        // Throwing exits (cancelled sleeps) must still stop the pinger, the transfer and the encoder.
        var cleanedUp = false
        func cleanUp() async -> [Int] {
            guard !cleanedUp else { return [] }
            cleanedUp = true
            pinger?.cancel()
            let statuses = await pinger?.value ?? []
            task.cancel()
            await teardown(config: config, token: token, identity: identity, playSessionId: playSessionId)
            return statuses
        }
        do {
        task.resume()
        let warmTarget = 16 * 1_048_576
        let warmDeadline = Date().addingTimeInterval(180)
        while reader.bytes < warmTarget, reader.completion == nil, Date() < warmDeadline {
            try await Task.sleep(for: .seconds(1))
        }
        let warmBytes = reader.bytes
        let status = reader.statusCode ?? -1
        log("arm=\(arm.rawValue) http=\(status) warm_bytes=\(warmBytes)")
        guard reader.completion == nil, warmBytes > 0 else {
            let label = reader.completionLabel
            _ = await cleanUp()
            return "not_started(http=\(status), completion=\(label))"
        }

        task.suspend()
        try await Task.sleep(for: .seconds(config.stallSeconds))
        let bytesAtResume = reader.bytes
        task.resume()

        let observeDeadline = Date().addingTimeInterval(120)
        while reader.completion == nil, Date() < observeDeadline,
              reader.bytes - bytesAtResume < 8 * 1_048_576 {
            try await Task.sleep(for: .seconds(1))
        }
        // Classify from a snapshot taken before our own cancel/teardown, which would otherwise
        // surface as a `cancelled` completion and be misread as the server killing the transcode.
        let resumedBytes = reader.bytes - bytesAtResume
        let serverEnded = reader.completion != nil
        let completionBeforeCancel = reader.completionLabel
        let pingStatuses = await cleanUp()
        try await Task.sleep(for: .seconds(10))

        let pingSummary = arm == .pingOnly
            ? " pings=\(pingStatuses.count) ping_non2xx=\(pingStatuses.filter { !(200..<300).contains($0) }.count)"
            : ""
        log("arm=\(arm.rawValue) resumed_bytes=\(resumedBytes) completion_before_cancel=\(completionBeforeCancel)\(pingSummary)")
        if resumedBytes >= 8 * 1_048_576 { return "survived" }
        if serverEnded { return "killed(\(completionBeforeCancel), resumed_bytes=\(resumedBytes))" }
        return "stalled(resumed_bytes=\(resumedBytes))"
        } catch {
            _ = await cleanUp()
            throw error
        }
    }

    private static func teardown(config: Config, token: String, identity: JellyfinClientIdentity,
                                 playSessionId: String) async {
        guard let request = try? JellyfinLibrary.activeEncodingStopRequest(
            server: config.server, token: token, identity: identity,
            deviceId: identity.deviceId, playSessionId: playSessionId) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Auth, item, user data

    private static func authenticate(config: Config,
                                     identity: JellyfinClientIdentity) async throws -> (String, String) {
        if let token = config.token, let userID = config.userID { return (token, userID) }
        let (enabledData, _) = try await send(
            JellyfinAuth.quickConnectEnabledRequest(server: config.server, identity: identity),
            label: "quick_connect_enabled")
        guard String(decoding: enabledData, as: UTF8.self).contains("true") else {
            throw ProbeFailure.quickConnectDisabled
        }
        let (initData, _) = try await send(
            JellyfinAuth.initiateQuickConnectRequest(server: config.server, identity: identity),
            label: "quick_connect_initiate")
        let initiated = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: initData)
        guard let secret = initiated.secret, let code = initiated.code else {
            throw ProbeFailure.missingField("quick_connect_secret")
        }
        log("QUICKCONNECT_CODE \(code)")
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let (stateData, _) = try await send(
                try JellyfinAuth.quickConnectStateRequest(server: config.server, secret: secret, identity: identity),
                label: "quick_connect_state")
            if try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: stateData).authenticated {
                let (authData, _) = try await send(
                    try JellyfinAuth.authenticateWithQuickConnectRequest(server: config.server, secret: secret, identity: identity),
                    label: "quick_connect_auth")
                let result = try JSONDecoder().decode(MediaBrowserAuthenticationResult.self, from: authData)
                guard let token = result.accessToken, let userID = result.user?.id else {
                    throw ProbeFailure.missingField("access_token")
                }
                log("QUICKCONNECT_APPROVED")
                return (token, userID)
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw ProbeFailure.quickConnectTimedOut
    }

    private static func resolveItem(config: Config, token: String, userID: String,
                                    identity: JellyfinClientIdentity) async throws -> String {
        if let itemID = config.itemID { return itemID }
        let base = try JellyfinPlayback.jellyfinURL(server: config.server, path: "/Users/\(userID)/Items")
        var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
        components.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
            URLQueryItem(name: "SortBy", value: "Runtime"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "1"),
        ]
        let request = JellyfinLibrary.authenticatedRequest(url: try #require(components.url),
                                                           token: token, identity: identity)
        let (data, _) = try await send(request, label: "longest_movie")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (object?["Items"] as? [[String: Any]])?.first
        guard let id = first?["Id"] as? String else { throw ProbeFailure.missingField("item") }
        if let ticks = first?["RunTimeTicks"] as? Int { log("item_runtime_min=\(ticks / 600_000_000)") }
        return id
    }

    private struct UserDataSnapshot: Equatable {
        let positionTicks: Int?
        let playCount: Int?
        let played: Bool?
    }

    private static func userData(config: Config, token: String, userID: String, itemID: String,
                                 identity: JellyfinClientIdentity) async throws -> UserDataSnapshot {
        let url = try JellyfinPlayback.jellyfinURL(server: config.server, path: "/Users/\(userID)/Items/\(itemID)")
        let (data, _) = try await send(
            JellyfinLibrary.authenticatedRequest(url: url, token: token, identity: identity),
            label: "user_data")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userData = object?["UserData"] as? [String: Any]
        return UserDataSnapshot(positionTicks: userData?["PlaybackPositionTicks"] as? Int,
                                playCount: userData?["PlayCount"] as? Int,
                                played: userData?["Played"] as? Bool)
    }
}

/// Counts body bytes and records completion; the probe suspends/resumes the task to stall it.
private final class StreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0
    private var _status: Int?
    private var _completion: String?

    var bytes: Int { lock.withLock { _bytes } }
    var statusCode: Int? { lock.withLock { _status } }
    var completion: String? { lock.withLock { _completion } }
    var completionLabel: String { completion ?? "none" }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { _status = (response as? HTTPURLResponse)?.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { _bytes += data.count }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let label: String
        if let error = error as NSError? {
            label = error.code == NSURLErrorCancelled ? "cancelled" : "error_\(error.domain)_\(error.code)"
        } else {
            label = "eof"
        }
        lock.withLock { if _completion == nil { _completion = label } }
    }
}
