import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Shared wrappers for copy/export/share variants of the redacted diagnostics report.
enum DiagnosticReportArtifact {
    static let exportFilename = "VisionPlay-Diagnostic-Report"
    static let feedbackFilename = "VisionPlay-Feedback.txt"

    struct Document: FileDocument {
        static var readableContentTypes: [UTType] { [.plainText] }

        var text: String = ""

        init(text: String = "") {
            self.text = text
        }

        init(configuration: ReadConfiguration) throws {
            text = ""
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: Data(text.utf8))
        }
    }

    struct ShareFile: Transferable {
        let text: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .plainText) { file in
                Data(file.text.utf8)
            }
            .suggestedFileName(DiagnosticReportArtifact.feedbackFilename)
        }
    }
}
