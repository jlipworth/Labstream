import Foundation
import PMSKit

extension DownloadManager {
    func cachedResumePresence(for key: DownloadAttemptKey) -> Bool {
        guard let identity = store.resumePresenceIdentity(for: key) else { return false }
        return resumePresenceEvidence[identity] == true
    }

    /// Progress/publication reads do no filesystem work. Cache keys include the exact attempt,
    /// artifact generation and path; a replace/delete invalidates old evidence immediately.
    func refreshResumePresenceEvidence(records: [DownloadRecord]) {
        let identities = Set(records.compactMap { record -> DownloadStore.ResumePresenceIdentity? in
            guard record.metadata?.resumeDisplayBytes != nil, let attempt = record.attemptID else { return nil }
            return store.resumePresenceIdentity(for: .init(ratingKey: record.ratingKey, attemptID: attempt))
        })
        resumePresenceEvidence = resumePresenceEvidence.filter { identities.contains($0.key) }
        for identity in identities where resumePresenceEvidence[identity] == nil && resumePresenceWorkers[identity] == nil {
            let work = DownloadStoreWork { [store] in store.observeResumePresence(identity) }
            resumePresenceWorkers[identity] = Task { @MainActor [weak self] in
                let observation = await work.observe(deadline: .after(30))
                guard let self else { return }
                self.resumePresenceWorkers.removeValue(forKey: identity)
                guard let result = observation, let exists = result,
                      self.store.resumePresenceIdentity(for: identity.key) == identity else { return }
                self.resumePresenceEvidence[identity] = exists
                self.offlineLibrarySnapshot = self.makeOfflineLibrarySnapshot(from: self.records)
            }
        }
    }
}
