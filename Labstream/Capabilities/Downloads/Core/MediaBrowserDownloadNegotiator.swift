#if !os(tvOS)
import Foundation
import PMSKit

/// One transport/decode/verdict boundary. Backend adapters retain their distinct download
/// profiles and typed decisions; callers retain exact-attempt persistence and encoder cleanup.
@MainActor
enum MediaBrowserDownloadNegotiator {
    static func negotiate<Response, Decision>(
        request: () throws -> URLRequest,
        send: (URLRequest) async throws -> (Data, URLResponse),
        decode: (Data) throws -> Response,
        decide: (Response) throws -> Decision
    ) async throws -> Decision {
        let (data, response) = try await send(request())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadManager.DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
        }
        return try decide(decode(data))
    }
}
extension DownloadManager {
    /// A suspended request can never publish or dispatch under a replacement login/server.
    func mediaBrowserSessionIsCurrent(_ captured: BackendSession) -> Bool {
        guard let live = appModel.backendSession(for: captured.kind) else { return false }
        return live == captured
    }
}
#endif
