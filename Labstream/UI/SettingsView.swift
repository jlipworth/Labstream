import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import PMSKit

/// Settings tab (#26/#47-#49): server info + reachability, playback experience controls,
/// local/remote quality caps, download defaults/storage, maintenance, diagnostics, and sign out.
struct SettingsView: View {
    let authManager: AuthManager

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var rediscovering = false
    @State private var selectingPlexServerID: String?
    @State private var checkingPlexServers = false
    @State private var confirmingSignOut = false
    @State private var confirmingDifferentServerSignIn: MediaBackendKind?
    @State private var confirmingReset = false
    @State private var confirmingRemoveAllDownloads = false
    @State private var confirmingRemoveCompletedDownloads = false
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var plexServerStatuses: [String: ConnectionStatus] = [:]
    @State private var plexServerOperationID: UUID?
    /// Transient "done" feedback for the one-shot maintenance/About actions.
    @State private var clearedImageCache = false
    @State private var clearedImageCacheResetID: UUID?
    @State private var clearedSpotlightIndex = false
    @State private var clearedSpotlightIndexResetID: UUID?
    @State private var resetPlaybackPrefs = false
    @State private var copiedDiagnostics = false
    @State private var copiedDiagnosticsResetID: UUID?
    #if !os(tvOS)
    @State private var exportingDiagnostics = false
    @State private var diagnosticExportDocument = DiagnosticReportArtifact.Document()
    #endif
    @State private var presentingFeedback = false
    @State private var switchingBackend: MediaBackendKind?

    @AppStorage(PlaybackPreferences.Keys.homeQualityKbps) private var homeMaxVideoBitrateKbps = PlaybackPreferences.defaultHomeQualityKbps
    @AppStorage(PlaybackPreferences.Keys.remoteQualityKbps) private var remoteMaxVideoBitrateKbps = PlaybackPreferences.defaultRemoteQualityKbps
    @AppStorage(PlaybackPreferences.Keys.autoPlayUpNext) private var autoPlayUpNext = true
    @AppStorage(PlaybackPreferences.Keys.upNextCountdownSeconds) private var upNextCountdownSeconds = PlaybackPreferences.defaultUpNextCountdownSeconds
    @AppStorage(PlaybackPreferences.Keys.resumeRewindSeconds) private var resumeRewindSeconds = 0
    @AppStorage(PlaybackPreferences.Keys.skipIntroMode) private var skipIntroModeRaw = PlaybackPreferences.SkipMode.manual.rawValue
    @AppStorage(PlaybackPreferences.Keys.skipCreditsMode) private var skipCreditsModeRaw = PlaybackPreferences.SkipMode.manual.rawValue
    @AppStorage(PlaybackPreferences.Keys.adaptiveBitrateEnabled) private var adaptiveBitrateEnabled = PlaybackPreferences.defaultAdaptiveBitrateEnabled
    // GH #196: advertises Dolby Vision to servers (dvh1 direct play, DOVI range types) and
    // defers the DV P5 tone-map guard. Default off until device-verified.
    @AppStorage(PlaybackPreferences.Keys.experimentalDVSignalling) private var experimentalDVSignalling = false
    @AppStorage(PlaybackPreferences.Keys.defaultDownloadQuality) private var defaultDownloadQuality = PlaybackPreferences.defaultDownloadQuality
    @AppStorage(PlaybackPreferences.Keys.downloadStorageLimitBytes) private var downloadStorageLimitBytes = DownloadStorageLimit.unlimited
    @AppStorage(PlaybackPreferences.Keys.allowCellularDownloads) private var allowCellularDownloads = PlaybackPreferences.defaultAllowCellularDownloads
    @AppStorage(PlaybackPreferences.Keys.prioritizeQuickDownloads) private var prioritizeQuickDownloads = PlaybackPreferences.defaultPrioritizeQuickDownloads
    @AppStorage(PlaybackPreferences.Keys.systemMediaSuggestionsEnabled) private var systemMediaSuggestionsEnabled = PlaybackPreferences.defaultSystemMediaSuggestionsEnabled
    /// Opt-in app diagnostics. Persisted, but the event buffer itself stays local/bounded.
    @AppStorage(AppDiagnostics.enabledDefaultsKey) private var diagnosticLoggingEnabled = false
    @AppStorage(PlaybackPreferences.Keys.preferredAudioLanguage) private var preferredAudioLanguage = ""
    @AppStorage(PlaybackPreferences.Keys.preferredSubtitleLanguage) private var preferredSubtitleLanguage = ""
    @AppStorage(PlaybackPreferences.Keys.subtitleAutoSelectMode) private var subtitleAutoSelectModeRaw = SubtitleAutoSelectMode.manual.rawValue
    @AppStorage(PlaybackPreferences.Keys.subtitleBurnMode) private var subtitleBurnModeRaw = SubtitleBurnMode.automatic.rawValue

    var body: some View {
        Form {
            backendSection
            serverSection
            librariesSection
            playbackSection
            if PlatformFeaturePolicy.supportsDownloads {
                storageSection
            }
            maintenanceSection
            diagnosticsSection
            aboutSection
            accountSection
        }
        .navigationTitle("Settings")
        .onAppear {
            PlaybackPreferences.migrateLegacyQualityIfNeeded()
            homeMaxVideoBitrateKbps = PlaybackPreferences.qualityKbps(forDefaultsKey: PlaybackPreferences.Keys.homeQualityKbps)
            remoteMaxVideoBitrateKbps = PlaybackPreferences.qualityKbps(forDefaultsKey: PlaybackPreferences.Keys.remoteQualityKbps)
        }
        #if !os(tvOS)
        .fileExporter(isPresented: $exportingDiagnostics,
                      document: diagnosticExportDocument,
                      contentType: .plainText,
                      defaultFilename: DiagnosticReportArtifact.exportFilename) { result in
            switch result {
            case .success:
                AppDiagnostics.record(.settingsUI, "diagnostics.report_export_completed", fields: [
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(diagnosticLoggingEnabled),
                ])
            case .failure(let error):
                AppDiagnostics.record(.settingsUI, "diagnostics.report_export_failed", fields: [
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(diagnosticLoggingEnabled),
                    "error": .error(error),
                ])
            }
        }
        #endif
        .sheet(isPresented: $presentingFeedback) {
            FeedbackSheet(reportText: diagnosticReportText,
                          githubIssuesURL: Self.feedbackIssuesURL,
                          appVersionBuild: "\(Self.appVersion) (\(Self.appBuild))",
                          osVersion: Self.shortOSVersion)
        }
        .confirmationDialog(differentServerConfirmationTitle,
                            isPresented: differentServerConfirmationBinding,
                            titleVisibility: .visible) {
            Button("Sign Out and Continue", role: .destructive) {
                confirmingDifferentServerSignIn = nil
                signOutAndHandoffIfNeeded()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(differentServerConfirmationMessage)
        }
    }

    /// Single source of truth for the web bug-report link (template-prefilled new-issue URL).
    static let feedbackIssuesURL = URL(string: "https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml")!

    /// "26.5"-style OS version for prefilling the bug form (the full
    /// `operatingSystemVersionString` carries a build suffix the form doesn't want).
    static var shortOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(v.majorVersion).\(v.minorVersion)"
        return v.patchVersion == 0 ? base : "\(base).\(v.patchVersion)"
    }

    // MARK: Playback

    private var playbackSection: some View {
        SwiftUI.Section {
            Picker(selection: $homeMaxVideoBitrateKbps) {
                qualityRows
            } label: {
                Label("Home / Local Quality", systemImage: "house")
            }
            .onChange(of: homeMaxVideoBitrateKbps) { _, newValue in
                PlaybackPreferences.setQualityKbps(newValue, forDefaultsKey: PlaybackPreferences.Keys.homeQualityKbps)
            }

            Picker(selection: $remoteMaxVideoBitrateKbps) {
                qualityRows
            } label: {
                Label("Internet / Remote Quality", systemImage: "globe")
            }
            .onChange(of: remoteMaxVideoBitrateKbps) { _, newValue in
                PlaybackPreferences.setQualityKbps(newValue, forDefaultsKey: PlaybackPreferences.Keys.remoteQualityKbps)
            }

            Toggle(isOn: $autoPlayUpNext) {
                Label("Auto Play Up Next", systemImage: "forward.end")
            }

            Picker("Up Next Countdown", selection: $upNextCountdownSeconds) {
                ForEach([0, 5, 10, 15, 30, 60], id: \.self) { seconds in
                    Text(seconds == 0 ? "Immediate" : "\(seconds)s").tag(seconds)
                }
            }
            .disabled(!autoPlayUpNext)

            Picker("Rewind on Resume", selection: $resumeRewindSeconds) {
                ForEach([0, 5, 10, 15, 30, 60], id: \.self) { seconds in
                    Text(seconds == 0 ? "None" : "\(seconds)s").tag(seconds)
                }
            }

            Picker("Skip Intro", selection: skipIntroModeBinding) {
                skipModeRows
            }

            Picker("Skip Credits", selection: skipCreditsModeBinding) {
                skipModeRows
            }

            Toggle(isOn: $adaptiveBitrateEnabled) {
                Label("Adaptive Bitrate", systemImage: "arrow.up.arrow.down.circle")
            }

            Toggle(isOn: $experimentalDVSignalling) {
                Label("Dolby Vision Signalling (Experimental)", systemImage: "sparkles.tv")
            }

            Toggle(isOn: Binding(
                get: { systemMediaSuggestionsEnabled },
                set: { enabled in
                    systemMediaSuggestionsEnabled = enabled
                    if !enabled {
                        SpotlightIndexer.deleteAll { ok in
                            AppDiagnostics.record(.settingsUI, "system_media_suggestions.disabled", fields: [
                                "spotlight_delete_accepted": .bool(ok),
                            ])
                        }
                    }
                    LabstreamShortcuts.updateAppShortcutParameters()
                })) {
                    Label("Show Media in Spotlight & Siri", systemImage: "magnifyingglass.circle")
                }

            Picker(selection: $preferredAudioLanguage) {
                ForEach(PlaybackLanguageOption.common) { option in
                    Text(option.label).tag(option.id)
                }
            } label: {
                Label("Preferred Audio", systemImage: "speaker.wave.2")
            }

            Picker(selection: Binding(
                get: { preferredSubtitleLanguage },
                set: { language in
                    preferredSubtitleLanguage = language
                    UserDefaults.standard.set(false, forKey: PlaybackPreferences.Keys.subtitlesOff)
                }
            )) {
                ForEach(PlaybackLanguageOption.common) { option in
                    Text(option.label).tag(option.id)
                }
            } label: {
                Label("Preferred Subtitles", systemImage: "captions.bubble")
            }

            Picker("Auto-select Subtitles", selection: Binding(
                get: { SubtitleAutoSelectMode(rawValue: subtitleAutoSelectModeRaw) ?? .manual },
                set: { subtitleAutoSelectModeRaw = $0.rawValue }
            )) {
                ForEach(SubtitleAutoSelectMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Picker("Burn Subtitles", selection: Binding(
                get: { SubtitleBurnMode(rawValue: subtitleBurnModeRaw) ?? .automatic },
                set: { subtitleBurnModeRaw = $0.rawValue }
            )) {
                ForEach(SubtitleBurnMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text(playbackFooter)
        }
    }

    @ViewBuilder
    private var qualityRows: some View {
        ForEach(StreamingQuality.ladder) { option in
            Text(StreamingQuality.label(kbps: option.kbps)).tag(option.kbps)
        }
    }

    @ViewBuilder
    private var skipModeRows: some View {
        ForEach(PlaybackPreferences.SkipMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
        }
    }

    private var skipIntroModeBinding: Binding<String> {
        Binding(get: { skipIntroModeRaw }, set: { skipIntroModeRaw = $0 })
    }

    private var skipCreditsModeBinding: Binding<String> {
        Binding(get: { skipCreditsModeRaw }, set: { skipCreditsModeRaw = $0 })
    }

    private var playbackFooter: String {
        let active = "Current \(appModel.activeStreamingQualityScopeLabel) cap: \(StreamingQuality.label(kbps: appModel.activeStreamingQualityKbps))."
        switch appModel.activeBackend {
        case .plex:
            let subtitleMode = SubtitleAutoSelectMode(rawValue: subtitleAutoSelectModeRaw) ?? .manual
            let burnMode = SubtitleBurnMode(rawValue: subtitleBurnModeRaw) ?? .automatic
            return active + " Home/Local applies when the selected Plex connection is advertised as local; Internet/Remote applies otherwise. These are maximum/default caps, not a Direct Play guarantee. Adaptive Bitrate may reopen the stream at a lower or higher capped quality after sustained stalls or healthy playback. Spotlight & Siri suggestions can expose browsed media titles to system surfaces; turn them off to stop new indexing and clear Labstream's Spotlight index. \(subtitleMode.help) \(burnMode.help)"
        case .jellyfin:
            return active + " Jellyfin currently uses the Internet/Remote cap. Adaptive Bitrate may reopen transcoded streams at a lower or higher capped quality after sustained stalls or healthy playback. Spotlight & Siri suggestions can expose browsed media titles to system surfaces; turn them off to stop new indexing and clear Labstream's Spotlight index. Skip modes are honored when marker data exists."
        case .emby:
            return active + " Emby currently uses the Internet/Remote cap. Adaptive Bitrate may reopen transcoded streams at a lower or higher capped quality after sustained stalls or healthy playback. Spotlight & Siri suggestions can expose browsed media titles to system surfaces; turn them off to stop new indexing and clear Labstream's Spotlight index."
        }
    }

    // MARK: Backend

    private var backendSection: some View {
        SwiftUI.Section {
            Picker("Media Backend", selection: Binding(
                get: { appModel.activeBackend },
                set: { backend in
                    switchToBackend(backend)
                })) {
                    ForEach(MediaBackendKind.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(switchingBackend != nil)

            if let switchingBackend {
                HStack {
                    ProgressView()
                    Text("Switching to \(switchingBackend.displayName)…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Switching keeps each backend’s credentials separate. If the selected backend has a saved session, Labstream reconnects automatically; otherwise it opens that backend’s sign-in flow.")
        }
    }

    private func switchToBackend(_ backend: MediaBackendKind) {
        guard backend != appModel.activeBackend else { return }
        switchingBackend = backend
        Task {
            await authManager.switchBackend(backend)
            let requiresSignIn = appModel.activeBackend == backend && !appModel.isBrowseReady
            switchingBackend = nil
            if requiresSignIn {
                handoffRequiredSignInToMainWindow()
            }
        }
    }

    // MARK: Server

    /// Result of the last manual reachability check. No background polling — the probe runs
    /// only on tap (and re-arms after re-discovery, which replaces the connection anyway).
    private enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case reachable(Date)
        case unreachable(Date)
    }

    private var serverSection: some View {
        SwiftUI.Section("Server") {
            switch appModel.activeBackend {
            case .plex:
                if appModel.plexServers.isEmpty {
                    Text("No Plex servers discovered.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Plex Server", selection: Binding(
                        get: { appModel.selectedServer?.clientIdentifier ?? "" },
                        set: { serverID in
                            guard !serverID.isEmpty,
                                  serverID != appModel.selectedServer?.clientIdentifier else { return }
                            selectingPlexServerID = serverID
                            let operationID = UUID()
                            plexServerOperationID = operationID
                            Task {
                                do {
                                    try await authManager.selectPlexServer(id: serverID)
                                    guard plexServerOperationID == operationID else { return }
                                    plexServerStatuses[serverID] = .reachable(.now)
                                } catch {
                                    guard plexServerOperationID == operationID else { return }
                                    plexServerStatuses[serverID] = .unreachable(.now)
                                }
                                connectionStatus = .unknown
                                selectingPlexServerID = nil
                                plexServerOperationID = nil
                            }
                        })) {
                            ForEach(appModel.plexServers) { server in
                                Text(serverPickerLabel(server))
                                    .tag(server.clientIdentifier)
                            }
                        }
                        .disabled(selectingPlexServerID != nil || rediscovering || checkingPlexServers)
                    if let selectingPlexServerID,
                       let server = appModel.plexServers.first(where: { $0.clientIdentifier == selectingPlexServerID }) {
                        HStack {
                            ProgressView()
                            Text("Selecting \(server.name)…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let server = appModel.selectedServer {
                    LabeledContent("Name", value: server.name)
                    if let version = server.productVersion, !version.isEmpty {
                        LabeledContent("Version", value: version)
                    }
                }
                if let url = appModel.serverBaseURL {
                    LabeledContent("Connection", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    connectionStatusRow
                }
                Button {
                    Task { await checkPlexServerReachability() }
                } label: {
                    if checkingPlexServers {
                        Label {
                            Text("Checking server reachability…")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("Check server reachability", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .disabled(checkingPlexServers || rediscovering || selectingPlexServerID != nil || appModel.plexServers.isEmpty)

                Button {
                    let operationID = UUID()
                    plexServerOperationID = operationID
                    Task {
                        rediscovering = true
                        try? await authManager.refreshServers()
                        guard plexServerOperationID == operationID else { return }
                        rediscovering = false
                        connectionStatus = .unknown
                        plexServerStatuses.removeAll()
                        plexServerOperationID = nil
                    }
                } label: {
                    if rediscovering {
                        Label {
                            Text("Re-discovering servers…")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("Re-discover servers", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(rediscovering || selectingPlexServerID != nil || checkingPlexServers)
            case .jellyfin:
                if let url = appModel.jellyfinServerBaseURL {
                    LabeledContent("Connection", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let userID = appModel.jellyfinUserID {
                    LabeledContent("User ID", value: userID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(role: .destructive) {
                    confirmingDifferentServerSignIn = .jellyfin
                } label: {
                    Label("Sign in to a different Jellyfin server", systemImage: "arrow.triangle.2.circlepath")
                }
            case .emby:
                if let url = appModel.embyServerBaseURL {
                    LabeledContent("Connection", value: url.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let userID = appModel.embyUserID {
                    LabeledContent("User ID", value: userID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(role: .destructive) {
                    confirmingDifferentServerSignIn = .emby
                } label: {
                    Label("Sign in to a different Emby server", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    /// Status dot + last-checked time. The explicit "Check server reachability" row below is
    /// the action; keeping this display-only avoids visionOS rendering the row as a giant button.
    private var connectionStatusRow: some View {
        HStack(spacing: 12) {
            Text("Status")
            Spacer()
            switch connectionStatus {
            case .unknown:
                Text("Not checked")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView()
            case .reachable(let date):
                statusValue(checkedAt(date), color: .green)
            case .unreachable(let date):
                statusValue(checkedAt(date), color: .red)
            }
        }
    }

    private func statusValue(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text(text)
                .foregroundStyle(color)
        }
    }

    private func checkedAt(_ date: Date) -> String {
        "Checked \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func serverPickerLabel(_ server: PlexDevice) -> String {
        var label = server.name
        switch plexServerStatuses[server.clientIdentifier] {
        case .reachable:
            label += " · Reachable"
        case .unreachable:
            label += " · Unreachable"
        case .checking:
            label += " · Checking"
        case .unknown, nil:
            break
        }
        return label
    }

    private func checkPlexServerReachability() async {
        let operationID = UUID()
        plexServerOperationID = operationID
        checkingPlexServers = true
        let servers = appModel.plexServers
        for server in servers {
            guard plexServerOperationID == operationID else { return }
            plexServerStatuses[server.clientIdentifier] = .checking
            let ok = await authManager.probePlexServer(id: server.clientIdentifier)
            guard plexServerOperationID == operationID else { return }
            plexServerStatuses[server.clientIdentifier] = ok ? .reachable(.now) : .unreachable(.now)
        }
        if let selectedID = appModel.selectedServer?.clientIdentifier,
           case let status? = plexServerStatuses[selectedID] {
            connectionStatus = status
        }
        checkingPlexServers = false
        plexServerOperationID = nil
    }

    // MARK: Libraries (#104)

    private var librariesSection: some View {
        SwiftUI.Section {
            NavigationLink {
                LibraryVisibilityEditor()
            } label: {
                Label("Choose Libraries", systemImage: "rectangle.stack.badge.person.crop")
            }
        } header: {
            Text("Libraries")
        } footer: {
            Text("Pick which libraries appear on the Libraries screen for this server. Choices are saved per backend; new server libraries appear automatically.")
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        SwiftUI.Section {
            Picker(selection: $defaultDownloadQuality) {
                Text("Original when available").tag("Original")
                ForEach(downloadQualityPresets, id: \.self) { preset in
                    Text(preset).tag(preset)
                }
            } label: {
                Label("Default Quality", systemImage: "arrow.down.circle")
            }

            Picker(selection: $downloadStorageLimitBytes) {
                ForEach(DownloadStorageLimit.options) { option in
                    Text(option.label).tag(option.bytes)
                }
            } label: {
                Label("Storage Limit", systemImage: "internaldrive")
            }

            Toggle(isOn: $allowCellularDownloads) {
                Label("Use cellular data for downloads", systemImage: "antenna.radiowaves.left.and.right")
            }

            Picker(selection: $prioritizeQuickDownloads) {
                Text("Respect server queue order").tag(false)
                Text("Prioritize quick downloads").tag(true)
            } label: {
                Label("Queue Order", systemImage: "arrow.up.to.line")
            }

            LabeledContent {
                Text("\(downloadManager.records.count)")
            } label: {
                Label("Items", systemImage: "tray.full")
            }
            LabeledContent {
                Text(formattedStorage)
            } label: {
                Label("Storage used", systemImage: "externaldrive")
            }

            if downloadManager.records.contains(where: { $0.isComplete }) {
                Button(role: .destructive) {
                    confirmingRemoveCompletedDownloads = true
                } label: {
                    Label("Remove completed downloads", systemImage: "trash")
                }
            }

            if !downloadManager.records.isEmpty {
                Button(role: .destructive) {
                    confirmingRemoveAllDownloads = true
                } label: {
                    Label("Remove all downloads", systemImage: "trash.slash")
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Download quality is the default for new downloads; Original still appears only when feasible. Cellular downloads are off by default where cellular data is available, and the setting applies to new transfers only. The storage limit is checked before enqueue/start and won’t delete existing downloads automatically. Prioritizing quick downloads only affects Plex server-side optimize jobs: when permitted, Labstream moves the new conversion behind the currently active one. Jellyfin and Emby keep their normal order.")
        }
        .confirmationDialog("Remove completed downloads?", isPresented: $confirmingRemoveCompletedDownloads, titleVisibility: .visible) {
            Button("Remove Completed", role: .destructive) {
                downloadManager.deleteCompletedDownloads()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAllDownloads, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                downloadManager.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cancels active transfers and removes downloaded files from this device.")
        }
    }

    private var downloadQualityPresets: [String] {
        [
            "Original video quality",
            "4K 40 Mbps",
            "1080p 20 Mbps", "1080p 12 Mbps", "1080p 10 Mbps",
            "1080p 8 Mbps", "720p 4 Mbps", "720p 3 Mbps",
            "720p 2 Mbps", "480p 1.5 Mbps"
        ]
    }

    private var formattedStorage: String {
        let total = downloadManager.records.reduce(0) { $0 + $1.bytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: Maintenance

    private var maintenanceSection: some View {
        SwiftUI.Section {
            Button {
                // PosterImage rides URLSession.shared's default cache — there is no
                // bespoke image cache, so this is the whole story.
                URLCache.shared.removeAllCachedResponses()
                clearedImageCache = true
                scheduleClearedImageCacheReset()
            } label: {
                if clearedImageCache {
                    Label("Cache cleared", systemImage: "checkmark")
                } else {
                    Label("Clear image cache", systemImage: "photo.on.rectangle.angled")
                }
            }
            .disabled(clearedImageCache)

            #if !os(tvOS)
            Button {
                SpotlightIndexer.deleteAll { ok in
                    Task { @MainActor in
                        clearedSpotlightIndex = ok
                        if ok { scheduleClearedSpotlightIndexReset() }
                        AppDiagnostics.record(.settingsUI, "spotlight_index.clear_requested", fields: [
                            "accepted": .bool(ok),
                        ])
                    }
                }
            } label: {
                if clearedSpotlightIndex {
                    Label("Spotlight index cleared", systemImage: "checkmark")
                } else {
                    Label("Clear Spotlight search results", systemImage: "magnifyingglass.circle")
                }
            }
            .disabled(clearedSpotlightIndex)
            #endif
        } header: {
            Text("Maintenance")
        } footer: {
            #if os(tvOS)
            Text("Artwork re-downloads the next time it appears.")
            #else
            Text("Artwork re-downloads on next view. Clearing Spotlight removes Labstream media from system search; browsing Home or library pages again repopulates results.")
            #endif
        }
    }


    private func scheduleClearedImageCacheReset() {
        let resetID = UUID()
        clearedImageCacheResetID = resetID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard clearedImageCacheResetID == resetID else { return }
            clearedImageCache = false
            clearedImageCacheResetID = nil
        }
    }

    private func scheduleClearedSpotlightIndexReset() {
        let resetID = UUID()
        clearedSpotlightIndexResetID = resetID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard clearedSpotlightIndexResetID == resetID else { return }
            clearedSpotlightIndex = false
            clearedSpotlightIndexResetID = nil
        }
    }

    // MARK: About

    private var diagnosticsSection: some View {
        SwiftUI.Section {
            Toggle(isOn: Binding(
                get: { diagnosticLoggingEnabled },
                set: { enabled in
                    // setEnabled is the single writer of the persisted flag; the @AppStorage
                    // binding observes the same UserDefaults key, so assigning it here would be
                    // a redundant double-write.
                    AppDiagnostics.setEnabled(enabled)
                })) {
                    Label("Enable diagnostic logging", systemImage: "ladybug")
                }

            #if !os(tvOS)
            Button {
                AppDiagnostics.record(.settingsUI, "diagnostics.report_copied", fields: [
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(diagnosticLoggingEnabled),
                ])
                PlatformPasteboard.copy(diagnosticReportText)
                copiedDiagnostics = true
                scheduleCopiedDiagnosticsReset()
            } label: {
                if copiedDiagnostics {
                    Label("Copied diagnostic report", systemImage: "checkmark")
                } else {
                    Label("Copy diagnostic report", systemImage: "doc.on.doc")
                }
            }
            #endif

            #if !os(tvOS)
            Button {
                AppDiagnostics.record(.settingsUI, "diagnostics.report_export_requested", fields: [
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(diagnosticLoggingEnabled),
                ])
                diagnosticExportDocument = DiagnosticReportArtifact.Document(text: diagnosticReportText)
                exportingDiagnostics = true
            } label: {
                Label("Export diagnostic report file", systemImage: "square.and.arrow.up")
            }
            #endif

            Button {
                AppDiagnostics.record(.settingsUI, "diagnostics.feedback_opened", fields: [
                    "events_in_buffer": .int(AppDiagnostics.events().count),
                    "logging_enabled": .bool(diagnosticLoggingEnabled),
                ])
                presentingFeedback = true
            } label: {
                Label("Send feedback to developer", systemImage: "exclamationmark.bubble")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            #if os(tvOS)
            Text("Logging is off by default. When enabled, Labstream keeps a bounded, redacted local ring buffer. Send feedback opens the TV support handoff without copying unavailable pasteboard data.")
            #else
            Text("Logging is off by default. When enabled, Labstream keeps a bounded local ring buffer for bug reports. Reports are copied or exported only when you tap a button, and sensitive values are omitted. Send feedback to developer opens a redacted report you can preview, share, or attach to a GitHub bug form.")
            #endif
        }
    }

    private var aboutSection: some View {
        SwiftUI.Section {
            LabeledContent("Version", value: Self.appVersion)
            LabeledContent("Build", value: Self.appBuild)
            if let slug = Self.buildSlug {
                LabeledContent("Build ID", value: slug)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
            }
            if let builtAt = Self.buildDateUTC {
                LabeledContent("Built", value: builtAt)
            }
            LabeledContent("OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            // Product/device name exactly as sent to Plex. NEVER the client identifier —
            // it's treated as a secret in this repo.
            LabeledContent("Client", value: "\(appModel.identity.product) on \(appModel.identity.deviceName)")
        } header: {
            Text("About")
        } footer: {
            // Trademark/branding sign-off (#92): nominative-use disclaimer covering all three
            // backends. Emby staff explicitly approved this "independent third-party / not
            // affiliated" wording for REST-API clients; Plex/Jellyfin permit descriptive use only.
            // Keep this in sync with the App Store description's disclaimer.
            Text("Labstream is an unofficial, independent third-party app. It is not affiliated "
                 + "with, endorsed by, sponsored by, or officially supported by Plex, Inc., the "
                 + "Jellyfin project, or Emby Media. “Plex”, “Jellyfin”, and “Emby” are trademarks "
                 + "of their respective owners and are used here only to indicate compatibility.")
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private static var buildSlug: String? {
        Bundle.main.object(forInfoDictionaryKey: "LabstreamBuildSlug") as? String
    }

    private static var buildDateUTC: String? {
        Bundle.main.object(forInfoDictionaryKey: "LabstreamBuildDateUTC") as? String
    }

    /// Bug-report blob. Includes versions, server name/version, selected quality, and the
    /// connection SCHEME only — never tokens, client identifiers, URLs/hosts, media titles,
    /// filenames, usernames, or library paths.
    private var diagnosticReportText: String {
        let storageAudit = downloadManager.storageAudit
        let downloadRecords = downloadManager.records
        return AppDiagnostics.report(context: DiagnosticReportContext(
            product: appModel.identity.product,
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            buildID: Self.buildSlug,
            builtAt: Self.buildDateUTC,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceName: appModel.identity.deviceName,
            platform: Self.platformName,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            keychainService: Self.keychainService,
            sandboxContainerIdentifier: Self.sandboxContainerIdentifier,
            backend: appModel.activeBackend.displayName,
            server: diagnosticServerLine,
            connectionScheme: diagnosticConnectionScheme,
            selectedQuality: "Home: \(StreamingQuality.label(kbps: homeMaxVideoBitrateKbps)); Remote: \(StreamingQuality.label(kbps: remoteMaxVideoBitrateKbps))",
            adaptiveBitrateEnabled: adaptiveBitrateEnabled,
            backgroundDownloadSessionIdentifier: BackgroundDownloadSession.identifier,
            downloadStorageLocation: Self.downloadStorageLocationDescription,
            downloadRecordCount: downloadRecords.count,
            activeDownloadCount: downloadRecords.filter { $0.status.isActiveWork }.count,
            completeDownloadCount: downloadRecords.filter(\.isComplete).count,
            downloadQueuePaused: downloadManager.isQueuePaused,
            downloadReferencedBytes: storageAudit.referencedBytes,
            downloadDirectoryBytes: storageAudit.directoryBytes,
            downloadUnreferencedBytes: storageAudit.unreferencedBytes,
            downloadOrphanCandidateCount: storageAudit.orphanCandidates.count,
            downloadOrphanCandidateBytes: storageAudit.orphanCandidateBytes,
            loggingEnabled: diagnosticLoggingEnabled
        ))
    }

    private static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(iOS)
        "iOS/iPadOS"
        #else
        "Apple"
        #endif
    }

    private static var keychainService: String? {
        Bundle.main.object(forInfoDictionaryKey: "LabstreamKeychainService") as? String
    }

    private static var sandboxContainerIdentifier: String? {
        #if os(macOS)
        // Do not export the full container path because it includes the user's home directory.
        // The bundle id is the relevant Mac sandbox identity and is enough to distinguish
        // production from per-worktree dev apps in a redacted diagnostic report.
        return Bundle.main.bundleIdentifier
        #else
        return nil
        #endif
    }

    private static var downloadStorageLocationDescription: String {
        #if os(macOS)
        "app-container/Application Support/Labstream/Downloads"
        #else
        "Application Support/Labstream/Downloads"
        #endif
    }

    private func scheduleCopiedDiagnosticsReset() {
        let resetID = UUID()
        copiedDiagnosticsResetID = resetID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard copiedDiagnosticsResetID == resetID else { return }
            copiedDiagnostics = false
            copiedDiagnosticsResetID = nil
        }
    }

    private var diagnosticServerLine: String? {
        switch appModel.activeBackend {
        case .plex:
            // Never include the user-chosen server NAME — it is often a personal name
            // ("Some Person's Laptop") that the best-effort redactor cannot catch. Mirror the
            // Jellyfin branch: emit only the product (and version, which is non-identifying).
            guard let server = appModel.selectedServer else { return "Plex Media Server" }
            let version = server.productVersion.map { " \($0)" } ?? ""
            return "Plex Media Server\(version)"
        case .jellyfin:
            return "Jellyfin"
        case .emby:
            return "Emby"
        }
    }

    private var diagnosticConnectionScheme: String? {
        switch appModel.activeBackend {
        case .plex:
            return appModel.serverBaseURL?.scheme
        case .jellyfin:
            return appModel.jellyfinServerBaseURL?.scheme
        case .emby:
            return appModel.embyServerBaseURL?.scheme
        }
    }

    // MARK: Account

    private var signOutConfirmationMessage: String {
        switch appModel.activeBackend {
        case .plex:
            return "Signing back in requires authorizing this device with plex.tv again."
        case .jellyfin:
            return "Signing back in requires connecting to your Jellyfin server again."
        case .emby:
            return "Signing back in requires connecting to your Emby server again."
        }
    }

    private var differentServerConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmingDifferentServerSignIn != nil },
            set: { presented in
                if !presented { confirmingDifferentServerSignIn = nil }
            }
        )
    }

    private var differentServerConfirmationBackend: MediaBackendKind {
        confirmingDifferentServerSignIn ?? appModel.activeBackend
    }

    private var differentServerConfirmationTitle: String {
        "Sign in to a different \(differentServerConfirmationBackend.displayName) server?"
    }

    private var differentServerConfirmationMessage: String {
        switch differentServerConfirmationBackend {
        case .plex:
            return signOutConfirmationMessage
        case .jellyfin:
            return "This signs out of the current Jellyfin server. Signing back in requires reconnecting to a Jellyfin server."
        case .emby:
            return "This signs out of the current Emby server. Signing back in requires reconnecting to an Emby server."
        }
    }

    private var accountSection: some View {
        SwiftUI.Section {
            switch appModel.activeBackend {
            case .plex:
                LabeledContent {
                    Text(appModel.plexAccountProfile?.displayName ?? "Unavailable")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Label("Signed In As", systemImage: "person.crop.circle")
                }
                if let username = appModel.plexAccountProfile?.username, !username.isEmpty,
                   username != appModel.plexAccountProfile?.displayName {
                    LabeledContent("Username", value: username)
                }
                Button {
                    Task { await authManager.refreshPlexAccountProfile() }
                } label: {
                    Label("Refresh account identity", systemImage: "person.crop.circle.badge.checkmark")
                }
            case .jellyfin:
                EmptyView()
            case .emby:
                EmptyView()
            }

            // Reset lives down here next to Sign Out: both are rarely-used, destructive-ish
            // account actions, so they're grouped away from the everyday playback toggles.
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                if resetPlaybackPrefs {
                    Label("Preferences reset", systemImage: "checkmark")
                } else {
                    Label("Reset playback preferences", systemImage: "arrow.counterclockwise")
                }
            }
            .disabled(resetPlaybackPrefs)
            // Reset silently throws away remembered choices, so confirm first.
            .confirmationDialog(
                "Reset playback preferences?",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    // Clears speed + subtitle/audio-language keys (single source of truth in
                    // PlaybackController). Deliberately leaves quality/up-next/download defaults
                    // alone because their Settings controls own them.
                    let defaults = UserDefaults.standard
                    for key in PlaybackController.persistedPreferenceKeys {
                        defaults.removeObject(forKey: key)
                    }
                    resetPlaybackPrefs = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the remembered playback speed, video fit/fill mode, and subtitle/audio language. Quality, Up Next, skip, and download defaults are unaffected.")
            }

            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Label("Sign Out of \(appModel.activeBackend.displayName)", systemImage: "rectangle.portrait.and.arrow.right")
            }
            // Sign-out is genuinely disruptive, so the destructive action gets
            // a backend-specific confirmation (#26/#37).
            .confirmationDialog(
                "Sign out of \(appModel.activeBackend.displayName)?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    signOutAndHandoffIfNeeded()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(signOutConfirmationMessage)
            }
        }
    }

    private func signOutAndHandoffIfNeeded() {
        authManager.signOut()
        handoffRequiredSignInToMainWindow()
    }

    private func handoffRequiredSignInToMainWindow() {
        #if os(macOS)
        dismiss()
        Task { @MainActor in
            // Let SwiftUI apply the dismissal before asking AppKit to foreground the
            // main window. This avoids the Settings window staying key while the
            // sign-in screen is already visible behind it.
            await Task.yield()
            MacSettingsSignInHandoff.focusMainWindow()
        }
        #endif
    }
}

#if os(macOS)
private enum MacSettingsSignInHandoff {
    @MainActor
    static func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow = NSApp.windows.first(where: { window in
            window.isVisible &&
            window.canBecomeKey &&
            !window.isMiniaturized &&
            !window.title.localizedCaseInsensitiveContains("settings")
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })?
            .makeKeyAndOrderFront(nil)
    }
}
#endif
