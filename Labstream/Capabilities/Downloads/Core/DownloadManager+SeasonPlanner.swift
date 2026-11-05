import Foundation
import PMSKit

struct SeasonEpisodeDownloadPlan {
    let item: MediaItem
    let backend: DownloadBackendKind
    let choice: DownloadIntentChoice
    let mediaIndex: Int
    let partIndex: Int
    let audioStreamIndex: Int?
    let mediaSourceIDOverride: String?
    let estimatedBytes: Int?
    let shouldStart: Bool
    /// B69: an Original-quality episode whose probe failed; its route is resolved at admission.
    var routeUnresolved: Bool = false

    var recordKey: String {
        DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: backend)
    }

}

/// The complete immutable result of season review. Keeping new rows and retry intents together
/// prevents the confirmation UI and commit path from independently recomputing different plans.
struct SeasonPlanDraft {
    let newPlans: [SeasonEpisodeDownloadPlan]
    let retryAttempts: [DownloadAttemptKey]

    var storageSummary: SeasonDownloadStorageSummary {
        SeasonDownloadStoragePolicy.summarize(newPlans.filter(\.shouldStart).map(\.estimatedBytes))
    }
}

struct SeasonPlannerRowDisposition {
    let action: SeasonDownloadExistingRowAction
    let retryAttempt: DownloadAttemptKey?
}

@MainActor
enum SeasonPlanResolutionSequence {
    /// Sequential planning is intentional because a probe may refresh backend authority. A
    /// cancelled sheet never starts the next probe or publishes a partial plan.
    static func map<Element, Output>(indices: [Int], elements: [Element],
                                     transform: @MainActor (Element) async -> Output) async -> [Output]? {
        var output: [Output] = []
        for index in indices where elements.indices.contains(index) {
            guard !Task.isCancelled else { return nil }
            let value = await transform(elements[index])
            guard !Task.isCancelled else { return nil }
            output.append(value)
        }
        guard !Task.isCancelled else { return nil }
        return output
    }
}

struct SeasonPlanCommitResult: Equatable {
    let added: Int
    let retried: Int
    let failureMessage: String?

    var succeeded: Bool { failureMessage == nil }
}

extension DownloadManager {
    func seasonPlannerRowDisposition(itemID: String, backend: DownloadBackendKind)
        -> SeasonPlannerRowDisposition {
        let key = DownloadRecordIdentity.recordKey(for: itemID, backend: backend)
        let record = store.record(for: key)
        let action = SeasonDownloadDedupPolicy.action(
            status: record?.status,
            deletionPending: store.isDeletionPending(ratingKey: key))
        let retryAttempt = action == .retryFailed
            ? record?.attemptID.map { DownloadAttemptKey(ratingKey: key, attemptID: $0) }
            : nil
        return SeasonPlannerRowDisposition(action: action, retryAttempt: retryAttempt)
    }

    /// Persist every new ordinary episode row before admitting any lane. Failed included rows are
    /// durably marked for the same bounded admission worker; paused rows are never passed here.
    /// Async so the store's durability waits (a full-index write, plus compensating writes on
    /// failure) never block the main actor; admission stays gated on the returned outcome via
    /// `seasonPlanCommitsInFlight`.
    func commitSeasonPlan(_ draft: SeasonPlanDraft)
        async -> SeasonPlanCommitResult {
        let plans = draft.newPlans
        let retryAttempts = draft.retryAttempts
        guard startupRecoveryState == .ready else {
            return .init(added: 0, retried: 0,
                         failureMessage: "Downloads are paused while recovery is completed.")
        }
        let knownBytes = plans.filter(\.shouldStart).compactMap(\.estimatedBytes)
            .filter { $0 > 0 }.reduce(0, +)
        if let message = seasonStorageLimitMessage(newKnownBytes: knownBytes,
                                                   retryAttempts: retryAttempts) {
            return .init(added: 0, retried: 0, failureMessage: message)
        }

        var records: [DownloadRecord] = []
        for plan in plans {
            guard store.record(for: plan.recordKey) == nil,
                  let record = plannedSeedRecord(for: plan) else {
                return .init(added: 0, retried: 0,
                             failureMessage: "The season plan changed before it could be saved. Review it again.")
            }
            records.append(record)
        }
        let applied = await persistPlannedSeeds(records, retryAttempts: retryAttempts)
        guard case .applied(let inserted, let retried) = applied else {
            let message: String
            switch applied {
            case .staleInput:
                message = "The season plan changed before it could be saved. Review it again."
            case .persistenceIndeterminate:
                message = "Download storage could not prove the saved plan. Downloads are paused for safety."
            case .persistenceFailed, .applied:
                message = "The complete season plan could not be saved safely. Nothing was started."
            }
            return .init(added: 0, retried: 0, failureMessage: message)
        }
        refreshRecords()
        scheduleAdmissionPump()
        return .init(added: inserted, retried: retried, failureMessage: nil)
    }

    /// The durable seed of a planned first start: a season episode, or a tap that waits for a
    /// lane (P4.3). It carries the exact source binding (Part or MediaSource), requested route,
    /// preset and audio selection; the store absorbs the planner flag into lifecycle `planned`.
    func plannedSeedRecord(for plan: SeasonEpisodeDownloadPlan) -> DownloadRecord? {
        guard let session = appModel.backendSession(for: plan.backend) else { return nil }
        let selected = DownloadMediaSelectionPolicy.selection(
            item: plan.item, mediaIndex: plan.mediaIndex, partIndex: plan.partIndex)
        let metadata = DownloadOfflineMetadataBuilder.metadata(
            from: plan.item,
            resolutionLabel: DownloadPresetPolicy.displayResolutionLabel(
                choice: plan.choice, chosenMedia: selected.media),
            requestedProfileLabel: DownloadChoicePolicy.requestedProfileLabel(for: plan.choice),
            mediaIndex: plan.mediaIndex,
            partIndex: plan.partIndex,
            optimizeTargetName: {
                if case .optimize(let target) = plan.choice { return target }
                return nil
            }(),
            session: session,
            mediaSourceID: plan.mediaSourceIDOverride ?? selected.mediaSourceID,
            audioStreamIndex: plan.audioStreamIndex,
            downloadLane: DownloadChoicePolicy.downloadLane(for: plan.choice),
            serverPreparedVersion: DownloadChoicePolicy.isServerPreparedVersion(for: plan.choice),
            seasonPlannerPendingAdmission: plan.shouldStart)
        var seedMetadata = metadata
        if plan.routeUnresolved { seedMetadata.admissionRouteUnresolved = true }
        return DownloadRecord(
            ratingKey: plan.recordKey,
            attemptID: DownloadAttemptID.generated(),
            title: plan.item.title,
            localURL: store.destinationURL(ratingKey: plan.recordKey, ext: "mp4"),
            bytes: 0, progress: 0, status: plan.shouldStart ? .queued : .failed,
            metadata: seedMetadata)
    }

    /// Persist planned seeds atomically. Admission stays closed (`seasonPlanCommitsInFlight`)
    /// until durability is proven, so a published-but-unproven row is never granted (pu-05/06).
    func persistPlannedSeeds(_ records: [DownloadRecord],
                             retryAttempts: [DownloadAttemptKey] = []) async -> DownloadStore.SeasonPlanStoreApplyResult {
        seasonPlanCommitsInFlight += 1
        defer {
            seasonPlanCommitsInFlight -= 1
            scheduleAdmissionPump()
        }
        let store = store
        let applied = await Task.detached(priority: .userInitiated) {
            store.applySeasonPlanAtomically(newRecords: records, retryAttempts: retryAttempts)
        }.value
        if case .persistenceIndeterminate = applied {
            blockAfterIndeterminateSeasonPersistence()
        }
        return applied
    }

    /// The 2 s season worker is gone (P4): planned rows are admitted by the one event-driven
    /// coordinator. Kept as the season planner's entry name.
    func scheduleSeasonPlannerAdmission() {
        scheduleAdmissionPump()
    }

    private func seasonAdmissionStillCurrent(_ record: DownloadRecord) -> Bool {
        let current = store.record(for: record.ratingKey)
        return !Task.isCancelled
            && SeasonPlanAdmissionAuthority.accepts(
                expected: record.attemptID, current: current?.attemptID,
                status: current?.status)
            && (record.attemptID.map {
                store.attemptAdmitsWork(DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0))
            } ?? false)
    }

    /// A granted planned first start (a season episode or a waiting tap): refresh the item, re-find
    /// the exact persisted source, then run the backend entry point. A refresh outage returns
    /// without failing the row; admission defers it with backoff (B67).
    func startPlannedRecord(_ record: DownloadRecord) async {
        guard let metadata = record.metadata,
              seasonAdmissionStillCurrent(record) else { return }
        let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
        let snapshotItem = metadata.makeMediaItem()
        let planner = DownloadItemPlanner(appModel: appModel, downloadManager: self)
        let item: MediaItem
        do {
            guard let refreshed = try await SeasonPlanAdmissionAuthority.refresh(
                isCurrent: { self.seasonAdmissionStillCurrent(record) },
                operation: { try await planner.refreshedItem(snapshotItem, backend: backend) }) else { return }
            item = refreshed
        } catch {
            // The item is gone: a visible source-missing failure, not an endless wait.
            if Self.isDefinitiveMissingItem(error), seasonAdmissionStillCurrent(record),
               let attemptID = record.attemptID {
                _ = await applyLifecycleEvent(
                    .transferFailed(.sourceMissing),
                    for: DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID),
                    context: "season_plan_source_missing")
                return
            }
            recordDownloadDiagnostic("downloads.admission_refresh_unavailable", fields: [
                "download_id": .identifier(record.ratingKey),
            ])
            return
        }
        // Refresh suspends before a start-attempt exists. Deletion/replacement must
        // revoke admission instead of letting the public enqueue API recreate the row.
        guard seasonAdmissionStillCurrent(record) else { return }
        var choice: DownloadIntentChoice = {
            if metadata.isServerPreparedVersion == true { return .existingVersion }
            switch metadata.resolvedDownloadLane() {
            case .original: return .original
            case .compatibleRemux: return .optimizeCompatible
            case .optimize:
                return .optimize(targetName: metadata.optimizeTargetName
                    ?? DownloadPresetPolicy.jellyfinDefaultDownloadPreset)
            }
        }()
        if metadata.admissionRouteUnresolved == true {
            // B69: the planner's probe failed, so resolve the Original-quality route now.
            guard let resolved = await resolveUnresolvedOriginalRoute(
                record, item: item, backend: backend, planner: planner) else { return }
            choice = resolved
        }
        var mediaIndex = metadata.mediaIndex ?? 0
        var partIndex = metadata.partIndex ?? 0
        // Media arrays may be reordered between confirmation and admission. Re-find the exact
        // persisted Part rather than silently switching an existing/source version by index.
        if let sourcePartID = metadata.sourcePartID {
            let matches = (item.media ?? []).enumerated().compactMap { mediaOffset, media in
                media.part.enumerated().first(where: { $0.element.id == sourcePartID }).map {
                    (mediaOffset, $0.offset)
                }
            }
            guard let exact = matches.first else {
                if let attemptID = record.attemptID {
                    _ = await applyLifecycleEvent(
                        .transferFailed(.sourceMissing),
                        for: DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID),
                        context: "season_plan_source_missing")
                }
                refreshRecords()
                return
            }
            mediaIndex = exact.0
            partIndex = exact.1
        }
        switch backend {
        case .plex:
            await download(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                           audioStreamIndex: metadata.audioStreamIndex,
                           allowReplacingExistingActiveRow: true)
        case .jellyfin:
            await downloadJellyfin(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                   audioStreamIndex: metadata.audioStreamIndex,
                                   mediaSourceIDOverride: metadata.mediaSourceID,
                                   allowReplacingExistingActiveRow: true)
        case .emby:
            await downloadEmby(item, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                               audioStreamIndex: metadata.audioStreamIndex,
                               mediaSourceIDOverride: metadata.mediaSourceID,
                               allowReplacingExistingActiveRow: true)
        }
    }
}

/// A metadata refresh never grants authority to create a missing or replaced row.
@MainActor
enum SeasonPlanAdmissionAuthority {
    static func refresh<Value>(isCurrent: () -> Bool,
                               operation: () async throws -> Value) async rethrows -> Value? {
        guard isCurrent() else { return nil }
        let value = try await operation()
        guard isCurrent() else { return nil }
        return value
    }

    static func accepts(expected: DownloadAttemptID?, current: DownloadAttemptID?,
                        status: DownloadStatus?) -> Bool {
        expected != nil && expected == current && status == .queued
    }
}
