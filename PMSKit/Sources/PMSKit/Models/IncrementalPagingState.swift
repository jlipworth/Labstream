/// Pure request-admission and stale-result state for bounded, incremental feeds.
public struct IncrementalPagingState: Equatable, Sendable {
    public struct RequestToken: Equatable, Sendable {
        public let identity: String
        public let generation: Int
        public let offset: Int
        public let limit: Int
    }

    public private(set) var identity: String
    public private(set) var generation: Int = 0
    public private(set) var loadedIDs: [String] = []
    public private(set) var nextOffset: Int = 0
    public private(set) var inFlightOffset: Int?
    public private(set) var failedOffset: Int?
    public private(set) var reportedTotal: Int?
    public private(set) var isTerminal = false
    public let pageSize: Int

    public init(identity: String, pageSize: Int) {
        self.identity = identity
        self.pageSize = max(pageSize, 1)
    }

    public mutating func beginRequest(offset: Int) -> RequestToken? {
        guard offset >= 0,
              !isTerminal,
              inFlightOffset == nil,
              offset == nextOffset || offset == failedOffset else { return nil }
        inFlightOffset = offset
        if failedOffset == offset { failedOffset = nil }
        return RequestToken(identity: identity,
                            generation: generation,
                            offset: offset,
                            limit: pageSize)
    }

    @discardableResult
    public mutating func acceptPage(_ ids: [String],
                                    reportedTotal: Int?,
                                    token: RequestToken) -> Bool {
        guard accepts(token) else { return false }
        inFlightOffset = nil
        failedOffset = nil
        self.reportedTotal = reportedTotal

        var known = Set(loadedIDs)
        for id in ids where known.insert(id).inserted {
            loadedIDs.append(id)
        }
        nextOffset = token.offset + ids.count
        isTerminal = ids.count < token.limit
        if let reportedTotal {
            isTerminal = isTerminal || nextOffset >= max(reportedTotal, 0)
        }
        return true
    }

    @discardableResult
    public mutating func acceptFailure(token: RequestToken) -> Bool {
        guard accepts(token) else { return false }
        inFlightOffset = nil
        failedOffset = token.offset
        return true
    }

    public mutating func refresh(identity: String) {
        self.identity = identity
        generation &+= 1
        loadedIDs = []
        nextOffset = 0
        inFlightOffset = nil
        failedOffset = nil
        reportedTotal = nil
        isTerminal = false
    }

    private func accepts(_ token: RequestToken) -> Bool {
        token.identity == identity
            && token.generation == generation
            && token.offset == inFlightOffset
            && token.limit == pageSize
    }
}
