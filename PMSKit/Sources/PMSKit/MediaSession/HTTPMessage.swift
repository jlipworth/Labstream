import Foundation

/// A parsed HTTP/1.1 request head (everything up to and including the blank line).
/// Pure and allocation-light: parsing is just a scan for the CRLFCRLF terminator and a
/// split of the lines above it. We only ever receive GET requests from AVKit (HLS), so
/// there is no request body to read.
struct HTTPRequestHead: Equatable {
    var method: String
    /// The request-target as sent, e.g. `/video/:/transcode/universal/index.m3u8?session=…`.
    var target: String
    var headers: [(name: String, value: String)]

    static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target
            && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
    }

    /// Case-insensitive header lookup (first match).
    func value(for name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Parse a request head from `data`. Returns nil if the terminating blank line
    /// (`\r\n\r\n`) has not arrived yet, so the caller knows to read more.
    /// `headByteCount` is the number of bytes consumed by the head, so any trailing
    /// bytes already read can be split off.
    static func parse(_ data: Data) -> (head: HTTPRequestHead, headByteCount: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let headBytes = data[data.startIndex..<range.lowerBound]
        guard let headText = String(data: headBytes, encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let head = HTTPRequestHead(method: parts[0], target: parts[1], headers: headers)
        return (head, range.upperBound - data.startIndex)
    }
}

/// A response to serialize back to AVKit. We always close the connection after one
/// response (`Connection: close`) — one request per connection keeps the loopback origin
/// trivial. Keep-alive is a later refinement, not needed for correctness.
struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [(name: String, value: String)]
    var body: Data

    init(status: Int, reason: String, headers: [(name: String, value: String)], body: Data) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        // Drop any upstream framing headers we are about to set ourselves.
        for (name, value) in headers
        where !["content-length", "connection", "transfer-encoding"].contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
