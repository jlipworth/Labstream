import Foundation
import Network

/// A minimal loopback HTTP/1.1 origin. Binds `127.0.0.1:0`, and for each inbound connection
/// reads exactly one request head (GET, no body — HLS), hands it to `handler`, writes the
/// serialized response, and closes. One request per connection keeps this trivial and is
/// correct for HLS; keep-alive is a deferred refinement.
final class LoopbackOrigin: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead) async -> HTTPResponse

    private let queue = DispatchQueue(label: "media-session-proxy.loopback")
    private var listener: NWListener?

    /// Start listening and resume with the bound port once ready.
    func start(handler: @escaping Handler) async throws -> Int {
        // The listener's state callbacks are treated as concurrently-executing, so the
        // resume-once guard must be a thread-safe reference rather than a captured `var`.
        let resume = ResumeOnce()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let params = NWParameters.tcp
                    params.requiredInterfaceType = .loopback
                    let listener = try NWListener(using: params, on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] conn in
                        self?.handle(conn, handler: handler)
                    }
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard resume.claim() else { return }
                            if let port = listener.port?.rawValue {
                                cont.resume(returning: Int(port))
                            } else {
                                cont.resume(throwing: URLError(.cannotConnectToHost))
                            }
                        case .failed(let err):
                            guard resume.claim() else { return }
                            cont.resume(throwing: err)
                        default:
                            break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    guard resume.claim() else { return }
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ conn: NWConnection, handler: @escaping Handler) {
        conn.start(queue: queue)
        readHead(conn, buffer: Data()) { head in
            guard let head else { conn.cancel(); return }
            Task {
                let response = await handler(head)
                conn.send(content: response.serialized(), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    /// Accumulate bytes until the request head is complete (`\r\n\r\n`), then deliver it.
    private func readHead(_ conn: NWConnection, buffer: Data, done: @escaping @Sendable (HTTPRequestHead?) -> Void) {
        if let parsed = HTTPRequestHead.parse(buffer) {
            done(parsed.head)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if let parsed = HTTPRequestHead.parse(next) {
                done(parsed.head)
            } else if isComplete || error != nil {
                done(nil)
            } else {
                self.readHead(conn, buffer: next, done: done)
            }
        }
    }
}

/// One-shot guard so a continuation resumes exactly once across the listener's state
/// callbacks, which the compiler treats as concurrently-executing.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once; false on every subsequent call.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
