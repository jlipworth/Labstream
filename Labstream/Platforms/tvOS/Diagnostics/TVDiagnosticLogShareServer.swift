import Foundation
import Network
import PMSKit

/// Serves the redacted diagnostics to a phone on the same network while the "Send log to iPhone"
/// screen is open. Plain HTTP on an ephemeral port; every path sits under a random token that
/// only the on-screen QR code carries (`DiagnosticLogShareHTTP`).
///
/// Listening for TCP does not raise the local-network prompt, and nothing is advertised over
/// Bonjour. The listener is not restricted to the local link, so a phone on another subnet of
/// the same home network still reaches it. All mutable state is confined to `queue`.
final class TVDiagnosticLogShareServer: @unchecked Sendable {
    enum Event: Sendable {
        case ready(port: UInt16)
        case failed
        case served(DiagnosticLogShareHTTP.Served)
    }

    private static let maxConnections = 8
    private static let connectionLifetime: TimeInterval = 30

    private let queue = DispatchQueue(label: "org.labstream.Labstream.diagnostics.share")
    private let token: String
    private let payload: DiagnosticLogShareHTTP.Payload
    private let onEvent: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(token: String,
         payload: DiagnosticLogShareHTTP.Payload,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.token = token
        self.payload = payload
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            guard let listener = try? NWListener(using: .tcp) else {
                onEvent(.failed)
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue { self.onEvent(.ready(port: port)) }
                case .failed:
                    listener?.cancel()
                    self.onEvent(.failed)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionLifetime) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffered = buffered
            if let data { buffered.append(data) }
            if DiagnosticLogShareHTTP.hasCompleteHead(buffered) {
                self.reply(on: connection, requestHead: String(decoding: buffered, as: UTF8.self))
            } else if error != nil || isComplete
                        || buffered.count > DiagnosticLogShareHTTP.maxRequestHeadBytes {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: buffered)
            }
        }
    }

    private func reply(on connection: NWConnection, requestHead: String) {
        let response = DiagnosticLogShareHTTP.respond(toRequestHead: requestHead, token: token,
                                                      payload: payload)
        let isHead = DiagnosticLogShareHTTP.isHeadRequest(requestHead)
        let served = isHead ? nil : response.served
        connection.send(content: response.serialized(includeBody: !isHead),
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [onEvent] error in
            if error == nil, let served { onEvent(.served(served)) }
            connection.cancel()
        })
    }
}

/// The address a phone on the same network can reach this Apple TV at.
enum TVLocalNetworkAddress {
    /// First up, non-loopback, non-link-local IPv4 address on an Ethernet or Wi-Fi interface.
    static func ipv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: interface.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.isEmpty, !text.hasPrefix("169.254.") { return text }
        }
        return nil
    }
}
