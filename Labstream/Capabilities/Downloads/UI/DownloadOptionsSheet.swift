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
    @State private var isStartingDownload = false
    @State private var confirmingExistingDownloadRemoval = false
    @State private var pendingExistingRemoval: DownloadOptionsModel.RemovalConfirmation?
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
            sharedExistingContent(record)
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
            DownloadOptionContent(title: title, detail: subtitle, systemImage: systemImage,
                                  selected: selected, disabled: disabled)
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
                     preferredAudioRole: UserDefaults.standard.string(
                        forKey: PlaybackPreferences.Keys.preferredAudioRole)
                        .flatMap(AudioStreamRole.init(rawValue:)) ?? .main,
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
                DownloadOptionContent(title: "Download original",
                    detail: directDetail(sizeBytes: option.sizeBytes, resolution: option.resolution),
                    systemImage: "checkmark.seal", selected: selectedChoice == .original)
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
                DownloadOptionContent(title: "Original quality (compatible)",
                    detail: compatibleRemuxSubtitle(option: option), systemImage: "wand.and.stars",
                    selected: selectedChoice == .optimizeCompatible)
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
                DownloadOptionContent(title: "Original video quality",
                    detail: "Keeps the source quality in a compatible Plex-prepared copy",
                    systemImage: "wand.and.stars", selected: selectedChoice == .plexOriginalQuality(preset))
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
                    DownloadOptionContent(title: preset, detail: serverPreparedAudioCaption,
                        systemImage: "gauge.with.dots.needle.bottom.50percent",
                        selected: selectedChoice == .optimize(preset))
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
                    DownloadOptionContent(title: version.label,
                        detail: version.playableOffline ? version.detail : "Won't play offline on this device",
                        systemImage: "rectangle.stack.badge.play",
                        selected: version.playableOffline && selectedChoice == selection,
                        disabled: !version.playableOffline)
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
        // pu-13 (P5): an unknown size is said, not silently counted as zero.
        guard let addedBytes else {
            return "Size unknown — this download is not counted toward the storage limit."
        }
        return downloadManager.storageLimitMessage(
            adding: addedBytes,
            replacingRatingKey: DownloadRecordIdentity.recordKey(for: item.ratingKey,
                                                                 backend: sheetBackend))
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
        SwiftUI.Section { sharedExistingContent(record) }
    }

    /// Both native wrappers render the library's live value, including waiting, server indexing,
    /// verification, error detail and exact action identity.
    @ViewBuilder
    private func sharedExistingContent(_ record: DownloadRecord) -> some View {
        let row = DownloadOptionsModel.existingRow(record, library: downloadManager.offlineLibrarySnapshot)
        let presentation = Self.existingPresentation(record, library: downloadManager.offlineLibrarySnapshot,
                                                     phase: downloadManager.rowPhase(for: row))
        DownloadRowContent(presentation: presentation)
        ForEach(presentation.actions.filter { $0 != .play }, id: \.rawValue) { action in
            if action == .delete {
                Button(role: .destructive) {
                    pendingExistingRemoval = .init(record: record)
                    confirmingExistingDownloadRemoval = true
                } label: { Label("Remove Download", systemImage: "trash") }
                .accessibilityLabel(presentation.actionLabel(.delete))
                .accessibilityIdentifier("download.delete")
                .disabled(downloadManager.startupRecoveryState != .ready)
            } else {
                Button {
                    switch action {
                    case .pause: downloadManager.pause(presentation.actionIdentity)
                    case .resume, .retry: downloadManager.retry(presentation.actionIdentity)
                    case .play, .delete: break
                    }
                    dismiss()
                } label: {
                    Label(action == .pause ? "Pause Download" : action == .resume ? "Resume Download" : "Retry Download",
                          systemImage: action == .pause ? "pause.circle" : action == .resume ? "play.circle" : "arrow.clockwise")
                }
                .foregroundStyle(.tint)
                .accessibilityLabel(presentation.actionLabel(action))
                .accessibilityIdentifier("download.\(action.rawValue)")
                .disabled(downloadManager.startupRecoveryState != .ready)
            }
        }
    }

    static func existingPresentation(_ record: DownloadRecord,
                                     library: OfflineLibrarySnapshot,
                                     phase: DownloadJobPhase? = nil) -> DownloadRowPresentation {
        DownloadRowPresentation(row: DownloadOptionsModel.existingRow(record, library: library), phase: phase)
    }

    private var existingDownloadRemovalTitle: String {
        pendingExistingRemoval?.title ?? "Remove download?"
    }
    private var existingDownloadRemovalActionTitle: String {
        pendingExistingRemoval?.actionTitle ?? "Remove Download"
    }
    private var existingDownloadRemovalMessage: String {
        pendingExistingRemoval?.message ?? Self.removalMessage(for: nil)
    }
    static func removalMessage(for record: DownloadRecord?) -> String {
        DownloadRemovalMessage.message(cancelsServerPrep: DownloadDeletePolicy.deletionCancelsServerPrep(record))
    }
    private func deleteExistingDownload() {
        guard let confirmation = pendingExistingRemoval else { return }
        Self.deleteExistingDownload(identity: confirmation.identity, manager: downloadManager)
        pendingExistingRemoval = nil
    }
    static func deleteExistingDownload(identity: OfflineDownloadRowActionIdentity, manager: DownloadManager) {
        manager.delete(identity)
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
        // P4: a tap goes through admission. It starts at once when a lane has room; otherwise it
        // waits as a durable planned row. #126: an Emby existing-version pick passes its
        // MediaSource id so the lane downloads THAT copy byte-for-byte.
        Task {
            await downloadManager.requestDownload(
                item, backend: sheetBackend, choice: choice,
                mediaIndex: downloadMediaIndex, partIndex: downloadPartIndex,
                audioStreamIndex: audioStreamIndex,
                mediaSourceIDOverride: sheetBackend == .emby
                    ? resolvedSelection.mediaSourceIDOverride : nil)
        }
        dismiss()
    }
}
#endif
