import Foundation

/// Stable filenames for user-initiated diagnostic report export/share artifacts.
///
/// Keep the names in PMSKit so Settings export, Feedback share previews, and tests do not drift
/// while the app target still owns platform wrappers such as `FileDocument` and `Transferable`.
public enum DiagnosticReportArtifactMetadata {
    public static let exportFilename = "Labstream-Diagnostic-Report"
    public static let feedbackFilename = "Labstream-Feedback.txt"
}
