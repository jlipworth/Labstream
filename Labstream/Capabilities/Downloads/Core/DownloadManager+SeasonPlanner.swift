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
        if let message = storageLimitMessage(adding: knownBytes), knownBytes > 0 {
            return .init(added: 0, retried: 0, failureMessage: message)
        }

        var records: [DownloadRecord] = []
        for plan in plans {
            guard store.record(for: plan.recordKey) == nil,
                  let session = appModel.backendSession(for: plan.backend) else {
                return .init(added: 0, retried: 0,
                             failureMessage: "The season plan changed before it could be saved. Review it again.")
            }
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
            let attemptID = DownloadAttemptID.generated()
            records.append(DownloadRecord(
                ratingKey: plan.recordKey,
                attemptID: attemptID,
                title: plan.item.title,
                localURL: store.destinationURL(ratingKey: plan.recordKey, ext: "mp4"),
                bytes: 0, progress: 0, status: plan.shouldStart ? .queued : .failed,
                metadata: metadata))
        }
        seasonPlanCommitsInFlight += 1
        defer { seasonPlanCommitsInFlight -= 1 }
        let store = store
        let plannedRecords = records
        let applied = await Task.detached(priority: .userInitiated) {
            store.applySeasonPlanAtomically(
                newRecords: plannedRecords, retryAttempts: retryAttempts)
        }.value
        guard case .applied(let inserted, let retried) = applied else {
            let message: String
            switch applied {
            case .staleInput:
                message = "The season plan changed before it could be saved. Review it again."
            case .persistenceIndeterminate:
                blockAfterIndeterminateSeasonPersistence()
                message = "Download storage could not prove the saved plan. Downloads are paused for safety."
            case .persistenceFailed, .applied:
                message = "The complete season plan could not be saved safely. Nothing was started."
            }
            return .init(added: 0, retried: 0, failureMessage: message)
        }
        refreshRecords()
        scheduleSeasonPlannerAdmission()
        return .init(added: inserted, retried: retried, failureMessage: nil)
    }

    func scheduleSeasonPlannerAdmission() {
        guard startupRecoveryState == .ready,
              seasonPlannerAdmissionTask == nil else { return }
        seasonPlannerAdmissionTask = Task { [weak self] in
            defer { self?.seasonPlannerAdmissionTask = nil }
            while !Task.isCancelled {
                guard let self else { return }
                let hasPending = await self.admitSeasonPlannerRowsOnce()
                if !hasPending { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Returns true while durable pending rows remain (including rows waiting for an occupied lane).
    private func admitSeasonPlannerRowsOnce() async -> Bool {
        // A commit's rows are published before their durability is proven; a failed commit
        // withdraws them. Keep polling instead of admitting anything mid-commit.
        if seasonPlanCommitsInFlight > 0 { return true }
        if isQueuePaused { return records.contains { $0.metadata?.seasonPlannerPendingAdmission == true } }
        let snapshot = store.records
        let pendingRecords = snapshot.filter {
            $0.metadata?.seasonPlannerPendingAdmission == true
                && ($0.status == .queued || $0.status == .failed)
        }
        guard !pendingRecords.isEmpty else { return false }
        let active = snapshot.filter { activeJobs.contains($0.ratingKey) }.map {
            SeasonDownloadAdmissionCandidate(id: $0.ratingKey, lane: seasonAdmissionLane(for: $0))
        }
        let pending = pendingRecords.map {
            SeasonDownloadAdmissionCandidate(id: $0.ratingKey, lane: seasonAdmissionLane(for: $0))
        }
        let admittedIDs = Set(SeasonDownloadAdmissionPolicy.admitted(
            pending: pending, active: active).map(\.id))
        for record in pendingRecords where admittedIDs.contains(record.ratingKey) {
            guard let attemptID = record.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            seasonPlannerAdmittingKeys.insert(record.ratingKey)
            switch store.updateMetadata(for: key, mutate: {
                $0.seasonPlannerPendingAdmission = nil
            }) {
            case .applied, .noChange:
                if record.status == .failed {
                    retry(ratingKey: record.ratingKey, allowReplacingExistingActiveRow: true)
                } else {
                    await startSeasonPlannedRecord(record)
                }
            case .staleOrMissing, .persistenceFailed:
                break
            }
            seasonPlannerAdmittingKeys.remove(record.ratingKey)
        }
        refreshRecords()
        return store.records.contains { $0.metadata?.seasonPlannerPendingAdmission == true }
    }

    private func startSeasonPlannedRecord(_ record: DownloadRecord) async {
        guard let metadata = record.metadata else { return }
        let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
        let snapshotItem = metadata.makeMediaItem()
        let planner = DownloadItemPlanner(appModel: appModel, downloadManager: self)
        guard let item = try? await planner.refreshedItem(snapshotItem, backend: backend) else {
            if let attemptID = record.attemptID {
                _ = setAttemptStatus(
                    .failed,
                    for: DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID),
                    context: "season_plan_refresh")
            }
            refreshRecords()
            return
        }
        let choice: DownloadIntentChoice = {
            if metadata.isServerPreparedVersion == true { return .existingVersion }
            switch metadata.resolvedDownloadLane() {
            case .original: return .original
            case .compatibleRemux: return .optimizeCompatible
            case .optimize:
                return .optimize(targetName: metadata.optimizeTargetName
                    ?? DownloadPresetPolicy.jellyfinDefaultDownloadPreset)
            }
        }()
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
                    _ = setAttemptStatus(
                        .failed,
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

    private func seasonAdmissionLane(for record: DownloadRecord) -> SeasonDownloadAdmissionLane {
        guard let metadata = record.metadata else { return .serverPreparation }
        return SeasonDownloadAdmissionPolicy.lane(
            backend: metadata.resolvedBackendKind(ratingKey: record.ratingKey),
            downloadLane: metadata.resolvedDownloadLane())
    }
}
