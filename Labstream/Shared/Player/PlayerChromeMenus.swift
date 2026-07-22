import PMSKit
import SwiftUI

enum CustomPlayerMenuKind: String, CaseIterable, Identifiable {
    #if os(visionOS)
    case screen
    #endif
    case quality
    case subtitles
    case audio
    case chapters
    case speed
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        #if os(visionOS)
        case .screen: "Screen Position"
        #endif
        case .quality: "Quality"
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .chapters: "Chapters"
        case .speed: "Speed"
        case .stats: "Stats"
        }
    }

    var shortTitle: String {
        switch self {
        #if os(visionOS)
        case .screen: "Screen"
        #endif
        case .quality: "Quality"
        case .subtitles: "Subs"
        case .audio: "Audio"
        case .chapters: "Chapters"
        case .speed: "Speed"
        case .stats: "Stats"
        }
    }

    var systemImage: String {
        switch self {
        #if os(visionOS)
        case .screen: "rectangle"
        #endif
        case .quality: "slider.horizontal.3"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .chapters: "list.bullet"
        case .speed: "speedometer"
        case .stats: "chart.bar.doc.horizontal"
        }
    }

    var minChromeWidth: CGFloat {
        switch self {
        case .quality, .subtitles, .audio, .speed, .stats: 72
        #if os(visionOS)
        case .screen: 82
        #endif
        case .chapters: 94
        }
    }

    var popoverSize: CGSize {
        #if os(macOS)
        switch self {
        case .quality: CGSize(width: 250, height: 228)
        case .speed: CGSize(width: 230, height: 188)
        case .subtitles, .audio: CGSize(width: 290, height: 210)
        case .chapters: CGSize(width: 920, height: 210)
        case .stats: CGSize(width: 420, height: 285)
        }
        #elseif os(tvOS)
        // Heights sized for bordered 58-pt rows plus inter-row spacing; the short
        // touch-era heights showed barely five rows and clipped the ladder mid-row.
        switch self {
        case .quality: CGSize(width: 520, height: 560)
        case .speed: CGSize(width: 440, height: 460)
        case .subtitles, .audio: CGSize(width: 620, height: 560)
        case .chapters: CGSize(width: 1_460, height: 300)
        // Stats is a fixed, unfocusable readout (no rows to scroll to on tvOS): it must be
        // tall enough for its full ~16-row worst case.
        case .stats: CGSize(width: 820, height: 700)
        }
        #else
        switch self {
        #if os(visionOS)
        case .screen: CGSize(width: 430, height: 390)
        #endif
        case .quality: CGSize(width: 340, height: 315)
        case .speed: CGSize(width: 300, height: 245)
        case .subtitles, .audio: CGSize(width: 390, height: 275)
        case .chapters: CGSize(width: 1_120, height: 228)
        case .stats: CGSize(width: 470, height: 330)
        }
        #endif
    }

    var popoverAlignment: Alignment {
        switch self {
        case .quality, .subtitles, .audio, .chapters: .center
        #if os(visionOS)
        case .screen, .speed, .stats: .trailing
        #else
        case .speed, .stats: .trailing
        #endif
        }
    }
}

struct CustomPlayerMenuPopover: View {
    #if os(visionOS)
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    #endif

    let menu: CustomPlayerMenuKind
    let controller: PlaybackController
    @Bindable var menuState: PlayerMenuState
    /// When set (Chapters, or any menu on a compact phone), overrides the menu's fixed authored
    /// width so a horizontal filmstrip can fill the available player width instead of sitting narrow
    /// on the wider Cinema canvas — and so the small menus stop overflowing a 390-pt phone.
    var widthOverride: CGFloat? = nil
    /// Caps the popover's overall height so its header/close button stays on-screen when the
    /// player is short (phone landscape, iPad split view). Each menu's content already scrolls
    /// internally, so the reduced height just scrolls.
    var maxPopoverHeight: CGFloat? = nil
    let onClose: () -> Void

    var body: some View {
        let base = menu.popoverSize
        let size = CGSize(width: widthOverride ?? base.width, height: clampedContentHeight(base: base.height))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label(menu.title, systemImage: menu.systemImage)
                    .font(headerFont)
                    .frame(maxHeight: headerHeight, alignment: .center)
                Spacer()
                Button(action: onClose) {
                    Label("Close menu", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: closeButtonSide, height: closeButtonSide)
                }
                #if os(iOS)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                #elseif os(macOS)
                .buttonStyle(.plain)
                .background(.white.opacity(0.08), in: Circle())
                .help("Close")
                #else
                .buttonStyle(.bordered)
                #endif
            }
            .frame(width: size.width, height: headerHeight, alignment: .center)
            #if os(tvOS)
            // Route Up presses from anywhere in the menu content into the header: without a
            // section spanning the full row, the Close button is only reachable from content
            // whose vertical projection overlaps it (e.g. the rightmost chapter card).
            .focusSection()
            #endif

            Divider()
                .opacity(0.35)
                .frame(width: size.width)

            menuContent
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                #if os(tvOS)
                // The row lists are ScrollViews of bordered buttons; without a clip the
                // focus-scaled rows draw past the platter's bottom edge.
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                #endif
        }
        .padding(popoverPadding)
        .frame(width: size.width + popoverPadding * 2, alignment: .leading)
        #if os(macOS)
        .background(popoverMaterial, in: RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
        #else
        .labstreamOverlayPlatter(.regularMaterial,
                                 in: RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous))
        #endif
        .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
        #if os(macOS)
        .colorScheme(.dark)
        #endif
    }

    private var headerFont: Font {
        #if os(macOS)
        .headline
        #elseif os(tvOS)
        .headline.weight(.semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var headerHeight: CGFloat {
        #if os(macOS)
        30
        #elseif os(tvOS)
        54
        #else
        44
        #endif
    }

    private var closeButtonSide: CGFloat {
        #if os(macOS)
        24
        #elseif os(tvOS)
        52
        #else
        44
        #endif
    }

    private var popoverPadding: CGFloat {
        #if os(macOS)
        14
        #elseif os(tvOS)
        24
        #else
        18
        #endif
    }

    private var popoverCornerRadius: CGFloat {
        #if os(macOS)
        15
        #elseif os(tvOS)
        28
        #else
        24
        #endif
    }

    private var popoverMaterial: Material {
        #if os(macOS)
        .regularMaterial
        #else
        .ultraThinMaterial
        #endif
    }

    /// Shrinks the content frame to fit `maxPopoverHeight` when the popover is height-constrained
    /// (small mobile heights / iPad split view). Chrome = outer padding (18×2), header (44),
    /// divider, and the VStack's inter-row spacing (12×2). Unset → the authored height passes
    /// through unchanged.
    private func clampedContentHeight(base: CGFloat) -> CGFloat {
        guard let maxPopoverHeight else { return base }
        let chrome: CGFloat = popoverPadding * 2 + headerHeight + 12 * 2 + 1
        return min(base, max(120, maxPopoverHeight - chrome))
    }

    @ViewBuilder private var menuContent: some View {
        switch menu {
        #if os(visionOS)
        case .screen:
            CinemaScreenAdjustmentView(session: cinemaSession)
        #endif
        case .quality:
            QualityTabView(state: menuState) { kbps in
                controller.reload(bitrateKbps: kbps)
                menuState.selectedBitrateKbps = kbps
                PlaybackPreferences.setQualityKbps(kbps, forDefaultsKey: controller.qualityPreferenceDefaultsKey)
                onClose()
            }
        case .subtitles:
            SubtitlesTabView(
                load: { try await controller.loadSubtitleTracks() },
                onSelect: { track in try await controller.selectSubtitle(track) }
            )
        case .audio:
            if controller.supportsMetadataAudioSelection {
                AudioStreamsTabView(
                    load: { controller.loadAudioStreamChoices() },
                    onSelect: { choice in await controller.selectAudioStream(choice) }
                )
            } else {
                AudioTabView(
                    load: { await controller.loadAudioTracks() },
                    onSelect: { track in await controller.selectAudio(track) }
                )
            }
        case .chapters:
            ChaptersTabView(
                chapters: controller.chapters,
                currentMs: { controller.currentResumeMs },
                thumbnailRequest: { index, thumb in controller.chapterThumbnailRequest(for: thumb, chapterIndex: index) },
                onJump: { startMs in
                    controller.performUserSeek(toMs: startMs)
                    onClose()
                }
            )
        case .speed:
            SpeedTabView(state: controller.speedState) { rate in
                controller.setPlaybackSpeed(rate)
                onClose()
            }
        case .stats:
            StatsTabView(diagnostics: controller.diagnostics)
        }
    }
}
