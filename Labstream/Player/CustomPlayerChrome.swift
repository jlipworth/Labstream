import AVFoundation
import AVKit
import PMSKit
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if os(macOS)
enum MacPlayerEscapeAction: Equatable {
    case closeMenu
    case closePlayer
    case passThrough
}

func macPlayerEscapeAction(isMenuPresented: Bool,
                           hasCloseAction: Bool) -> MacPlayerEscapeAction {
    if isMenuPresented { return .closeMenu }
    if hasCloseAction { return .closePlayer }
    return .passThrough
}
#endif

/// Shared scrubber-clock tick used by both the windowed custom player and the Cinema scene.
///
/// Resolves the live duration from the player item (falling back to the catalog duration) and
/// pushes the controller's resume position into the scrub state unless the user is mid-drag.
@MainActor
func tickCustomScrubberClock(_ scrubState: inout PlaybackScrubState,
                             from controller: PlaybackController,
                             fallbackDurationMs: Int) {
    let duration = controller.player.currentItem?.duration
    let durationMs: Int
    if let duration, duration.seconds.isFinite, duration.seconds > 0 {
        durationMs = Int((duration.seconds * 1000).rounded())
    } else {
        durationMs = fallbackDurationMs
    }
    scrubState.updateDuration(durationMs)
    // Self-clear the seek hold once the live clock has actually landed at/after the target (the
    // per-item readyToPlay fires once and may precede that, so the 500ms tick backstops it).
    controller.releaseSeekHoldIfLanded()
    // Zombie watch: a starved rebuild can report `.playing` with a parked clock, a state no
    // KVO transition ever surfaces — this tick poll is the ONLY signal that escalates it to
    // the Reconnecting/Retry overlay and the only one that clears the overlay on recovery.
    controller.detectZombiePlaybackIfStuck()
    if !scrubState.isDragging {
        // While a user seek is in flight (in-buffer native seek, or an out-of-buffer
        // rebuild/reopen), pass `holdCommittedTarget: true` so the committed target stays pinned:
        // during a Jellyfin/Emby/Plex stream rebuild `currentResumeMs` can briefly alternate
        // between a near-target reading and a stale fallback, which made the time label bounce
        // (GH #110). The hold is released by the controller's seek lifecycle (seek completion /
        // post-rebuild readyToPlay / failure / stop / max-hold ceiling).
        scrubState.updateLivePosition(controller.currentResumeMs,
                                      holdCommittedTarget: controller.isSeeking)
    }
}

/// App-owned full-screen chrome for the custom player.
///
/// This deliberately carries the playback feature set that used to live in system surfaces: the
/// custom route must not regress just because it owns its transport. The chrome behaves like player chrome,
/// not permanent app UI: taps reveal it, playback auto-hides it, and modal menu/error/reconnect
/// states keep it visible while the viewer is acting on them.
struct CustomPlayerChrome: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(RealityTheaterSessionStore.self) private var realityTheaterSession
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
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
    let allowsRealityTheater: Bool

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var selectedMenu: CustomPlayerMenuKind?
    @State private var menuState: PlayerMenuState
    @State private var trickPlayPreviewTask: Task<Void, Never>?
    @State private var trickPlayPreviewImage: UIImage?
    @State private var trickPlayPreviewTimeMs: Int?
    @State private var trickPlayPreviewCaptureTimeMs: Int?
    @State private var trickPlayPreviewLoading = false
    @State private var trickPlayImageCache = TrickPlayPreviewImageCache(limit: 32)
    @State private var trickPlayRequestGeneration = 0
    @State private var trickPlayInFlightTargetMs: Int?
    @State private var hoverPreviewTargetMs: Int?
    @State private var hoverPreviewX: CGFloat?
    @State private var mobileDisplayStatus: String?
    @State private var mobileDisplayStatusTask: Task<Void, Never>?
    #if os(iOS)
    @State private var chromeViewportSize: CGSize = .zero
    #endif
    #if os(macOS)
    @State private var macWindowBridge = MacPlayerWindowBridge()
    @State private var macKeyMonitor: Any?
    #endif
    /// True only between a Slider `onEditingChanged(true)` and its matching `(false)`. Guards the
    /// scrubber binding's defensive `beginDrag` so a trailing value-set arriving after the commit
    /// cannot re-open the drag (see `scrubberBinding`).
    @State private var scrubEditingSessionActive = false

    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?,
         allowsRealityTheater: Bool = false) {
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
        self.allowsRealityTheater = allowsRealityTheater
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
         onClose: (() -> Void)?,
         allowsRealityTheater: Bool = false) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.trickPlayProvider = trickPlayProvider
        _mobileVideoDisplayMode = mobileVideoDisplayMode
        self.mobileSystemCoordinator = mobileSystemCoordinator
        self.onRetry = onRetry
        self.onClose = onClose
        self.allowsRealityTheater = allowsRealityTheater
        _menuState = State(initialValue: PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps))
    }
    #endif

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                #if os(iOS)
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

            if shouldShowChrome {
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
        #if os(iOS)
        // System-player behavior: the status bar and home indicator ride with the chrome —
        // hidden over clean video, back the moment controls reveal. Without this the clock/
        // battery and indicator bar sit lit over the picture for the whole session.
        .statusBarHidden(!shouldShowChrome)
        .persistentSystemOverlays(shouldShowChrome ? .automatic : .hidden)
        #endif
    }

    private var shouldShowChrome: Bool {
        chromeVisible || controller.transport.showsPausedControl || controller.transportStatus.keepsChromeVisible || selectedMenu != nil
    }

    private var isTransportStatusPresented: Bool {
        controller.transportStatus.activeStatus != nil
    }

    private var isCompactMobileChrome: Bool {
        #if os(iOS)
        mobileChromeLayout.usesCompactChrome
        #else
        false
        #endif
    }

    private var isPhoneLandscapeChrome: Bool {
        #if os(iOS)
        mobileChromeLayout.isPhoneLandscape
        #else
        false
        #endif
    }

    #if os(iOS)
    private var mobileChromeLayout: MobilePlayerChromeLayoutPolicy {
        MobilePlayerChromeLayoutPolicy(horizontalSizeClass: horizontalSizeClass,
                                       verticalSizeClass: verticalSizeClass,
                                       idiom: UIDevice.current.userInterfaceIdiom,
                                       viewportSize: chromeViewportSize)
    }
    #endif

    private var bottomChromeHorizontalInset: CGFloat {
        #if os(macOS)
        22
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

    private var bottomChromeBottomInset: CGFloat {
        #if os(macOS)
        18
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

    private var subtitleBottomPadding: CGFloat {
        if chromeVisible {
            isPhoneLandscapeChrome ? 116 : 168
        } else {
            isPhoneLandscapeChrome ? 42 : 64
        }
    }

    @ViewBuilder private var offlineSubtitleOverlay: some View {
        if let text = controller.offlineSubtitleOverlay.text, !text.isEmpty {
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 8)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var transientStatusOverlay: some View {
        // The chrome renders the controller-owned transport status verbatim. It does not compose
        // buffering, retry, and failure booleans, so Cinema cannot show duplicate dialogs when HLS
        // delivery chatters between waiting and playing.
        if let status = controller.transportStatus.activeStatus {
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

    private var topChrome: some View {
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

    private var topChromeHorizontalInset: CGFloat {
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

    private var topChromeTopInset: CGFloat {
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

    #if os(iOS)
    private var topUtilityButtonExtraTopPadding: CGFloat {
        10
    }

    private var topUtilityButtonVisualSide: CGFloat {
        isPhoneLandscapeChrome ? 38 : 44
    }

    private var topUtilityButtonHitSide: CGFloat {
        max(44, topUtilityButtonVisualSide)
    }

    private var airPlayButton: some View {
        AirPlayRoutePickerButton()
            .frame(width: topUtilityButtonVisualSide, height: topUtilityButtonVisualSide)
            .frame(width: topUtilityButtonHitSide, height: topUtilityButtonHitSide)
            .iosPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscapeChrome)
            .accessibilityLabel("AirPlay")
    }

    private var displayModeButton: some View {
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

    private func setMobileVideoDisplayMode(_ mode: MobileVideoDisplayMode) {
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

    private var pipButton: some View {
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
    #endif

    #if os(macOS)
    @ViewBuilder
    private var macTopTrailingControls: some View {
        HStack(spacing: 10) {
            macFullscreenButton
            if let onClose {
                macTopChromeButton("Close Player", systemImage: "xmark") {
                    requestPlayerClose(onClose)
                }
            }
        }
    }

    private var macFullscreenButton: some View {
        macTopChromeButton("Toggle Full Screen",
                           systemImage: "arrow.up.left.and.arrow.down.right",
                           autoHidesChrome: true) {
            macWindowBridge.toggleFullScreen()
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
    }

    private func macTopChromeButton(_ help: String,
                                    systemImage: String,
                                    autoHidesChrome: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button {
            // A destructive/dismissal action keeps the controls pinned while it completes,
            // but entering native fullscreen is not a modal interaction. Restart the ordinary
            // five-second hide timer so the expanded movie does not retain its chrome until the
            // viewer clicks the playback surface for the first time.
            revealChrome(keepVisible: !autoHidesChrome)
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.42))
                    .frame(width: 34, height: 34)
                Circle()
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    .frame(width: 34, height: 34)
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // Keep the visible control subtle, but make the actual pointer/tap target match
            // Apple's 44pt minimum. The old 30pt hit target was easy to miss near the macOS
            // titlebar/fullscreen chrome even when the cursor looked like it was inside the
            // visible circle.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .help(help)
        .accessibilityLabel(help)
    }
    #endif

    #if os(iOS) || os(macOS)
    /// Zero-size buttons whose only job is to register hardware-keyboard shortcuts. Space
    /// toggles play/pause; ←/→ perform the fast 30s jumps; ⇧←/⇧→ perform the finer 10s
    /// jumps. On iOS, Esc closes the player. macOS handles physical Escape in its existing
    /// focus-independent AppKit key monitor. Kept out of the visible layout via `opacity(0)`.
    @ViewBuilder private var keyboardShortcuts: some View {
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

    #if os(macOS)
    private func installMacKeyMonitor() {
        guard macKeyMonitor == nil else { return }
        macKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleMacKeyDown(event) {
                return nil
            }
            return event
        }
    }

    private func removeMacKeyMonitor() {
        guard let macKeyMonitor else { return }
        NSEvent.removeMonitor(macKeyMonitor)
        self.macKeyMonitor = nil
    }

    private func handleMacKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 53, modifiers.isEmpty { // Escape
            guard !event.isARepeat else { return true }
            switch macPlayerEscapeAction(isMenuPresented: selectedMenu != nil,
                                         hasCloseAction: onClose != nil) {
            case .closeMenu:
                closeMenu()
            case .closePlayer:
                if let onClose { requestPlayerClose(onClose) }
            case .passThrough:
                return false
            }
            return true
        }

        let seconds: Int?
        switch event.keyCode {
        case 123: // left arrow
            if modifiers.isEmpty {
                seconds = -30
            } else if modifiers == .shift {
                seconds = -10
            } else {
                seconds = nil
            }
        case 124: // right arrow
            if modifiers.isEmpty {
                seconds = 30
            } else if modifiers == .shift {
                seconds = 10
            } else {
                seconds = nil
            }
        default:
            seconds = nil
        }

        guard let seconds else { return false }
        performRelativeSkip(seconds: seconds)
        return true
    }
    #endif

    @ViewBuilder
    private var controls: some View {
        #if os(macOS)
        macControls
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

    #if os(macOS)
    private var macControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            macControlsHeader

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 14) {
                macTransportControls

                Text(format(ms: scrubState.displayedPositionMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 62, alignment: .trailing)

                timelineSlider
                .controlSize(.small)
                .tint(.white)

                Text(format(ms: scrubState.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 62, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 1_120)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.11), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
        .colorScheme(.dark)
    }

    private var macControlsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                macTitleLabel

                Spacer(minLength: 20)

                macMenuStrip
            }

            VStack(alignment: .leading, spacing: 9) {
                macTitleLabel
                macMenuStrip
            }
        }
    }

    private var macTitleLabel: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 160, idealWidth: 300, maxWidth: 460, alignment: .leading)
            .layoutPriority(1)
            .accessibilityLabel(title)
    }

    private var macTransportControls: some View {
        HStack(spacing: 7) {
            macSkipButton(seconds: -30)
            macSkipButton(seconds: -10)
            macPlayPauseButton
            macSkipButton(seconds: 10)
            macSkipButton(seconds: 30)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var macPlayPauseButton: some View {
        Button {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        } label: {
            Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.white.opacity(0.14), in: Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .help(controller.transport.showsPausedControl ? "Play" : "Pause")
    }

    private func macSkipButton(seconds: Int) -> some View {
        let isForward = seconds > 0
        let amount = abs(seconds)
        return Button {
            performRelativeSkip(seconds: seconds)
        } label: {
            Image(systemName: isForward ? "goforward.\(amount)" : "gobackward.\(amount)")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(scrubState.durationMs <= 0 ? 0.34 : 0.82))
        .background(.white.opacity(0.075), in: Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
        }
        .disabled(scrubState.durationMs <= 0)
        .help(isForward ? "Skip Forward \(amount) Seconds" : "Skip Back \(amount) Seconds")
        .accessibilityLabel(isForward ? "Skip forward \(amount) seconds" : "Skip back \(amount) seconds")
    }

    private var macMenuStrip: some View {
        HStack(spacing: 7) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .frame(minWidth: menu.minChromeWidth, minHeight: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(selectedMenu == menu ? 1 : 0.78))
                .background(.white.opacity(selectedMenu == menu ? 0.18 : 0.075),
                            in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(selectedMenu == menu ? 0.18 : 0.09), lineWidth: 0.5)
                }
                .help(menu.title)
                .accessibilityLabel(menu.title)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    #endif

    private var regularControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            regularControlsHeader

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 16) {
                #if !os(iOS)
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
    private var regularControlsHeader: some View {
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

            realityTheaterDeveloperButton
                .fixedSize(horizontal: true, vertical: false)

            menuStrip
                .fixedSize(horizontal: true, vertical: false)
        }
        #endif
    }

    private var regularTitleLabel: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            // Keep the title present, but do not let it reserve half the row on iPad:
            // the one-tap menu pills are the interactive controls and need the width.
            .frame(minWidth: 120, idealWidth: 260, maxWidth: 360, alignment: .leading)
            .accessibilityLabel(title)
    }

    #if os(iOS)
    private var regularIOSHeaderInline: some View {
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

    private var regularIOSHeaderStacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            regularTitleLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            menuStrip
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    #endif

    #if os(iOS)
    private var phoneLandscapeControls: some View {
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
    #endif

    private var compactControls: some View {
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
                #if !os(iOS)
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

    private var compactScrubberColumn: some View {
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

    private var playPauseButton: some View {
        Button(action: {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        }) {
            playPauseButtonLabel
        }
        #if os(visionOS)
        .buttonStyle(.borderedProminent)
        #else
        // Neutral symbol on the glass platter, like the system player's
        // transport controls — the accent stays reserved for real CTAs.
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        #endif
        .accessibilityLabel(controller.transport.showsPausedControl ? "Play" : "Pause")
        .accessibilityHint("Toggles playback")
    }

    #if os(iOS)
    /// iPhone and iPad follow the familiar full-screen player hierarchy: the primary
    /// play/pause action belongs over the picture, not crowded into the timeline bar.
    private var iosCenterPlayPauseButton: some View {
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

    private func phoneLandscapeSkipButton(seconds: Int) -> some View {
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
    #endif

    @ViewBuilder
    private var playPauseButtonLabel: some View {
        #if os(iOS)
        ZStack {
            Circle()
                .fill(.white.opacity(isCompactMobileChrome ? 0.16 : 0.12))
            Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                .font((isCompactMobileChrome ? Font.title2 : Font.title3).weight(.semibold))
        }
        .frame(width: playPauseButtonSide, height: playPauseButtonSide)
        .contentShape(Circle())
        #else
        Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
            .font(.title2.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        #endif
    }

    private var playPauseButtonSide: CGFloat {
        #if os(iOS)
        isPhoneLandscapeChrome ? 46 : (isCompactMobileChrome ? 56 : 44)
        #else
        44
        #endif
    }


    @ViewBuilder private var trickPlayPreview: some View {
        VStack(spacing: 8) {
            if trickPlayProvider != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    if let trickPlayPreviewImage {
                        Image(uiImage: trickPlayPreviewImage)
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
    private var timelineSlider: some View {
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

    private var skipControls: some View {
        HStack(spacing: 8) {
            skipButton(seconds: -30)
            skipButton(seconds: -10)
            skipButton(seconds: 10)
            skipButton(seconds: 30)
        }
    }

    private func skipButton(seconds: Int) -> some View {
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

    @ViewBuilder private var cinemaButton: some View {
        #if os(visionOS)
        // Shipping Cinema uses the custom-player ImmersiveSpace. The separate RealityKit theater
        // prototype has its own feature/session boundary and remains gated until device-ready.
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


    @ViewBuilder private var cinemaScreenButton: some View {
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


    @ViewBuilder private var realityTheaterDeveloperButton: some View {
        #if os(visionOS)
        if allowsRealityTheater
            && (RealityTheaterFeature.isDeviceTestingEntryPointVisible
                || RealityTheaterFeature.isDeveloperEntryPointEnabled()
                || RealityTheaterFeature.isShippingEntryPointVisible) {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleRealityTheaterMode() }
            } label: {
                Label(realityTheaterSession.phase == .open ? "Exit Cinema" : "Cinema",
                      systemImage: realityTheaterSession.phase == .open
                      ? "rectangle.on.rectangle.slash" : "theatermasks.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: realityTheaterButtonMinWidth)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(realityTheaterSession.phase == .opening)
            .help("RealityKit cinema prototype for #12 headset testing")
        }
        #else
        EmptyView()
        #endif
    }


    private var realityTheaterButtonMinWidth: CGFloat {
        realityTheaterSession.phase == .open ? 112 : CustomPlayerMenuKind.quality.minChromeWidth
    }

    @ViewBuilder private var menuStrip: some View {
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

    #if os(iOS)

    private var phoneLandscapePrimaryMenus: [CustomPlayerMenuKind] {
        availableMenus.filter { [.quality, .subtitles, .audio, .chapters, .speed, .stats].contains($0) }
    }

    private var phoneLandscapeOverflowMenus: [CustomPlayerMenuKind] {
        availableMenus.filter { !phoneLandscapePrimaryMenus.contains($0) }
    }

    /// Compact landscape controls keep the complete playback-option set visible now
    /// that play/pause lives over the picture and no longer consumes this row.
    private var phoneLandscapeMenuStrip: some View {
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

    private func phoneLandscapeMenuButton(_ menu: CustomPlayerMenuKind) -> some View {
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

    private func phoneLandscapeMenuMinWidth(_ menu: CustomPlayerMenuKind) -> CGFloat {
        switch menu {
        case .quality: 78
        case .subtitles: 70
        case .audio: 68
        case .chapters: 84
        case .speed, .stats: 66
        case .screen: 72
        }
    }

    /// visionOS-parity labeled pills in iOS glass styling — every menu one tap away.
    private var labeledMenuStrip: some View {
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
    private var scrollableLabeledMenuStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            labeledMenuStrip
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
    #endif

    private var availableMenus: [CustomPlayerMenuKind] {
        CustomPlayerMenuKind.allCases.filter { menu in
            switch menu {
            case .screen:
                return false
            case .quality:
                return controller.supportsQualityReload
            case .subtitles, .audio, .chapters, .speed, .stats:
                return true
            }
        }
    }

    private func upNextCard(_ next: MediaItem) -> some View {
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

    private var scrubberBinding: Binding<Double> {
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

    private func handleScrubEditingChanged(_ editing: Bool) {
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
    private func handleTimelineHover(_ phase: HoverPhase, trackWidth: CGFloat) {
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

    private func refreshPreviewAfterDrag() {
        if let hoverPreviewTargetMs {
            updateTrickPlayPreview(for: hoverPreviewTargetMs, debounce: true)
        } else {
            clearTrickPlayPreview()
        }
    }

    private func updateTrickPlayPreview(for targetMs: Int?, debounce: Bool) {
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
            let decoded = thumbnail.flatMap { UIImage(data: $0.imageData) }
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

    private var activeTrickPlayTargetMs: Int? {
        if scrubState.isDragging { return scrubState.draftPositionMs }
        return hoverPreviewTargetMs
    }

    private func endHoverPreview() {
        hoverPreviewTargetMs = nil
        hoverPreviewX = nil
        if !scrubState.isDragging { clearTrickPlayPreview() }
    }

    private func clearTrickPlayPreview() {
        trickPlayRequestGeneration &+= 1
        trickPlayPreviewTask?.cancel()
        trickPlayInFlightTargetMs = nil
        trickPlayPreviewLoading = false
        trickPlayPreviewImage = nil
        trickPlayPreviewTimeMs = nil
        trickPlayPreviewCaptureTimeMs = nil
    }

    private func performRelativeSkip(seconds: Int) {
        revealChrome(keepVisible: true)
        let target = controller.performRelativeUserSeek(bySeconds: seconds,
                                                        durationMs: scrubState.durationMs)
        _ = scrubState.commit(toMs: target)
        revealChrome()
    }

    private func requestPlayerClose(_ close: () -> Void) {
        #if os(macOS)
        revealChrome(keepVisible: true)
        guard !macWindowBridge.exitFullScreenIfNeeded() else { return }
        #else
        revealChrome()
        #endif
        close()
    }

    private func toggleCinemaMode() async {
        #if os(visionOS)
        switch cinemaSession.presentationState {
        case .closed:
            cinemaSession.presentationState = .inTransition
            switch await openImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            case .opened:
                // Detach the normal player window after the immersive surface is open so its
                // translucent pane does not sit in front of Cinema. The immersive Exit path
                // stops/clears playback before reopening the app, so there is nothing to preserve.
                onClose?()
                dismissWindow(id: CustomCinemaMode.mainWindowID)
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                cinemaSession.presentationState = .closed
            }
        case .open:
            cinemaSession.prepareExit(returningTo: cinemaSession.item, autoPlay: false, advancingToNext: false)
            // Just dismiss; the cinema scaffold's onDisappear owns the exit (stop the session, route
            // to the content detail page, reopen the window). It fires for every dismissal — this
            // button, a single Crown press, or a system collapse — so the exit path lives in one place.
            await dismissImmersiveSpace()
        case .inTransition:
            break
        }
        #endif
    }


    private func toggleRealityTheaterMode() async {
        #if os(visionOS)
        switch realityTheaterSession.phase {
        case .inactive, .prepared:
            realityTheaterSession.prepare(title: title,
                                          controller: controller,
                                          configuration: realityTheaterSession.configuration)
            realityTheaterSession.markOpening()
            switch await openImmersiveSpace(id: RealityTheaterFeature.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                realityTheaterSession.markClosed()
            }
        case .open:
            realityTheaterSession.markOpening()
            await dismissImmersiveSpace()
        case .opening:
            break
        }
        #endif
    }

    /// Chapters is a horizontal filmstrip; unlike the small fixed menus it should fill most of the
    /// player width and stay centered. A fixed 1120-pt width looked right in the windowed player but
    /// narrow and right-shifted on the much wider Cinema canvas, so size it to the available width
    /// (capped) to keep the same proportion in both. On a compact phone the small fixed-width menus
    /// (Stats 470, Subtitles/Audio 390, Quality 340) plus the popover's +36 frame also overflow a
    /// 390-pt screen, so clamp every menu to the available width there. Returns nil for menus that
    /// keep their authored fixed size (regular width / visionOS).
    private var menuHorizontalInset: CGFloat {
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
    private var menuBottomClearance: CGFloat {
        if isPhoneLandscapeChrome {
            8
        } else if isCompactMobileChrome {
            16
        } else {
            34
        }
    }

    private var menuTopClearance: CGFloat {
        if isPhoneLandscapeChrome {
            12
        } else if isCompactMobileChrome {
            28
        } else {
            48
        }
    }

    private func menuPopoverHeightLimit(availableHeight: CGFloat) -> CGFloat {
        max(160, availableHeight - menuBottomClearance - menuTopClearance)
    }

    private func adaptiveMenuWidth(for menu: CustomPlayerMenuKind, available: CGFloat) -> CGFloat? {
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

    private func openMenu(_ menu: CustomPlayerMenuKind) {
        revealChrome(keepVisible: true)
        selectedMenu = menu
    }

    private func closeMenu() {
        selectedMenu = nil
        revealChrome()
    }

    private func handlePlayerSurfaceTap() {
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

    private func revealChrome(keepVisible: Bool = false) {
        chromeVisible = true
        hideTask?.cancel()
        if !keepVisible {
            scheduleChromeHideIfNeeded()
        }
    }

    private func scheduleChromeHideIfNeeded() {
        hideTask?.cancel()
        guard !controller.transport.showsPausedControl,
              !controller.transportStatus.keepsChromeVisible,
              selectedMenu == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  !controller.transport.showsPausedControl,
                  !controller.transportStatus.keepsChromeVisible,
                  selectedMenu == nil else { return }
            chromeVisible = false
        }
    }

    private func format(ms: Int) -> String {
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


#if os(iOS)
private struct IOSPlayerTopUtilityButtonStyle: ViewModifier {
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

private struct PhoneLandscapePlayerMenuButtonStyle: ViewModifier {
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

private extension View {
    func iosPlayerTopUtilityButtonStyle(isPhoneLandscape: Bool) -> some View {
        modifier(IOSPlayerTopUtilityButtonStyle(isPhoneLandscape: isPhoneLandscape))
    }

    func phoneLandscapePlayerMenuButtonStyle(isSelected: Bool) -> some View {
        modifier(PhoneLandscapePlayerMenuButtonStyle(isSelected: isSelected))
    }
}
#endif

#if os(iOS)
/// Pure sizing policy for the mobile player chrome.
///
/// iPhones in landscape are constrained by height even when their horizontal size class is
/// regular, and iPad split views can be compact without being phone-like. Keep those cases
/// explicit so we drop chrome rows based on the actual viewport instead of only one size class.
private struct MobilePlayerChromeLayoutPolicy: Equatable {
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
#endif

#if os(iOS)
private struct AirPlayRoutePickerButton: UIViewRepresentable {
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
#endif

#if os(macOS)
/// Weak bridge from SwiftUI chrome to the AppKit window that hosts the custom player.
///
/// The fullscreen action intentionally uses the native macOS window transition for the
/// whole SwiftUI/AVPlayerLayer surface rather than introducing AVKit's stock
/// `AVPlayerView`/fullscreen controller.
@MainActor
private final class MacPlayerWindowBridge {
    weak var window: NSWindow?

    func toggleFullScreen() {
        (window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    @discardableResult
    func exitFullScreenIfNeeded() -> Bool {
        guard let targetWindow = window ?? NSApp.keyWindow,
              targetWindow.styleMask.contains(.fullScreen) else { return false }
        targetWindow.toggleFullScreen(nil)
        return true
    }
}

private struct MacPlayerWindowReader: NSViewRepresentable {
    let bridge: MacPlayerWindowBridge

    func makeNSView(context: Context) -> MacPlayerWindowReaderView {
        let view = MacPlayerWindowReaderView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: MacPlayerWindowReaderView, context: Context) {
        nsView.bridge = bridge
        bridge.window = nsView.window
    }
}

private final class MacPlayerWindowReaderView: NSView {
    weak var bridge: MacPlayerWindowBridge?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bridge?.window = window
    }
}
#endif

private enum CustomPlayerMenuKind: String, CaseIterable, Identifiable {
    case screen
    case quality
    case subtitles
    case audio
    case chapters
    case speed
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "Screen Position"
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
        case .screen: "Screen"
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
        case .screen: "rectangle"
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
        case .screen: 82
        case .chapters: 94
        }
    }

    var popoverSize: CGSize {
        #if os(macOS)
        switch self {
        case .screen: CGSize(width: 360, height: 320)
        case .quality: CGSize(width: 250, height: 228)
        case .speed: CGSize(width: 230, height: 188)
        case .subtitles, .audio: CGSize(width: 290, height: 210)
        case .chapters: CGSize(width: 920, height: 210)
        case .stats: CGSize(width: 420, height: 285)
        }
        #else
        switch self {
        case .screen: CGSize(width: 430, height: 390)
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
        case .screen, .speed, .stats: .trailing
        }
    }
}

private struct CustomPlayerMenuPopover: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession

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

            Divider()
                .opacity(0.35)
                .frame(width: size.width)

            menuContent
                .frame(width: size.width, height: size.height, alignment: .topLeading)
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
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var headerHeight: CGFloat {
        #if os(macOS)
        30
        #else
        44
        #endif
    }

    private var closeButtonSide: CGFloat {
        #if os(macOS)
        24
        #else
        44
        #endif
    }

    private var popoverPadding: CGFloat {
        #if os(macOS)
        14
        #else
        18
        #endif
    }

    private var popoverCornerRadius: CGFloat {
        #if os(macOS)
        15
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
        case .screen:
            #if os(visionOS)
            CinemaScreenAdjustmentView(session: cinemaSession)
            #else
            EmptyView()
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


#if os(visionOS)
private struct CinemaScreenAdjustmentView: View {
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

#endif

struct CustomTransportStatusOverlay: View {
    let status: PlaybackTransportStatus
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let onTogglePause: () -> Void
    /// On a compact phone (and a 320-pt Slide Over pane) a fixed 340-pt platter overflows the
    /// 40-pt-padded region, so cap instead of pinning the width there. Regular width / visionOS
    /// keep the exact 340-pt platter.
    var isCompact: Bool = false

    private var title: String {
        switch status {
        case .none: ""
        case .buffering: "Buffering…"
        case .pausedBuffering: "Paused — buffering…"
        case .reconnecting: "Reconnecting…"
        case .failed: "Playback failed"
        }
    }

    private var detail: String? {
        switch status {
        case .none:
            nil
        case .buffering:
            "You can pause now and let the stream build buffer before playing."
        case .pausedBuffering:
            "Playback will stay paused once the stream is ready."
        case .reconnecting:
            nil
        case .failed(let message):
            message?.isEmpty == false ? message : nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            switch status {
            case .failed:
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
            default:
                ProgressView(title)
                    .controlSize(.large)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            switch status {
            case .buffering, .pausedBuffering:
                Button {
                    onTogglePause()
                } label: {
                    Label(isPausedBuffering ? "Play when ready" : "Pause while loading",
                          systemImage: isPausedBuffering ? "play.fill" : "pause.fill")
                }
                .playerTransportProminentButtonStyle()
                .controlSize(.small)
            case .reconnecting:
                if let onClose {
                    Button(role: .cancel, action: onClose) {
                        Text("Close")
                            .frame(width: 150)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            case .failed:
                VStack(spacing: 8) {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(minWidth: 160)
                    }
                    .playerTransportProminentButtonStyle()
                    if let onClose {
                        Button(action: onClose) {
                            Text("Close")
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: isCompact ? 340 : nil)
        .frame(width: isCompact ? nil : 340)
        .labstreamOverlayPlatter(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 18)
    }

    private var isPausedBuffering: Bool {
        if case .pausedBuffering = status { return true }
        return false
    }
}

private extension View {
    /// Player status CTAs live under the iOS player-wide `.tint(.white)`. Plainly inheriting that
    /// into `.glassProminent` can produce a low-contrast white-on-white buffering action, so pin the
    /// label to dark text only for these high-contrast monochrome player status buttons.
    @ViewBuilder
    func playerTransportProminentButtonStyle() -> some View {
        #if os(visionOS)
        self.labstreamGlassProminentButtonStyle()
        #else
        self.buttonStyle(.glassProminent)
            .tint(.white)
            .foregroundStyle(.black)
        #endif
    }
}
