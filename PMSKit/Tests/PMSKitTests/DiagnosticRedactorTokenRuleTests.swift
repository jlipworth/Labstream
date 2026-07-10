import Foundation
import Testing
@testable import PMSKit

/// Audit lens 8 B-1: the bare-token rule of last resort used to blank ANY 24+ char run of
/// `[A-Za-z0-9_=-]` — which swallowed ~25 long snake_case downloads diagnostic labels and every
/// AVFoundation error summary. The rule now requires at least one digit; these tests pin both
/// directions: labels survive, realistic token shapes still die.
@Suite("Diagnostic redactor bare-token rule")
struct DiagnosticRedactorTokenRuleTests {

    /// The previously-blanked diagnostic vocabulary (all ≥24 chars, digitless).
    private static let downloadsLabels = [
        "changed_resource_restart",
        "validator_mismatch_at_drain",
        "durable_checkpoint_ahead",
        "range_checkpoint_recovered",
        "serverAuthorizationRejected",
        "plex_session_mismatch_or_unavailable",
        "emby_session_mismatch_or_unavailable",
        "jellyfin_session_mismatch_or_unavailable",
        "unverified_timeout_not",
        "unverified_probe_failed",
        "failed_incomplete_bytes_kept",
        "resume_missing_job_id_recreate",
        "jellyfin_keepalive_degraded",
        "optimize_poll_unreachable",
        "range_resume_deferred_backend",
    ]

    @Test("Long digitless diagnostic labels survive redaction", arguments: downloadsLabels)
    func labelsSurvive(label: String) {
        #expect(DiagnosticRedactor.redact(label) == label)
        #expect(!DiagnosticRedactor.redact("reason=\(label) attempt=first").contains("[token]"))
    }

    @Test("AVFoundation error summaries survive intact")
    func errorSummarySurvives() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let summary = DiagnosticRedactor.safeErrorSummary(error)
        #expect(summary.contains("family=avfoundation"))
        #expect(DiagnosticRedactor.redact(summary) == summary)
    }

    /// Realistic token shapes: 32-hex, mixed-alnum Plex-style, base64-ish, JWT segment.
    private static let tokenShapes = [
        "ABCDEF0123456789ABCDEF0123456789",
        "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
        "xJ9v2mQ7pL4kR8tW3nZ6cY1s",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
        "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA==",
    ]

    @Test("Realistic token shapes are still redacted", arguments: tokenShapes)
    func tokensDie(token: String) {
        // Base64 `=` padding can sit outside the match's trailing word boundary, so assert the
        // payload is gone and "[token]" appears rather than exact equality.
        let bare = DiagnosticRedactor.redact(token)
        #expect(bare.contains("[token]"))
        #expect(!bare.contains(String(token.prefix(20))))
        #expect(!DiagnosticRedactor.redact("stray body \(token) trailing").contains(String(token.prefix(20))))
    }

    @Test("key=value and URL rules remain the primary scrubbers regardless of digits")
    func primaryRulesUnaffected() {
        // A digitless secret still dies when it appears in the key=value form.
        let digitless = "X-Plex-Token=abcdefghijklmnopqrstuvwxyz"
        #expect(DiagnosticRedactor.redact(digitless) == "X-Plex-Token=[redacted]")
        // And inside a URL everything collapses to the URL shape.
        let url = "https://plex.example.internal/library?X-Plex-Token=abcdefghijklmnopqrstuvwxyz"
        #expect(DiagnosticRedactor.redact(url) == "[url:https]")
    }

    @Test("Bounded unverified label stays under the bare-token threshold")
    func unverifiedLabelBounded() {
        let long = BackgroundFinalizationResultPolicy.unverifiedResultLabel(
            reason: "asset_not_playable_after_retry_budget_exhausted")
        #expect(long.count < 24)
        #expect(DiagnosticRedactor.redact(long) == long)
        #expect(BackgroundFinalizationResultPolicy.unverifiedResultLabel(reason: "timeout_not_ready")
                == "unverified_timeout_not")
        #expect(BackgroundFinalizationResultPolicy.unverifiedResultLabel(reason: "")
                == "unverified_probe")
    }
}
