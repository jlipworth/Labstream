import Foundation

public enum MediaBackendChoice: String, Sendable, Equatable {
    case plex
    case jellyfin
}

public struct MediaBackendCredentialSnapshot: Sendable, Equatable {
    public let plexToken: String?
    public let jellyfinServerURLString: String?
    public let jellyfinAccessToken: String?
    public let jellyfinUserID: String?

    public init(plexToken: String?,
                jellyfinServerURLString: String?,
                jellyfinAccessToken: String?,
                jellyfinUserID: String?) {
        self.plexToken = plexToken
        self.jellyfinServerURLString = jellyfinServerURLString
        self.jellyfinAccessToken = jellyfinAccessToken
        self.jellyfinUserID = jellyfinUserID
    }

    public func hasSavedSession(for backend: MediaBackendChoice) -> Bool {
        switch backend {
        case .plex:
            return !(plexToken ?? "").isEmpty
        case .jellyfin:
            return !(jellyfinServerURLString ?? "").isEmpty &&
                !(jellyfinAccessToken ?? "").isEmpty &&
                !(jellyfinUserID ?? "").isEmpty
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
