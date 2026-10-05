import Foundation

/// Playback-only explanations. Classify domain/code, never display server text or URLs.
/// The underlying error is left intact for the diagnostic report.
public enum PlaybackFailureExplanation {
    public static let deliveryTimeout = "The video did not arrive in time. The connection may be slow, or the server may need more time to prepare it. Try again or choose a lower playback quality."

    public static func message(for error: Error?) -> String? {
        guard let error else { return nil }
        var current = error as NSError
        var seen = Set<ObjectIdentifier>()
        var explanation: String?
        // Wrappers often hide the useful decoder/network error. Prefer the deepest known
        // cause, with a bound and cycle guard for externally supplied NSError chains.
        for _ in 0..<12 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { break }
            if let message = message(domain: current.domain, code: current.code) {
                explanation = message
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return explanation
    }

    private static func message(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case ("CoreMediaErrorDomain", -12889), ("CoreMediaErrorDomain", -16830):
            return deliveryTimeout
        case ("CoreMediaErrorDomain", -12906), ("CoreMediaErrorDomain", -12910),
             ("NSOSStatusErrorDomain", -12906), ("NSOSStatusErrorDomain", -12910),
             ("AVFoundationErrorDomain", -11855):
            return "This device could not decode this version of the video. Try another version or choose a lower playback quality so the server can convert it."
        case ("AVFoundationErrorDomain", -11828):
            return "This device could not read the media format. Try another version or choose a lower playback quality."
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return deliveryTimeout
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return "The connection was interrupted. Check your network connection, then try again."
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            return "Labstream could not reach the server. Check that the server is running and reachable from this network, then try again."
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            return "Labstream could not establish a secure connection to the server. Check the device date and time, or ask the server owner to check its security certificate."
        case (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired):
            return "The server requires sign-in before it can play this video. Sign in again, then retry playback."
        default:
            return nil
        }
    }
}
