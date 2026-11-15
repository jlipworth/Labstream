import Foundation

public struct DiagnosticReportContext: Sendable, Equatable {
    public var product: String
    public var appVersion: String
    public var appBuild: String
    public var buildID: String?
    public var builtAt: String?
    public var operatingSystem: String
    public var deviceName: String
    /// Hardware model identifier such as "iPhone17,1" — a product code, not a device ID.
    public var deviceModel: String?
    /// "App Store", "TestFlight", or "Development".
    public var installSource: String?
    public var platform: String?
    public var bundleIdentifier: String?
    public var keychainService: String?
    public var sandboxContainerIdentifier: String?
    public var backend: String
    public var server: String?
    /// Server software version. Rendered through `safeVersion`, not the redactor: a four-part
    /// version such as Emby's "4.8.11.0" looks like an IPv4 address to the redactor.
    public var serverVersion: String?
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
                deviceModel: String? = nil,
                installSource: String? = nil,
                platform: String? = nil,
                bundleIdentifier: String? = nil,
                keychainService: String? = nil,
                sandboxContainerIdentifier: String? = nil,
                backend: String,
                server: String? = nil,
                serverVersion: String? = nil,
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
        self.deviceModel = deviceModel
        self.installSource = installSource
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.keychainService = keychainService
        self.sandboxContainerIdentifier = sandboxContainerIdentifier
        self.backend = backend
        self.server = server
        self.serverVersion = serverVersion
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
    /// The report split for a length-limited destination: everything except the event log, and
    /// the event log one JSON line per event (oldest to newest).
    public struct Parts: Sendable, Equatable {
        public var head: String
        public var eventLines: [String]
    }

    public static func render(context: DiagnosticReportContext,
                              events: [DiagnosticEvent],
                              metricKitSummaries: [MetricKitDiagnosticSummary] = [],
                              maxEvents: Int = 80,
                              generatedAt: Date = Date()) -> String {
        let parts = renderParts(context: context, events: events, metricKitSummaries: metricKitSummaries,
                                maxEvents: maxEvents, generatedAt: generatedAt)
        return ([parts.head] + (parts.eventLines.isEmpty ? ["(none)"] : parts.eventLines))
            .joined(separator: "\n")
    }

    /// One line naming the build, OS, device, install source, backend and connection, for the
    /// issue form's environment field and the Apple TV QR link.
    public static func environmentLine(context: DiagnosticReportContext) -> String {
        var parts = ["\(redact(context.product)) \(redact(context.appVersion)) (\(redact(context.appBuild)))",
                     redact(context.operatingSystem)]
        parts.append(context.deviceModel.map(safeModel) ?? redact(context.deviceName))
        if let source = context.installSource, !source.isEmpty { parts.append(redact(source)) }
        parts.append(serverText(context) ?? redact(context.backend))
        if let scheme = context.connectionScheme, !scheme.isEmpty { parts.append(redact(scheme)) }
        return parts.joined(separator: " · ")
    }

    public static func renderParts(context: DiagnosticReportContext,
                                   events: [DiagnosticEvent],
                                   metricKitSummaries: [MetricKitDiagnosticSummary] = [],
                                   maxEvents: Int = 80,
                                   generatedAt: Date = Date()) -> Parts {
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
        if let source = context.installSource, !source.isEmpty {
            lines.append("- Install source: \(redact(source))")
        }
        lines.append("- OS: \(redact(context.operatingSystem))")
        lines.append("- Device: \(redact(context.deviceName))")
        if let model = context.deviceModel, !model.isEmpty {
            lines.append("- Device model: \(safeModel(model))")
        }
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
        if let server = serverText(context) {
            lines.append("- Server: \(server)")
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
        return Parts(head: lines.joined(separator: "\n"), eventLines: shownEvents.map { $0.jsonLine() })
    }

    /// "Jellyfin 10.9.11": the redacted server product followed by its version.
    private static func serverText(_ context: DiagnosticReportContext) -> String? {
        let product = context.server.flatMap { $0.isEmpty ? nil : redact($0) }
        let version = context.serverVersion.map(safeVersion).flatMap { $0.isEmpty ? nil : $0 }
        switch (product, version) {
        case let (product?, version?): return "\(product) \(version)"
        case let (product?, nil): return product
        case let (nil, version?): return "\(redact(context.backend)) \(version)"
        case (nil, nil): return nil
        }
    }

    /// The leading run of digits, dots, hyphens and letters of a software version, capped in
    /// length, so it bypasses the redactor without being able to carry a
    /// host, path or address-with-port.
    static func safeVersion(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        // Stop at the first other character, so text after the version cannot ride along.
        return String(String.UnicodeScalarView(value.unicodeScalars.prefix(while: allowed.contains)).prefix(24))
    }

    /// A hardware model identifier ("iPhone17,1", "Mac15,6") reduced to letters, digits and commas.
    static func safeModel(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,")
        return String(String.UnicodeScalarView(value.unicodeScalars.filter(allowed.contains)).prefix(24))
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
