import Foundation

/// The HTTP side of "Send log to iPhone" on Apple TV, with no sockets in it.
///
/// Apple TV has no clipboard, share sheet or file exporter, so the app serves the redacted
/// diagnostics to a phone on the same network while one Settings screen is open. This type turns
/// a request head into a response; the app target owns the listener. Every path is under a
/// random per-presentation token, so a device that has not scanned the QR code gets 404.
public enum DiagnosticLogShareHTTP {
    /// What one presentation of the screen serves. Both parts are already redacted by the
    /// diagnostics pipeline before they reach this type.
    public struct Payload: Sendable, Equatable {
        /// The same report the other platforms copy or export.
        public var reportText: String
        /// The on-disk event log (JSON lines, oldest first). Empty when nothing was recorded.
        public var eventLog: Data

        public init(reportText: String, eventLog: Data) {
            self.reportText = reportText
            self.eventLog = eventLog
        }
    }

    public enum Served: String, Sendable, Equatable {
        case page
        case report
        case eventLog = "event_log"
    }

    public struct Response: Sendable, Equatable {
        public var status: Int
        public var headers: [(name: String, value: String)]
        public var body: Data
        /// Set when the response carried one of the payload's resources.
        public var served: Served?

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body && lhs.served == rhs.served
                && lhs.headers.map(\.name) == rhs.headers.map(\.name)
                && lhs.headers.map(\.value) == rhs.headers.map(\.value)
        }

        public func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The bytes to put on the wire. `includeBody` is false for HEAD.
        public func serialized(includeBody: Bool = true) -> Data {
            var head = "HTTP/1.1 \(status) \(DiagnosticLogShareHTTP.reason(status))\r\n"
            for header in headers { head += "\(header.name): \(header.value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var data = Data(head.utf8)
            if includeBody { data.append(body) }
            return data
        }
    }

    public static let reportPathComponent = "report.txt"
    public static let eventLogPathComponent = "events.jsonl"
    /// A request head larger than this is rejected rather than buffered.
    public static let maxRequestHeadBytes = 16_384

    /// 16 lowercase hex characters: short enough to keep the QR code coarse, long enough that a
    /// neighbour cannot guess it while the screen is open.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// True once `data` holds a complete request head (the blank line has arrived).
    public static func hasCompleteHead(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    /// True when the request line asks for HEAD, so the body must be left off the wire.
    public static func isHeadRequest(_ requestHead: String) -> Bool {
        requestHead.hasPrefix("HEAD ")
    }

    public static func respond(toRequestHead requestHead: String,
                               token: String,
                               payload: Payload) -> Response {
        // `isNewline`, not a comparison with "\r": Swift treats "\r\n" as one Character.
        let requestLine = requestHead.prefix { !$0.isNewline }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return plain(400, "Bad request")
        }
        guard parts[0] == "GET" || parts[0] == "HEAD" else {
            var response = plain(405, "Method not allowed")
            response.headers.append(("Allow", "GET, HEAD"))
            return response
        }
        // Drop the query: iOS adds nothing here, but a pasted link might.
        let path = parts[1].prefix { $0 != "?" && $0 != "#" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !token.isEmpty, components.first == token, components.count <= 2 else {
            return plain(404, "Not found")
        }
        switch components.count == 2 ? components[1] : nil {
        case nil:
            return Response(status: 200,
                            headers: [("Content-Type", "text/html; charset=utf-8")] + noStore,
                            body: Data(page(token: token, payload: payload).utf8),
                            served: .page)
        case reportPathComponent:
            return download(Data(payload.reportText.utf8),
                            contentType: "text/plain; charset=utf-8",
                            filename: DiagnosticReportArtifactMetadata.exportFilename + ".txt",
                            served: .report)
        case eventLogPathComponent:
            return download(payload.eventLog,
                            contentType: "application/x-ndjson",
                            filename: DiagnosticReportArtifactMetadata.eventLogFilename,
                            served: .eventLog)
        default:
            return plain(404, "Not found")
        }
    }

    // MARK: - Private

    private static let noStore: [(name: String, value: String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
    ]

    private static func plain(_ status: Int, _ text: String) -> Response {
        Response(status: status,
                 headers: [("Content-Type", "text/plain; charset=utf-8")] + noStore,
                 body: Data((text + "\n").utf8),
                 served: nil)
    }

    private static func download(_ body: Data, contentType: String, filename: String,
                                 served: Served) -> Response {
        Response(status: 200,
                 headers: [("Content-Type", contentType),
                           ("Content-Disposition", "attachment; filename=\"\(filename)\"")] + noStore,
                 body: body,
                 served: served)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    private static func page(token: String, payload: Payload) -> String {
        let eventLines = payload.eventLog.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "\n") { count += 1 }
        }
        let eventLog = eventLines == 0
            ? "<p class=\"muted\">No event log yet. Turn on diagnostic logging on the Apple TV, "
                + "reproduce the problem, then open this screen again.</p>"
            : "<a class=\"button\" href=\"/\(token)/\(eventLogPathComponent)\" download>"
                + "Full event log<span>\(eventLines) events · \(byteCount(payload.eventLog.count))"
                + "</span></a>"
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Labstream diagnostics</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 17px -apple-system, system-ui, sans-serif; margin: 0; padding: 32px 20px;
               max-width: 520px; margin-inline: auto; }
        h1 { font-size: 26px; margin: 0 0 8px; }
        p { line-height: 1.4; }
        .muted { opacity: 0.65; font-size: 15px; }
        .button { display: block; margin: 16px 0; padding: 16px 18px; border-radius: 14px;
                  background: #0a84ff; color: #fff; text-decoration: none; font-weight: 600; }
        .button span { display: block; font-weight: 400; font-size: 14px; opacity: 0.85;
                       margin-top: 2px; }
        </style>
        </head>
        <body>
        <h1>Labstream diagnostics</h1>
        <p>From your Apple TV. Server names, addresses and file names are already removed.</p>
        <a class="button" href="/\(token)/\(reportPathComponent)" download>Diagnostic report\
        <span>Summary and most recent events · \(byteCount(payload.reportText.utf8.count))</span></a>
        \(eventLog)
        <p class="muted">These links work only while the screen on your Apple TV is open.</p>
        </body>
        </html>

        """
    }

    private static func byteCount(_ bytes: Int) -> String {
        bytes < 1_000_000
            ? "\(max(1, (bytes + 512) / 1_024)) KB"
            : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
