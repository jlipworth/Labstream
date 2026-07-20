import Foundation

/// Centralized product capability policy for platform-level exceptions.
///
/// Keep this separate from API availability checks: an API may compile on tvOS while the
/// corresponding Labstream product contract is still intentionally unsupported there.
enum PlatformFeaturePolicy {
    #if os(tvOS)
    static let supportsDownloads = false
    #else
    static let supportsDownloads = true
    #endif
}
