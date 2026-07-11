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
        public let userID: String

        /// Stores only server identity. Credentials, query items, and fragments are discarded.
        public init?(baseURL: URL, serverID: String?, userID: String) {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false,
                  !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            components.scheme = scheme
            components.host = components.host?.lowercased()
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            guard let value = components.url?.absoluteString else { return nil }
            self.baseURLString = value
            self.serverID = Self.nonempty(serverID)
            self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public func matches(_ session: BackendSession) -> Bool {
            guard session.userID == userID else { return false }
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
                                   userID: try c.decode(String.self, forKey: .userID)) else {
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
            try c.encode(userID, forKey: .userID)
        }

        private static func nonempty(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }

    public enum Operation: Equatable, Sendable {
        case activeEncoding(playSessionID: String)
        case embyConvert(EmbyConvertIdentity)
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

    public init?(id: UUID = UUID(), attemptKey: DownloadAttemptKey,
                 backend: DownloadBackendKind, server: ServerIdentity, operation: Operation) {
        guard !attemptKey.ratingKey.isEmpty, backend != .plex else { return nil }
        switch operation {
        case .activeEncoding(let playSessionID):
            guard !playSessionID.isEmpty else { return nil }
        case .embyConvert(let identity):
            guard backend == .emby else { return nil }
            if case .ambiguousCreate(_, _, let started, _) = identity {
                guard started.isFinite else { return nil }
            }
        }
        self.version = Self.currentVersion
        self.id = id
        self.attemptKey = attemptKey
        self.backend = backend
        self.server = server
        self.operation = operation
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
    }
    private enum OperationType: String, Codable { case activeEncoding, embyConvert }
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
        }
        guard let value = Self(id: id, attemptKey: attemptKey, backend: backend,
                               server: server, operation: operation) else {
            throw DecodingError.dataCorruptedError(forKey: .operationType, in: c,
                                                    debugDescription: "Invalid cleanup intent")
        }
        self = value
    }
}
