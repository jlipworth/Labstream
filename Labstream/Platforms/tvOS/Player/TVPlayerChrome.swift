import Foundation
import PMSKit
import SwiftUI

// Target-exclusive TV presentation, focus, and remote-input leaf for the shared player chrome.
/// Explicit focus ownership keeps a hidden player surface in the remote responder chain, then
/// restores focus to real chrome controls when any directional command reveals them.
enum TVPlayerFocus: Hashable {
    case menu(CustomPlayerMenuKind)
    /// The remote-driven timeline scrubber (its own full-width row, so Left/Right have no
    /// horizontal focus candidates and the scrub handler is the only actor for those presses).
    case timeline
    /// The nonvisual full-screen input owner shown only while the chrome is hidden. Without a
    /// focusable item in the player subtree, tvOS delivers presses to the window with
    /// `focusedItem == nil` and none of SwiftUI's command/gesture handlers ever fire, so hidden
    /// chrome could never be revealed by the remote (TVUI-024).
    case hiddenSurface
}
/// Renders nothing but the label, focused or not. The hidden-chrome input owner must be
/// invisible: every built-in tvOS button style paints a focused platter over its label,
/// which on a full-screen clear button becomes an opaque wash over the video.
struct TVHiddenSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension CustomPlayerChrome {
    /// Television chrome is a remote control surface, not the iPad/visionOS row scaled up by
    /// tvOS's focus engine. Keep a compact information/actions header and a symmetric transport
    /// row with time labels that cannot wrap.
    var tvControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 22) {
                // body (29pt) over headline (38pt) plus the tighter menu strip below buys
                // the title roughly twice the characters before truncating.
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 220, idealWidth: 520, maxWidth: 760, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: 18)

                tvMenuStrip
            }
            // The focus section must span the full row — title and spacer included — so an Up
            // press from the timeline (whose vertical projection may miss the trailing menu
            // strip) is routed into the strip's nearest button.
            .focusSection()

            // TV-native timeline: no on-screen transport buttons — the remote IS the
            // transport (hardware play/pause, ±10s side presses while chrome is hidden,
            // Select-on-timeline). The scrubber must be the ONLY focusable in the row: a
            // Left/Right press then has no horizontal focus candidate, which is what lets
            // `onMoveCommand` scrub instead of fighting the engine's geometric resolution
            // (see tvTimelineMove).
            HStack(spacing: 14) {
                // Never truncate the clocks: size to content (h:mm:ss needs more than the
                // old fixed 100pt at tvOS type sizes) with a floor so the slider doesn't
                // jiggle at ordinary digit changes.
                Text(format(ms: scrubState.displayedPositionMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 100, alignment: .trailing)

                tvTimelineScrubber

                Text(format(ms: scrubState.durationMs))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 100, alignment: .leading)
            }
            .focusSection()
        }
    }

    /// Remote-driven scrubber (the chrome's default focus). Left/Right steps
    /// the draft position with press-streak acceleration, Select commits the seek, and moving
    /// focus away (Up) abandons the draft (cleanup in the tvPlayerFocus onChange). While a
    /// draft is open the trick-play preview floats above the thumb.
    var tvTimelineScrubber: some View {
        GeometryReader { geometry in
            let fraction = scrubberBinding.wrappedValue
            let isFocused = tvPlayerFocus == .timeline
            Button {
                tvTimelineSelect()
            } label: {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(isFocused ? 0.34 : 0.22))
                    Capsule()
                        .fill(.white.opacity(isFocused ? 1.0 : 0.72))
                        .frame(width: max(0, geometry.size.width * fraction))
                }
                .frame(height: isFocused ? 13 : 7)
                .frame(maxHeight: .infinity, alignment: .center)
                .overlay(alignment: .leading) {
                    if isFocused {
                        Circle()
                            .fill(.white)
                            .frame(width: 22, height: 22)
                            .shadow(radius: 6)
                            .offset(x: max(0, geometry.size.width * fraction - 11))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
            // Bare label only: the system focused-button platter would white-wash the row.
            .buttonStyle(TVHiddenSurfaceButtonStyle())
            .focusEffectDisabled()
            .focused($tvPlayerFocus, equals: .timeline)
            .disabled(scrubState.durationMs <= 0)
            .onMoveCommand { tvTimelineMove($0) }
            .accessibilityIdentifier("tv.player.timeline")
            .accessibilityLabel("Timeline")
            .accessibilityValue(format(ms: scrubState.displayedPositionMs))
            .overlay(alignment: .topLeading) {
                if scrubState.isDragging, isFocused {
                    trickPlayPreview
                        .fixedSize()
                        .position(x: CGFloat(TrickPlayPreviewGeometry.cardCenterX(
                            pointerX: Double(geometry.size.width * fraction),
                            trackWidth: Double(geometry.size.width),
                            cardWidth: 210
                        )), y: trickPlayProvider == nil ? -34 : -112)
                        .zIndex(20)
                }
            }
        }
        .frame(minWidth: 40, minHeight: 32, idealHeight: 32, maxHeight: 32)
    }

    /// Left/Right while the timeline is focused: open/extend a scrub draft. The row has no
    /// other focusable, so the engine cannot move focus for these presses — this handler is
    /// the sole actor (unlike the chrome-root onMoveCommand, which observes presses the
    /// engine ALSO resolves). Up/Down fall through to the engine untouched.
    func tvTimelineMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            guard scrubState.durationMs > 0 else { return }
            if !scrubState.isDragging {
                // Seed from the displayed position, not the raw player clock: while a prior
                // committed seek is still rebuilding the stream, currentResumeMs can report
                // the pre-seek offset and a rapid second scrub would restart from there.
                scrubState.beginDrag(livePositionMs: scrubState.displayedPositionMs)
            }
            // Press-streak acceleration: holding (or hammering) the direction escalates the
            // stride, so long titles are traversable without giving up fine-grained steps.
            let now = Date()
            if now.timeIntervalSince(tvScrubLastStepAt) < 0.4 {
                tvScrubStreak += 1
            } else {
                tvScrubStreak = 0
            }
            tvScrubLastStepAt = now
            let strideMs = tvScrubStreak >= 12 ? 60_000 : (tvScrubStreak >= 5 ? 30_000 : 10_000)
            let delta = direction == .right ? strideMs : -strideMs
            let target = min(max(scrubState.displayedPositionMs + delta, 0), scrubState.durationMs)
            scrubState.updateDrag(fraction: Double(target) / Double(scrubState.durationMs))
            updateTrickPlayPreview(for: scrubState.draftPositionMs, debounce: false)
            revealChrome(keepVisible: true)
            tvEvidenceLog("timeline scrub \(direction) -> \(target)ms stride=\(strideMs)")
        default:
            // Up/Down are engine-resolved focus moves (into the menu strip), but this
            // handler still consumes the command chain, so the chrome-root onMoveCommand
            // never sees the press and cannot restart the auto-hide countdown — captured
            // evidence showed the chrome hiding mid-strip-traversal 5s after the reveal.
            scheduleChromeHideIfNeeded()
        }
    }

    /// Select on the timeline: commit an open scrub draft, else toggle playback (matching the
    /// system player's click-to-pause on the touch surface).
    func tvTimelineSelect() {
        if scrubState.isDragging {
            if let target = scrubState.commit() {
                tvEvidenceLog("timeline commit \(target)ms")
                controller.performUserSeek(toMs: target)
            }
            clearTrickPlayPreview()
            revealChrome()
        } else {
            revealChrome()
            controller.togglePlayback()
            scheduleChromeHideIfNeeded()
        }
    }

    var tvMenuStrip: some View {
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(minWidth: menu.minChromeWidth, minHeight: 34)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focused($tvPlayerFocus, equals: .menu(menu))
                .accessibilityLabel(menu.title)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Full-screen, visually empty focus owner rendered only while the chrome is hidden. It keeps
    /// a focusable item alive in the player subtree so directional/Select/Play-Pause presses keep
    /// routing into the SwiftUI handlers (see `TVPlayerFocus.hiddenSurface`). A `Button` rather
    /// than a tap gesture: button activation is not subject to the tvOS 18+ SwiftUI
    /// first-press-after-focus-change regression.
    var tvHiddenChromeInputOwner: some View {
        Button {
            tvEvidenceLog("hiddenSurface select")
            revealTVChrome()
        } label: {
            Color.clear
        }
        // Even `.plain` (and `.focusEffectDisabled()`) still paints tvOS's focused-button
        // platter — a full-screen white wash over the video the moment the chrome hides.
        // A custom style renders only the (clear) label, with no focused appearance at all.
        .buttonStyle(TVHiddenSurfaceButtonStyle())
        .focusEffectDisabled()
        .contentShape(Rectangle())
        .focused($tvPlayerFocus, equals: .hiddenSurface)
        .accessibilityLabel("Show playback controls")
        .accessibilityIdentifier("tv.player.hiddenSurface")
    }

    /// Focus must land on the hidden-surface owner only after the render pass that inserts it.
    func tvFocusHiddenSurface() {
        tvEnsureFocus(.hiddenSurface)
    }

    /// Single dpad press while the chrome is hidden = this many seconds of instant skip
    /// (the tvOS platform standard; larger jumps come from the scrubber's stride
    /// acceleration, so 10 stays the fine-grained default).
    var tvRemoteSkipSeconds: Int { 10 }

    /// Where focus lands when the chrome reveals: the timeline (the only transport
    /// surface), unless there is no seekable duration, in which case the menu strip.
    var tvDefaultChromeFocus: TVPlayerFocus {
        if scrubState.durationMs > 0 { return .timeline }
        return availableMenus.first.map { .menu($0) } ?? .timeline
    }

    func revealTVChrome() {
        revealChrome(keepVisible: true)
        // Focus assignment must follow the render that reintroduces the controls.
        tvEnsureFocus(tvDefaultChromeFocus)
        Task { @MainActor in
            await Task.yield()
            scheduleChromeHideIfNeeded()
        }
    }

    /// Writes `tvPlayerFocus` after the render pass that (re)introduces the target view, then
    /// VERIFIES the write stuck. A `@FocusState` write that races the view's insertion is
    /// silently dropped and resets to nil; captured evidence (TVUI-024 flake) shows the focus
    /// engine then auto-picks an item outside the chrome's command scope and every subsequent
    /// remote press bypasses SwiftUI. Outside an open submenu, nil focus is never a valid
    /// resting state for the player, so a nil observed after the write is always a dropped
    /// write — retry, bounded so a torn-down player can't loop.
    func tvEnsureFocus(_ target: TVPlayerFocus, attempt: Int = 0) {
        Task { @MainActor in
            await Task.yield()
            guard selectedMenu == nil else { return }
            let targetStillValid = target == .hiddenSurface ? !shouldShowChrome : shouldShowChrome
            guard targetStillValid else { return }
            tvPlayerFocus = target
            guard attempt < 4 else { return }
            try? await Task.sleep(for: .milliseconds(120))
            if tvPlayerFocus == nil, selectedMenu == nil {
                tvEvidenceLog("focus write \(String(describing: target)) dropped; retry \(attempt + 1)")
                tvEnsureFocus(target, attempt: attempt + 1)
            }
        }
    }

    /// Diagonal focus fallback while the chrome is visible: the menu strip sits top-right and
    /// the timeline spans the row below, so Left off the strip's leading edge drops onto the
    /// timeline (a plain Left has no in-row target there).
    ///
    /// `onMoveCommand` fires for EVERY dpad press — engine-resolved or not — and its ordering
    /// against the engine's focus update is inconsistent (captured 2026-07-21: update precedes
    /// the command by ~80-105ms on some presses, trails it by ~5ms on others). Acting on every
    /// command therefore hijacked ordinary in-row moves (one Right press hopped playPause →
    /// skip(10) → Quality). Two guards restrict the fallback to genuinely dead presses: the
    /// focused item must be the row's edge item in the pressed direction (the engine has no
    /// in-row target), and focus must not have just changed (a trailing command for a press
    /// the engine already resolved).
    func tvHandleUnresolvedMove(_ direction: MoveCommandDirection) {
        guard selectedMenu == nil else { return }
        guard Date().timeIntervalSince(tvPlayerFocusChangedAt) > 0.15 else { return }
        switch (direction, tvPlayerFocus) {
        case (.left, .menu(let menu)) where menu == availableMenus.first:
            if scrubState.durationMs > 0 { tvPlayerFocus = .timeline }
        default:
            break
        }
    }
}
