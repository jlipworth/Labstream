import Foundation

/// Backend-independent classification for saved credential validation.
///
/// Only an explicit authentication rejection proves that a saved secret is unusable.
/// Permission failures and availability errors preserve it so a restricted library,
/// reverse proxy, or temporary outage cannot turn into destructive logout churn.
public enum CredentialValidationDecision: Sendable, Equatable {
    case valid
    case invalidCredential
    case refreshExpiredCredential
    case preserveCredential
}

public enum CredentialValidationPolicy {
    public static func decision(httpStatus: Int, supportsExpiredTokenRefresh: Bool = false)
        -> CredentialValidationDecision {
        switch httpStatus {
        case 200..<300:
            return .valid
        case 401:
            return .invalidCredential
        case 498 where supportsExpiredTokenRefresh:
            return .refreshExpiredCredential
        default:
            return .preserveCredential
        }
    }
}
