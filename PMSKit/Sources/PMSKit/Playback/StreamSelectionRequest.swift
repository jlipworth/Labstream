import Foundation

/// `/library/parts/{partID}` — persist the active stream selection on a media part.
///
/// PMS muxes only the part's *selected* audio/subtitle stream into a transcoded HLS
/// session, so switching tracks means PUTting the new `audioStreamID` (or
/// `subtitleStreamID`) here and then restarting the transcode at the live playhead.
/// `allParts=1` applies the choice to every part of the item (multi-file movies).
public enum StreamSelectionRequest {

    /// Select the active audio stream for a part.
    ///
    /// - Parameters:
    ///   - server: base server URL (scheme+host+port).
    ///   - token: Plex auth token (sent both as a query param and a header).
    ///   - identity: client identity for the standard `X-Plex-*` headers.
    ///   - partID: `Part.id` of the media part being played.
    ///   - audioStreamID: `Stream.id` of the audio stream (`streamType == 2`) to activate.
    public static func selectAudioStream(server: URL,
                                         token: String,
                                         identity: ClientIdentity,
                                         partID: Int,
                                         audioStreamID: Int) -> PlexRequest {
        select(server: server, token: token, identity: identity, partID: partID,
               streamParam: "audioStreamID", streamID: audioStreamID)
    }

    /// Select the active subtitle stream for a part (`0` = subtitles off).
    public static func selectSubtitleStream(server: URL,
                                            token: String,
                                            identity: ClientIdentity,
                                            partID: Int,
                                            subtitleStreamID: Int) -> PlexRequest {
        select(server: server, token: token, identity: identity, partID: partID,
               streamParam: "subtitleStreamID", streamID: subtitleStreamID)
    }

    private static func select(server: URL,
                               token: String,
                               identity: ClientIdentity,
                               partID: Int,
                               streamParam: String,
                               streamID: Int) -> PlexRequest {
        let url = server.appendingPathComponent("/library/parts/\(partID)")
        var items: [URLQueryItem] = [
            .init(name: streamParam, value: String(streamID)),
            .init(name: "allParts", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        items.append(contentsOf: TimelineRequest.identityQueryItems(identity))
        return PlexRequest(url: url, method: "PUT",
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
