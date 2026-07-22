#if !os(tvOS)
import SwiftUI
import PMSKit

/// One-time per-season planner. The durable Offline rows are the only queue/source of truth; this
/// sheet disappears after committing and deliberately retains no season job or rolling policy.
struct SeasonDownloadPlannerSheet: View {
    let season: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var episodes: [MediaItem] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var scope: SeasonDownloadEpisodeScope = .all
    @State private var selectedQuality = DownloadPresetPolicy.compatibleOriginalQualityName
    @State private var resolving = false
    @State private var resolvedOptions: [DownloadItemPlanningOptions] = []
    @State private var useExistingVersions = false
    @State private var showingConfirmation = false
    @State private var commitError: String?

    private var backend: DownloadBackendKind { appModel.activeBackend.downloadBackendKind }
    private var watchedSummary: SeasonDownloadSelectionSummary {
        SeasonDownloadSelectionPolicy.select(
            states: episodes.map { SeasonEpisodeWatchedState(viewCount: $0.viewCount, backend: backend) },
            scope: scope)
    }
    private var usableWatchedCount: Int {
        watchedSummary.watchedCount + watchedSummary.unwatchedCount
    }
    private var serverUnwatchedCount: Int {
        episodes.filter { SeasonEpisodeWatchedState(viewCount: $0.viewCount, backend: backend) == .unwatched }.count
    }
    private var qualityNames: [String] {
        let presets = backend == .plex
            ? DownloadPresetPolicy.visiblePresetNames(serverTargets: [])
            : DownloadPresetPolicy.bitratePresetNames
        return [DownloadPresetPolicy.compatibleOriginalQualityName]
            + presets.filter { !DownloadPresetPolicy.isPlexOriginalQualityTarget($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    SwiftUI.Section { ProgressView("Refreshing season watched state…") }
                } else if let loadError {
                    SwiftUI.Section {
                        ContentUnavailableView("Couldn’t refresh season", systemImage: "exclamationmark.triangle",
                                               description: Text(loadError))
                    }
                } else {
                    scopeSection
                    qualitySection
                    if resolving {
                        SwiftUI.Section { ProgressView("Planning each episode…") }
                    } else if !resolvedOptions.isEmpty {
                        existingVersionSection
                        summarySection
                    }
                    if let commitError {
                        SwiftUI.Section {
                            Label(commitError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Download Season")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if resolvedOptions.isEmpty {
                        Button("Review") { Task { await resolvePlan() } }
                            .disabled(loading || resolving || selectedEpisodeIndices.isEmpty)
                    } else {
                        Button("Download") { showingConfirmation = true }
                            .disabled(storageBlockMessage != nil || (newPlans.isEmpty && retryKeys.isEmpty))
                    }
                }
            }
        }
        .task { await refreshSeason() }
        .confirmationDialog("Start season downloads?", isPresented: $showingConfirmation,
                            titleVisibility: .visible) {
            Button("Add to Offline Queue") { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var scopeSection: some View {
        SwiftUI.Section("Episodes") {
            Picker("Episode scope", selection: $scope) {
                Text("All episodes — \(episodes.count)").tag(SeasonDownloadEpisodeScope.all)
                if usableWatchedCount > 0 {
                    Text("Unwatched episodes — \(serverUnwatchedCount)")
                        .tag(SeasonDownloadEpisodeScope.unwatched)
                }
            }
            .onChange(of: scope) { _, _ in resolvedOptions = [] }
            if watchedSummary.unavailableCount > 0 {
                Text("Watched state is unavailable for \(watchedSummary.unavailableCount) episode(s). "
                     + (scope == .unwatched ? "They will be skipped." : "All episodes still includes them."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if usableWatchedCount == 0 {
                Text("The server returned no usable watched state, so only All episodes is available.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySection: some View {
        SwiftUI.Section("Quality") {
            Picker("Desired quality", selection: $selectedQuality) {
                ForEach(qualityNames, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: selectedQuality) { _, _ in resolvedOptions = [] }
            Text("Quality is requested once, then each episode is resolved independently against its own source and backend response.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var existingVersionSection: some View {
        if nearestExistingSelections.values.contains(where: { $0 != nil }) {
            SwiftUI.Section("Existing server versions") {
                Picker("Prepared versions", selection: $useExistingVersions) {
                    Text("Create Selected Quality").tag(false)
                    Text("Use Existing Versions").tag(true)
                }
                Text("Existing versions use the nearest overall resolution and bitrate match. "
                     + "They are faster, but episode quality may vary.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        SwiftUI.Section("Plan") {
            LabeledContent("Selected", value: "\(selectedEpisodeIndices.count) episodes")
            if alreadyAvailableCount > 0 { LabeledContent("Already available", value: "\(alreadyAvailableCount)") }
            if alreadyPlannedCount > 0 { LabeledContent("Already planned", value: "\(alreadyPlannedCount)") }
            if pausedCount > 0 { LabeledContent("Paused (unchanged)", value: "\(pausedCount)") }
            if !retryKeys.isEmpty { LabeledContent("Failures to retry", value: "\(retryKeys.count)") }
            if unresolvedCount > 0 { LabeledContent("Unsupported rows", value: "\(unresolvedCount) failed") }
            if useExistingVersions {
                LabeledContent("Existing versions", value: "\(existingVersionCount)")
                LabeledContent("Selected-quality versions", value: "\(max(0, newPlans.count - existingVersionCount))")
                if !qualityRange.isEmpty { LabeledContent("Resolved range", value: qualityRange) }
            }
            LabeledContent("Additional storage", value: storageText)
            if let storageBlockMessage {
                Label(storageBlockMessage, systemImage: "internaldrive.fill.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
            Text("Rows are saved before any work starts. Admission is bounded by transfer lane; the Offline queue controls pause, retry, delete, recovery, and progress.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var selectedEpisodeIndices: [Int] { watchedSummary.selectedIndices }
    private var selectedOptions: [DownloadItemPlanningOptions] { resolvedOptions }

    private var rowActions: [String: SeasonDownloadExistingRowAction] {
        Dictionary(uniqueKeysWithValues: selectedOptions.map {
            ($0.item.ratingKey, downloadManager.seasonPlannerRowAction(
                itemID: $0.item.ratingKey, backend: backend))
        })
    }

    private var alreadyAvailableCount: Int { rowActions.values.filter { $0 == .alreadyAvailable }.count }
    private var alreadyPlannedCount: Int { rowActions.values.filter { $0 == .alreadyPlanned }.count }
    private var pausedCount: Int { rowActions.values.filter { $0 == .preservePaused }.count }
    private var retryKeys: [String] {
        selectedOptions.compactMap { option in
            guard rowActions[option.item.ratingKey] == .retryFailed else { return nil }
            return DownloadRecordIdentity.recordKey(for: option.item.ratingKey, backend: backend)
        }
    }

    private var nearestExistingSelections: [String: Int?] {
        Dictionary(uniqueKeysWithValues: selectedOptions.map { option in
            let source = option.item.media?.first
            let requested = requestedQualityPoint(source: source)
            let candidates = option.existingVersions.map {
                (SeasonDownloadQualityPoint(width: $0.width, height: $0.height,
                                            bitrateKbps: $0.bitrateKbps),
                 $0.sizeBytes, $0.playableOffline)
            }
            return (option.item.ratingKey,
                    SeasonDownloadExistingVersionMatchPolicy.nearestIndex(
                        requested: requested, candidates: candidates))
        })
    }

    private var newPlans: [SeasonEpisodeDownloadPlan] {
        selectedOptions.compactMap { option in
            guard rowActions[option.item.ratingKey] == .add else { return nil }
            let preferredLanguage = UserDefaults.standard.string(
                forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
            let sourceSelection = DownloadMediaSelectionPolicy.selection(
                item: option.item, mediaIndex: 0, partIndex: 0)
            let audio = DownloadAudioSelectionPolicy.selectedAudioStreamIndex(
                part: sourceSelection.part, preferredLanguage: preferredLanguage)
            var choice: DownloadIntentChoice
            var mediaIndex = 0
            var mediaSourceID: String?
            var estimate: Int?
            var shouldStart = true
            if useExistingVersions,
               let nearest = nearestExistingSelections[option.item.ratingKey] ?? nil,
               option.existingVersions.indices.contains(nearest) {
                let version = option.existingVersions[nearest]
                choice = .existingVersion
                estimate = version.sizeBytes
                switch version.target {
                case .plexMediaIndex(let index): mediaIndex = index
                case .embyMediaSource(let id, _): mediaSourceID = id
                }
            } else if selectedQuality == DownloadPresetPolicy.compatibleOriginalQualityName {
                if option.original != nil {
                    choice = .original
                } else if backend == .plex,
                          let originalPreset = DownloadPresetPolicy.plexOriginalQualityPreset(in: option.presets) {
                    choice = .optimize(targetName: originalPreset)
                } else if option.compatibleRemux != nil {
                    choice = .optimizeCompatible
                } else {
                    // Keep the unsupported episode visible as its own ordinary failed row. Do not
                    // substitute a materially unrelated bitrate rendition for Original quality.
                    choice = .original
                    shouldStart = false
                }
                estimate = downloadManager.estimatedBytes(
                    for: option.item, choice: choice, mediaIndex: mediaIndex, partIndex: 0,
                    backend: backend)
            } else {
                choice = .optimize(targetName: selectedQuality)
                estimate = downloadManager.estimatedBytes(
                    for: option.item, choice: choice, mediaIndex: mediaIndex, partIndex: 0,
                    backend: backend)
            }
            return SeasonEpisodeDownloadPlan(
                item: option.item, backend: backend, choice: choice,
                mediaIndex: mediaIndex, partIndex: 0,
                audioStreamIndex: choice == .original || choice == .existingVersion ? nil : audio,
                mediaSourceIDOverride: mediaSourceID,
                estimatedBytes: estimate,
                shouldStart: shouldStart)
        }
    }

    private var storageSummary: SeasonDownloadStorageSummary {
        SeasonDownloadStoragePolicy.summarize(newPlans.filter(\.shouldStart).map(\.estimatedBytes))
    }
    private var storageText: String {
        let known = DownloadStorageLimitPolicy.byteString(storageSummary.knownBytes)
        return storageSummary.unknownCount == 0
            ? known : "\(known) known + \(storageSummary.unknownCount) unknown"
    }
    private var storageBlockMessage: String? {
        guard storageSummary.knownBytes > 0 else { return nil }
        return downloadManager.storageLimitMessage(adding: storageSummary.knownBytes)
    }
    private var unresolvedCount: Int { newPlans.filter { !$0.shouldStart }.count }
    private var existingVersionCount: Int {
        newPlans.filter { if case .existingVersion = $0.choice { return true }; return false }.count
    }
    private var qualityRange: String {
        let labels = selectedOptions.compactMap { option -> String? in
            guard useExistingVersions,
                  let nearest = nearestExistingSelections[option.item.ratingKey] ?? nil,
                  option.existingVersions.indices.contains(nearest) else { return selectedQuality }
            return option.existingVersions[nearest].label.components(separatedBy: " · ").first
        }
        return Array(Set(labels)).sorted().joined(separator: " – ")
    }
    private var confirmationMessage: String {
        var text = "Add \(newPlans.count) new episode row(s) and retry \(retryKeys.count) included failure(s). "
            + "Additional storage: \(storageText)."
        if storageSummary.unknownCount > 0 {
            text += " Unknown sizes are not counted as zero; continuing explicitly accepts that uncertainty."
        }
        text += " Transfers may continue in the background, but may stall during sleep or Vision Pro off-head/deep standby and resume when active."
        return text
    }

    private func requestedQualityPoint(source: Media?) -> SeasonDownloadQualityPoint {
        if selectedQuality == DownloadPresetPolicy.compatibleOriginalQualityName {
            return .init(width: source?.width, height: source?.height, bitrateKbps: source?.bitrate)
        }
        let profile = DownloadPresetPolicy.customDownloadProfile(named: selectedQuality)
        let dimensions = profile?.settings.videoResolution?.split(separator: "x").compactMap { Int($0) }
        return .init(width: dimensions?.first,
                     height: dimensions?.dropFirst().first,
                     bitrateKbps: profile?.settings.maxVideoBitrateKbps)
    }

    private func refreshSeason() async {
        loading = true
        do {
            let loaded: [MediaItem]
            switch backend {
            case .plex:
                loaded = try await PlexBrowseService(appModel: appModel).children(ratingKey: season.ratingKey)
            case .jellyfin:
                loaded = try await JellyfinBrowseService(appModel: appModel)
                    .items(parentId: season.ratingKey, recursive: false)
            case .emby:
                loaded = try await EmbyBrowseService(appModel: appModel)
                    .items(parentId: season.ratingKey, recursive: false)
            }
            episodes = loaded.normalizedForContainerBrowser(childrenAreEpisodes: true)
            if usableWatchedCount == 0 { scope = .all }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func resolvePlan() async {
        resolving = true
        commitError = nil
        resolvedOptions = []
        let planner = DownloadItemPlanner(appModel: appModel, downloadManager: downloadManager)
        let preferred = UserDefaults.standard.string(
            forKey: PlaybackPreferences.Keys.preferredAudioLanguage)
        var results: [DownloadItemPlanningOptions] = []
        // Deliberately bounded at one: probing may mint/refresh backend state, while actual work is
        // admitted later by the separate lane-aware window.
        for index in selectedEpisodeIndices where episodes.indices.contains(index) {
            let child = episodes[index]
            let item = (try? await planner.refreshedItem(child, backend: backend)) ?? child
            results.append(await planner.options(
                for: item, preferredAudioLanguage: preferred, backend: backend))
        }
        resolvedOptions = results
        useExistingVersions = false
        resolving = false
    }

    private func commit() {
        let result = downloadManager.commitSeasonPlan(new: newPlans, retryKeys: retryKeys)
        if let error = result.failureMessage {
            commitError = error
        } else {
            dismiss()
        }
    }
}
#endif
