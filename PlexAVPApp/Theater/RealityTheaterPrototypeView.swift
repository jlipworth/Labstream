import AVFoundation
import RealityKit
import SwiftUI
import UIKit

/// Hidden RealityKit prototype space for issue #12.
///
/// This is intentionally a theater-layout scaffold, not a shipping playback route. It proves that
/// the app has a separate RealityKit scene/model boundary with screen, seat, and controls anchors;
/// it does not wire a visible shipping player-chrome button or claim device-ready Cinema behavior.
struct RealityTheaterPrototypeView: View {
    @Environment(RealityTheaterSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        let configuration = session.configuration

        ZStack(alignment: .top) {
            RealityTheaterScene(configuration: configuration,
                                player: session.player,
                                title: session.title ?? "Theater Lab")
            VStack(spacing: 12) {
                prototypeBanner(configuration: configuration)
                tuningPanel(configuration: configuration)
            }
            .padding(.top, 30)
        }
        .onAppear { session.markOpen() }
        .onDisappear { session.markClosed() }
    }

    private func prototypeBanner(configuration: RealityTheaterConfiguration) -> some View {
        VStack(spacing: 6) {
            Label("RealityKit Theater Lab", systemImage: "theatermasks.fill")
                .font(.headline.weight(.semibold))
            Text("DEBUG/developer-only for #12 device comparison — not a shipping Cinema entry point.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(configuration.debugSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func tuningPanel(configuration: RealityTheaterConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("Manual tuning", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { session.resetConfigurationToDefaults() }
                    .buttonStyle(.bordered)
                Button("Close Lab", systemImage: "xmark.circle") {
                    Task { @MainActor in
                        session.markOpening()
                        await dismissImmersiveSpace()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            presetRow
            metricSlider(title: "Width", value: widthBinding, range: RealityTheaterScreenConfiguration.widthRangeMeters, suffix: "m")
            metricSlider(title: "Distance", value: distanceBinding, range: RealityTheaterScreenConfiguration.distanceRangeMeters, suffix: "m")
            metricSlider(title: "Vertical", value: verticalOffsetBinding, range: RealityTheaterScreenConfiguration.verticalOffsetRangeMeters, suffix: "m")

            HStack(spacing: 16) {
                Picker("Seat", selection: seatBinding) {
                    ForEach(RealityTheaterSeatPreset.allCases) { seat in
                        Text(seat.displayName).tag(seat)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Controls", selection: controlsPlacementBinding) {
                    ForEach(RealityTheaterControlsPlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Open/close: open via the custom player Theater Lab button after setting `\(RealityTheaterFeature.developerDefaultsKey)=true`; close with this button or Exit Theater Lab in chrome.")
                Text("Environment: compare from Windowed, Mixed, and 100% full Environment; note whether the app pulls you out of immersion.")
                Text("Video surface: active AVPlayer attachment is \(session.player == nil ? "not present" : "present"); verify playback continues while tuning.")
                Text("Controls: compare Below screen vs Seat rail reachability; reset returns to Apple-ish default.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 860)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Text(session.phaseLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 10) {
            Text("Baselines")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(RealityTheaterBaselinePreset.allCases) { preset in
                Button(preset.displayName) { session.applyPreset(preset) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func metricSlider(title: String,
                              value: Binding<Double>,
                              range: ClosedRange<Float>,
                              suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound), step: 0.05)
            Text(String(format: "%.2f%@", value.wrappedValue, suffix))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(session.configuration.screen.widthMeters) },
                set: { newValue in
                    session.updateConfiguration { configuration in
                        configuration.screen = RealityTheaterScreenConfiguration(widthMeters: Float(newValue),
                                                                                distanceMeters: configuration.screen.distanceMeters,
                                                                                verticalOffsetMeters: configuration.screen.verticalOffsetMeters,
                                                                                aspectRatio: configuration.screen.aspectRatio)
                    }
                })
    }

    private var distanceBinding: Binding<Double> {
        Binding(get: { Double(session.configuration.screen.distanceMeters) },
                set: { newValue in
                    session.updateConfiguration { configuration in
                        configuration.screen = RealityTheaterScreenConfiguration(widthMeters: configuration.screen.widthMeters,
                                                                                distanceMeters: Float(newValue),
                                                                                verticalOffsetMeters: configuration.screen.verticalOffsetMeters,
                                                                                aspectRatio: configuration.screen.aspectRatio)
                    }
                })
    }

    private var verticalOffsetBinding: Binding<Double> {
        Binding(get: { Double(session.configuration.screen.verticalOffsetMeters) },
                set: { newValue in
                    session.updateConfiguration { configuration in
                        configuration.screen = RealityTheaterScreenConfiguration(widthMeters: configuration.screen.widthMeters,
                                                                                distanceMeters: configuration.screen.distanceMeters,
                                                                                verticalOffsetMeters: Float(newValue),
                                                                                aspectRatio: configuration.screen.aspectRatio)
                    }
                })
    }

    private var seatBinding: Binding<RealityTheaterSeatPreset> {
        Binding(get: { session.configuration.seat },
                set: { newValue in session.updateConfiguration { $0.seat = newValue } })
    }

    private var controlsPlacementBinding: Binding<RealityTheaterControlsPlacement> {
        Binding(get: { session.configuration.controlsPlacement },
                set: { newValue in session.updateConfiguration { $0.controlsPlacement = newValue } })
    }
}

private extension RealityTheaterSessionStore {
    var phaseLabel: String {
        switch phase {
        case .inactive: "inactive"
        case .prepared: "prepared"
        case .opening: "transitioning"
        case .open: "open"
        }
    }
}

private struct RealityTheaterScene: View {
    private static let playerAttachmentID = "reality-theater-player-surface"

    let configuration: RealityTheaterConfiguration
    let player: AVPlayer?
    let title: String

    var body: some View {
        RealityView { content, attachments in
            content.add(RealityTheaterEntityFactory.makeRoot(configuration: configuration,
                                                            hasVideoSurface: player != nil))
            if let playerSurface = attachments.entity(for: Self.playerAttachmentID) {
                RealityTheaterEntityFactory.placePlayerSurface(playerSurface,
                                                               configuration: configuration)
                content.add(playerSurface)
            }
        } update: { content, attachments in
            if let playerSurface = attachments.entity(for: Self.playerAttachmentID) {
                RealityTheaterEntityFactory.placePlayerSurface(playerSurface,
                                                               configuration: configuration)
                if playerSurface.parent == nil {
                    content.add(playerSurface)
                }
            }
        } attachments: {
            Attachment(id: Self.playerAttachmentID) {
                RealityTheaterPlayerAttachment(player: player, title: title)
            }
        }
        .id(configuration)
    }
}

private struct RealityTheaterPlayerAttachment: View {
    let player: AVPlayer?
    let title: String

    var body: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.black)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.largeTitle.weight(.semibold))
                            Text("No active player")
                                .font(.headline)
                            Text("Open from the custom player with the developer theater flag enabled.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(player == nil ? "AVPlayer attachment: missing" : "AVPlayer attachment: active")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(14)
        }
        .frame(width: 1280, height: 720)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

@MainActor
private enum RealityTheaterEntityFactory {
    static func makeRoot(configuration: RealityTheaterConfiguration,
                         hasVideoSurface: Bool) -> Entity {
        let root = Entity()
        root.name = "reality-theater-root"

        let screenFrame = ModelEntity(
            mesh: .generateBox(width: configuration.screen.widthMeters + 0.16,
                               height: configuration.screen.heightMeters + 0.16,
                               depth: 0.04,
                               cornerRadius: 0.045),
            materials: [SimpleMaterial(color: UIColor(white: 0.18, alpha: 1.0),
                                       roughness: 0.75,
                                       isMetallic: false)]
        )
        screenFrame.name = "reality-theater-screen-frame"
        screenFrame.position = configuration.screenPosition + SIMD3<Float>(0, 0, 0.025)
        root.addChild(screenFrame)

        let screenSurface = ModelEntity(
            mesh: .generateBox(width: configuration.screen.widthMeters,
                               height: configuration.screen.heightMeters,
                               depth: 0.025,
                               cornerRadius: 0.025),
            materials: [SimpleMaterial(color: hasVideoSurface ? UIColor(white: 0.02, alpha: 1.0) : UIColor.black,
                                       roughness: 0.45,
                                       isMetallic: false)]
        )
        screenSurface.name = "reality-theater-screen-placeholder"
        screenSurface.position = configuration.screenPosition
        root.addChild(screenSurface)

        let controlsRail = ModelEntity(
            mesh: .generateBox(width: 1.9,
                               height: 0.08,
                               depth: 0.22,
                               cornerRadius: 0.04),
            materials: [SimpleMaterial(color: UIColor(white: 0.28, alpha: 1.0),
                                       roughness: 0.8,
                                       isMetallic: false)]
        )
        controlsRail.name = "reality-theater-controls-anchor-\(configuration.controlsPlacement.rawValue)"
        controlsRail.position = configuration.controlsPosition
        root.addChild(controlsRail)

        let seatMarker = ModelEntity(
            mesh: .generateBox(width: 1.35,
                               height: 0.12,
                               depth: 0.72,
                               cornerRadius: 0.06),
            materials: [SimpleMaterial(color: UIColor(white: 0.10, alpha: 1.0),
                                       roughness: 0.9,
                                       isMetallic: false)]
        )
        seatMarker.name = "reality-theater-seat-\(configuration.seat.rawValue)"
        seatMarker.position = configuration.seat.prototypeSeatOffset
        root.addChild(seatMarker)

        return root
    }

    static func placePlayerSurface(_ entity: Entity,
                                   configuration: RealityTheaterConfiguration) {
        entity.name = "reality-theater-player-attachment"
        entity.position = configuration.screenPosition + SIMD3<Float>(0, 0, 0.055)
        // RealityView attachments are authored in SwiftUI points. Scale the 1280x720 attachment
        // so its visible width matches the meter-based theater screen configuration.
        let scale = configuration.screen.widthMeters / 1280.0
        entity.scale = SIMD3<Float>(repeating: scale)
    }
}
