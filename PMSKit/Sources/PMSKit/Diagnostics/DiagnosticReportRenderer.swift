import Foundation

public struct DiagnosticReportContext: Sendable, Equatable {
    public var product: String
    public var appVersion: String
    public var appBuild: String
    public var buildID: String?
    public var builtAt: String?
    public var operatingSystem: String
    public var deviceName: String
    public var platform: String?
    public var bundleIdentifier: String?
    public var keychainService: String?
    public var sandboxContainerIdentifier: String?
    public var backend: String
    public var server: String?
    public var connectionScheme: String?
    public var selectedQuality: String
    public var adaptiveBitrateEnabled: Bool?
    public var backgroundDownloadSessionIdentifier: String?
    public var downloadStorageLocation: String?
    public var downloadRecordCount: Int?
    public var activeDownloadCount: Int?
    public var completeDownloadCount: Int?
    public var downloadQueuePaused: Bool?
    public var downloadReferencedBytes: Int?
    public var downloadDirectoryBytes: Int?
    public var downloadUnreferencedBytes: Int?
    public var downloadOrphanCandidateCount: Int?
    public var downloadOrphanCandidateBytes: Int?
    public var loggingEnabled: Bool

    public init(product: String,
                appVersion: String,
                appBuild: String,
                buildID: String? = nil,
                builtAt: String? = nil,
                operatingSystem: String,
                deviceName: String,
                platform: String? = nil,
                bundleIdentifier: String? = nil,
                keychainService: String? = nil,
                sandboxContainerIdentifier: String? = nil,
                backend: String,
                server: String? = nil,
                connectionScheme: String? = nil,
                selectedQuality: String,
                adaptiveBitrateEnabled: Bool? = nil,
                backgroundDownloadSessionIdentifier: String? = nil,
                downloadStorageLocation: String? = nil,
                downloadRecordCount: Int? = nil,
                activeDownloadCount: Int? = nil,
                completeDownloadCount: Int? = nil,
                downloadQueuePaused: Bool? = nil,
                downloadReferencedBytes: Int? = nil,
                downloadDirectoryBytes: Int? = nil,
                downloadUnreferencedBytes: Int? = nil,
                downloadOrphanCandidateCount: Int? = nil,
                downloadOrphanCandidateBytes: Int? = nil,
                loggingEnabled: Bool) {
        self.product = product
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.buildID = buildID
        self.builtAt = builtAt
        self.operatingSystem = operatingSystem
        self.deviceName = deviceName
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.keychainService = keychainService
        self.sandboxContainerIdentifier = sandboxContainerIdentifier
        self.backend = backend
        self.server = server
        self.connectionScheme = connectionScheme
        self.selectedQuality = selectedQuality
        self.adaptiveBitrateEnabled = adaptiveBitrateEnabled
        self.backgroundDownloadSessionIdentifier = backgroundDownloadSessionIdentifier
        self.downloadStorageLocation = downloadStorageLocation
        self.downloadRecordCount = downloadRecordCount
        self.activeDownloadCount = activeDownloadCount
        self.completeDownloadCount = completeDownloadCount
        self.downloadQueuePaused = downloadQueuePaused
        self.downloadReferencedBytes = downloadReferencedBytes
        self.downloadDirectoryBytes = downloadDirectoryBytes
        self.downloadUnreferencedBytes = downloadUnreferencedBytes
        self.downloadOrphanCandidateCount = downloadOrphanCandidateCount
        self.downloadOrphanCandidateBytes = downloadOrphanCandidateBytes
        self.loggingEnabled = loggingEnabled
    }
}

public enum DiagnosticReportRenderer {
    public static func render(context: DiagnosticReportContext,
                              events: [DiagnosticEvent],
                              metricKitSummaries: [MetricKitDiagnosticSummary] = [],
                              maxEvents: Int = 80,
                              generatedAt: Date = Date()) -> String {
        let shownEvents = Array(events.suffix(max(0, maxEvents)))
        var lines: [String] = []
        lines.append("Labstream Diagnostic Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("Sensitive values are omitted: tokens, client identifiers, hostnames/IPs, full URLs, usernames, library paths, filenames, and media titles should not appear in this report.")
        lines.append("")
        lines.append("App")
        lines.append("- Product: \(redact(context.product))")
        lines.append("- Version: \(redact(context.appVersion)) (\(redact(context.appBuild)))")
        lines.append("- Build ID: \(redact(context.buildID ?? "unknown"))")
        lines.append("- Built: \(redact(context.builtAt ?? "unknown"))")
        lines.append("- OS: \(redact(context.operatingSystem))")
        lines.append("- Device: \(redact(context.deviceName))")
        if context.platform != nil
            || context.bundleIdentifier != nil
            || context.keychainService != nil
            || context.sandboxContainerIdentifier != nil {
            lines.append("- Platform: \(redact(context.platform ?? "unknown"))")
            lines.append("- Bundle ID: \(safeIdentity(context.bundleIdentifier))")
            lines.append("- Keychain service: \(safeIdentity(context.keychainService))")
            lines.append("- Sandbox/container identity: \(safeIdentity(context.sandboxContainerIdentifier))")
        }
        lines.append("- Backend: \(redact(context.backend))")
        if let server = context.server, !server.isEmpty {
            lines.append("- Server: \(redact(server))")
        }
        if let scheme = context.connectionScheme, !scheme.isEmpty {
            lines.append("- Connection scheme: \(redact(scheme))")
        }
        lines.append("- Selected quality: \(redact(context.selectedQuality))")
        if let adaptiveBitrateEnabled = context.adaptiveBitrateEnabled {
            lines.append("- Adaptive Bitrate: \(adaptiveBitrateEnabled ? "enabled" : "disabled")")
        }
        if context.downloadReferencedBytes != nil
            || context.downloadDirectoryBytes != nil
            || context.downloadOrphanCandidateCount != nil
            || context.downloadRecordCount != nil
            || context.backgroundDownloadSessionIdentifier != nil {
            lines.append("")
            lines.append("Downloads")
            lines.append("- Background session: \(safeIdentity(context.backgroundDownloadSessionIdentifier))")
            lines.append("- Storage location: \(redact(context.downloadStorageLocation ?? "unknown"))")
            lines.append("- Queue paused: \(context.downloadQueuePaused.map { $0 ? "yes" : "no" } ?? "unknown")")
            lines.append("- Records: \(context.downloadRecordCount ?? 0) total, \(context.activeDownloadCount ?? 0) active, \(context.completeDownloadCount ?? 0) complete")
            lines.append("- Referenced bytes: \(byteBucket(context.downloadReferencedBytes))")
            lines.append("- Directory bytes: \(byteBucket(context.downloadDirectoryBytes))")
            lines.append("- Unreferenced bytes: \(byteBucket(context.downloadUnreferencedBytes))")
            let orphanCount = context.downloadOrphanCandidateCount ?? 0
            lines.append("- Conservative orphan candidates: \(orphanCount) (\(byteBucket(context.downloadOrphanCandidateBytes)))")
        }
        lines.append("")
        lines.append("Diagnostics")
        lines.append("- Diagnostic logging enabled: \(context.loggingEnabled ? "yes" : "no")")
        lines.append("- Ring buffer events: \(events.count) total, showing last \(shownEvents.count)")
        lines.append("- Collection is local and export is user-initiated.")
        lines.append("")
        lines.append(contentsOf: MetricKitDiagnosticSummarizer.reportSection(for: metricKitSummaries))
        lines.append("")
        lines.append("Recent playback snapshot")
        if let snapshot = latestPlaybackSnapshot(in: events) {
            for key in snapshot.fields.keys.sorted() {
                lines.append("- \(key): \(snapshot.fields[key]?.description ?? "")")
            }
        } else {
            lines.append("- No playback snapshot captured in this app run.")
        }
        lines.append("")
        lines.append("Recent redacted events (JSONL, oldest to newest)")
        if shownEvents.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: shownEvents.map { $0.jsonLine() })
        }
        return lines.joined(separator: "\n")
    }

    private static func byteBucket(_ bytes: Int?) -> String {
        guard let bytes else { return "unknown" }
        return DiagnosticRedactor.byteBucket(bytes)
    }

    private static func latestPlaybackSnapshot(in events: [DiagnosticEvent]) -> DiagnosticEvent? {
        events.last { event in
            event.category == .playback && event.name == "playback.snapshot"
        }
    }

    private static func redact(_ value: String) -> String {
        DiagnosticRedactor.redact(value)
    }

    private static func safeIdentity(_ value: String?) -> String {
        DiagnosticRedactor.safeLogToken(value)
    }
}
