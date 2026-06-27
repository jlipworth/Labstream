import Foundation

/// Shared executor for MediaBrowser `/Videos/ActiveEncodings` teardown.
///
/// Backend-specific services still own request construction because Jellyfin and Emby carry
/// different auth/user-id dialects. This helper centralizes the identical send/catch/status
/// interpretation so teardown behavior cannot drift between the two app services.
public enum MediaBrowserActiveEncodingStopExecutor {
    public typealias RequestBuilder = () throws -> URLRequest
    public typealias Sender = (URLRequest) async throws -> Void
    public typealias HTTPStatusExtractor = (Error) -> Int?

    @MainActor
    @discardableResult
    public static func stop(playSessionId: String,
                            makeRequest: RequestBuilder,
                            send: Sender,
                            httpStatus: HTTPStatusExtractor) async -> Bool {
        guard !playSessionId.isEmpty else { return false }
        let request: URLRequest
        do {
            request = try makeRequest()
        } catch {
            return false
        }

        do {
            try await send(request)
            return true
        } catch {
            return MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: httpStatus(error))
        }
    }
}
