import Foundation

/// Builds the prefilled GitHub new-issue link for the in-app report form (`app_report.yml`).
///
/// GitHub fills issue-form text fields from query parameters named after each field's `id`. A
/// link that is too long is rejected, so the report is fitted to a length budget: the head
/// (build, device, server, crash summaries, last playback) always goes first, then as many of the
/// newest events as fit. The caller copies the complete report to the clipboard separately.
public enum FeedbackIssueLink {
    public static let template = "app_report.yml"
    /// Conservative: GitHub rejects very long request lines, and a QR code is far smaller still.
    public static let defaultMaxLength = 6000

    public struct Result: Sendable, Equatable {
        public var url: String
        /// How many event lines made it into the link.
        public var includedEvents: Int
        /// False when not even the report head fitted and the link carries no report.
        public var includesReport: Bool
    }

    /// - Parameters:
    ///   - base: `https://github.com/<owner>/<repo>/issues/new`, without a query.
    ///   - note: the user's description, already redacted. Becomes the title and "What happened".
    ///   - environment: `DiagnosticReportRenderer.environmentLine`.
    ///   - parts: `DiagnosticReportRenderer.renderParts`; nil sends no report (Apple TV QR code).
    public static func make(base: String,
                            note: String,
                            environment: String,
                            parts: DiagnosticReportRenderer.Parts?,
                            maxLength: Int = defaultMaxLength) -> Result {
        var fields: [(String, String)] = [("template", template)]
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            fields.append(("title", title(from: trimmedNote)))
            fields.append(("what-happened", trimmedNote))
        }
        if !environment.isEmpty { fields.append(("environment", environment)) }
        let bare = url(base, fields)
        guard let parts else { return Result(url: bare, includedEvents: 0, includesReport: false) }

        let headOnly = url(base, fields + [("report", parts.head + "\n(events omitted: link length)")])
        guard headOnly.count <= maxLength else {
            return Result(url: bare, includedEvents: 0, includesReport: false)
        }
        // Newest events are the ones nearest the failure; add them until the budget is spent.
        var included: [String] = []
        var best = parts.eventLines.isEmpty
            ? url(base, fields + [("report", parts.head + "\n(none)")])
            : headOnly
        if best.count > maxLength { best = headOnly }
        for line in parts.eventLines.reversed() {
            let candidate = [line] + included
            let omitted = parts.eventLines.count - candidate.count
            let prefix = omitted > 0 ? "\n(\(omitted) older events omitted: link length)\n" : "\n"
            let text = parts.head + prefix + candidate.joined(separator: "\n")
            let link = url(base, fields + [("report", text)])
            guard link.count <= maxLength else { break }
            included = candidate
            best = link
        }
        return Result(url: best, includedEvents: included.count, includesReport: true)
    }

    /// The first line of the note, shortened, as the issue title.
    static func title(from note: String) -> String {
        let firstLine = note.split(whereSeparator: \.isNewline).first.map(String.init) ?? note
        let collapsed = firstLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > 72 else { return collapsed }
        return String(collapsed.prefix(71)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func url(_ base: String, _ fields: [(String, String)]) -> String {
        let query = fields.map { "\(encoded($0.0))=\(encoded($0.1))" }.joined(separator: "&")
        return "\(base)?\(query)"
    }

    /// RFC 3986 unreserved characters plus `:` `,` `/`, which are legal in a query value and
    /// common in the report. `&`, `=`, `+`, `#` and spaces are always escaped (GitHub reads a bare
    /// `+` as a space).
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:,/")
        return set
    }()

    static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
