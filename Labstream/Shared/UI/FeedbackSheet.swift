import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import PMSKit

/// Problem-report flow (#272, no backend).
///
/// The fast path is **Open a GitHub issue**: it deep-links to the short in-app report form
/// (`app_report.yml`) with the description, an environment line and the redacted report already
/// filled in, and copies the complete report to the clipboard. The link always carries the
/// report's head (build, device, server, crash summaries, last playback) and as many of the
/// newest events as fit. The free-text note is folded in ONLY through `DiagnosticRedactor.redact`
/// (never raw), and the preview shows the report that ships. `ShareLink` covers Mail and Files.
struct FeedbackSheet: View {
    /// Built by `FeedbackSheetHost`; every string in it is redacted again when rendered.
    let context: DiagnosticReportContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Optional "What happened?" free text. Scrubbed before it joins the report.
    @State private var note: String = ""
    @State private var copied = false
    @State private var openedIssue = false

    private var reportText: String { AppDiagnostics.report(context: context) }
    private var environmentLine: String { DiagnosticReportRenderer.environmentLine(context: context) }

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

    /// `…/issues/new` with no query — the base the prefill parameters are attached to.
    private var issuesNewBase: String {
        var components = URLComponents(url: LabstreamLinks.bugReport, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.string ?? LabstreamLinks.bugReport.absoluteString
    }

    private var githubIssueURL: URL {
        let link = FeedbackIssueLink.make(base: issuesNewBase, note: redactedNote,
                                          environment: environmentLine,
                                          parts: AppDiagnostics.reportParts(context: context))
        return URL(string: link.url) ?? LabstreamLinks.bugReport
    }

    #if os(tvOS)
    /// A QR code cannot carry the report and stay scannable from a sofa, so the Apple TV link
    /// holds the description (trimmed) and the one-line environment only.
    private static let maxQRNoteLength = 280

    private var tvIssueURL: String {
        FeedbackIssueLink.make(base: issuesNewBase,
                               note: String(redactedNote.prefix(Self.maxQRNoteLength)),
                               environment: environmentLine, parts: nil).url
    }

    /// Apple TV has no browser, clipboard or share sheet: the screen is a note field beside a QR
    /// code that opens the prefilled bug form on a phone.
    var body: some View {
        HStack(alignment: .center, spacing: 100) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Report a problem")
                    .font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Text("What happened?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Describe the problem", text: $note)
                        .accessibilityIdentifier("feedback.note")
                    Text(redactedNote.isEmpty
                         ? "Server names, addresses and file names are removed."
                         : "Will be sent as: \(redactedNote)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sent with your note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(environmentLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("feedback.environment")
                }
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("feedback.cancel")
            }
            .frame(maxWidth: 820, alignment: .leading)

            VStack(spacing: 24) {
                if let image = QRCodeRenderer.image(for: tvIssueURL) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420, height: 420)
                        .padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .accessibilityLabel("QR code for the bug form")
                        .accessibilityIdentifier("feedback.qr")
                }
                Text("Scan with your iPhone")
                    .font(.headline)
                Text("Opens the report form, filled in. We read every report. Issues are public.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: the cover is otherwise translucent and Settings shows through the text.
        .background(Color.black.ignoresSafeArea())
    }
    #else
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("What happened?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("feedback.note")
                    if noteWasScrubbed {
                        Label("Scrubbed for privacy — will be sent as: \(redactedNote)",
                              systemImage: "checkmark.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Describe the problem")
                } footer: {
                    Text("Reports are how Labstream gets better, and we read every one. Your note is scrubbed for tokens, server name/URL/IP, usernames, paths, and filenames. Media titles or personal details in ordinary prose may remain, so check the preview below.")
                }

                SwiftUI.Section {
                    Button {
                        PlatformPasteboard.copy(reportText)
                        openedIssue = true
                        openURL(githubIssueURL)
                    } label: {
                        Label("Open a GitHub issue", systemImage: "ant")
                    }
                    .accessibilityIdentifier("feedback.openIssue")
                    if openedIssue {
                        Label("The full report is also on your clipboard, in case you want to paste it over the shortened one in the form.",
                              systemImage: "doc.on.clipboard")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("feedback.clipboardNote")
                    }

                    Button {
                        PlatformPasteboard.copy(reportText)
                        copied = true
                        resetCopiedSoon()
                    } label: {
                        Label(copied ? "Copied report" : "Copy report",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    ShareLink(
                        item: DiagnosticReportArtifact.ShareFile(text: reportText),
                        preview: SharePreview(DiagnosticReportArtifact.feedbackFilename)
                    ) {
                        Label("Share report…", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Open a GitHub issue fills in a short form with your description, your app and device details, and the report below. You only need to press Submit. It needs a GitHub account, and everything in an issue is public. No account? Share the report to \(LabstreamLinks.supportEmailAddress) instead.")
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
            .navigationTitle("Report a problem")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    #endif

    private func resetCopiedSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
