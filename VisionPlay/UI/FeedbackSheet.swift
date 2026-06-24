import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PMSKit

/// Bug-report flow (#85 v1, no backend).
///
/// The fast path is **Open a GitHub issue**: it deep-links to the bug form with the user's
/// description and version fields already filled in, attaches the redacted diagnostic report
/// inline when it fits in the URL, and always copies the report to the clipboard as the
/// paste-it-yourself fallback. The optional free-text note is the only new input; it is folded
/// in ONLY through `DiagnosticRedactor.redact` (never raw) and the live "exactly what is
/// shared" preview shows the report that ships. `ShareLink` covers the share-to-Mail/Files path.
struct FeedbackSheet: View {
    /// Already redacted upstream by SettingsView's `diagnosticReportText`.
    let reportText: String
    /// The canonical new-issue URL (`…/issues/new?template=bug_report.yml`). Its base is reused
    /// to build the prefilled link; on overflow it is the plain fallback.
    let githubIssuesURL: URL
    /// "1.2.0 (1)" — prefills the form's version field. Empty string omits it.
    let appVersionBuild: String
    /// "26.5" — prefills the visionOS-version field. Empty string omits it.
    let osVersion: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Optional "What were you doing?" free text. Scrubbed before it joins the report.
    @State private var note: String = ""
    @State private var copied = false

    /// GitHub issue forms cap how long a prefill URL they accept; past this we drop the report
    /// from the URL and rely on the clipboard copy instead. Conservative so we never 414.
    private static let maxPrefillURLLength = 6000

    /// The note exactly as it will be shared/prefilled: run through the same redactor as the
    /// report so it can never carry a token / host / IP / path / filename / email out. Empty
    /// when the note is blank.
    private var redactedNote: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : DiagnosticRedactor.redact(trimmed)
    }

    /// True when redaction actually changed the user's note (so we can tell them).
    private var noteWasScrubbed: Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && redactedNote != trimmed
    }

    /// `…/issues/new` with no query — the base we re-attach our own prefill params to.
    private var issuesNewBase: String {
        var components = URLComponents(url: githubIssuesURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? githubIssuesURL.absoluteString
    }

    /// The bug form prefilled by field `id`: description (`what-happened`), the two version
    /// fields, and the redacted report (`diagnostic-report`) when it fits under the length cap.
    private var githubIssueURL: URL {
        var items: [(String, String)] = [("template", "bug_report.yml")]
        if !redactedNote.isEmpty { items.append(("what-happened", redactedNote)) }
        if !appVersionBuild.isEmpty { items.append(("app-version", appVersionBuild)) }
        if !osVersion.isEmpty { items.append(("visionos-version", osVersion)) }

        func url(_ pairs: [(String, String)]) -> String {
            let query = pairs
                .map { "\(Self.percentEncoded($0.0))=\(Self.percentEncoded($0.1))" }
                .joined(separator: "&")
            return "\(issuesNewBase)?\(query)"
        }

        let withReport = url(items + [("diagnostic-report", reportText)])
        let chosen = withReport.count <= Self.maxPrefillURLLength ? withReport : url(items)
        return URL(string: chosen) ?? githubIssuesURL
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("What were you doing?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    if noteWasScrubbed {
                        Label("Scrubbed for privacy — will be sent as: \(redactedNote)",
                              systemImage: "checkmark.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Describe the problem (optional)")
                } footer: {
                    Text("Your note is scrubbed the same way the rest of the report is — tokens, server name/URL/IP, usernames, paths, filenames, and media titles are removed before it's shared.")
                }

                SwiftUI.Section {
                    Button {
                        UIPasteboard.general.string = reportText
                        openURL(githubIssueURL)
                    } label: {
                        Label("Open a GitHub issue", systemImage: "ant")
                    }

                    Button {
                        UIPasteboard.general.string = reportText
                        copied = true
                        resetCopiedSoon()
                    } label: {
                        Label(copied ? "Copied report" : "Copy report",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    ShareLink(
                        item: FeedbackReportFile(text: reportText),
                        preview: SharePreview("VisionPlay-Feedback.txt")
                    ) {
                        Label("Share report…", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Open a GitHub issue fills in the form with your description and versions, attaches the report when it fits, and copies it to your clipboard either way so you can paste it into the report field. Everything in a GitHub issue is public — review the preview below first.")
                }

                SwiftUI.Section {
                    Text(reportText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Diagnostic report (exactly what is shared)")
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

    private func resetCopiedSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    /// Percent-encode a query value, allowing only alphanumerics so `&`, `=`, `+`, `#`, and
    /// spaces are all escaped (GitHub treats a bare `+` as a space, so `.urlQueryAllowed` is
    /// not safe here).
    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
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
