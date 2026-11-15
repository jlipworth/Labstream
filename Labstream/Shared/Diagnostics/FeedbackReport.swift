import Foundation
import SwiftUI
import PMSKit

/// Builds the redacted problem report from app state, for every entry point (Settings, the
/// playback failure card, the Mac Help menu).
///
/// Includes versions, device model, install source, server product/version, selected quality and
/// the connection SCHEME only: never tokens, client identifiers, URLs/hosts, the server's name,
/// media titles, filenames, usernames, or library paths.
@MainActor
enum FeedbackReport {
    static func context(appModel: AppModel,
                        downloads: DownloadSummary?,
                        serverVersion: String?) -> DiagnosticReportContext {
        let defaults = UserDefaults.standard
        let home = defaults.object(forKey: PlaybackPreferences.Keys.homeQualityKbps) as? Int
            ?? PlaybackPreferences.defaultHomeQualityKbps
        let remote = defaults.object(forKey: PlaybackPreferences.Keys.remoteQualityKbps) as? Int
            ?? PlaybackPreferences.defaultRemoteQualityKbps
        let adaptive = defaults.object(forKey: PlaybackPreferences.Keys.adaptiveBitrateEnabled) as? Bool
            ?? PlaybackPreferences.defaultAdaptiveBitrateEnabled
        return DiagnosticReportContext(
            product: appModel.identity.product,
            appVersion: appVersion,
            appBuild: appBuild,
            buildID: Bundle.main.object(forInfoDictionaryKey: "LabstreamBuildSlug") as? String,
            builtAt: Bundle.main.object(forInfoDictionaryKey: "LabstreamBuildDateUTC") as? String,
            operatingSystem: operatingSystem,
            deviceName: appModel.identity.deviceName,
            deviceModel: DeviceEnvironment.modelIdentifier,
            installSource: DeviceEnvironment.installSource,
            platform: platformName,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            keychainService: Bundle.main.object(forInfoDictionaryKey: "LabstreamKeychainService") as? String,
            sandboxContainerIdentifier: sandboxContainerIdentifier,
            backend: appModel.activeBackend.displayName,
            server: serverProduct(appModel),
            serverVersion: serverVersion ?? knownServerVersion(appModel),
            connectionScheme: connectionScheme(appModel),
            selectedQuality: "Home: \(StreamingQuality.label(kbps: home)); Remote: \(StreamingQuality.label(kbps: remote))",
            adaptiveBitrateEnabled: adaptive,
            backgroundDownloadSessionIdentifier: downloads?.backgroundSessionIdentifier,
            downloadStorageLocation: downloads == nil ? nil : downloadStorageLocation,
            downloadRecordCount: downloads?.recordCount,
            activeDownloadCount: downloads?.activeCount,
            completeDownloadCount: downloads?.completeCount,
            downloadQueuePaused: downloads?.queuePaused,
            downloadReferencedBytes: downloads?.referencedBytes,
            downloadDirectoryBytes: downloads?.directoryBytes,
            downloadUnreferencedBytes: downloads?.unreferencedBytes,
            downloadOrphanCandidateCount: downloads?.orphanCandidateCount,
            downloadOrphanCandidateBytes: downloads?.orphanCandidateBytes,
            loggingEnabled: AppDiagnostics.isEnabled
        )
    }

    /// The download figures the report carries. Absent on Apple TV, which has no downloads.
    struct DownloadSummary {
        var backgroundSessionIdentifier: String
        var recordCount: Int
        var activeCount: Int
        var completeCount: Int
        var queuePaused: Bool
        var referencedBytes: Int
        var directoryBytes: Int
        var unreferencedBytes: Int
        var orphanCandidateCount: Int
        var orphanCandidateBytes: Int
    }

    #if !os(tvOS)
    static func downloadSummary(_ manager: DownloadManager) -> DownloadSummary {
        let audit = manager.storageAudit
        let records = manager.records
        return DownloadSummary(backgroundSessionIdentifier: BackgroundDownloadSession.identifier,
                               recordCount: records.count,
                               activeCount: records.filter { $0.status.isActiveWork }.count,
                               completeCount: records.filter(\.isComplete).count,
                               queuePaused: manager.isQueuePaused,
                               referencedBytes: audit.referencedBytes,
                               directoryBytes: audit.directoryBytes,
                               unreferencedBytes: audit.unreferencedBytes,
                               orphanCandidateCount: audit.orphanCandidates.count,
                               orphanCandidateBytes: audit.orphanCandidateBytes)
    }
    #endif

    /// "iOS 27.1 (24B80)": platform, version and OS build, without the words "Version" and
    /// "Build" that `operatingSystemVersionString` adds.
    static var operatingSystem: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(PlatformClientIdentity.plexPlatform) \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion != 0 { text += ".\(v.patchVersion)" }
        let full = ProcessInfo.processInfo.operatingSystemVersionString
        if let open = full.range(of: "(Build "), let close = full.range(of: ")", range: open.upperBound..<full.endIndex) {
            text += " (\(full[open.upperBound..<close.lowerBound]))"
        }
        return text
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// The server's software version. Plex reports it at discovery; Jellyfin and Emby publish it
    /// at the unauthenticated `/System/Info/Public`, which is asked only when a report is opened.
    static func fetchServerVersion(appModel: AppModel) async -> String? {
        let base: URL?
        switch appModel.activeBackend {
        case .plex: return knownServerVersion(appModel)
        case .jellyfin: base = appModel.jellyfinServerBaseURL
        case .emby: base = appModel.embyServerBaseURL
        }
        guard let base else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("System/Info/Public"))
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(EmbyServerInfo.self, from: data) else { return nil }
        return info.version
    }

    private static func knownServerVersion(_ appModel: AppModel) -> String? {
        guard appModel.activeBackend == .plex else { return nil }
        return appModel.selectedServer?.productVersion
    }

    /// Product only. Never the user-chosen server NAME: it is often a personal name that the
    /// best-effort redactor cannot catch.
    private static func serverProduct(_ appModel: AppModel) -> String {
        switch appModel.activeBackend {
        case .plex: "Plex Media Server"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        }
    }

    private static func connectionScheme(_ appModel: AppModel) -> String? {
        switch appModel.activeBackend {
        case .plex: appModel.serverBaseURL?.scheme
        case .jellyfin: appModel.jellyfinServerBaseURL?.scheme
        case .emby: appModel.embyServerBaseURL?.scheme
        }
    }

    private static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS/iPadOS"
        #else
        "Apple"
        #endif
    }

    private static var sandboxContainerIdentifier: String? {
        #if os(macOS)
        // Not the container path, which includes the user's home directory. The bundle id is the
        // Mac sandbox identity and distinguishes production from per-worktree dev apps.
        return Bundle.main.bundleIdentifier
        #else
        return nil
        #endif
    }

    private static var downloadStorageLocation: String {
        #if os(macOS)
        "app-container/Application Support/Labstream/Downloads"
        #else
        "Application Support/Labstream/Downloads"
        #endif
    }
}

/// Facts about the device and install that a report needs and the client identity omits.
enum DeviceEnvironment {
    /// The hardware model identifier ("iPhone17,1", "AppleTV14,1", "RealityDevice14,1",
    /// "Mac15,6"). A product code shared by every unit of that model, not a device identifier.
    static let modelIdentifier: String? = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (simulator)" }
        #else
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size: size_t = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return model.isEmpty ? nil : model
        #endif
    }()

    /// Where this copy came from, read from the App Store receipt's file name: TestFlight
    /// installs carry `sandboxReceipt`, App Store installs `receipt`, and development builds none.
    static let installSource: String = {
        #if DEBUG
        return "Development (debug build)"
        #else
        guard let receipt = Bundle.main.appStoreReceiptURL else { return "Development" }
        if receipt.lastPathComponent == "sandboxReceipt" { return "TestFlight" }
        return FileManager.default.fileExists(atPath: receipt.path) ? "App Store" : "Development"
        #endif
    }()
}

private struct AllowsProblemReportKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False where a report sheet cannot be presented (the visionOS Cinema attachment).
    var allowsProblemReport: Bool {
        get { self[AllowsProblemReportKey.self] }
        set { self[AllowsProblemReportKey.self] = newValue }
    }
}

/// Presents the report screen with a report built when it opens.
private struct ReportProblemSheet: ViewModifier {
    @Binding var isPresented: Bool
    let source: String

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Full screen on Apple TV: the system sheet is a narrow card that truncates the form.
        content.fullScreenCover(isPresented: $isPresented) { FeedbackSheetHost(source: source) }
        #else
        content.sheet(isPresented: $isPresented) { FeedbackSheetHost(source: source) }
        #endif
    }
}

extension View {
    /// `source` names the entry point in the local diagnostic log ("settings", "playback_failure").
    func reportProblemSheet(isPresented: Binding<Bool>, source: String) -> some View {
        modifier(ReportProblemSheet(isPresented: isPresented, source: source))
    }
}

/// Reads the app state, builds the report, and asks the server for its version once.
struct FeedbackSheetHost: View {
    let source: String

    @Environment(AppModel.self) private var appModel
    #if !os(tvOS)
    @Environment(DownloadManager.self) private var downloadManager: DownloadManager?
    #endif
    @State private var serverVersion: String?

    private var context: DiagnosticReportContext {
        #if os(tvOS)
        FeedbackReport.context(appModel: appModel, downloads: nil, serverVersion: serverVersion)
        #else
        FeedbackReport.context(appModel: appModel,
                               downloads: downloadManager.map(FeedbackReport.downloadSummary),
                               serverVersion: serverVersion)
        #endif
    }

    var body: some View {
        FeedbackSheet(context: context)
            .task {
                AppDiagnostics.record(.settingsUI, "diagnostics.feedback_opened", fields: [
                    "source": .label(source),
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(AppDiagnostics.isEnabled),
                ])
                serverVersion = await FeedbackReport.fetchServerVersion(appModel: appModel)
            }
    }
}
