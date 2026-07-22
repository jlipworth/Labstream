import Foundation
import PMSKit

/// Cross-cutting contract for the final handoff from a backend-specific source decision to the
/// shared background transfer engine.
///
/// Backends still own source resolution, server-prep, keepalive, and cleanup quirks. This value
/// captures only the common transfer-start surface: exact seeded ownership, diagnostics,
/// expected-byte accounting, and the per-lane failure-release policy. Keeping it explicit makes it
/// harder for a new lane to bypass
/// `downloads.start` / `downloads.start_failed` or forget which paths release the in-flight slot on
/// immediate URLSession start failure.
struct DownloadTransferStartPlan {
    let attemptKey: DownloadAttemptKey
    var ratingKey: String { attemptKey.ratingKey }
    let backendLabel: String
    let choiceLabel: String
    let urlShape: URL?
    let expectedBytes: Int?
    let releaseInFlightOnFailure: Bool
    let extraDiagnosticFields: [String: DiagnosticFieldValue]

    init(attemptKey: DownloadAttemptKey,
         backendLabel: String,
         choiceLabel: String,
         urlShape: URL?,
         expectedBytes: Int?,
         releaseInFlightOnFailure: Bool,
         extraDiagnosticFields: [String: DiagnosticFieldValue] = [:]) {
        self.attemptKey = attemptKey
        self.backendLabel = backendLabel
        self.choiceLabel = choiceLabel
        self.urlShape = urlShape
        self.expectedBytes = expectedBytes
        self.releaseInFlightOnFailure = releaseInFlightOnFailure
        self.extraDiagnosticFields = extraDiagnosticFields
    }
}
