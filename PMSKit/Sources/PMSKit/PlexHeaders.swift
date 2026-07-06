public enum PlexHeaders {
    /// Standard header set. Note: for streaming URLs the token is passed as a
    /// query param instead (see TranscodeRequest); these headers are for API calls.
    public static func standard(identity: ClientIdentity, token: String?) -> [String: String] {
        var h: [String: String] = [
            "X-Plex-Client-Identifier": identity.clientIdentifier,
            "X-Plex-Product": identity.product,
            "X-Plex-Version": identity.version,
            "X-Plex-Platform": identity.platform,
            "X-Plex-Device": identity.device,
            "X-Plex-Device-Name": identity.deviceName,
            "Accept": "application/json",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    /// Header set for Plex media-plane HLS requests. These still carry the same X-Plex
    /// identity as control requests, but must accept playlist/segment responses rather than
    /// JSON only. A stable User-Agent also avoids edge/WAF rejection on tokenized media URLs.
    public static func media(identity: ClientIdentity, token: String?) -> [String: String] {
        var h = standard(identity: identity, token: token)
        h["Accept"] = "application/json,*/*"
        h["User-Agent"] = "\(identity.product)/\(identity.version)"
        return h
    }
}
