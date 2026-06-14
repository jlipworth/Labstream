import Foundation

/// Server discovery via plex.tv resources, plus connection ranking.
///
/// The resources endpoint returns every server/device the account can reach,
/// each with one or more candidate connections (local LAN, remote public, relay).
/// `bestConnection` ranks them so we prefer a direct local connection, then any
/// direct (non-relay) connection, before falling back to a relay.
public enum ResourceDiscovery {
    static let base = URL(string: "https://clients.plex.tv/api/v2/resources")!

    /// Request descriptor for `GET https://clients.plex.tv/api/v2/resources`.
    /// `includeHttps=1` asks plex.tv to include the HTTPS connection URIs
    /// (the `*.plex.direct` hostnames with valid certs).
    public static func resourcesRequest(token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base, method: "GET",
                    queryItems: [
                        .init(name: "includeHttps", value: "1"),
                        .init(name: "includeRelay", value: "1"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Rank candidate connections by *preference priority*: local first, then
    /// non-relay, then relay. Sort is stable on (local desc, non-relay desc).
    ///
    /// NOTE: priority is not reachability. A server advertises every interface it
    /// has as a "local" connection — including container/VPN/virtual interfaces
    /// (e.g. a Docker `10.42.x.x` bridge) that no real client can reach. Callers
    /// MUST probe these in order and use the first that actually responds, rather
    /// than blindly taking `bestConnection`. See `AuthManager.firstReachable`.
    public static func rankedConnections(_ connections: [PlexConnection]) -> [PlexConnection] {
        connections
            .enumerated()
            .sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a.local != b.local { return a.local && !b.local }
                if a.relay != b.relay { return !a.relay && b.relay }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Highest-priority connection by static rank. Convenience for tests and for
    /// the fallback when no connection responds to a reachability probe.
    public static func bestConnection(_ connections: [PlexConnection]) -> PlexConnection? {
        rankedConnections(connections).first
    }
}

/// Top-level response from `GET /api/v2/resources` (a JSON array of devices).
public struct ResourcesResponse: Decodable, Sendable {
    public let devices: [PlexDevice]
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.devices = try container.decode([PlexDevice].self)
    }
    public init(devices: [PlexDevice]) {
        self.devices = devices
    }
}

/// A server/device the account can reach.
public struct PlexDevice: Decodable, Sendable, Identifiable {
    public let name: String
    public let clientIdentifier: String
    public let provides: String?
    public let accessToken: String?
    /// PMS version string (e.g. "1.40.2.8395-abcdef123"), as advertised in the
    /// resources payload. Display-only (#26 Settings); absent for non-server devices.
    public let productVersion: String?
    public let connections: [PlexConnection]

    public var id: String { clientIdentifier }

    enum CodingKeys: String, CodingKey {
        case name
        case clientIdentifier
        case provides
        case accessToken
        case productVersion
        case connections = "connections"
    }

    public init(name: String, clientIdentifier: String, provides: String? = nil,
                accessToken: String? = nil, productVersion: String? = nil,
                connections: [PlexConnection]) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.provides = provides
        self.accessToken = accessToken
        self.productVersion = productVersion
        self.connections = connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.clientIdentifier = try c.decodeIfPresent(String.self, forKey: .clientIdentifier) ?? ""
        self.provides = try c.decodeIfPresent(String.self, forKey: .provides)
        self.accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        self.productVersion = try c.decodeIfPresent(String.self, forKey: .productVersion)
        self.connections = try c.decodeIfPresent([PlexConnection].self, forKey: .connections) ?? []
    }
}

/// One candidate connection to a device.
public struct PlexConnection: Decodable, Sendable, Equatable {
    public let uri: String
    public let local: Bool
    public let relay: Bool

    enum CodingKeys: String, CodingKey {
        case uri
        case local
        case relay
    }

    public init(uri: String, local: Bool, relay: Bool) {
        self.uri = uri
        self.local = local
        self.relay = relay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uri = try c.decodeIfPresent(String.self, forKey: .uri) ?? ""
        self.local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        self.relay = try c.decodeIfPresent(Bool.self, forKey: .relay) ?? false
    }
}
