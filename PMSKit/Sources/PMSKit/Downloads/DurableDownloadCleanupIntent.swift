import Foundation

/// Attempt-scoped, credential-free authority to retry server cleanup after process death.
///
/// The tagged operation shape is explicit rather than relying on synthesized enum coding so its
/// persisted representation remains stable as more cleanup kinds are added.
public struct DurableDownloadCleanupIntent: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public struct ServerIdentity: Codable, Equatable, Sendable {
        public let baseURLString: String
        public let serverID: String?
        /// Required for Jellyfin/Emby. Plex cleanup is server-scoped (optimize queue items belong
        /// to the server, not the account), so Plex identities carry no user.
        public let userID: String?

        /// Stores only server identity. Credentials, query items, and fragments are discarded.
        /// Whether a user is required is decided per backend by `DurableDownloadCleanupIntent`.
        public init?(baseURL: URL, serverID: String?, userID: String?) {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else { return nil }
            components.scheme = scheme
            components.host = components.host?.lowercased()
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            guard let value = components.url?.absoluteString else { return nil }
            self.baseURLString = value
            self.serverID = Self.nonempty(serverID)
            self.userID = Self.nonempty(userID)
        }

        /// Cleanup matching only; resume eligibility stays with `BackendSession.matchesPersistedServer`.
        /// A user-bound identity requires the same user (GUID formatting normalized); a server ID,
        /// when recorded, must match exactly; otherwise the normalized base URL decides.
        public func matches(_ session: BackendSession) -> Bool {
            if let userID {
                guard let liveUserID = session.userID,
                      MediaBrowserUserIdentity.sameUser(liveUserID, userID) else { return false }
            }
            if let serverID { return session.serverID == serverID }
            guard let persistedURL = URL(string: baseURLString) else { return false }
            return BackendURLIdentity.sameBaseURL(persistedURL, session.baseURL)
        }

        private enum CodingKeys: String, CodingKey { case baseURLString, serverID, userID }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rawURL = try c.decode(String.self, forKey: .baseURLString)
            guard let url = URL(string: rawURL),
                  let value = Self(baseURL: url,
                                   serverID: try c.decodeIfPresent(String.self, forKey: .serverID),
                                   userID: try c.decodeIfPresent(String.self, forKey: .userID)) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .baseURLString, in: c,
                    debugDescription: "Cleanup server identity must be a credential-free HTTP(S) base URL")
            }
            self = value
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(baseURLString, forKey: .baseURLString)
            try c.encodeIfPresent(serverID, forKey: .serverID)
            try c.encodeIfPresent(userID, forKey: .userID)
        }

        private static func nonempty(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }

    public enum Operation: Equatable, Sendable {
        case activeEncoding(playSessionID: String)
        case embyConvert(EmbyConvertIdentity)
        /// Remove this row's Plex optimize (type-42) queue item, matched by its exact title.
        case plexOptimize(queueTitle: String)
    }

    /// What is known about the Plex create PUT behind a `plexOptimize` intent. An absent queue item
    /// retires the intent only once the create is known to have landed; an unresolved create may
    /// still become visible later.
    public enum PlexCreateEvidence: String, Codable, Equatable, Sendable {
        case confirmed
        case unresolved
    }

    /// Why the intent exists, which decides when the runner may execute it. Not part of the
    /// operation identity: `ensure` deduplicates on operation, so a later delete reuses an earlier
    /// terminal-release intent rather than adding a second one.
    public enum Provenance: Equatable, Sendable {
        /// Written by delete; runs once the row's removal has committed.
        case rowDeletion
        /// Written for a handle a terminal row still references; runs while that row is terminal
        /// and unprotected, or once it is gone.
        case terminalRelease
        /// The originating attempt gave the resource up while its row may live on.
        case abandonment(originAttempt: DownloadAttemptKey)
    }

    public enum EmbyConvertIdentity: Equatable, Sendable {
        case knownJob(jobID: Int)
        /// Identity for POST-accepted/response-lost: enough to recover exactly one new job.
        case ambiguousCreate(baselineJobIDs: [Int],
                             fingerprint: EmbyConvertRecoveryPolicy.Fingerprint,
                             attemptStartedAtEpochSeconds: Double,
                             phase: EmbyConvertRecoveryPolicy.Phase)
    }

    public let version: Int
    public let id: UUID
    public let attemptKey: DownloadAttemptKey
    public let backend: DownloadBackendKind
    public let server: ServerIdentity
    public let operation: Operation
    /// `nil` for entries written before provenance existed; the app classifies them once on load.
    public let provenance: Provenance?
    /// Present only for `plexOptimize`.
    public let plexCreate: PlexCreateEvidence?

    public init?(id: UUID = UUID(), attemptKey: DownloadAttemptKey,
                 backend: DownloadBackendKind, server: ServerIdentity, operation: Operation,
                 provenance: Provenance? = nil, plexCreate: PlexCreateEvidence? = nil) {
        guard !attemptKey.ratingKey.isEmpty else { return nil }
        switch operation {
        case .activeEncoding(let playSessionID):
            guard backend != .plex, !playSessionID.isEmpty else { return nil }
        case .embyConvert(let identity):
            guard backend == .emby else { return nil }
            if case .ambiguousCreate(_, _, let started, _) = identity {
                guard started.isFinite else { return nil }
            }
        case .plexOptimize(let queueTitle):
            guard backend == .plex, !queueTitle.isEmpty, plexCreate != nil else { return nil }
        }
        if case .plexOptimize = operation {} else { guard plexCreate == nil else { return nil } }
        // MediaBrowser cleanup is always user-bound; Plex cleanup is server-scoped.
        guard (backend == .plex) == (server.userID == nil) else { return nil }
        if case .abandonment(let origin) = provenance {
            guard !origin.ratingKey.isEmpty else { return nil }
        }
        self.version = Self.currentVersion
        self.id = id
        self.attemptKey = attemptKey
        self.backend = backend
        self.server = server
        self.operation = operation
        self.provenance = provenance
        self.plexCreate = plexCreate
    }

    /// The same authority with its provenance settled (legacy classification) or its create
    /// evidence upgraded once the item has been seen.
    public func with(provenance: Provenance?, plexCreate: PlexCreateEvidence? = nil) -> Self? {
        Self(id: id, attemptKey: attemptKey, backend: backend, server: server,
             operation: operation, provenance: provenance, plexCreate: plexCreate ?? self.plexCreate)
    }

    /// A stale completion can clear only the exact durable entry it executed.
    public func matchesForClear(id: UUID, attemptKey: DownloadAttemptKey,
                                operation: Operation) -> Bool {
        self.id == id && self.attemptKey == attemptKey && self.operation == operation
    }

    /// Cleanup may execute only against the persisted backend, user, and server identity.
    public func matches(session: BackendSession) -> Bool {
        session.kind == backend && server.matches(session)
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, attemptKey, backend, server, operationType
        case playSessionID, embyConvertMode, embyConvertJobID, baselineJobIDs
        case fingerprint, attemptStartedAtEpochSeconds, phase
        case queueTitle, plexCreate, provenance, provenanceOriginAttempt
    }
    private enum OperationType: String, Codable { case activeEncoding, embyConvert, plexOptimize }
    private enum ProvenanceTag: String, Codable { case rowDeletion, terminalRelease, abandonment }
    private enum ConvertMode: String, Codable { case knownJob, ambiguousCreate }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(attemptKey, forKey: .attemptKey)
        try c.encode(backend, forKey: .backend)
        try c.encode(server, forKey: .server)
        switch operation {
        case .activeEncoding(let playSessionID):
            try c.encode(OperationType.activeEncoding, forKey: .operationType)
            try c.encode(playSessionID, forKey: .playSessionID)
        case .embyConvert(.knownJob(let jobID)):
            try c.encode(OperationType.embyConvert, forKey: .operationType)
            try c.encode(ConvertMode.knownJob, forKey: .embyConvertMode)
            try c.encode(jobID, forKey: .embyConvertJobID)
        case .embyConvert(.ambiguousCreate(let baseline, let fingerprint, let started, let phase)):
            try c.encode(OperationType.embyConvert, forKey: .operationType)
            try c.encode(ConvertMode.ambiguousCreate, forKey: .embyConvertMode)
            try c.encode(baseline, forKey: .baselineJobIDs)
            try c.encode(fingerprint, forKey: .fingerprint)
            try c.encode(started, forKey: .attemptStartedAtEpochSeconds)
            try c.encode(phase, forKey: .phase)
        case .plexOptimize(let queueTitle):
            try c.encode(OperationType.plexOptimize, forKey: .operationType)
            try c.encode(queueTitle, forKey: .queueTitle)
            try c.encodeIfPresent(plexCreate, forKey: .plexCreate)
        }
        switch provenance {
        case nil: break
        case .rowDeletion: try c.encode(ProvenanceTag.rowDeletion, forKey: .provenance)
        case .terminalRelease: try c.encode(ProvenanceTag.terminalRelease, forKey: .provenance)
        case .abandonment(let origin):
            try c.encode(ProvenanceTag.abandonment, forKey: .provenance)
            try c.encode(origin, forKey: .provenanceOriginAttempt)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                    debugDescription: "Unsupported cleanup intent version")
        }
        let id = try c.decode(UUID.self, forKey: .id)
        let attemptKey = try c.decode(DownloadAttemptKey.self, forKey: .attemptKey)
        let backend = try c.decode(DownloadBackendKind.self, forKey: .backend)
        let server = try c.decode(ServerIdentity.self, forKey: .server)
        let operation: Operation
        switch try c.decode(OperationType.self, forKey: .operationType) {
        case .activeEncoding:
            operation = .activeEncoding(playSessionID: try c.decode(String.self, forKey: .playSessionID))
        case .embyConvert:
            switch try c.decode(ConvertMode.self, forKey: .embyConvertMode) {
            case .knownJob:
                operation = .embyConvert(.knownJob(jobID: try c.decode(Int.self, forKey: .embyConvertJobID)))
            case .ambiguousCreate:
                operation = .embyConvert(.ambiguousCreate(
                    baselineJobIDs: try c.decode([Int].self, forKey: .baselineJobIDs),
                    fingerprint: try c.decode(EmbyConvertRecoveryPolicy.Fingerprint.self, forKey: .fingerprint),
                    attemptStartedAtEpochSeconds: try c.decode(Double.self, forKey: .attemptStartedAtEpochSeconds),
                    phase: try c.decode(EmbyConvertRecoveryPolicy.Phase.self, forKey: .phase)))
            }
        case .plexOptimize:
            operation = .plexOptimize(queueTitle: try c.decode(String.self, forKey: .queueTitle))
        }
        let provenance: Provenance?
        switch try c.decodeIfPresent(ProvenanceTag.self, forKey: .provenance) {
        case nil: provenance = nil
        case .rowDeletion: provenance = .rowDeletion
        case .terminalRelease: provenance = .terminalRelease
        case .abandonment:
            provenance = .abandonment(originAttempt: try c.decode(
                DownloadAttemptKey.self, forKey: .provenanceOriginAttempt))
        }
        guard let value = Self(id: id, attemptKey: attemptKey, backend: backend,
                               server: server, operation: operation, provenance: provenance,
                               plexCreate: try c.decodeIfPresent(PlexCreateEvidence.self,
                                                                 forKey: .plexCreate)) else {
            throw DecodingError.dataCorruptedError(forKey: .operationType, in: c,
                                                    debugDescription: "Invalid cleanup intent")
        }
        self = value
    }
}
