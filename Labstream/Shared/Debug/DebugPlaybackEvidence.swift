#if DEBUG
import Foundation
import PMSKit
import os

/// Read-only DEBUG evidence export, no listener or command transport. The fixed sandbox
/// destination cannot be chosen by a server/URL. Export requires an explicit launch flag.
enum DebugPlaybackEvidence {
    @MainActor static func exportTapSummary(_ summary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
              data.count <= 4096 else { return }
        let encoded = Array(data.base64EncodedString().utf8)
        let count = (encoded.count + 511) / 512
        for index in 0..<count {
            let part = String(decoding: encoded[index * 512..<min(encoded.count, (index + 1) * 512)], as: UTF8.self)
            Logger(subsystem: "org.labstream.Labstream", category: "PlaybackEvidence")
                .notice("evidence.tap.part index=\(index, privacy: .public) count=\(count, privacy: .public) payload=\(part, privacy: .public)")
        }
    }
    enum DeliveryTransport: String, Codable { case hlsPlaylistURL, remoteOriginalFileRoute, localFileURL, unknown }
    /// Classifies the actual attached asset or an explicitly negotiated original-file route.
    /// A codec, source extension, or generic Direct Stream decision is not transport evidence.
    static func deliveryTransport(assetURL: URL?, originalFileRoute: Bool) -> DeliveryTransport {
        guard let assetURL else { return .unknown }
        if assetURL.isFileURL { return .localFileURL }
        guard ["http", "https"].contains(assetURL.scheme?.lowercased() ?? "") else { return .unknown }
        if assetURL.pathExtension.lowercased() == "m3u8" { return .hlsPlaylistURL }
        return originalFileRoute ? .remoteOriginalFileRoute : .unknown
    }
    enum Decision: String, Codable { case copy, encode, unknown }
    enum Provenance: String, Codable { case serverDecision, enforcedRequest, unknown }
    enum Attachment: String, Codable { case attached, detached, unknown }
    enum Consent: String, Codable { case pending, notPending }
    enum Backend: String, Codable { case plex, jellyfin, emby, offline, unknown }
    enum Phase: String, Codable { case playing, waiting, paused, failed, consent, stopped }
    // Write-only snapshots. The offline validator explicitly supports older private v1 exports.
    struct Snapshot: Encodable {
        let buildNumber: Int
        let phase: Phase
        let bufferBucketSeconds: Int
        let renderedFormat: String
        let schemaVersion: Int
        let generation: Int
        let backend: Backend
        let qualityKbps: Int
        let videoDecision: Decision
        let videoProvenance: Provenance
        let audioDecision: Decision
        let consent: Consent
        let visibleAttachment: Attachment
        let positionBucketSeconds: Int
        let cleanupRequested: Bool
        let serverCleanup: String
        let deliveryTransport: DeliveryTransport
    }

    @MainActor static func exportReportIfRequested(_ report: DebugPlaybackScenario.Report) {
        guard ProcessInfo.processInfo.arguments.contains("--vp-probe-evidence"),
              report.snapshots.count <= 8 else { return }
        if let data = try? JSONEncoder().encode(report), data.count <= 32 * 1024 {
            // Unified logging truncates long dynamic strings. Keep each public fragment
            // small and reconstruct only a complete, ordered report for the exact PID.
            let encoded = Array(data.base64EncodedString().utf8)
            let size = 512
            let count = (encoded.count + size - 1) / size
            let logger = Logger(subsystem: "org.labstream.Labstream", category: "PlaybackEvidence")
            for index in 0..<count {
                let end = min(encoded.count, (index + 1) * size)
                let part = String(decoding: encoded[index * size..<end], as: UTF8.self)
                logger.notice("evidence.run.part index=\(index, privacy: .public) count=\(count, privacy: .public) payload=\(part, privacy: .public)")
            }
        }
        write(report, filename: "run.json")
    }

    @MainActor static func exportProgressIfRequested(_ evidence: PlaybackProgressEvidence) {
        guard ProcessInfo.processInfo.arguments.contains("--vp-probe-evidence") else { return }
        write(evidence, filename: "progress.json")
    }

    private static func write<T: Encodable>(_ payload: T, filename: String) {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("AgentPlaybackEvidence", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(payload)
            guard data.count <= 256 * 1024 else { return }
            let destination = directory.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            Logger(subsystem: "org.labstream.Labstream", category: "PlaybackEvidence")
                .error("evidence.export blocked=true")
        }
    }
}
#endif
