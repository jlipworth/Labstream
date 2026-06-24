import SwiftUI
import UniformTypeIdentifiers
import PMSKit

/// Bug-report share flow (#85 v1, no backend).
///
/// Takes the ALREADY-redacted diagnostic `reportText` (built by SettingsView) plus the
/// canonical GitHub bug-form URL. The user's optional free-text note is the only new
/// input, and it is folded into the shared blob ONLY through `DiagnosticRedactor.redact`
/// — never raw — so the live preview shows exactly what would ship. Sharing goes through
/// SwiftUI's native `ShareLink` (a `.txt` via `FeedbackReportFile`), and "Open an issue
/// on GitHub" deep-links to the template-prefilled new-issue form.
struct FeedbackSheet: View {
    /// Already redacted upstream by SettingsView's `diagnosticReportText`.
    let reportText: String
    let githubIssuesURL: URL

    @Environment(\.dismiss) private var dismiss

    /// Optional "What were you doing?" free text. Scrubbed before it joins the report.
    @State private var note: String = ""

    /// The exact blob that will be shared/copied: the user's note (redacted) prepended to
    /// the already-redacted report. The note is run through `DiagnosticRedactor.redact` so
    /// it can never carry a token / host / IP / path / filename / email into the report.
    private var sharedReport: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return reportText }
        let redactedNote = DiagnosticRedactor.redact(trimmed)
        return "What I was doing:\n\(redactedNote)\n\n\(reportText)"
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("What were you doing?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Describe the problem (optional)")
                } footer: {
                    Text("Your note is scrubbed the same way the rest of the report is — tokens, server name/URL/IP, usernames, paths, filenames, and media titles are removed before it's shared.")
                }

                SwiftUI.Section {
                    ShareLink(
                        item: FeedbackReportFile(text: sharedReport),
                        preview: SharePreview("VisionPlay-Feedback.txt")
                    ) {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }

                    Link(destination: githubIssuesURL) {
                        Label("Open an issue on GitHub", systemImage: "ant")
                    }
                } footer: {
                    Text("Share the report into Messages, Mail, Files, or Notes, then open the GitHub bug form and paste it. Everything in a GitHub issue is public — review the preview below first.")
                }

                SwiftUI.Section {
                    Text(sharedReport)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Preview (exactly what is shared)")
                }
            }
            .navigationTitle("Send feedback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Transferable wrapper so `ShareLink` shares the report as a `.txt` file (first share-sheet
/// use in the app). Exported as `.plainText`; the share sheet suggests the filename below.
struct FeedbackReportFile: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName("VisionPlay-Feedback.txt")
    }
}
