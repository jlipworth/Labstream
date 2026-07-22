#if !os(tvOS)
import SwiftUI
import PMSKit

/// Probe-first download sheet (offline-download redesign). On appear it checks whether the
/// selected source can be downloaded directly *and* asks the server for its real optimizer
/// presets. Optimizer presets are always shown: a source file may stream/direct-play but still be
/// an offline-unplayable container (for example MKV), so "Original" is only an optional extra.
/// Both routes converge on the same background-`URLSession` + validation pipeline.
struct DownloadOptionsSheet: View {
    let item: MediaItem
    var mediaIndex: Int = 0
    var partIndex: Int = 0
    var audioStreamIndexOverride: Int? = nil
    var backend: DownloadBackendKind? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(PlaybackPreferences.Keys.defaultDownloadQuality) private var defaultDownloadQuality = PlaybackPreferences.defaultDownloadQuality

    private typealias OriginalOption = DownloadOptionsModel.OriginalOption
    private typealias CompatibleRemuxOption = DownloadOptionsModel.CompatibleRemuxOption
    private typealias DownloadSelection = DownloadOptionsModel.Selection

    @State private var optionsModel = DownloadOptionsModel()
    @State private var retryingExistingDownload = false
    @State private var isStartingDownload = false
    @State private var confirmingExistingDownloadRemoval = false
    @State private var confirmingCompatibleRemuxFallback = false

    private var probeState: DownloadOptionsModel.ProbeState {
        get { optionsModel.probeState }
        nonmutating set { optionsModel.probeState = newValue }
    }
    private var selectedChoice: DownloadSelection? {
        get { optionsModel.selection }
        nonmutating set { optionsModel.selection = newValue }
    }

    private var sheetBackend: DownloadBackendKind {
        backend ?? appModel.activeBackend
    }

    private var selectedDownloadAudioTrack: DownloadAudioTrackSelection? {
        let selection = DownloadMediaSelectionPolicy.selection(item: item,
                                                               mediaIndex: mediaIndex,
                                                               partIndex: partIndex)
        return DownloadAudioSelectionPolicy.selectedAudioTrack(
            part: selection.part,
            overrideStreamIndex: audioStreamIndexOverride)
    }

    private var selectedDownloadAudioStreamIndex: Int? {
        selectedDownloadAudioTrack?.streamIndex
    }

    private var serverPreparedAudioCaption: String? {
        guard sheetBackend == .jellyfin || sheetBackend == .emby,
              let track = selectedDownloadAudioTrack else { return nil }
        return "Audio: \(track.displayName)"
    }

    private func serverPreparedSubtitle(_ subtitle: String?) -> String? {
        guard let serverPreparedAudioCaption else { return subtitle }
        guard let subtitle, !subtitle.isEmpty else { return serverPreparedAudioCaption }
        return "\(subtitle)\n\(serverPreparedAudioCaption)"
    }

    private var existingRecord: DownloadRecord? {
        let key = DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: sheetBackend)
        return downloadManager.records.first { $0.ratingKey == key }
    }

    var body: some View {
        Group {
            #if os(macOS)
            macDialog
            #else
            formDialog
            #endif
        }
        .task { await runProbe() }
        .confirmationDialog(existingDownloadRemovalTitle,
                            isPresented: $confirmingExistingDownloadRemoval,
                            titleVisibility: .visible) {
            Button(existingDownloadRemovalActionTitle, role: .destructive) {
                deleteExistingDownload()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(existingDownloadRemovalMessage)
        }
        .confirmationDialog(DownloadCompatibleRemuxDisclosurePolicy.confirmationTitle,
                            isPresented: $confirmingCompatibleRemuxFallback,
                            titleVisibility: .visible) {
            Button("Continue with fallback") { startDownload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DownloadCompatibleRemuxDisclosurePolicy.confirmationMessage)
        }
    }

    private var formDialog: some View {
        NavigationStack {
            Form {
                if let record = existingRecord {
                    existingSection(record)
                } else {
                    switch probeState {
                    case .checking:
                        SwiftUI.Section { Label("Checking compatibility…", systemImage: "wifi") }
                    case let .ready(original, compatibleRemux, presets, probeFailed, unsupportedOriginal, existingVersions):
                        if let original {
                            directSection(option: original)
                        }
                        if let compatibleRemux {
                            compatibleRemuxSection(option: compatibleRemux)
                        }
                        if unsupportedOriginal, compatibleRemux == nil {
                            originalUnsupportedSection
                        }
                        if let plexOriginalPreset = plexOriginalOptimizePreset(in: presets) {
                            plexOriginalQualitySection(preset: plexOriginalPreset)
                        }
                        optimizeSection(presets: optimizePresetsExcludingPlexOriginal(presets),
                                        allPresets: presets,
                                        probeFailed: probeFailed,
                                        originalAvailable: original != nil)
                        // #112: existing server versions go BELOW the quality presets as a distinct section.
                        if !existingVersions.isEmpty {
                            existingVersionsSection(existingVersions)
                        }
                        storageLimitSection
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
                        Button("Download") { requestStartDownload() }
                            .disabled(isStartingDownload || selectedChoice == nil || selectedStorageLimitMessage != nil)
                    }
                }
            }
        }
    }

    #if os(macOS)
    private var macDialog: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Download")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    macDialogContent
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 360, maxHeight: 520)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if existingRecord == nil, probeState != .checking {
                    Button("Download") { requestStartDownload() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStartingDownload || selectedChoice == nil || selectedStorageLimitMessage != nil)
                }
            }
            .padding(24)
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var macDialogContent: some View {
        if let record = existingRecord {
            macExistingContent(record)
        } else {
            switch probeState {
            case .checking:
                macInfoSection(systemImage: "wifi",
                               title: nil,
                               message: "Checking compatibility…")
            case let .ready(original, compatibleRemux, presets, probeFailed, unsupportedOriginal, existingVersions):
                if let original {
                    macSelectionSection(
                        title: "Original",
                        footer: "Downloads the raw source file without server conversion. This is the most resumable route when the server supports byte ranges."
                    ) {
                        macSelectionRow(title: "Download original",
                                        subtitle: directDetail(sizeBytes: original.sizeBytes, resolution: original.resolution),
                                        systemImage: "checkmark.seal",
                                        selected: selectedChoice == .original) {
                            selectedChoice = .original
                        }
                    }
                }
                if let compatibleRemux {
                    macSelectionSection(
                        title: "Original quality",
                        footer: compatibleRemuxFooter
                    ) {
                        macSelectionRow(title: "Original quality (compatible)",
                                        subtitle: compatibleRemuxSubtitle(option: compatibleRemux),
                                        systemImage: "wand.and.stars",
                                        selected: selectedChoice == .optimizeCompatible) {
                            selectedChoice = .optimizeCompatible
                        }
                    }
                }
                if unsupportedOriginal, compatibleRemux == nil {
                    macInfoSection(systemImage: "info.circle",
                                   title: nil,
                                   message: "The original can stream, but its file container may not play as a raw offline local file here. Original quality is not available for this item/server response, so pick a bitrate preset to create a compatible offline copy.")
                }
                if let plexOriginalPreset = plexOriginalOptimizePreset(in: presets) {
                    macSelectionSection(
                        title: "Original quality",
                        footer: "Creates a compatible offline copy at Plex's original video quality. Plex may prepare the file on the server before downloading."
                    ) {
                        macSelectionRow(title: "Original video quality",
                                        subtitle: "Keeps the source quality in a compatible Plex-prepared copy",
                                        systemImage: "wand.and.stars",
                                        selected: selectedChoice == .plexOriginalQuality(plexOriginalPreset)) {
                            selectedChoice = .plexOriginalQuality(plexOriginalPreset)
                        }
                    }
                }
                macOptimizeSection(presets: optimizePresetsExcludingPlexOriginal(presets),
                                   allPresets: presets,
                                   probeFailed: probeFailed,
                                   originalAvailable: original != nil)
                if !existingVersions.isEmpty {
                    macExistingVersionsSection(existingVersions)
                }
                if let message = selectedStorageLimitMessage {
                    macInfoSection(systemImage: "internaldrive.fill.badge.exclamationmark",
                                   title: nil,
                                   message: message)
                }
                macInfoSection(systemImage: "wifi",
                               title: nil,
                               message: "Transfers can continue in the background, but the system may pause them while the app is backgrounded or the device sleeps.")
            }
        }
    }

    @ViewBuilder
    private func macExistingContent(_ record: DownloadRecord) -> some View {
        macSelectionSection(title: "Current download", footer: nil) {
            let statusText: String = {
                if record.isComplete { return record.isUnverified ? "Downloaded; playback not verified" : "Downloaded for offline viewing" }
                if record.status == .failed { return "Download failed" }
                if record.status == .paused { return "Download paused" }
                if record.status == .preparing { return "Preparing on server…" }
                return "Download already exists"
            }()
            Label(statusText, systemImage: record.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.body.weight(.medium))
            if record.bytes > 0 {
                Text(DownloadStorageLimitPolicy.byteString(record.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.status == .failed || record.status == .paused {
                Button(record.status == .failed ? "Retry Download" : "Resume Download") {
                    guard !retryingExistingDownload else { return }
                    retryingExistingDownload = true
                    retryDownload()
                    dismiss()
                }
                .disabled(retryingExistingDownload)
            }
            Button("Remove Download", role: .destructive) {
                confirmingExistingDownloadRemoval = true
            }
        }
    }

    @ViewBuilder
    private func macOptimizeSection(presets: [String], allPresets: [String], probeFailed: Bool,
                                    originalAvailable: Bool) -> some View {
        macSelectionSection(
            title: optimizeSectionTitle,
            footer: probeFailed
                ? "Couldn't check compatibility, so Labstream will ask the server for a compatible offline version. Server work can take a while and may require retry if interrupted."
                : originalAvailable
                    ? "The server prepares a bitrate-capped compatible copy. This can take a while and can continue from checkpoints when the server provides a static file; live streams may require retry if interrupted."
                    : "The server prepares a compatible offline version. This can take a while and can continue from checkpoints when the server provides a static file; live streams may require retry if interrupted."
        ) {
            ForEach(presets, id: \.self) { preset in
                macSelectionRow(title: preset,
                                subtitle: serverPreparedAudioCaption,
                                systemImage: "gauge.with.dots.needle.bottom.50percent",
                                selected: selectedChoice == .optimize(preset)) {
                    selectedChoice = .optimize(preset)
                }
            }
        }
        .onAppear {
            if selectedChoice == .original, originalAvailable { return }
            if selectedChoice == .optimizeCompatible { return }
            if case .plexOriginalQuality = selectedChoice { return }
            if case .existingVersion = selectedChoice { return }
            if case .embyExistingVersion = selectedChoice { return }
            if case .optimize(let selected)? = selectedChoice, allPresets.contains(selected) { return }
            selectedChoice = preferredSelection(originalAvailable: originalAvailable,
                                                compatibleRemuxAvailable: false,
                                                presets: allPresets)
        }
    }

    @ViewBuilder
    private func macExistingVersionsSection(_ versions: [DownloadExistingVersionOption]) -> some View {
        macSelectionSection(
            title: "Existing server versions",
            footer: "Downloads a version your server already has, exactly as-is — no new conversion is started and the server's existing copy is left in place."
        ) {
            ForEach(versions) { version in
                let selection = selection(forExistingVersion: version)
                macSelectionRow(title: version.label,
                                subtitle: version.playableOffline ? version.detail : "Won't play offline on this device",
                                systemImage: "rectangle.stack.badge.play",
                                selected: version.playableOffline && selectedChoice == selection,
                                disabled: !version.playableOffline) {
                    selectedChoice = selection
                }
            }
        }
    }

    private func macSelectionSection<Content: View>(title: String,
                                                    footer: String?,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 8) {
                content()
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func macSelectionRow(title: String,
                                 subtitle: String?,
                                 systemImage: String,
                                 selected: Bool,
                                 disabled: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func macInfoSection(systemImage: String, title: String?, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    #endif

    // MARK: - Probe

    private func runProbe() async {
        guard existingRecord == nil else { return }
        let result = await DownloadItemPlanner(appModel: appModel, downloadManager: downloadManager)
            .options(for: item,
                     mediaIndex: mediaIndex,
                     partIndex: partIndex,
                     audioStreamIndexOverride: audioStreamIndexOverride,
                     preferredAudioLanguage: UserDefaults.standard.string(
                        forKey: PlaybackPreferences.Keys.preferredAudioLanguage),
                     backend: sheetBackend)
        let original = result.original.map {
            OriginalOption(sizeBytes: $0.sizeBytes, resolution: $0.resolution)
        }
        let compatible = result.compatibleRemux.map {
            CompatibleRemuxOption(codecSummary: $0.codecSummary)
        }
        selectedChoice = preferredSelection(originalAvailable: original != nil,
                                            compatibleRemuxAvailable: compatible != nil,
                                            presets: result.presets)
        probeState = .ready(
            original: original,
            compatibleRemux: compatible,
            presets: result.presets,
            probeFailed: result.probeFailed,
            originalStreamableButOfflineUnsupported: result.originalStreamableButOfflineUnsupported,
            existingVersions: result.existingVersions)
    }

    private func plexOriginalOptimizePreset(in presets: [String]) -> String? {
        guard sheetBackend == .plex else { return nil }
        return DownloadPresetPolicy.plexOriginalQualityPreset(in: presets)
    }

    private func optimizePresetsExcludingPlexOriginal(_ presets: [String]) -> [String] {
        guard sheetBackend == .plex else { return presets }
        return DownloadPresetPolicy.presetsExcludingPlexOriginalQuality(presets)
    }

    // MARK: - Sections

    @ViewBuilder
    private func directSection(option: OriginalOption) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .original
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download original").foregroundStyle(.primary)
                        Text(directDetail(sizeBytes: option.sizeBytes, resolution: option.resolution))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .original {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original")
        } footer: {
            Text("Downloads the raw source file without server conversion. This is the most resumable route when the server supports byte ranges.")
        }
    }

    @ViewBuilder
    private func compatibleRemuxSection(option: CompatibleRemuxOption) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .optimizeCompatible
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original quality (compatible)").foregroundStyle(.primary)
                        Text(compatibleRemuxSubtitle(option: option) ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .optimizeCompatible {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original quality")
        } footer: {
            Label {
                Text(compatibleRemuxFooter)
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    private var originalUnsupportedSection: some View {
        SwiftUI.Section {
            Label {
                Text("The original can stream, but its file container may not play as a raw offline local file here. Original quality is not available for this item/server response, so pick a bitrate preset to create a compatible offline copy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    private func directDetail(sizeBytes: Int?, resolution: String?) -> String {
        var parts: [String] = []
        if let sizeBytes, sizeBytes > 0 {
            parts.append(DownloadStorageLimitPolicy.byteString(sizeBytes))
        }
        if let resolution { parts.append(resolution) }
        return parts.isEmpty ? "Original file" : parts.joined(separator: " · ")
    }

    private func compatibleRemuxSubtitle(option: CompatibleRemuxOption) -> String? {
        var lines = [option.codecSummary ?? "Keeps original video, converts to a compatible MP4"]
        if DownloadCompatibleRemuxDisclosurePolicy.showsFallbackDisclosure(backend: sheetBackend) {
            lines.append(DownloadCompatibleRemuxDisclosurePolicy.fallbackCaption)
        }
        return serverPreparedSubtitle(lines.joined(separator: "\n"))
    }

    private var compatibleRemuxFooter: String {
        var text = "Keeps original video quality by copying/remuxing into a compatible MP4 (audio is converted only if needed). This uses a live server remux, not a prebuilt offline copy; it can be slower and may restart from the beginning if interrupted."
        if DownloadCompatibleRemuxDisclosurePolicy.showsFallbackDisclosure(backend: sheetBackend) {
            text += " " + DownloadCompatibleRemuxDisclosurePolicy.fallbackCaption
        }
        return text
    }


    @ViewBuilder
    private func plexOriginalQualitySection(preset: String) -> some View {
        SwiftUI.Section {
            Button {
                selectedChoice = .plexOriginalQuality(preset)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original video quality").foregroundStyle(.primary)
                        Text("Keeps the source quality in a compatible Plex-prepared copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChoice == .plexOriginalQuality(preset) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Original quality")
        } footer: {
            Label {
                Text("Creates a compatible offline copy at Plex's original video quality. Plex may prepare the file on the server before downloading.")
            } icon: {
                Image(systemName: "info.circle")
            }
        }
    }

    @ViewBuilder
    private func optimizeSection(presets: [String], allPresets: [String], probeFailed: Bool,
                                 originalAvailable: Bool) -> some View {
        SwiftUI.Section {
            ForEach(presets, id: \.self) { preset in
                Button {
                    selectedChoice = .optimize(preset)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset).foregroundStyle(.primary)
                            if let serverPreparedAudioCaption {
                                Text(serverPreparedAudioCaption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selectedChoice == .optimize(preset) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(optimizeSectionTitle)
        } footer: {
            Label {
                Text(probeFailed
                     ? "Couldn't check compatibility, so Labstream will ask the server for a compatible offline version. Server work can take a while and may require retry if interrupted."
                     : originalAvailable
                        ? "The server prepares a bitrate-capped compatible copy. This can take a while and can continue from checkpoints when the server provides a static file; live streams may require retry if interrupted."
                        : "The server prepares a compatible offline version. This can take a while and can continue from checkpoints when the server provides a static file; live streams may require retry if interrupted.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .onAppear {
            if selectedChoice == .original, originalAvailable {
                return
            }
            // Original-quality helper selections are self-contained (not in this preset list); leave
            // them intact.
            if selectedChoice == .optimizeCompatible { return }
            if case .plexOriginalQuality = selectedChoice { return }
            // #112/#126: an explicit existing-version pick is self-contained; never clobber it.
            if case .existingVersion = selectedChoice { return }
            if case .embyExistingVersion = selectedChoice { return }
            if case .optimize(let selected)? = selectedChoice, allPresets.contains(selected) {
                return
            }
            selectedChoice = preferredSelection(originalAvailable: originalAvailable,
                                                compatibleRemuxAvailable: false, presets: allPresets)
        }
    }

    private var optimizeSectionTitle: String {
        switch sheetBackend {
        case .plex:
            "Optimize on server"
        case .jellyfin, .emby:
            "Convert on server"
        }
    }

    @ViewBuilder
    private func existingVersionsSection(_ versions: [DownloadExistingVersionOption]) -> some View {
        SwiftUI.Section {
            ForEach(versions) { version in
                let selection = selection(forExistingVersion: version)
                Button {
                    selectedChoice = selection
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.badge.play")
                            .foregroundStyle(version.playableOffline ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.label)
                                .foregroundStyle(version.playableOffline ? .primary : .secondary)
                            if let detail = version.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !version.playableOffline {
                                Text("Won't play offline on this device")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if version.playableOffline, selectedChoice == selection {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!version.playableOffline)
            }
        } header: {
            Text("Existing server versions")
        } footer: {
            Text("Downloads a version your server already has, exactly as-is — no new conversion is started and the server's existing copy is left in place.")
        }
    }

    private var infoSection: some View {
        SwiftUI.Section {
            Label {
                Text("Transfers can continue in the background, but the system may pause "
                     + "them while the app is backgrounded or the device sleeps.")
                    .font(.footnote).foregroundStyle(.secondary)
            } icon: { Image(systemName: "wifi") }
        }
    }


    @ViewBuilder
    private var storageLimitSection: some View {
        if let message = selectedStorageLimitMessage {
            SwiftUI.Section {
                Label {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "internaldrive.fill.badge.exclamationmark")
                }
            }
        }
    }

    private var selectedStorageLimitMessage: String? {
        guard let resolvedSelection else { return nil }
        // #126: an Emby existing version is addressed by MediaSource id, not a `Media` index, so the
        // estimator can't size it — use the converted source's own reported size for the pre-check.
        let addedBytes: Int?
        switch resolvedSelection.sizing {
        case .reported(let sizeBytes):
            addedBytes = sizeBytes
        case .estimateFromMedia:
            addedBytes = downloadManager.estimatedBytes(
                for: item, choice: resolvedSelection.intent.choice,
                mediaIndex: resolvedSelection.mediaIndex,
                partIndex: resolvedSelection.partIndex)
        }
        return downloadManager.storageLimitMessage(adding: addedBytes)
    }

    private var resolvedSelection: DownloadOptionsModel.ResolvedSelection? {
        optionsModel.resolvedSelection(baseMediaIndex: mediaIndex, basePartIndex: partIndex,
                                       audioStreamIndex: selectedDownloadAudioStreamIndex)
    }

    private func selection(forExistingVersion option: DownloadExistingVersionOption) -> DownloadSelection {
        switch option.target {
        case .plexMediaIndex(let index):
            return .existingVersion(index)
        case .embyMediaSource(let id, let sizeBytes):
            return .embyExistingVersion(mediaSourceId: id, sizeBytes: sizeBytes)
        }
    }

    private func preferredSelection(originalAvailable: Bool,
                                    compatibleRemuxAvailable: Bool,
                                    presets: [String]) -> DownloadSelection? {
        DownloadPresetPolicy.preferredPickerChoice(originalAvailable: originalAvailable,
                                                   compatibleRemuxAvailable: compatibleRemuxAvailable,
                                                   presets: presets,
                                                   backend: sheetBackend,
                                                   defaultDownloadQuality: defaultDownloadQuality)
            .map(selection(for:))
    }

    private func selection(for intent: DownloadIntentChoice) -> DownloadSelection {
        switch intent {
        case .original:
            return .original
        case .optimizeCompatible:
            return .optimizeCompatible
        case .existingVersion:
            return .existingVersion(mediaIndex)
        case .optimize(let targetName):
            if sheetBackend == .plex, DownloadPresetPolicy.isPlexOriginalQualityTarget(targetName) {
                return .plexOriginalQuality(targetName)
            }
            return .optimize(targetName)
        }
    }

    // MARK: - Already-downloaded state

    @ViewBuilder
    private func existingSection(_ record: DownloadRecord) -> some View {
        let isComplete = record.isComplete
        let isFailed = record.status == .failed
        let isPaused = record.status == .paused
        let isPreparing = record.status == .preparing
        SwiftUI.Section {
            if isComplete {
                if record.isUnverified {
                    Label("Downloaded; playback not verified", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Label("Downloaded for offline viewing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(DownloadStorageLimitPolicy.byteString(record.bytes))
                    .font(.caption).foregroundStyle(.secondary)
            } else if isFailed {
                Label("Download failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                existingDownloadActionButton(title: "Retry Download",
                                             systemImage: "arrow.clockwise") {
                    guard !retryingExistingDownload else { return }
                    retryingExistingDownload = true
                    retryDownload()
                    dismiss()
                }
                .disabled(retryingExistingDownload)
            } else if isPaused {
                Label("Download paused", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                let displayBytes = existingDownloadDisplayBytes(for: record)
                if displayBytes > 0 {
                    Text(DownloadStorageLimitPolicy.byteString(displayBytes))
                        .font(.caption).foregroundStyle(.secondary)
                }
                existingDownloadActionButton(title: "Resume Download",
                                             systemImage: "play.circle") {
                    guard !retryingExistingDownload else { return }
                    retryingExistingDownload = true
                    retryDownload()
                    dismiss()
                }
                .disabled(retryingExistingDownload)
            } else if isPreparing {
                // Emby convert-then-download: the server is rendering the file before any byte
                // download begins. Surface it as an indeterminate "Preparing on server…" with the
                // live convert percentage when known (same plumbing as the offline-list row).
                Label("Preparing on server…", systemImage: "gearshape.arrow.triangle.2.circlepath")
                if let p = downloadManager.optimizeProgress[record.ratingKey] {
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } else {
                Label(existingDownloadPhaseLabel(for: record), systemImage: "arrow.down.circle")
                if let fraction = downloadManager.displayFraction(for: record) {
                    ProgressView(value: fraction.value)
                    Text(existingDownloadProgressText(fraction: fraction,
                                                      bytes: existingDownloadDisplayBytes(for: record),
                                                      resolution: record.metadata?.resolutionLabel))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    let displayBytes = existingDownloadDisplayBytes(for: record)
                    if displayBytes > 0 {
                        Text(DownloadStorageLimitPolicy.byteString(displayBytes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                existingDownloadActionButton(title: "Pause Download",
                                             systemImage: "pause.circle") {
                    downloadManager.pause(ratingKey: DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: sheetBackend))
                    dismiss()
                }
            }
            if let bitrate = DownloadRowDisplayPolicy.downloadQualityText(for: record) {
                Text(bitrate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                confirmingExistingDownloadRemoval = true
            } label: {
                Label(isComplete ? "Remove Download" : "Cancel Download", systemImage: "trash")
            }
        }
    }

    private func existingDownloadDisplayBytes(for record: DownloadRecord) -> Int {
        let fraction = downloadManager.displayFraction(for: record)
        let expected = record.metadata?.sourcePartSize
        let fractionBytes = fraction.flatMap { fraction -> Int? in
            guard let expected, expected > 0 else { return nil }
            return Int((fraction.value * Double(expected)).rounded(.down))
        }
        return max(record.bytes,
                   record.metadata?.resumeDisplayBytes ?? 0,
                   fractionBytes ?? 0)
    }

    private func existingDownloadProgressText(fraction: DownloadProgressDisplay.Fraction,
                                              bytes: Int,
                                              resolution: String?) -> String {
        var pieces = [DownloadRowDisplayPolicy.percentText(fraction)]
        if bytes > 0 {
            pieces.append(DownloadStorageLimitPolicy.byteString(bytes))
        }
        if let resolution, !resolution.isEmpty {
            pieces.append(resolution)
        }
        return pieces.joined(separator: " • ")
    }

    // MARK: - Action


    /// Existing-download actions live inside a Form section, where default Button styling can
    /// render accent-colored rows with subtly different glyph/text sizing across states. Keep
    /// Retry/Resume/Pause visually identical and let the surrounding Form provide the row affordance.
    private func existingDownloadActionButton(title: String,
                                              systemImage: String,
                                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .imageScale(.medium)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func existingDownloadPhaseLabel(for record: DownloadRecord) -> String {
        DownloadRowStatusCaptionPolicy.compactActiveCaption(
            lane: record.metadata?.resolvedDownloadLane() ?? .original,
            backend: record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey),
            isServerPreparedVersion: record.metadata?.isServerPreparedVersion == true)
    }

    private var existingDownloadRemovalTitle: String {
        existingRecord?.isComplete == true ? "Remove downloaded file?" : "Cancel this download?"
    }

    private var existingDownloadRemovalActionTitle: String {
        existingRecord?.isComplete == true ? "Remove Download" : "Cancel Download"
    }

    private var existingDownloadRemovalMessage: String {
        if existingRecord?.isComplete == true {
            return "This removes the offline copy from this device. You can download it again later."
        }
        return "This stops the transfer and removes any partial file from this device."
    }

    private func deleteExistingDownload() {
        downloadManager.delete(ratingKey: DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: sheetBackend))
    }

    private func retryDownload() {
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex retry path (which would mis-key and no-op for Emby).
        switch sheetBackend {
        case .plex:
            downloadManager.retry(ratingKey: item.ratingKey)
        case .jellyfin:
            downloadManager.retry(ratingKey: DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: sheetBackend))
        case .emby:
            // Re-run the full Emby lane, which re-probes PlaybackInfo and re-decides original vs
            // transcode (a now-compatible file goes original). `.original` is intent-only here.
            downloadManager.retry(ratingKey: DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: sheetBackend))
        }
    }

    private func requestStartDownload() {
        guard !isStartingDownload, existingRecord == nil, selectedChoice != nil else { return }
        if selectedChoice == .optimizeCompatible {
            let source = DownloadMediaSelectionPolicy.selection(
                item: item, mediaIndex: mediaIndex, partIndex: partIndex).media
            if DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
                backend: sheetBackend, sourceWidth: source?.width, sourceHeight: source?.height) {
                confirmingCompatibleRemuxFallback = true
                return
            }
        }
        startDownload()
    }

    private func startDownload() {
        guard !isStartingDownload, existingRecord == nil, let resolvedSelection else { return }
        isStartingDownload = true
        let intent = resolvedSelection.intent
        let choice = intent.choice
        let audioStreamIndex = intent.audioStreamIndex
        // #112: an existing-version pick downloads from THAT version's `Media` index (part 0), not
        // the selected source index. Every other choice resolves to the sheet's media/part index.
        let downloadMediaIndex = resolvedSelection.mediaIndex
        let downloadPartIndex = resolvedSelection.partIndex
        // Exhaustive over the backend so a new lane is a compile error here, not a silent
        // fall-through into the Plex download path (which fails quietly on nil Plex creds).
        switch sheetBackend {
        case .plex:
            Task { await downloadManager.download(item, choice: choice,
                                                  mediaIndex: downloadMediaIndex, partIndex: downloadPartIndex,
                                                  audioStreamIndex: audioStreamIndex) }
        case .jellyfin:
            Task { await downloadManager.downloadJellyfin(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex,
                                                          audioStreamIndex: audioStreamIndex) }
        case .emby:
            // #126: an existing-version pick addresses a specific converted MediaSource by id; pass
            // it as the override so the lane downloads THAT copy byte-for-byte (no new conversion).
            if let mediaSourceId = resolvedSelection.mediaSourceIDOverride {
                Task { await downloadManager.downloadEmby(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex,
                                                          audioStreamIndex: audioStreamIndex,
                                                          mediaSourceIDOverride: mediaSourceId) }
            } else {
                Task { await downloadManager.downloadEmby(item, choice: choice,
                                                          mediaIndex: downloadMediaIndex,
                                                          partIndex: downloadPartIndex,
                                                          audioStreamIndex: audioStreamIndex) }
            }
        }
        dismiss()
    }
}
#endif
