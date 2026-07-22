import AVKit
import Foundation
import PMSKit
import SwiftUI
import UIKit

// Target-exclusive mobile presentation leaves for the shared player chrome.
extension CustomPlayerChrome {
    var mobileChromeLayout: MobilePlayerChromeLayoutPolicy {
        MobilePlayerChromeLayoutPolicy(horizontalSizeClass: horizontalSizeClass,
                                       verticalSizeClass: verticalSizeClass,
                                       idiom: UIDevice.current.userInterfaceIdiom,
                                       viewportSize: chromeViewportSize)
    }

    var topUtilityButtonExtraTopPadding: CGFloat {
        10
    }

    var topUtilityButtonVisualSide: CGFloat {
        isPhoneLandscapeChrome ? 38 : 44
    }

    var topUtilityButtonHitSide: CGFloat {
        max(44, topUtilityButtonVisualSide)
    }

    var airPlayButton: some View {
        AirPlayRoutePickerButton()
            .frame(width: topUtilityButtonVisualSide, height: topUtilityButtonVisualSide)
            .frame(width: topUtilityButtonHitSide, height: topUtilityButtonHitSide)
            .iosPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscapeChrome)
            .accessibilityLabel("AirPlay")
    }

    var displayModeButton: some View {
        Button {
            setMobileVideoDisplayMode(mobileVideoDisplayMode.toggled)
        } label: {
            Label(mobileVideoDisplayMode.accessibilityLabel,
                  systemImage: mobileVideoDisplayMode.systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: topUtilityButtonVisualSide, height: topUtilityButtonVisualSide)
                .frame(width: topUtilityButtonHitSide, height: topUtilityButtonHitSide)
        }
        .buttonStyle(.plain)
        .iosPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscapeChrome)
        .accessibilityLabel(mobileVideoDisplayMode.accessibilityLabel)
    }

    func setMobileVideoDisplayMode(_ mode: MobileVideoDisplayMode) {
        guard mode != mobileVideoDisplayMode else { return }
        mobileVideoDisplayMode = mode
        mobileDisplayStatusTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { mobileDisplayStatus = mode.statusLabel }
        mobileDisplayStatusTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) { mobileDisplayStatus = nil }
            }
        }
        revealChrome()
    }

    var pipButton: some View {
        Button {
            revealChrome(keepVisible: true)
            mobileSystemCoordinator?.togglePictureInPicture()
        } label: {
            let isActive = mobileSystemCoordinator?.isPictureInPictureActive == true
            Label(isActive ? "Exit Picture in Picture" : "Picture in Picture",
                  systemImage: isActive ? "pip.exit" : "pip.enter")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: topUtilityButtonVisualSide, height: topUtilityButtonVisualSide)
                .frame(width: topUtilityButtonHitSide, height: topUtilityButtonHitSide)
        }
        .buttonStyle(.plain)
        .iosPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscapeChrome)
    }
    var regularIOSHeaderInline: some View {
        HStack(alignment: .center, spacing: 10) {
            regularTitleLabel
                .frame(minWidth: 280, idealWidth: 380, maxWidth: 480, alignment: .leading)
                .layoutPriority(3)

            Spacer(minLength: 6)

            labeledMenuStrip
                .frame(maxWidth: .infinity, alignment: .trailing)
                .layoutPriority(2)
        }
    }

    var regularIOSHeaderStacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            regularTitleLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            menuStrip
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    var phoneLandscapeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Match the hierarchy people expect from iPhone media players: seeking is
            // the primary full-width row, while transport and playback options sit
            // below it. Never make the timeline compete horizontally with our richer
            // Quality/Subtitles/Audio controls.
            compactScrubberColumn
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                phoneLandscapeSkipButton(seconds: -30)
                phoneLandscapeSkipButton(seconds: -10)
                phoneLandscapeSkipButton(seconds: 10)
                phoneLandscapeSkipButton(seconds: 30)

                Spacer(minLength: 12)

                phoneLandscapeMenuStrip
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
    /// iPhone and iPad follow the familiar full-screen player hierarchy: the primary
    /// play/pause action belongs over the picture, not crowded into the timeline bar.
    var iosCenterPlayPauseButton: some View {
        Button {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        } label: {
            Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                .font(.system(size: isPhoneLandscapeChrome ? 28 : 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .glassEffect(.regular, in: Circle())
                .shadow(color: .black.opacity(0.34), radius: 12, y: 5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 80, height: 80)
        .contentShape(Circle())
        .accessibilityLabel(controller.transport.showsPausedControl ? "Play" : "Pause")
        .accessibilityHint("Toggles playback")
    }

    func phoneLandscapeSkipButton(seconds: Int) -> some View {
        let isForward = seconds > 0
        let amount = abs(seconds)
        return Button {
            performRelativeSkip(seconds: seconds)
        } label: {
            Image(systemName: isForward ? "goforward.\(amount)" : "gobackward.\(amount)")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.10), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .disabled(scrubState.durationMs <= 0)
        .accessibilityLabel(isForward ? "Skip forward \(amount) seconds" : "Skip back \(amount) seconds")
    }

    var phoneLandscapePrimaryMenus: [CustomPlayerMenuKind] {
        availableMenus.filter { [.quality, .subtitles, .audio, .chapters, .speed, .stats].contains($0) }
    }

    var phoneLandscapeOverflowMenus: [CustomPlayerMenuKind] {
        availableMenus.filter { !phoneLandscapePrimaryMenus.contains($0) }
    }

    /// Compact landscape controls keep the complete playback-option set visible now
    /// that play/pause lives over the picture and no longer consumes this row.
    var phoneLandscapeMenuStrip: some View {
        HStack(spacing: 6) {
            ForEach(phoneLandscapePrimaryMenus) { menu in
                phoneLandscapeMenuButton(menu)
            }

            if !phoneLandscapeOverflowMenus.isEmpty {
                Menu {
                    ForEach(phoneLandscapeOverflowMenus) { menu in
                        Button {
                            openMenu(menu)
                        } label: {
                            Label(menu.title, systemImage: menu.systemImage)
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .phoneLandscapePlayerMenuButtonStyle(isSelected: selectedMenu.map { phoneLandscapeOverflowMenus.contains($0) } ?? false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    func phoneLandscapeMenuButton(_ menu: CustomPlayerMenuKind) -> some View {
        Button {
            openMenu(menu)
        } label: {
            Label(menu.shortTitle, systemImage: menu.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(minWidth: phoneLandscapeMenuMinWidth(menu), minHeight: 40)
                .padding(.horizontal, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .phoneLandscapePlayerMenuButtonStyle(isSelected: selectedMenu == menu)
        .accessibilityLabel(menu.title)
    }

    func phoneLandscapeMenuMinWidth(_ menu: CustomPlayerMenuKind) -> CGFloat {
        switch menu {
        case .quality: 78
        case .subtitles: 70
        case .audio: 68
        case .chapters: 84
        case .speed, .stats: 66
        }
    }

    /// visionOS-parity labeled pills in iOS glass styling — every menu one tap away.
    var labeledMenuStrip: some View {
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: menu.minChromeWidth, minHeight: 44)
                        .padding(.horizontal, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glass)
                .tint(.primary)
            }
        }
    }

    /// The labeled pills in a trailing-anchored horizontal scroller — the variant for
    /// rows too narrow to seat the whole strip. Pills keep their full size and titles;
    /// the viewer swipes to reach the clipped ones.
    var scrollableLabeledMenuStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            labeledMenuStrip
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

struct IOSPlayerTopUtilityButtonStyle: ViewModifier {
    let isPhoneLandscape: Bool

    private var visibleSide: CGFloat { isPhoneLandscape ? 38 : 44 }
    private var hitSide: CGFloat { max(44, visibleSide) }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .frame(width: hitSide, height: hitSide)
            .background {
                Circle()
                    .fill(.clear)
                    .frame(width: visibleSide, height: visibleSide)
                    .glassEffect(.regular, in: Circle())
            }
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
    }
}

struct PhoneLandscapePlayerMenuButtonStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.92))
            .background(.white.opacity(isSelected ? 0.20 : 0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(isSelected ? 0.24 : 0.12), lineWidth: 0.7)
            }
            .contentShape(Capsule())
    }
}

extension View {
    func iosPlayerTopUtilityButtonStyle(isPhoneLandscape: Bool) -> some View {
        modifier(IOSPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscape))
    }

    func phoneLandscapePlayerMenuButtonStyle(isSelected: Bool) -> some View {
        modifier(PhoneLandscapePlayerMenuButtonStyle(isSelected: isSelected))
    }
}
/// Pure sizing policy for the mobile player chrome.
///
/// iPhones in landscape are constrained by height even when their horizontal size class is
/// regular, and iPad split views can be compact without being phone-like. Keep those cases
/// explicit so we drop chrome rows based on the actual viewport instead of only one size class.
struct MobilePlayerChromeLayoutPolicy: Equatable {
    let horizontalSizeClass: UserInterfaceSizeClass?
    let verticalSizeClass: UserInterfaceSizeClass?
    let idiom: UIUserInterfaceIdiom
    let viewportSize: CGSize

    private var hasMeasuredViewport: Bool {
        viewportSize.width > 0 && viewportSize.height > 0
    }

    private var isGeometryLandscape: Bool {
        hasMeasuredViewport && viewportSize.width > viewportSize.height
    }

    private var shortestMeasuredSide: CGFloat? {
        hasMeasuredViewport ? min(viewportSize.width, viewportSize.height) : nil
    }

    var isPhoneLandscape: Bool {
        idiom == .phone
            && (verticalSizeClass == .compact
                || (isGeometryLandscape && (shortestMeasuredSide ?? 0) <= 500))
    }

    var usesCompactChrome: Bool {
        idiom == .phone
            || horizontalSizeClass == .compact
            || verticalSizeClass == .compact
            || (shortestMeasuredSide.map { $0 < 500 } ?? false)
    }
}
struct AirPlayRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .white
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = .white
        uiView.activeTintColor = .white
    }
}
