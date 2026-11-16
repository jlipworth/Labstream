import SwiftUI
import PMSKit

/// Owns one presentation of the share server and the address shown for it.
@MainActor
@Observable
final class TVDiagnosticLogShareModel {
    enum State: Equatable {
        case starting
        case ready(address: String)
        case unavailable
    }

    private(set) var state: State = .starting
    private(set) var downloaded = false
    private var server: TVDiagnosticLogShareServer?

    func start(payload: DiagnosticLogShareHTTP.Payload) {
        guard server == nil else { return }
        guard let host = TVLocalNetworkAddress.ipv4() else {
            state = .unavailable
            return
        }
        let token = DiagnosticLogShareHTTP.makeToken()
        let server = TVDiagnosticLogShareServer(token: token, payload: payload) { [weak self] event in
            Task { @MainActor in self?.handle(event, host: host, token: token) }
        }
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func handle(_ event: TVDiagnosticLogShareServer.Event, host: String, token: String) {
        guard server != nil else { return }
        switch event {
        case .ready(let port):
            state = .ready(address: "http://\(host):\(port)/\(token)/")
        case .failed:
            state = .unavailable
        case .served(let served):
            guard served != .page else { return }
            downloaded = true
            AppDiagnostics.record(.settingsUI, "diagnostics.log_share_served", fields: [
                "resource": .label(served.rawValue),
            ])
        }
    }
}

/// "Send log to iPhone": Apple TV has no clipboard, share sheet or file exporter, so the redacted
/// report and event log are offered to a phone on the same network through a QR code. The link
/// stops working when this screen closes.
struct TVDiagnosticLogShareScreen: View {
    /// Built by Settings when the screen opens; already redacted.
    let reportText: String

    @Environment(\.dismiss) private var dismiss
    @State private var model = TVDiagnosticLogShareModel()
    @State private var eventCount = 0

    var body: some View {
        HStack(alignment: .center, spacing: 100) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Send log to iPhone")
                    .font(.title.bold())
                Text("Scan the code with an iPhone or iPad on the same network, then choose a file to download. Server names, addresses and file names are already removed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("logShare.status")
                if model.downloaded {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .accessibilityIdentifier("logShare.downloaded")
                }
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("logShare.done")
            }
            .frame(maxWidth: 820, alignment: .leading)

            VStack(spacing: 24) {
                switch model.state {
                case .starting:
                    ProgressView()
                        .frame(width: 468, height: 468)
                case .ready(let address):
                    if let image = QRCodeRenderer.image(for: address) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 420, height: 420)
                            .padding(24)
                            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .accessibilityLabel("QR code for the log download")
                            .accessibilityIdentifier("logShare.qr")
                    }
                    Text(address)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("logShare.address")
                    Text("Works only while this screen is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unavailable:
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 120))
                        .foregroundStyle(.secondary)
                        .frame(width: 468, height: 468)
                    Text("This Apple TV is not on a network a phone can reach.")
                        .font(.headline)
                        .accessibilityIdentifier("logShare.unavailable")
                }
            }
            .frame(width: 720)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque: the cover is otherwise translucent and Settings shows through the text.
        .background(Color.black.ignoresSafeArea())
        .task {
            let eventLog = AppDiagnostics.eventLogSnapshot()
            eventCount = eventLog.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "\n") { count += 1 }
            }
            AppDiagnostics.record(.settingsUI, "diagnostics.log_share_opened", fields: [
                "events_on_disk": .int(eventCount),
                "logging_enabled": .bool(AppDiagnostics.isEnabled),
            ])
            model.start(payload: .init(reportText: reportText, eventLog: eventLog))
        }
        .onDisappear { model.stop() }
    }

    private var status: String {
        if eventCount == 0 {
            return AppDiagnostics.isEnabled
                ? "No events recorded yet. Reproduce the problem, then open this screen again."
                : "Diagnostic logging is off, so there are no events to send. Turn it on, reproduce the problem, then open this screen again."
        }
        let events = eventCount == 1 ? "1 event" : "\(eventCount) events"
        return AppDiagnostics.isEnabled
            ? "\(events) recorded."
            : "\(events) recorded before logging was turned off."
    }
}
