import Foundation
import SwiftUI

// Target-exclusive visionOS Cinema controls. All mutation is delegated to the typed transition
// coordinator; this leaf only supplies SwiftUI's environment actions.
extension CustomPlayerChrome {
    func toggleCinemaMode() async {
        let coordinator = cinemaSession.transitionCoordinator
        switch coordinator.presentationState {
        case .closed:
            await coordinator.enter(
                openImmersiveSpace: {
                    switch await openImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
                    case .opened:
                        return .opened
                    case .userCancelled:
                        return .userCancelled
                    case .error:
                        return .failed
                    @unknown default:
                        return .failed
                    }
                },
                detachPlayerWindow: {
                    // Detach only after the generation-fenced open result succeeds. The same
                    // PlaybackController/AVPlayer remains retained by the Cinema session.
                    onClose?()
                    dismissWindow(id: CustomCinemaMode.mainWindowID)
                })
        case .open:
            guard let generation = coordinator.activeGeneration else { return }
            await coordinator.requestExit(
                generation: generation,
                request: .explicit(origin: cinemaSession.origin,
                                   hasCurrentItem: cinemaSession.item != nil),
                stageReturn: { cinemaSession.stageReturnItem(cinemaSession.item) },
                dismissImmersiveSpace: { await dismissImmersiveSpace() })
        case .inTransition:
            break
        }
    }
}

struct CinemaScreenAdjustmentView: View {
    let session: CustomCinemaSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { session.applyReclinedScreenPreset() } label: {
                        Label("I'm reclined", systemImage: "chair.lounge")
                    }
                    .buttonStyle(.bordered)

                    Button { session.applyLyingDownScreenPreset() } label: {
                        Label("Lying down", systemImage: "bed.double")
                    }
                    .buttonStyle(.bordered)
                }

                Button { session.resetScreenAdjustment() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }

            adjustmentRow(title: "Tilt",
                          valueText: formatDegrees(session.screenAdjustment.pitchDegrees),
                          lowerLabel: "Top away",
                          lowerSystemImage: "arrow.up.backward",
                          upperLabel: "Top toward",
                          upperSystemImage: "arrow.down.forward",
                          lowerAction: { session.nudgeScreenAdjustment(pitchDegrees: -2) },
                          upperAction: { session.nudgeScreenAdjustment(pitchDegrees: 2) }) {
                Slider(value: pitchBinding,
                       in: Double(CustomCinemaScreenAdjustment.pitchDegreesRange.lowerBound)...Double(CustomCinemaScreenAdjustment.pitchDegreesRange.upperBound),
                       step: 1)
            }

            adjustmentRow(title: "Height",
                          valueText: formatMeters(session.screenAdjustment.verticalDeltaMeters),
                          lowerLabel: "Lower",
                          lowerSystemImage: "arrow.down",
                          upperLabel: "Raise",
                          upperSystemImage: "arrow.up",
                          lowerAction: { session.nudgeScreenAdjustment(verticalDeltaMeters: -0.10) },
                          upperAction: { session.nudgeScreenAdjustment(verticalDeltaMeters: 0.10) }) {
                Slider(value: heightBinding,
                       in: Double(CustomCinemaScreenAdjustment.verticalDeltaRange.lowerBound)...Double(CustomCinemaScreenAdjustment.verticalDeltaRange.upperBound),
                       step: 0.05)
            }

            adjustmentRow(title: "Distance",
                          valueText: formatMeters(session.screenAdjustment.distanceDeltaMeters),
                          lowerLabel: "Closer",
                          lowerSystemImage: "minus.magnifyingglass",
                          upperLabel: "Farther",
                          upperSystemImage: "plus.magnifyingglass",
                          lowerAction: { session.nudgeScreenAdjustment(distanceDeltaMeters: -0.25) },
                          upperAction: { session.nudgeScreenAdjustment(distanceDeltaMeters: 0.25) }) {
                Slider(value: distanceBinding,
                       in: Double(CustomCinemaScreenAdjustment.distanceDeltaRange.lowerBound)...Double(CustomCinemaScreenAdjustment.distanceDeltaRange.upperBound),
                       step: 0.05)
            }

        }
    }

    private var pitchBinding: Binding<Double> {
        Binding {
            Double(session.screenAdjustment.pitchDegrees)
        } set: { newValue in
            var next = session.screenAdjustment
            next.pitchDegrees = Float(newValue)
            session.updateScreenAdjustment(next)
        }
    }

    private var heightBinding: Binding<Double> {
        Binding {
            Double(session.screenAdjustment.verticalDeltaMeters)
        } set: { newValue in
            var next = session.screenAdjustment
            next.verticalDeltaMeters = Float(newValue)
            session.updateScreenAdjustment(next)
        }
    }

    private var distanceBinding: Binding<Double> {
        Binding {
            Double(session.screenAdjustment.distanceDeltaMeters)
        } set: { newValue in
            var next = session.screenAdjustment
            next.distanceDeltaMeters = Float(newValue)
            session.updateScreenAdjustment(next)
        }
    }

    private func adjustmentRow<Control: View>(title: String,
                                              valueText: String,
                                              lowerLabel: String,
                                              lowerSystemImage: String,
                                              upperLabel: String,
                                              upperSystemImage: String,
                                              lowerAction: @escaping () -> Void,
                                              upperAction: @escaping () -> Void,
                                              @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(action: lowerAction) {
                    Label(lowerLabel, systemImage: lowerSystemImage)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(lowerLabel)

                control()

                Button(action: upperAction) {
                    Label(upperLabel, systemImage: upperSystemImage)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(upperLabel)
            }
        }
    }

    private func formatDegrees(_ value: Float) -> String {
        String(format: "%+.0f°", value)
    }

    private func formatMeters(_ value: Float) -> String {
        String(format: "%+.2fm", value)
    }
}
