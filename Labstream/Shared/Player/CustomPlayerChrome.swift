import PMSKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App-owned full-screen chrome for the custom player.
///
/// This deliberately carries the playback feature set that used to live in system surfaces: the
/// custom route must not regress just because it owns its transport. The chrome behaves like player chrome,
/// not permanent app UI: taps reveal it, playback auto-hides it, and modal menu/error/reconnect
/// states keep it visible while the viewer is acting on them.
struct CustomPlayerChrome: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass
    #endif
    #if os(visionOS)
    @Environment(CustomCinemaSessionStore.self) var cinemaSession
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissWindow) var dismissWindow
    #endif

    let controller: PlaybackController
    let title: String
    @Binding var scrubState: PlaybackScrubState
    let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    #if os(iOS)
    let mobileSystemCoordinator: MobilePlayerSystemCoordinator?
    @Binding var mobileVideoDisplayMode: MobileVideoDisplayMode
    #endif
    let onRetry: () -> Void
    let onClose: (() -> Void)?

    @State var chromeVisible = true
    @State var hideTask: Task<Void, Never>?
    @State var selectedMenu: CustomPlayerMenuKind?
    @State var menuState: PlayerMenuState
    @State var trickPlayPreviewTask: Task<Void, Never>?
    @State var trickPlayPreviewImage: DecodedImage?
    @State var trickPlayPreviewTimeMs: Int?
    @State var trickPlayPreviewCaptureTimeMs: Int?
    @State var trickPlayPreviewLoading = false
    @State var trickPlayImageCache = TrickPlayPreviewImageCache(limit: 32)
    @State var trickPlayRequestGeneration = 0
    @State var trickPlayInFlightTargetMs: Int?
    @State var hoverPreviewTargetMs: Int?
    @State var hoverPreviewX: CGFloat?
    @State var mobileDisplayStatus: String?
    @State var mobileDisplayStatusTask: Task<Void, Never>?
    #if os(tvOS)
    @FocusState var tvPlayerFocus: TVPlayerFocus?
    /// Scrub-stride acceleration bookkeeping for the remote timeline (see tvTimelineMove).
    @State var tvScrubLastStepAt: Date = .distantPast
    @State var tvScrubStreak: Int = 0
    /// When `tvPlayerFocus` last changed — the "engine already resolved this press" guard in
    /// `tvHandleUnresolvedMove` (see ordering evidence there).
    @State var tvPlayerFocusChangedAt: Date = .distantPast
    #endif
    #if os(iOS)
    @State var chromeViewportSize: CGSize = .zero
    #endif
    #if os(macOS)
    @State var macWindowBridge = MacPlayerWindowBridge()
    @State var macKeyMonitor: Any?
    #endif
    /// True only between a Slider `onEditingChanged(true)` and its matching `(false)`. Guards the
    /// scrubber binding's defensive `beginDrag` so a trailing value-set arriving after the commit
    /// cannot re-open the drag (see `scrubberBinding`).
    @State var scrubEditingSessionActive = false

    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.trickPlayProvider = trickPlayProvider
        #if os(iOS)
        _mobileVideoDisplayMode = .constant(.fit)
        self.mobileSystemCoordinator = nil
        #endif
        self.onRetry = onRetry
        self.onClose = onClose
        _menuState = State(initialValue: PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps))
    }

    #if os(iOS)
    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         mobileVideoDisplayMode: Binding<MobileVideoDisplayMode>,
         mobileSystemCoordinator: MobilePlayerSystemCoordinator?,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.trickPlayProvider = trickPlayProvider
        _mobileVideoDisplayMode = mobileVideoDisplayMode
        self.mobileSystemCoordinator = mobileSystemCoordinator
        self.onRetry = onRetry
        self.onClose = onClose
        _menuState = State(initialValue: PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps))
    }
    #endif

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                #if os(tvOS)
                .onTapGesture { handlePlayerSurfaceTap() }
                #elseif os(iOS)
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                    .onEnded { gesture in
                        switch gesture {
                        case .first: setMobileVideoDisplayMode(mobileVideoDisplayMode.toggled)
                        case .second: handlePlayerSurfaceTap()
                        }
                    })
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    guard let selection = MobileVideoDisplayMode.pinchSelection(
                        magnification: Double(value.magnification)) else { return }
                    setMobileVideoDisplayMode(selection)
                })
                #else
                .onTapGesture { handlePlayerSurfaceTap() }
                #endif

            #if os(tvOS)
            if !shouldShowChrome {
                tvHiddenChromeInputOwner
            }
            #endif

            if shouldShowChrome, !tvSubmenuHidesTopChrome {
                topChrome
                    .transition(.opacity)
            }

            #if os(iOS)
            // The status platter owns the primary transport action while buffering/reconnecting.
            // Do not leave the ordinary center play/pause button visible through its translucent
            // material, where it reads as a second action directly behind the dialog.
            if shouldShowChrome, selectedMenu == nil, !isTransportStatusPresented {
                iosCenterPlayPauseButton
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            #endif

            transientStatusOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))

            #if os(iOS)
            if let mobileDisplayStatus {
                Text(mobileDisplayStatus)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.68), in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            #endif

            offlineSubtitleOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, isCompactMobileChrome ? 18 : 80)
                .padding(.bottom, subtitleBottomPadding)
                .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                .allowsHitTesting(false)

            VStack {
                Spacer()

                if selectedMenu == nil, let marker = controller.skipMarker.active {
                    HStack {
                        Spacer()
                        Button {
                            controller.skipCurrentMarker()
                        } label: {
                            Label(marker.kind.label, systemImage: marker.kind.systemImage)
                        }
                        .labstreamGlassProminentButtonStyle()
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 14)
                    .transition(.opacity)
                }

                if selectedMenu == nil, controller.upNext.isShown, let next = controller.upNext.nextItem {
                    upNextCard(next)
                        .padding(.horizontal, isCompactMobileChrome ? 14 : 34)
                        .padding(.bottom, 14)
                }

                if shouldShowChrome, selectedMenu == nil {
                    controls
                        .padding(.horizontal, bottomChromeHorizontalInset)
                        .padding(.bottom, bottomChromeBottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if let selectedMenu {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        CustomPlayerMenuPopover(menu: selectedMenu,
                                                controller: controller,
                                                menuState: menuState,
                                                widthOverride: adaptiveMenuWidth(for: selectedMenu,
                                                                                 available: geo.size.width),
                                                maxPopoverHeight: menuPopoverHeightLimit(availableHeight: geo.size.height),
                                                onClose: { closeMenu() })
                            .frame(maxWidth: .infinity, alignment: selectedMenu.popoverAlignment)
                            .padding(.horizontal, menuHorizontalInset)
                            .padding(.bottom, menuBottomClearance)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                #if os(tvOS)
                // Menu/Back with a submenu open must close the submenu (restoring focus to its
                // originating button), not fall through to the presentation and exit playback.
                .onExitCommand { closeMenu() }
                #endif
            }

            #if os(iOS) || os(macOS)
            // Hardware-keyboard transport. These zero-size buttons stay in the hierarchy
            // regardless of `shouldShowChrome`, so the shortcuts fire even while the chrome
            // is auto-hidden (the on-screen transport buttons are gone at that point).
            keyboardShortcuts
            #endif
        }
        #if os(iOS)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            chromeViewportSize = newSize
        }
        #endif
        #if os(macOS)
        .background(MacPlayerWindowReader(bridge: macWindowBridge))
        #endif
        #if os(tvOS)
        .onMoveCommand { direction in
            tvEvidenceLog("onMoveCommand \(direction) chromeVisible=\(shouldShowChrome)")
            guard shouldShowChrome else {
                // Apple-native hidden-chrome behavior: a side press is an instant ±10s
                // skip (with a brief reveal so the landing position is visible), not
                // just a reveal. Up/Down/Select reveal without seeking.
                switch direction {
                case .left, .right:
                    performRelativeSkip(seconds: direction == .right ? tvRemoteSkipSeconds
                                                                     : -tvRemoteSkipSeconds)
                    revealTVChrome()
                default:
                    revealTVChrome()
                }
                return
            }
            tvHandleUnresolvedMove(direction)
            // Navigating IS using the chrome: every dpad press restarts the auto-hide
            // countdown so the controls never vanish mid-traversal and reset focus.
            scheduleChromeHideIfNeeded()
        }
        .onPlayPauseCommand {
            tvEvidenceLog("onPlayPauseCommand chromeVisible=\(shouldShowChrome)")
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        }
        #endif
        .animation(.easeInOut(duration: 0.18), value: shouldShowChrome)
        .animation(.easeInOut(duration: 0.18), value: selectedMenu)
        .animation(.easeInOut(duration: 0.18), value: controller.skipMarker.active != nil)
        #if os(iOS)
        // System-player look: the whole chrome is monochrome — white pills, symbols,
        // and scrubber — instead of inheriting the amber app accent. The brand color
        // stays in the browse UI; inside the player it reads as non-native.
        .tint(.white)
        #endif
        .onAppear {
            revealChrome()
            #if os(tvOS)
            // Verified write, not a raw assignment: the appear-time write races the
            // chrome's insertion and is silently dropped otherwise (TVUI-024 evidence).
            tvEnsureFocus(tvDefaultChromeFocus)
            #endif
            #if os(macOS)
            installMacKeyMonitor()
            #endif
        }
        .onDisappear {
            hideTask?.cancel()
            endHoverPreview()
            mobileDisplayStatusTask?.cancel()
            #if os(macOS)
            removeMacKeyMonitor()
            #endif
        }
        .onChange(of: controller.transport.isPaused) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.transport.pauseRequested) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.transportStatus.status) { _, _ in
            scheduleChromeHideIfNeeded()
        }
        .onChange(of: selectedMenu) { _, menu in
            if menu != nil { endHoverPreview() }
        }
        #if os(tvOS)
        .onChange(of: shouldShowChrome) { _, visible in
            tvEvidenceLog("shouldShowChrome -> \(visible)")
            if visible {
                if tvPlayerFocus == nil || tvPlayerFocus == .hiddenSurface {
                    tvEnsureFocus(tvDefaultChromeFocus)
                }
            } else {
                tvFocusHiddenSurface()
            }
        }
        .onChange(of: tvPlayerFocus) { old, new in
            tvPlayerFocusChangedAt = Date()
            // Leaving the timeline (Up, or a chrome hide) abandons any open scrub draft:
            // the draft's only commit path is Select ON the timeline.
            if old == .timeline, new != .timeline, scrubState.isDragging {
                scrubState.cancel()
                clearTrickPlayPreview()
                // The drag cancelled the hide timer (revealChrome(keepVisible:)) and any
                // reschedule attempt that raced this change hit the isDragging guard, so
                // restart the countdown here or the chrome stays pinned forever.
                scheduleChromeHideIfNeeded()
                tvEvidenceLog("timeline scrub abandoned on focus exit")
            }
            tvEvidenceLog("tvPlayerFocus \(String(describing: old)) -> \(String(describing: new))")
        }
        #endif
        #if os(iOS)
        // System-player behavior: the status bar and home indicator ride with the chrome —
        // hidden over clean video, back the moment controls reveal. Without this the clock/
        // battery and indicator bar sit lit over the picture for the whole session.
        .statusBarHidden(!shouldShowChrome)
        .persistentSystemOverlays(shouldShowChrome ? .automatic : .hidden)
        #endif
    }

    var shouldShowChrome: Bool {
        chromeVisible || controller.transport.showsPausedControl || controller.transportStatus.keepsChromeVisible || selectedMenu != nil
    }

    /// tvOS treats an open submenu as modal: the top Close button leaves the hierarchy so remote
    /// focus must live inside the popover, which is what routes Menu/Back to `closeMenu()`
    /// (via the popover's `onExitCommand`) instead of dismissing the whole player presentation.
    var tvSubmenuHidesTopChrome: Bool {
        #if os(tvOS)
        selectedMenu != nil
        #else
        false
        #endif
    }

    var isTransportStatusPresented: Bool {
        controller.transportStatus.activeStatus != nil
    }

    var isCompactMobileChrome: Bool {
        #if os(iOS)
        mobileChromeLayout.usesCompactChrome
        #else
        false
        #endif
    }

    var isPhoneLandscapeChrome: Bool {
        #if os(iOS)
        mobileChromeLayout.isPhoneLandscape
        #else
        false
        #endif
    }

    var bottomChromeHorizontalInset: CGFloat {
        #if os(macOS)
        22
        #elseif os(tvOS)
        56
        #else
        if isPhoneLandscapeChrome {
            8
        } else if isCompactMobileChrome {
            12
        } else {
            34
        }
        #endif
    }

    var bottomChromeBottomInset: CGFloat {
        #if os(macOS)
        18
        #elseif os(tvOS)
        44
        #else
        if isPhoneLandscapeChrome {
            8
        } else if isCompactMobileChrome {
            14
        } else {
            28
        }
        #endif
    }

    var subtitleBottomPadding: CGFloat {
        if chromeVisible {
            isPhoneLandscapeChrome ? 116 : 168
        } else {
            isPhoneLandscapeChrome ? 42 : 64
        }
    }

    @ViewBuilder var offlineSubtitleOverlay: some View {
        if let text = controller.offlineSubtitleOverlay.text, !text.isEmpty {
            let presentation = controller.captionAppearance.offlinePresentation
            Text(text)
                .font(presentation.fontName.map {
                    Font.custom($0, size: 22 * presentation.relativeCharacterSize)
                } ?? .system(size: 22 * presentation.relativeCharacterSize,
                             weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(presentation.foreground.color)
                .captionEdge(presentation.edge)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(presentation.background.color,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(presentation.window.color,
                            in: RoundedRectangle(
                                cornerRadius: presentation.windowCornerRadius,
                                style: .continuous))
                .transition(.opacity)
        }
    }

    @ViewBuilder var transientStatusOverlay: some View {
        // The chrome renders the controller-owned transport status verbatim. It does not compose
        // buffering, retry, and failure booleans, so Cinema cannot show duplicate dialogs when HLS
        // delivery chatters between waiting and playing.
        if let consentGeneration = controller.videoTranscodeConsent.generation {
            VStack(spacing: 16) {
                Text("Allow video transcoding?").font(.headline)
                Text("Original playback could not be started or verified. The server can try converting the video, which may require substantial processing and change HDR or picture quality.")
                    .multilineTextAlignment(.center)
                Button("Allow Video Transcoding") { controller.approveVideoTranscoding(generation: consentGeneration) }
                    .accessibilityIdentifier("playback.allowVideoTranscoding")
                Button("Not Now") { controller.declineVideoTranscoding(generation: consentGeneration) }
                    .accessibilityIdentifier("playback.declineVideoTranscoding")
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        } else if let status = controller.transportStatus.activeStatus {
            CustomTransportStatusOverlay(status: status,
                                         onRetry: {
                                             revealChrome()
                                             onRetry()
                                         },
                                         onClose: onClose,
                                         onTogglePause: {
                                             revealChrome(keepVisible: true)
                                             controller.togglePlayback()
                                         },
                                         isCompact: isCompactMobileChrome)
        }
    }

    var topChrome: some View {
        VStack {
            HStack(spacing: 14) {
                if let onClose {
                    #if os(visionOS)
                    Button(action: {
                        revealChrome()
                        onClose()
                    }) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.bordered)
                    #elseif os(macOS)
                    EmptyView()
                    #elseif os(iOS)
                    // iOS system players use a subdued monochrome glass circle for
                    // dismiss, not a large accent-tinted platter.
                    Button(action: {
                        revealChrome()
                        onClose()
                    }) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .frame(width: topUtilityButtonVisualSide, height: topUtilityButtonVisualSide)
                            .frame(width: topUtilityButtonHitSide, height: topUtilityButtonHitSide)
                    }
                    .buttonStyle(.plain)
                    .iosPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscapeChrome)
                    // Sit a touch lower than the visionOS chrome so the circle clears
                    // the status-bar corner radius comfortably.
                    .padding(.top, topUtilityButtonExtraTopPadding)
                    #else
                    Button(action: {
                        revealChrome()
                        onClose()
                    }) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Close")
                    #endif
                }

                Spacer()

                #if os(iOS)
                displayModeButton
                    .padding(.top, topUtilityButtonExtraTopPadding)

                // System-player parity: AirPlay + Picture in Picture sit as monochrome glass
                // circles at the top-trailing corner, opposite the close button. Backgrounding
                // pauses ordinary video, but active AirPlay/PiP routes keep playing.
                if mobileSystemCoordinator != nil {
                    airPlayButton
                        .padding(.top, topUtilityButtonExtraTopPadding)
                }

                if mobileSystemCoordinator?.isPictureInPicturePossible == true {
                    pipButton
                        .padding(.top, topUtilityButtonExtraTopPadding)
                }
                #endif

                #if os(macOS)
                macTopTrailingControls
                #endif
            }
            #if os(macOS)
            .padding(.leading, topChromeHorizontalInset)
            .padding(.trailing, topChromeHorizontalInset)
            #else
            .padding(.horizontal, topChromeHorizontalInset)
            #endif
            .padding(.top, topChromeTopInset)

            Spacer()
        }
    }

    var topChromeHorizontalInset: CGFloat {
        #if os(macOS)
        16
        #else
        if isPhoneLandscapeChrome {
            12
        } else if isCompactMobileChrome {
            16
        } else {
            28
        }
        #endif
    }

    var topChromeTopInset: CGFloat {
        #if os(macOS)
        14
        #else
        if isPhoneLandscapeChrome {
            6
        } else if isCompactMobileChrome {
            12
        } else {
            28
        }
        #endif
    }



    #if os(iOS) || os(macOS)
    /// Zero-size buttons whose only job is to register hardware-keyboard shortcuts. Space
    /// toggles play/pause; ←/→ perform the fast 30s jumps; ⇧←/⇧→ perform the finer 10s
    /// jumps. On iOS, Esc closes the player. macOS handles physical Escape in its existing
    /// focus-independent AppKit key monitor. Kept out of the visible layout via `opacity(0)`.
    @ViewBuilder var keyboardShortcuts: some View {
        Group {
            Button("Play or pause") {
                revealChrome()
                controller.togglePlayback()
                scheduleChromeHideIfNeeded()
            }
            .keyboardShortcut(.space, modifiers: [])

            #if os(iOS)
            Button("Skip back 30 seconds") {
                performRelativeSkip(seconds: -30)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Skip forward 30 seconds") {
                performRelativeSkip(seconds: 30)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Skip back 10 seconds") {
                performRelativeSkip(seconds: -10)
            }
            .keyboardShortcut(.leftArrow, modifiers: .shift)

            Button("Skip forward 10 seconds") {
                performRelativeSkip(seconds: 10)
            }
            .keyboardShortcut(.rightArrow, modifiers: .shift)
            #endif

            #if os(iOS)
            if let onClose {
                Button("Close player") {
                    revealChrome()
                    requestPlayerClose(onClose)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            #endif
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    #endif


    @ViewBuilder
    var controls: some View {
        #if os(macOS)
        macControls
        #elseif os(tvOS)
        tvControls
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 1_760)
            .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .foregroundStyle(.white)
            .colorScheme(.dark)
        #elseif os(iOS)
        if isPhoneLandscapeChrome {
            phoneLandscapeControls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
                .colorScheme(.dark)
        } else if isCompactMobileChrome {
            compactControls
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            regularControls
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        #else
        if isCompactMobileChrome {
            compactControls
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            regularControls
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        #endif
    }



    var regularControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            regularControlsHeader

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 16) {
                #if os(visionOS)
                playPauseButton
                #endif

                skipControls

                Text(format(ms: scrubState.displayedPositionMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)

                timelineSlider

                Text(format(ms: scrubState.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    var regularControlsHeader: some View {
        #if os(iOS)
        // On iPad, the full labeled menu strip is more important than reserving a wide title
        // column. Try the one-row system-player shape first, then fall back to a two-row header
        // before letting the pills clip off the right edge.
        ViewThatFits(in: .horizontal) {
            regularIOSHeaderInline
            regularIOSHeaderStacked
        }
        #else
        HStack(alignment: .center, spacing: 10) {
            regularTitleLabel

            Spacer(minLength: 6)

            cinemaButton
                .fixedSize(horizontal: true, vertical: false)

            cinemaScreenButton
                .fixedSize(horizontal: true, vertical: false)

            menuStrip
                .fixedSize(horizontal: true, vertical: false)
        }
        #endif
    }

    var regularTitleLabel: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            // Keep the title present, but do not let it reserve half the row on iPad:
            // the one-tap menu pills are the interactive controls and need the width.
            .frame(minWidth: 120, idealWidth: 260, maxWidth: 360, alignment: .leading)
            .accessibilityLabel(title)
    }



    var compactControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .accessibilityLabel(title)

                Spacer(minLength: 8)
            }

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                #if os(visionOS)
                playPauseButton
                #endif

                compactScrubberColumn
            }

            // Two skips (matching the hardware-keyboard mapping ←10/→30); the four-skip
            // strip stays exclusive to the regular/iPad layout. The labeled pill strip
            // (~660 pt ideal) shares the row only when it fully fits (roomy landscape);
            // otherwise it drops to its own full-width row, where it scrolls horizontally
            // on a portrait phone. Fixed ideal widths keep ViewThatFits deterministic.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    skipButton(seconds: -10)
                    skipButton(seconds: 30)
                    Spacer(minLength: 8)
                    menuStrip
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        skipButton(seconds: -10)
                        skipButton(seconds: 30)
                        Spacer(minLength: 0)
                    }
                    menuStrip
                }
            }
        }
    }

    var compactScrubberColumn: some View {
        VStack(spacing: 4) {
            timelineSlider

            HStack {
                Text(format(ms: scrubState.displayedPositionMs))
                Spacer()
                Text(format(ms: scrubState.durationMs))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    #if os(visionOS)
    var playPauseButton: some View {
        Button(action: {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        }) {
            Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(controller.transport.showsPausedControl ? "Play" : "Pause")
        .accessibilityHint("Toggles playback")
    }
    #endif


    @ViewBuilder var trickPlayPreview: some View {
        VStack(spacing: 8) {
            if trickPlayProvider != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    if let trickPlayPreviewImage {
                        Image(decodedImage: trickPlayPreviewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else if trickPlayPreviewLoading {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay { ShimmerView() }
                    } else {
                        Image(systemName: "film")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 190, height: 107)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                }
            }

            Text(format(ms: TrickPlayPreviewResolutionPolicy.displayedTimeMs(
                targetMs: trickPlayPreviewTimeMs,
                thumbnailCaptureTimeMs: trickPlayPreviewCaptureTimeMs,
                fallbackMs: scrubState.displayedPositionMs
            )))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 16)
        .allowsHitTesting(false)
        .accessibilityLabel("Scrub preview")
    }

    /// Shared slider surface. Continuous hover is deliberately attached to its padded container,
    /// not an overlay, so pointer previews never steal click/drag hit testing from `Slider`.
    var timelineSlider: some View {
        GeometryReader { geometry in
            #if os(tvOS)
            ProgressView(value: scrubberBinding.wrappedValue, total: 1)
                .disabled(scrubState.durationMs <= 0)
                .frame(maxHeight: .infinity)
            #else
            Slider(value: scrubberBinding, in: 0...1) { editing in
                handleScrubEditingChanged(editing)
            }
            .disabled(scrubState.durationMs <= 0)
            .frame(maxHeight: .infinity)
            #if os(macOS) || os(iOS)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                handleTimelineHover(phase, trackWidth: geometry.size.width)
            }
            #endif
            .overlay(alignment: .topLeading) {
                if hoverPreviewTargetMs != nil,
                   !scrubState.isDragging,
                   let hoverPreviewX {
                    trickPlayPreview
                        .fixedSize()
                        .position(x: CGFloat(TrickPlayPreviewGeometry.cardCenterX(
                            pointerX: Double(hoverPreviewX),
                            trackWidth: Double(geometry.size.width),
                            cardWidth: 210
                        )), y: trickPlayProvider == nil ? -18 : -76)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
            #endif
        }
        .frame(minWidth: 40, minHeight: 32, idealHeight: 32, maxHeight: 32)
    }

    var skipControls: some View {
        HStack(spacing: 8) {
            skipButton(seconds: -30)
            skipButton(seconds: -10)
            skipButton(seconds: 10)
            skipButton(seconds: 30)
        }
    }

    func skipButton(seconds: Int) -> some View {
        let isForward = seconds > 0
        let amount = abs(seconds)
        // Keep every visible skip target at least 44pt; the old 38pt regular/visionOS
        // square was too small for reliable gaze/pinch acquisition.
        let side: CGFloat = 44
        return Button {
            performRelativeSkip(seconds: seconds)
        } label: {
            Label(isForward ? "Forward \(amount) seconds" : "Back \(amount) seconds",
                  systemImage: isForward ? "goforward.\(amount)" : "gobackward.\(amount)")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: side, height: side)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(scrubState.durationMs <= 0)
        .accessibilityLabel(isForward ? "Skip forward \(amount) seconds" : "Skip back \(amount) seconds")
    }

    @ViewBuilder var cinemaButton: some View {
        #if os(visionOS)
        if !CustomCinemaMode.isUserVisible {
            EmptyView()
        } else if cinemaSession.presentationState == .open {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Exit Cinema", systemImage: "rectangle.on.rectangle.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 112)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
        } else {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Cinema", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 82)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
        }
        #else
        EmptyView()
        #endif
    }


    @ViewBuilder var cinemaScreenButton: some View {
        #if os(visionOS)
        if CustomCinemaMode.isUserVisible && cinemaSession.presentationState == .open {
            Button {
                openMenu(.screen)
            } label: {
                Label("Screen position", systemImage: "rectangle.arrowtriangle.2.outward")
                    .labelStyle(.iconOnly)
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
            .accessibilityLabel("Screen position")
            .help("Adjust Cinema screen position")
        }
        #else
        EmptyView()
        #endif
    }


    @ViewBuilder var menuStrip: some View {
        #if os(visionOS)
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: menu.minChromeWidth)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        #elseif os(iOS)
        if isPhoneLandscapeChrome {
            phoneLandscapeMenuStrip
        } else {
            // Flat menus, no "…" overflow on portrait phone/iPad: every width keeps
            // the LABELED pills and scrolls them rather than degrading to icons.
            ViewThatFits(in: .horizontal) {
                labeledMenuStrip
                scrollableLabeledMenuStrip
            }
        }
        #else
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: menu.minChromeWidth)
                }
            }
        }
        #endif
    }


    var availableMenus: [CustomPlayerMenuKind] {
        CustomPlayerMenuKind.allCases.filter { menu in
            switch menu {
            #if os(visionOS)
            case .screen:
                return false
            #endif
            case .quality:
                return controller.supportsQualityReload
            case .subtitles, .audio, .chapters, .speed, .stats:
                return true
            }
        }
    }

    func upNextCard(_ next: MediaItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Playing in \(controller.upNext.countdown)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                revealChrome()
                controller.cancelUpNext()
            }
            .buttonStyle(.bordered)
            Button("Play Now") {
                revealChrome()
                controller.playNextNow()
            }
            .labstreamGlassProminentButtonStyle()
        }
        .padding(isCompactMobileChrome ? 14 : 18)
        .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    var scrubberBinding: Binding<Double> {
        Binding {
            guard scrubState.durationMs > 0 else { return 0 }
            return Double(scrubState.displayedPositionMs) / Double(scrubState.durationMs)
        } set: { fraction in
            revealChrome(keepVisible: true)
            if !scrubState.isDragging {
                // This is the PRIMARY drag-begin path: handleScrubEditingChanged(true)
                // deliberately does not beginDrag (the Slider keeps a session open across
                // touches — see the comment there), so a drag opens on the first value-set
                // that moves the value. A stray set outside any session is still ignored,
                // or it would re-open a drag with no session left to close it.
                guard scrubEditingSessionActive else { return }
                // The Slider echoes the committed position back through the binding right
                // after a release (inside the freshly re-opened session). Honoring it would
                // re-pin the drag forever, so a drag begins only when the incoming value
                // has genuinely moved away from what is displayed. 250ms of media time is
                // far below one point of thumb travel on any real timeline, so the first
                // actual finger movement always clears it.
                guard scrubState.durationMs > 0 else { return }
                let clamped = min(max(fraction, 0), 1)
                let targetMs = Int((Double(scrubState.durationMs) * clamped).rounded())
                guard abs(targetMs - scrubState.displayedPositionMs) > 250 else { return }
                scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
            }
            scrubState.updateDrag(fraction: fraction)
            updateTrickPlayPreview(for: scrubState.draftPositionMs, debounce: false)
        }
    }

    func handleScrubEditingChanged(_ editing: Bool) {
        scrubEditingSessionActive = editing
        if editing {
            revealChrome(keepVisible: true)
            // Do NOT beginDrag here. SwiftUI's Slider closes and immediately re-opens the
            // editing session on every release (observed live on iPadOS: editing(false) →
            // editing(true) within 1ms, echoing one value-set at the committed position),
            // and keeps that session open across touches — the user's NEXT drag reuses it,
            // and if the user walks away it simply never closes. Opening the drag eagerly
            // here let that dangling session pin isDragging true forever (trickplay preview
            // + displayed position frozen) and — because beginDrag samples the mid-rebuild
            // player clock — even commit a bogus seek to 0ms. The drag instead begins in
            // scrubberBinding on the first value-set that actually MOVES the value (the
            // post-release echo repeats the committed position exactly; a real finger
            // diverges immediately).
        } else if scrubState.isDragging, let target = scrubState.commit() {
            controller.performUserSeek(toMs: target)
            refreshPreviewAfterDrag()
            revealChrome()
        } else {
            // No drag ever began in this editing session (thumb touched without movement,
            // or the Slider's post-release session closing) — nothing to seek.
            refreshPreviewAfterDrag()
            revealChrome()
        }
    }

    #if os(macOS) || os(iOS)
    func handleTimelineHover(_ phase: HoverPhase, trackWidth: CGFloat) {
        #if os(iOS)
        // `onContinuousHover` is also available to an attached pointer on iPhone, but #237 is
        // intentionally an iPad pointer enhancement. Touch-only interaction remains untouched.
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        #endif

        switch phase {
        case .active(let location):
            guard let targetMs = TrickPlayPreviewGeometry.targetMs(
                pointerX: Double(location.x),
                trackWidth: Double(trackWidth),
                durationMs: scrubState.durationMs
            ) else {
                endHoverPreview()
                return
            }
            hoverPreviewX = min(max(location.x, 0), trackWidth)
            hoverPreviewTargetMs = targetMs
            revealChrome(keepVisible: true)
            guard !scrubState.isDragging else { return }
            // Continuous pointer movement commonly arrives faster than the preview debounce.
            // Cancelling and restarting that delay on every event starves the provider entirely,
            // leaving the card shimmering until the pointer becomes perfectly still. Start the
            // request immediately; provider/index caching plus generation checks still prevent
            // duplicate network loads and stale images.
            updateTrickPlayPreview(for: targetMs, debounce: false)
        case .ended:
            endHoverPreview()
            if !scrubState.isDragging { scheduleChromeHideIfNeeded() }
        }
    }
    #endif

    func refreshPreviewAfterDrag() {
        if let hoverPreviewTargetMs {
            updateTrickPlayPreview(for: hoverPreviewTargetMs, debounce: true)
        } else {
            clearTrickPlayPreview()
        }
    }

    func updateTrickPlayPreview(for targetMs: Int?, debounce: Bool) {
        guard let targetMs else {
            clearTrickPlayPreview()
            return
        }

        trickPlayPreviewTimeMs = targetMs
        guard let provider = trickPlayProvider else {
            trickPlayRequestGeneration &+= 1
            trickPlayPreviewTask?.cancel()
            trickPlayInFlightTargetMs = nil
            trickPlayPreviewLoading = false
            trickPlayPreviewImage = nil
            return
        }

        if let cached = trickPlayImageCache.nearestImage(to: targetMs, toleranceMs: 15_000) {
            trickPlayRequestGeneration &+= 1
            trickPlayPreviewTask?.cancel()
            trickPlayInFlightTargetMs = nil
            trickPlayPreviewImage = cached.image
            trickPlayPreviewCaptureTimeMs = cached.timeMs
            trickPlayPreviewLoading = false
            return
        }

        // A continuous pointer stream (including stationary hover ticks) can repeat the exact
        // same target while a fetch for it is already in flight. Cancelling and firing another
        // identical request wouldn't stop the first one's URLSession task anyway (cancellation
        // only stops us from acting on it), so it would just fan out duplicate network fetches.
        // Let the in-flight request finish rather than racing a copy of itself; a genuinely new
        // target below still cancels and replaces immediately.
        guard trickPlayInFlightTargetMs != targetMs else { return }

        trickPlayRequestGeneration &+= 1
        let generation = trickPlayRequestGeneration
        trickPlayPreviewLoading = true
        trickPlayPreviewTask?.cancel()
        trickPlayInFlightTargetMs = targetMs
        trickPlayPreviewTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
            }
            let thumbnail = await provider.thumbnail(nearMs: targetMs)
            guard !Task.isCancelled else { return }
            let decoded: DecodedImage?
            if let thumbnail {
                decoded = await DecodedImage.decodeEagerlyOffMain(data: thumbnail.imageData)
            } else {
                decoded = nil
            }
            // The detached ImageIO flight is allowed to finish after this request is superseded, but
            // a cancelled/stale generation must never publish or enter the MainActor cache.
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if trickPlayInFlightTargetMs == targetMs {
                    trickPlayInFlightTargetMs = nil
                }
                let completion = TrickPlayPreviewResolutionPolicy.completion(
                    requestGeneration: generation,
                    currentGeneration: trickPlayRequestGeneration,
                    requestTargetMs: targetMs,
                    activeTargetMs: activeTrickPlayTargetMs,
                    decodedThumbnailTimeMs: decoded == nil ? nil : thumbnail?.timeMs
                )
                switch completion {
                case .ignoredStale:
                    return
                case .clearImage:
                    trickPlayPreviewLoading = false
                    trickPlayPreviewImage = nil
                    trickPlayPreviewCaptureTimeMs = nil
                case .showImage(let captureTimeMs):
                    guard let decoded else { return }
                    trickPlayPreviewLoading = false
                    trickPlayImageCache.insert(decoded, for: captureTimeMs)
                    trickPlayPreviewImage = decoded
                    trickPlayPreviewCaptureTimeMs = captureTimeMs
                }
            }
        }
    }

    var activeTrickPlayTargetMs: Int? {
        if scrubState.isDragging { return scrubState.draftPositionMs }
        return hoverPreviewTargetMs
    }

    func endHoverPreview() {
        hoverPreviewTargetMs = nil
        hoverPreviewX = nil
        if !scrubState.isDragging { clearTrickPlayPreview() }
    }

    func clearTrickPlayPreview() {
        trickPlayRequestGeneration &+= 1
        trickPlayPreviewTask?.cancel()
        trickPlayInFlightTargetMs = nil
        trickPlayPreviewLoading = false
        trickPlayPreviewImage = nil
        trickPlayPreviewTimeMs = nil
        trickPlayPreviewCaptureTimeMs = nil
    }

    func performRelativeSkip(seconds: Int) {
        revealChrome(keepVisible: true)
        let target = controller.performRelativeUserSeek(bySeconds: seconds,
                                                        durationMs: scrubState.durationMs)
        _ = scrubState.commit(toMs: target)
        revealChrome()
    }

    func requestPlayerClose(_ close: () -> Void) {
        #if os(macOS)
        revealChrome(keepVisible: true)
        guard !macWindowBridge.exitFullScreenIfNeeded() else { return }
        #else
        revealChrome()
        #endif
        close()
    }



    /// Chapters is a horizontal filmstrip; unlike the small fixed menus it should fill most of the
    /// player width and stay centered. A fixed 1120-pt width looked right in the windowed player but
    /// narrow and right-shifted on the much wider Cinema canvas, so size it to the available width
    /// (capped) to keep the same proportion in both. On a compact phone the small fixed-width menus
    /// (Stats 470, Subtitles/Audio 390, Quality 340) plus the popover's +36 frame also overflow a
    /// 390-pt screen, so clamp every menu to the available width there. Returns nil for menus that
    /// keep their authored fixed size (regular width / visionOS).
    var menuHorizontalInset: CGFloat {
        if isPhoneLandscapeChrome {
            8
        } else if isCompactMobileChrome {
            12
        } else {
            54
        }
    }

    /// Keep floating menus comfortably above the safe area. Bottom transport chrome is hidden while
    /// a menu is open, so this is a modest edge clearance rather than another full chrome height.
    var menuBottomClearance: CGFloat {
        if isPhoneLandscapeChrome {
            8
        } else if isCompactMobileChrome {
            16
        } else {
            34
        }
    }

    var menuTopClearance: CGFloat {
        if isPhoneLandscapeChrome {
            12
        } else if isCompactMobileChrome {
            28
        } else {
            48
        }
    }

    func menuPopoverHeightLimit(availableHeight: CGFloat) -> CGFloat {
        max(160, availableHeight - menuBottomClearance - menuTopClearance)
    }

    func adaptiveMenuWidth(for menu: CustomPlayerMenuKind, available: CGFloat) -> CGFloat? {
        guard available > 0 else { return nil }
        // Footprint outside the content: the popover's internal +36 frame and the horizontal
        // padding applied to the popover on each side.
        let chrome: CGFloat = 36 + menuHorizontalInset * 2
        if menu == .chapters {
            return min(1680, max(isCompactMobileChrome ? 0 : 720, available - chrome))
        }
        guard isCompactMobileChrome else { return nil }
        // Compress the fixed-width menus to fit the phone-width bottom sheet.
        return min(menu.popoverSize.width, max(0, available - chrome))
    }

    func openMenu(_ menu: CustomPlayerMenuKind) {
        revealChrome(keepVisible: true)
        selectedMenu = menu
        #if os(tvOS)
        tvPlayerFocus = nil
        #endif
    }

    func closeMenu() {
        let closingMenu = selectedMenu
        selectedMenu = nil
        revealChrome()
        #if os(tvOS)
        // Verified write: the raw post-yield assignment can still race the strip's
        // re-insertion and drop (same failure class as the appear-time write, TVUI-024).
        if let closingMenu {
            tvEnsureFocus(.menu(closingMenu))
        }
        #endif
    }

    func handlePlayerSurfaceTap() {
        tvEvidenceLog("playerSurfaceTap chromeVisible=\(shouldShowChrome) menu=\(String(describing: selectedMenu))")
        if selectedMenu != nil {
            closeMenu()
            return
        }

        guard !controller.transport.showsPausedControl,
              !controller.transportStatus.keepsChromeVisible else {
            revealChrome(keepVisible: true)
            return
        }

        if chromeVisible {
            hideTask?.cancel()
            chromeVisible = false
        } else {
            revealChrome()
        }
    }

    func revealChrome(keepVisible: Bool = false) {
        chromeVisible = true
        hideTask?.cancel()
        if !keepVisible {
            scheduleChromeHideIfNeeded()
        }
    }


    func scheduleChromeHideIfNeeded() {
        hideTask?.cancel()
        guard !controller.transport.showsPausedControl,
              !controller.transportStatus.keepsChromeVisible,
              !scrubState.isDragging,
              selectedMenu == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  !controller.transport.showsPausedControl,
                  !controller.transportStatus.keepsChromeVisible,
                  !scrubState.isDragging,
                  selectedMenu == nil else { return }
            tvEvidenceLog("autoHide firing")
            chromeVisible = false
            #if os(tvOS)
            tvFocusHiddenSurface()
            #endif
        }
    }

    /// TVUI-024 evidence trace (SwiftUI layer). No-op outside DEBUG tvOS.
    func tvEvidenceLog(_ message: @autoclosure () -> String) {
        #if os(tvOS) && DEBUG
        if TVInputEvidence.isRequested {
            NSLog("%@", "TVPlayerEvidence: \(message())")
        }
        #endif
    }

    func format(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension View {
    @ViewBuilder
    func captionEdge(_ edge: CaptionTextEdgePresentation) -> some View {
        switch edge {
        case .none:
            self
        case .raised:
            self.shadow(color: .white.opacity(0.65), radius: 0, x: -1, y: -1)
                .shadow(color: .black.opacity(0.8), radius: 0, x: 1, y: 1)
        case .depressed:
            self.shadow(color: .black.opacity(0.8), radius: 0, x: -1, y: -1)
                .shadow(color: .white.opacity(0.5), radius: 0, x: 1, y: 1)
        case .uniform:
            self.shadow(color: .black, radius: 1.2, x: 0, y: 0)
        case .dropShadow:
            self.shadow(color: .black.opacity(0.9), radius: 2, x: 2, y: 2)
        }
    }
}
