import Foundation

public enum MediaBackendChoice: String, Sendable, Equatable {
    case plex
    case jellyfin
    case emby
}

public struct MediaBackendCredentialSnapshot: Sendable, Equatable {
    public let plexToken: String?
    public let jellyfinServerURLString: String?
    public let jellyfinAccessToken: String?
    public let jellyfinUserID: String?
    public let embyServerURLString: String?
    public let embyAccessToken: String?
    public let embyUserID: String?

    public init(plexToken: String?,
                jellyfinServerURLString: String?,
                jellyfinAccessToken: String?,
                jellyfinUserID: String?,
                embyServerURLString: String? = nil,
                embyAccessToken: String? = nil,
                embyUserID: String? = nil) {
        self.plexToken = plexToken
        self.jellyfinServerURLString = jellyfinServerURLString
        self.jellyfinAccessToken = jellyfinAccessToken
        self.jellyfinUserID = jellyfinUserID
        self.embyServerURLString = embyServerURLString
        self.embyAccessToken = embyAccessToken
        self.embyUserID = embyUserID
    }

    public func hasSavedSession(for backend: MediaBackendChoice) -> Bool {
        switch backend {
        case .plex:
            return !(plexToken ?? "").isEmpty
        case .jellyfin:
            return !(jellyfinServerURLString ?? "").isEmpty &&
                !(jellyfinAccessToken ?? "").isEmpty &&
                !(jellyfinUserID ?? "").isEmpty
        case .emby:
            return !(embyServerURLString ?? "").isEmpty &&
                !(embyAccessToken ?? "").isEmpty &&
                !(embyUserID ?? "").isEmpty
        }
    }
}

public enum MediaBackendSwitchResolution: Sendable, Equatable {
    case alreadyActive
    case restoreSavedSession
    case requireLogin
}

public enum MediaBackendSwitch {
    public static func resolve(active: MediaBackendChoice,
                               target: MediaBackendChoice,
                               credentials: MediaBackendCredentialSnapshot) -> MediaBackendSwitchResolution {
        guard active != target else { return .alreadyActive }
        return credentials.hasSavedSession(for: target) ? .restoreSavedSession : .requireLogin
    }
}
