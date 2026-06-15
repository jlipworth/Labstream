import AVFoundation
import RealityKit
import SwiftUI
import UIKit

/// Hidden RealityKit prototype space for issue #12.
///
/// This is intentionally a theater-layout scaffold, not a shipping playback route. It proves that
/// the app has a separate RealityKit scene/model boundary with screen, seat, and controls anchors;
/// it does not wire a visible player-chrome button or claim device-ready Cinema behavior.
struct RealityTheaterPrototypeView: View {
    @Environment(RealityTheaterSessionStore.self) private var session

    var body: some View {
        let configuration = session.configuration

        ZStack(alignment: .top) {
            RealityTheaterScene(configuration: configuration,
                                player: session.player,
                                title: session.title ?? "Theater Lab")
            prototypeBanner
                .padding(.top, 30)
        }
        .onAppear { session.markOpen() }
        .onDisappear { session.markClosed() }
    }

    private var prototypeBanner: some View {
        VStack(spacing: 6) {
            Label("RealityKit Theater Prototype", systemImage: "theatermasks.fill")
                .font(.headline.weight(.semibold))
            Text("Hidden for #12 device iteration — not a shipping Cinema button.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
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
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
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
        controlsRail.name = "reality-theater-controls-anchor"
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
