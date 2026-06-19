import SwiftUI

/// Emby-style "Stats for Nerds" glass panel.
///
/// Hosted as the Stats menu in the custom player chrome (see `CustomPlayerChrome`).
/// It observes a `PlaybackDiagnostics` and re-renders as the numbers tick (~1s).
/// Deliberately compact and legible; it never displays any token or URL query material.
///
/// `onClose` is optional: when the panel is presented as an info-panel tab the tab chrome
/// provides dismissal, so the inline close button is omitted (pass `nil`). `showsHeader`
/// false also drops the "Stats for Nerds" label and the glass-card chrome — the system
/// info panel already titles the tab and provides the backdrop.
@MainActor
struct StatsForNerdsView: View {
    var diagnostics: PlaybackDiagnostics
    var onClose: (() -> Void)?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Label("Stats for Nerds", systemImage: "chart.bar.doc.horizontal")
                        .font(.headline)
                    if let onClose {
                        Spacer(minLength: 24)
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 2)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("Connection", diagnostics.connectionHost)
                row("Mode", diagnostics.modeText)
                if diagnostics.decisionText != "—" {
                    row("Decision", diagnostics.decisionText, wraps: true)
                }
                row("Source", "\(diagnostics.sourceResolution) · \(diagnostics.container)")
                row("Video", diagnostics.videoCodec)
                row("Audio", diagnostics.audioCodec)
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Target", diagnostics.targetBitrateLabel)
                row("Observed", kbps(diagnostics.observedBitrateKbps))
                row("Indicated", kbps(diagnostics.indicatedBitrateKbps))
                row("Dropped frames", "\(diagnostics.droppedFrames)")
                row("Stalls", "\(diagnostics.stalls)")
                row("Buffer ahead", String(format: "%.1f s", diagnostics.bufferedAheadSeconds))
                row("Keep up", diagnostics.likelyToKeepUp ? "Yes" : "No")
            }
            .font(.system(showsHeader ? .caption : .callout, design: .monospaced))
        }
        .padding(showsHeader ? 16 : 0)
        .frame(width: showsHeader ? 340 : 430, alignment: .leading)
        .background {
            if showsHeader {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(radius: 12, y: 4)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, wraps: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }

    private func kbps(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        if value >= 1000 {
            return String(format: "%.1f Mbps", value / 1000)
        }
        return String(format: "%.0f kbps", value)
    }
}
