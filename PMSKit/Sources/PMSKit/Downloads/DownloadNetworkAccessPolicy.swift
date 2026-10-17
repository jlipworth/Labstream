import Foundation

/// Network-cost policy for download data-plane requests (D5).
///
/// The Downloads "Use cellular data" setting governs every costly network class, not only
/// cellular radios: constrained networks (Low Data Mode) and expensive networks (for example a
/// personal hotspot) follow the same setting. The background session stays permissive and each
/// freshly created request carries the policy, so a settings change applies to new tasks without
/// recreating the session; resume-data tasks keep the policy archived with their original request.
public enum DownloadNetworkAccessPolicy {
    public static func applying(allowsCostlyNetworks: Bool, to request: URLRequest) -> URLRequest {
        var policyRequest = request
        policyRequest.allowsCellularAccess = allowsCostlyNetworks
        policyRequest.allowsConstrainedNetworkAccess = allowsCostlyNetworks
        policyRequest.allowsExpensiveNetworkAccess = allowsCostlyNetworks
        return policyRequest
    }
}
