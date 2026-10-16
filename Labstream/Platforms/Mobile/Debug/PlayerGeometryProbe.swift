import SwiftUI
#if DEBUG
import AVFoundation
import os
#endif

#if DEBUG
/// Debug-only, privacy-safe player geometry log (#258). Records labels, window-space frames,
/// safe-area insets, and the AVPlayerLayer video rectangle — never titles, URLs, or identifiers —
/// so chrome placement can be compared against the active picture across source aspects.
/// Active only for UI-testing launches that pass `--ui-testing-player-geometry`.
@MainActor
enum PlayerGeometryProbe {
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "PlayerGeometry")

    static var isEnabled: Bool { DebugUITestLaunchConfiguration.logsPlayerGeometry }

    static func record(_ label: String, frame: CGRect, insets: EdgeInsets? = nil, detail: String = "") {
        guard isEnabled else { return }
        var line = "PlayerGeometry label=\(label) frame=\(format(frame))"
        if let insets {
            line += " safeArea=t\(round(insets.top)),l\(round(insets.leading)),"
                + "b\(round(insets.bottom)),r\(round(insets.trailing))"
        }
        if !detail.isEmpty { line += " \(detail)" }
        log.notice("\(line, privacy: .public)")
    }

    static func recordVideoRect(_ layer: AVPlayerLayer) {
        guard isEnabled else { return }
        record("videoRect", frame: layer.videoRect,
               detail: "layerBounds=\(format(layer.bounds)) gravity=\(layer.videoGravity.rawValue)")
    }

    private static func format(_ rect: CGRect) -> String {
        "\(round(rect.minX)),\(round(rect.minY)),\(round(rect.width))x\(round(rect.height))"
    }

    private static func round(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
#endif

extension View {
    /// Logs this view's window-space frame under `label` in DEBUG geometry-probe runs; a no-op
    /// otherwise (and compiled out of Release).
    @ViewBuilder
    func playerGeometryProbe(_ label: String, detail: String = "") -> some View {
        #if DEBUG
        if PlayerGeometryProbe.isEnabled {
            onGeometryChange(for: PlayerGeometrySample.self) { proxy in
                PlayerGeometrySample(frame: proxy.frame(in: .global), insets: proxy.safeAreaInsets)
            } action: { sample in
                PlayerGeometryProbe.record(label, frame: sample.frame, insets: sample.insets,
                                           detail: detail)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
struct PlayerGeometrySample: Equatable {
    let frame: CGRect
    let insets: EdgeInsets
}
#endif
