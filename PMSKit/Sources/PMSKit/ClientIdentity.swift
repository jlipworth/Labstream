public struct ClientIdentity: Sendable, Equatable {
    public let clientIdentifier: String
    public let product: String
    public let version: String
    public let deviceName: String
    public init(clientIdentifier: String, product: String, version: String, deviceName: String) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.deviceName = deviceName
    }
}

extension ClientIdentity {
    public var jellyfin: JellyfinClientIdentity {
        JellyfinClientIdentity(client: product,
                               device: deviceName,
                               deviceId: clientIdentifier,
                               version: version)
    }
}
