import AVKit
import Foundation
import PMSKit
import SwiftUI
import UIKit

// Target-exclusive mobile presentation leaves for the shared player chrome.
//
// iPhone and iPad use ONE control arrangement in every pose (iPhone Duo design spec, "Player"):
//
//   top row      Close, PiP and gravity at leading; AirPlay at trailing
//   transport    −10 / play-pause / +10, centred
//   title        the title (1 line) and a 1–2 word caption, at leading
//   scrubber     the timeline with elapsed and remaining times
//   menus        Quality, Subtitles, Audio, Chapters, Speed, Stats
//
// The menus are labeled glass capsules whenever they fit (beside the title on a wide viewport,
// else on their own row under the scrubber) and icon-only circles, same order, when they do not.
// Quality is always present and first (dimmed when the source only plays at original quality).
// The transport adds −30 / +30 outside the ±10 pair when the row has room. `MobilePlayerArrangement`
// (PMSKit) decides only where the group sits: the whole safe frame, the video rectangle on a
// portrait viewport, the trailing half in book, or a deck below the hinge in tabletop.
extension CustomPlayerChrome {
    nonisolated static let mobileChromeSpace = "labstream.player.mobileChrome"
    /// Stats panel width on a regular viewport: room for the four-column tile grid.
    static let mobileWideStatsWidth: CGFloat = 600

    /// Chrome composition from the measured player viewport and size classes
    /// (`MobilePlayerChromeLayoutPolicy`). The idiom only selects the phone-landscape metrics.
    var mobileChromeLayout: MobilePlayerChromeLayoutPolicy {
        MobilePlayerChromeLayoutPolicy(horizontalSizeClass: Self.policySizeClass(horizontalSizeClass),
                                       verticalSizeClass: Self.policySizeClass(verticalSizeClass),
                                       isPhoneIdiom: UIDevice.current.userInterfaceIdiom == .phone,
                                       viewportWidth: Double(chromeViewportSize.width),
                                       viewportHeight: Double(chromeViewportSize.height))
    }

    var mobileChromeBranch: MobilePlayerChromeLayoutPolicy.Branch {
        mobileChromeLayout.branch
    }

    static func policySizeClass(_ sizeClass: UserInterfaceSizeClass?) -> MobilePlayerChromeLayoutPolicy.SizeClass? {
        switch sizeClass {
        case .compact: .compact
        case .regular: .regular
        case nil: nil
        @unknown default: nil
        }
    }

    // MARK: Arrangement in local space

    /// `mobileArrangement` (global space) moved into this view's own space. Before the player is
    /// measured, the whole view below the latched top inset is the overlay.
    var mobileLocalArrangement: MobilePlayerArrangement {
        if let arrangement = mobileArrangement, let origin = mobileChromeGlobalOrigin,
           arrangement.chromeFrame.width > 0, arrangement.chromeFrame.height > 0 {
            func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            return MobilePlayerArrangement(mode: arrangement.mode,
                                           videoFrame: local(arrangement.videoFrame),
                                           chromeFrame: local(arrangement.chromeFrame),
                                           transportFrame: local(arrangement.transportFrame),
                                           bottomGroupFrame: local(arrangement.bottomGroupFrame),
                                           statusFrame: local(arrangement.statusFrame))
        }
        let full = CGRect(origin: .zero, size: chromeViewportSize)
        let top = min(mobileLatchedTopSafeInset, full.height)
        let safe = CGRect(x: 0, y: top, width: full.width, height: full.height - top)
        return MobilePlayerArrangement(mode: .overlay, videoFrame: full, chromeFrame: safe,
                                       transportFrame: safe, bottomGroupFrame: safe, statusFrame: safe)
    }

    /// Distance from the top of this view to the top row. In the overlay and book the group starts
    /// at the safe edge and keeps the authored inset (or the latched inset plus a margin); on the
    /// video rectangle and the tabletop deck it starts one margin inside the group's frame.
    func mobileTopRowY(_ arrangement: MobilePlayerArrangement) -> CGFloat {
        let inner: CGFloat
        switch arrangement.mode {
        case .overlay, .book: inner = 0
        case .videoRect, .tabletop: inner = mobileEdgeInset
        }
        return max(arrangement.chromeFrame.minY + inner, topChromeEffectiveTopInset)
    }

    func mobileBottomInset(_ arrangement: MobilePlayerArrangement) -> CGFloat {
        switch arrangement.mode {
        case .videoRect: mobileEdgeInset
        case .tabletop: bottomChromeBottomInset
        case .overlay, .book:
            // The group's frame already stops at the bottom safe edge (the home indicator), so the
            // authored margin counts from the picture's edge, not on top of the inset. Stacking
            // both left a tall dead band under the circles on the unfolded Duo.
            max(mobileMinimumSafeEdgeMargin,
                bottomChromeBottomInset - max(0, arrangement.videoFrame.maxY - arrangement.chromeFrame.maxY))
        }
    }

    /// The least gap kept between the controls and a non-zero safe edge.
    var mobileMinimumSafeEdgeMargin: CGFloat { 8 }

    /// Margin between the group's frame and its controls: 16 pt compact, 24 pt regular.
    var mobileEdgeInset: CGFloat {
        isCompactMobileChrome ? 16 : 24
    }

    /// Visible circle diameter; every hit target stays at least 44 pt.
    var mobileCircleSide: CGFloat {
        isCompactMobileChrome ? 40 : 44
    }

    var mobilePlayPauseSide: CGFloat {
        isCompactMobileChrome ? 60 : 68
    }

    /// The transport sits midway between the measured top row and bottom group, inside the
    /// transport frame's column.
    func mobileTransportRect(_ arrangement: MobilePlayerArrangement) -> CGRect {
        let frame = arrangement.transportFrame
        var top = frame.minY
        var bottom = frame.maxY
        if mobileTopRowFrame.height > 0 { top = max(top, mobileTopRowFrame.maxY) }
        if mobileBottomGroupFrame.height > 0 { bottom = min(bottom, mobileBottomGroupFrame.minY) }
        guard bottom > top else { return frame }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
    }

    /// The transport status centres in the video rectangle (upright), the book group, or the
    /// tabletop picture half; with chrome visible it also clears the top row and bottom group.
    func mobileStatusRect(_ arrangement: MobilePlayerArrangement) -> CGRect {
        let frame = arrangement.statusFrame
        guard arrangement.mode != .tabletop else { return frame }
        var top = frame.minY
        var bottom = frame.maxY
        if shouldShowChrome, mobileTopRowFrame.height > 0 { top = max(top, mobileTopRowFrame.maxY) }
        if shouldShowChrome, selectedMenu == nil, mobileBottomGroupFrame.height > 0 {
            bottom = min(bottom, mobileBottomGroupFrame.minY)
        }
        guard bottom > top else { return frame }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
    }

    /// Menus anchor to the bottom group (the deck's buttons in tabletop) and are clamped to its
    /// width, so in book they open in the trailing half, clear of the fold.
    func mobileMenuRect(_ arrangement: MobilePlayerArrangement) -> CGRect {
        let group = arrangement.bottomGroupFrame
        let top = arrangement.mode == .tabletop ? arrangement.chromeFrame.minY : topChromeEffectiveTopInset
        guard group.maxY > top else { return group }
        return CGRect(x: group.minX, y: top, width: group.width, height: group.maxY - top)
    }

    // MARK: Layers

    @ViewBuilder var mobileChromeLayers: some View {
        let arrangement = mobileLocalArrangement

        if shouldShowChrome, arrangement.mode != .tabletop {
            mobileScrim
                .mobilePlaced(in: mobileScrimRect(arrangement))
                .allowsHitTesting(false)
                .transition(.opacity)
        }

        if shouldShowChrome {
            mobileTopRow
                .padding(.horizontal, mobileEdgeInset)
                .padding(.top, max(0, mobileTopRowY(arrangement) - arrangement.chromeFrame.minY))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.mobileChromeSpace)) } action: {
                    mobileTopRowFrame = $0
                    topChromeOccupiedHeight = $0.maxY
                }
                .mobilePlaced(in: arrangement.chromeFrame, alignment: .top)
                .transition(.opacity)
        }

        // The status platter owns the primary transport action while buffering/reconnecting, so
        // the transport row is not left visible through its translucent material.
        if shouldShowChrome, selectedMenu == nil, !isTransportStatusPresented {
            mobileTransportRow
                .mobilePlaced(in: mobileTransportRect(arrangement), alignment: .center)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        }

        transientStatusOverlay
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(statusOverlayMargin)
            .mobilePlaced(in: mobileStatusRect(arrangement))

        if let mobileDisplayStatus {
            Text(mobileDisplayStatus)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.68), in: Capsule())
                .allowsHitTesting(false)
                .transition(.opacity)
                .mobilePlaced(in: arrangement.statusFrame)
        }

        offlineSubtitleOverlay
            .padding(.horizontal, isCompactMobileChrome ? 18 : 80)
            .padding(.bottom, mobileSubtitleBottomPadding(arrangement))
            .animation(.easeInOut(duration: 0.2), value: chromeVisible)
            .allowsHitTesting(false)
            .mobilePlaced(in: mobileSubtitleRect(arrangement), alignment: .bottom)

        VStack(spacing: 14) {
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
                .transition(.opacity)
            }

            if selectedMenu == nil, controller.upNext.isShown, let next = controller.upNext.nextItem {
                upNextCard(next)
            }

            if shouldShowChrome, selectedMenu == nil {
                mobileBottomGroup
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.mobileChromeSpace)) } action: {
                        mobileBottomGroupFrame = $0
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        bottomChromeOccupiedHeight = $0
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, mobileEdgeInset)
        .padding(.bottom, mobileBottomInset(arrangement))
        .mobilePlaced(in: arrangement.bottomGroupFrame, alignment: .bottom)

        if let selectedMenu {
            let menuRect = mobileMenuRect(arrangement)
            CustomPlayerMenuPopover(menu: selectedMenu,
                                    controller: controller,
                                    menuState: menuState,
                                    widthOverride: adaptiveMenuWidth(for: selectedMenu,
                                                                     available: menuRect.width),
                                    maxPopoverHeight: menuPopoverHeightLimit(availableHeight: menuRect.height),
                                    onClose: { closeMenu() })
                .frame(maxWidth: .infinity, alignment: selectedMenu.popoverAlignment)
                .padding(.horizontal, menuHorizontalInset)
                .padding(.bottom, menuBottomClearance)
                .mobilePlaced(in: menuRect, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// TV-app style legibility scrim over the group's frame: dark at the top row and under the
    /// bottom group, clear over the middle of the picture.
    var mobileScrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.45), location: 0),
            .init(color: .black.opacity(0), location: 0.3),
            .init(color: .black.opacity(0), location: 0.55),
            .init(color: .black.opacity(0.6), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The scrim darkens the whole picture, not just the safe frame the controls sit in: over a
    /// full-bleed picture (overlay, book) it runs under the status strip and the home-indicator
    /// band too, so tapping never leaves undimmed stripes at the top and bottom edges. On the
    /// upright video rectangle the bands are already black, so it stays on the group's frame,
    /// where its gradient stops line up with the top row and the bottom group.
    func mobileScrimRect(_ arrangement: MobilePlayerArrangement) -> CGRect {
        switch arrangement.mode {
        case .overlay, .book: arrangement.videoFrame.union(arrangement.chromeFrame)
        case .videoRect, .tabletop: arrangement.chromeFrame
        }
    }

    func mobileSubtitleRect(_ arrangement: MobilePlayerArrangement) -> CGRect {
        switch arrangement.mode {
        case .tabletop: arrangement.statusFrame
        case .overlay, .videoRect, .book: arrangement.chromeFrame
        }
    }

    func mobileSubtitleBottomPadding(_ arrangement: MobilePlayerArrangement) -> CGFloat {
        guard arrangement.mode != .tabletop else { return 16 }
        if chromeVisible, mobileBottomGroupFrame.height > 0 {
            return max(0, arrangement.chromeFrame.maxY - mobileBottomGroupFrame.minY) + 8
        }
        return subtitleBottomPadding
    }

    // MARK: Top row

    var mobileTopRow: some View {
        HStack(spacing: 10) {
            if let onClose {
                mobileCircleButton("Close", systemImage: "xmark") {
                    revealChrome()
                    onClose()
                }
                .playerGeometryProbe("topClose")
            }

            if mobileSystemCoordinator != nil {
                pipButton
                    .playerGeometryProbe("topPiP")
            }

            displayModeButton
                .playerGeometryProbe("topDisplayMode")

            Spacer(minLength: 0)

            if mobileSystemCoordinator != nil {
                airPlayButton
                    .playerGeometryProbe("topAirPlay")
            }
        }
    }

    var mobileHitSide: CGFloat { max(44, mobileCircleSide) }

    var airPlayButton: some View {
        AirPlayRoutePickerButton()
            .frame(width: mobileCircleSide, height: mobileCircleSide)
            .frame(width: mobileHitSide, height: mobileHitSide)
            .mobilePlayerCircleStyle(visibleSide: mobileCircleSide)
            .accessibilityLabel("AirPlay")
    }

    var displayModeButton: some View {
        mobileCircleButton(mobileVideoDisplayMode.accessibilityLabel,
                           systemImage: mobileVideoDisplayMode.systemImage) {
            setMobileVideoDisplayMode(mobileVideoDisplayMode.toggled)
        }
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

    /// The PiP slot is always present (dimmed while PiP is unavailable for the item or route), so
    /// availability changes never move the gravity button beside it (#258).
    var pipButton: some View {
        let isActive = mobileSystemCoordinator?.isPictureInPictureActive == true
        let isPossible = isActive || mobileSystemCoordinator?.isPictureInPicturePossible == true
        return mobileCircleButton(isActive ? "Exit Picture in Picture" : "Picture in Picture",
                                  systemImage: isActive ? "pip.exit" : "pip.enter") {
            revealChrome(keepVisible: true)
            mobileSystemCoordinator?.togglePictureInPicture()
        }
        .disabled(!isPossible)
        .opacity(isPossible ? 1 : 0.45)
    }

    // MARK: Transport

    var mobileTransportRow: some View {
        ViewThatFits(in: .horizontal) {
            mobileTransportRow(includesLongSkips: true)
            mobileTransportRow(includesLongSkips: false)
        }
    }

    func mobileTransportRow(includesLongSkips: Bool) -> some View {
        HStack(spacing: isCompactMobileChrome ? 20 : 28) {
            if includesLongSkips {
                mobileSkipButton(seconds: -30, visibleSide: mobileLongSkipSide)
            }
            mobileSkipButton(seconds: -10)
            mobilePlayPauseButton
                .playerGeometryProbe("centerPlayPause")
            mobileSkipButton(seconds: 10)
            if includesLongSkips {
                mobileSkipButton(seconds: 30, visibleSide: mobileLongSkipSide)
            }
        }
        // Keep the long skips well clear of the screen edges; they are secondary to ±10.
        .padding(.horizontal, includesLongSkips ? mobileEdgeInset * 2 : 0)
    }

    /// The ±30 circles sit outside ±10 and read as secondary: slightly smaller discs.
    var mobileLongSkipSide: CGFloat {
        isCompactMobileChrome ? 34 : 38
    }

    var mobilePlayPauseButton: some View {
        Button {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        } label: {
            Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                .font(.system(size: isCompactMobileChrome ? 26 : 30, weight: .semibold))
                .frame(width: mobilePlayPauseSide, height: mobilePlayPauseSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mobilePlayerCircleStyle(visibleSide: mobilePlayPauseSide)
        .accessibilityLabel(controller.transport.showsPausedControl ? "Play" : "Pause")
        .accessibilityHint("Toggles playback")
    }

    func mobileSkipButton(seconds: Int, visibleSide: CGFloat? = nil) -> some View {
        let isForward = seconds > 0
        let amount = abs(seconds)
        return mobileCircleButton(isForward ? "Skip forward \(amount) seconds" : "Skip back \(amount) seconds",
                                  systemImage: isForward ? "goforward.\(amount)" : "gobackward.\(amount)",
                                  visibleSide: visibleSide) {
            performRelativeSkip(seconds: seconds)
        }
        .disabled(scrubState.durationMs <= 0)
    }

    // MARK: Title, scrubber, circles

    var mobileBottomGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The first that fits: labeled menus beside the title, labeled menus on their own
            // row under the scrubber, then icon-only circles in the same order. A row never
            // mixes labeled and icon-only buttons.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 12) {
                        mobileTitleBlock
                            .frame(minWidth: 160, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
                        mobileMenuPills
                            .playerGeometryProbe("bottomMenuRow", detail: "variant=inline")
                    }
                    mobileScrubberBlock
                }
                VStack(alignment: .leading, spacing: 6) {
                    mobileTitleBlock
                    mobileScrubberBlock
                    mobileMenuPills
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                        .playerGeometryProbe("bottomMenuRow", detail: "variant=row")
                }
                VStack(alignment: .leading, spacing: 6) {
                    mobileTitleBlock
                    mobileScrubberBlock
                    mobileMenuCircles
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                        .playerGeometryProbe("bottomMenuRow", detail: "variant=icons")
                }
            }
        }
        .foregroundStyle(.white)
        .playerGeometryProbe("bottomPlatter",
                             detail: "branch=\(mobileChromeBranch.rawValue) arrangement=\(mobileLocalArrangement.mode.rawValue)")
    }

    /// The menus in one fixed order, Quality first. It is always present, so an item's menu set
    /// never moves a button; when the source only plays at original quality it is dimmed.
    static let mobileMenuOrder: [CustomPlayerMenuKind] = [.quality, .subtitles, .audio, .chapters, .speed, .stats]

    var mobileMenuPills: some View {
        HStack(spacing: 6) {
            ForEach(Self.mobileMenuOrder, id: \.self) { mobileMenuPill($0) }
        }
        .fixedSize()
    }

    var mobileMenuCircles: some View {
        HStack(spacing: isCompactMobileChrome ? 6 : 10) {
            ForEach(Self.mobileMenuOrder, id: \.self) { mobileMenuCircle($0) }
        }
    }

    func mobileCircleButton(_ title: String, systemImage: String, visibleSide: CGFloat? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(visibleSide.map { $0 < mobileCircleSide ? .subheadline.weight(.semibold) : .body.weight(.semibold) }
                      ?? .body.weight(.semibold))
                .frame(width: mobileHitSide, height: mobileHitSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mobilePlayerCircleStyle(visibleSide: visibleSide ?? mobileCircleSide)
        .accessibilityLabel(title)
    }

    /// A labeled glass capsule for a player menu: the same glass and height as the circles.
    func mobileMenuPill(_ menu: CustomPlayerMenuKind) -> some View {
        Button {
            openMenu(menu)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: menu.systemImage)
                Text(menu.title)
            }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: mobileCircleSide)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background {
            Capsule()
                .fill(.clear)
                .frame(height: mobileCircleSide)
                .glassEffect(.regular, in: Capsule())
        }
        .shadow(color: .black.opacity(0.32), radius: 9, y: 4)
        .accessibilityLabel(menu.title)
        .mobileMenuAvailability(menu, available: isMobileMenuAvailable(menu))
    }

    func mobileMenuCircle(_ menu: CustomPlayerMenuKind) -> some View {
        mobileCircleButton(menu.title, systemImage: menu.systemImage) {
            openMenu(menu)
        }
        .mobileMenuAvailability(menu, available: isMobileMenuAvailable(menu))
    }

    func isMobileMenuAvailable(_ menu: CustomPlayerMenuKind) -> Bool {
        availableMenus.contains(menu)
    }

    var mobileTitleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let mobileCaption, !mobileCaption.isEmpty {
                Text(mobileCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    var mobileScrubberBlock: some View {
        VStack(spacing: 2) {
            timelineSlider
            HStack {
                Text(format(ms: scrubState.displayedPositionMs))
                Spacer()
                Text("−" + format(ms: max(0, scrubState.durationMs - scrubState.displayedPositionMs)))
                    .accessibilityLabel("Remaining \(format(ms: max(0, scrubState.durationMs - scrubState.displayedPositionMs)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Layout changes

    /// A chrome branch change (rotation, window resize, iPhone Duo fold) rebuilds the scrubber in a
    /// different composition. Abandon an open scrub draft rather than committing a seek from a
    /// slider that no longer exists, and restart the auto-hide countdown that the drag suspended.
    func handleMobileChromeBranchChange(from old: MobilePlayerChromeLayoutPolicy.Branch,
                                        to new: MobilePlayerChromeLayoutPolicy.Branch) {
        let wasDragging = cancelMobileScrubForLayoutChange()
        AppDiagnostics.record(.playback, "player.chrome_branch_change", fields: [
            "from": .label(old.rawValue),
            "to": .label(new.rawValue),
            "scrub_cancelled": .bool(wasDragging),
        ])
    }

    /// A pose change (book, tabletop, flat) or a switch between the overlay and the video
    /// rectangle moves the scrubber, so a scrub in progress is cancelled the same way.
    func handleMobileArrangementModeChange(from old: MobilePlayerArrangement.Mode,
                                           to new: MobilePlayerArrangement.Mode) {
        let wasDragging = cancelMobileScrubForLayoutChange()
        AppDiagnostics.record(.playback, "player.arrangement_change", fields: [
            "from": .label(old.rawValue),
            "to": .label(new.rawValue),
            "scrub_cancelled": .bool(wasDragging),
        ])
    }

    private func cancelMobileScrubForLayoutChange() -> Bool {
        let wasDragging = scrubState.isDragging
        if wasDragging {
            scrubState.cancel()
        }
        scrubEditingSessionActive = false
        endHoverPreview()
        clearTrickPlayPreview()
        scheduleChromeHideIfNeeded()
        return wasDragging
    }

    var mobileChromeGeometryDetail: String {
        let layout = mobileChromeLayout
        return "branch=\(layout.branch.rawValue) phoneLandscape=\(layout.isPhoneLandscape) compact=\(layout.usesCompactChrome)"
            + " arrangement=\(mobileLocalArrangement.mode.rawValue)"
            + " h=\(horizontalSizeClass.map { "\($0)" } ?? "nil")"
            + " v=\(verticalSizeClass.map { "\($0)" } ?? "nil")"
    }
}

/// One glass-circle style for every player control: a monochrome glass disc of `visibleSide`
/// inside a hit target of at least 44 pt.
struct MobilePlayerCircleStyle: ViewModifier {
    let visibleSide: CGFloat

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

extension View {
    /// An unavailable menu keeps its slot (so nothing beside it moves) but is dimmed and inert.
    @ViewBuilder
    func mobileMenuAvailability(_ menu: CustomPlayerMenuKind, available: Bool) -> some View {
        if menu == .quality {
            disabled(!available)
                .opacity(available ? 1 : 0.45)
                .accessibilityHint(available ? "Changes the streaming quality"
                                             : "This source plays at its original quality")
        } else {
            disabled(!available)
                .opacity(available ? 1 : 0.45)
        }
    }

    func mobilePlayerCircleStyle(visibleSide: CGFloat) -> some View {
        modifier(MobilePlayerCircleStyle(visibleSide: visibleSide))
    }

    /// Places the view in `rect` (the parent's coordinate space) with `alignment` inside it. The
    /// empty part of the rect is not hit-testable, so taps fall through to the player surface.
    func mobilePlaced(in rect: CGRect, alignment: Alignment = .center) -> some View {
        frame(width: max(0, rect.width), height: max(0, rect.height), alignment: alignment)
            .position(x: rect.midX, y: rect.midY)
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
