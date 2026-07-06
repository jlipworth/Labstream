public struct ClientIdentity: Sendable, Equatable {
    public let clientIdentifier: String
    public let product: String
    public let version: String
    /// User-safe device display name used in diagnostics/settings and X-Plex-Device-Name.
    public let deviceName: String
    /// X-Plex-Platform value. Defaults preserve the existing visionOS request identity.
    public let platform: String
    /// X-Plex-Device value. Defaults preserve the existing Apple Vision Pro request identity.
    public let device: String

    public init(clientIdentifier: String,
                product: String,
                version: String,
                deviceName: String,
                platform: String = "visionOS",
                device: String? = nil) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.deviceName = deviceName
        self.platform = platform
        self.device = device ?? deviceName
    }
}

extension ClientIdentity {
    public var jellyfin: JellyfinClientIdentity {
        JellyfinClientIdentity(client: product,
                               device: deviceName,
                               deviceId: clientIdentifier,
                               version: version)
    }

    public var emby: EmbyClientIdentity {
        EmbyClientIdentity(client: product,
                           device: deviceName,
                           deviceId: clientIdentifier,
                           version: version)
    }
}
