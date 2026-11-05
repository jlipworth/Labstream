import Foundation

/// Single source of truth for the public support, privacy, and contact links shown in the app
/// (Settings ▸ About, the sign-in footer, the Mac Help menu, and the feedback handoff).
///
/// App Review guideline 5.1.1(i) requires an easily accessible in-app privacy-policy link, and the
/// support page must lead to real contact information. When the project site moves to
/// `https://labstream.app/`, change `siteBase` only; keep it in sync with
/// `appstore/metadata/*/en-US/support_url.txt` and `appstore/metadata/app/en-US/privacy_policy_url.txt`.
enum LabstreamLinks {
    static let siteBase = "https://jlipworth.github.io/Labstream/"

    static let privacyPolicy = URL(string: siteBase + "privacy/")!
    static let support = URL(string: siteBase + "support/")!

    static let supportEmailAddress = "support@labstream.app"
    static let supportEmail = URL(string: "mailto:" + supportEmailAddress)!

    /// Template-prefilled GitHub new-issue URL for the bug form.
    static let bugReport = URL(string: "https://github.com/jlipworth/Labstream/issues/new?template=bug_report.yml")!

    /// A URL without its scheme or trailing slash, for places the user must read or type it
    /// (Apple TV cannot open a browser).
    static func displayString(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://", "mailto:"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
