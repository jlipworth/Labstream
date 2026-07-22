import AppKit
import SwiftUI

// Target-exclusive Mac presentation and hardware-input leaf for the shared player chrome.
extension CustomPlayerChrome {
    @ViewBuilder
    var macTopTrailingControls: some View {
        HStack(spacing: 10) {
            macFullscreenButton
            if let onClose {
                macTopChromeButton("Close Player", systemImage: "xmark") {
                    requestPlayerClose(onClose)
                }
            }
        }
    }

    var macFullscreenButton: some View {
        macTopChromeButton("Toggle Full Screen",
                           systemImage: "arrow.up.left.and.arrow.down.right",
                           autoHidesChrome: true) {
            macWindowBridge.toggleFullScreen()
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
    }

    func macTopChromeButton(_ help: String,
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
    func installMacKeyMonitor() {
        guard macKeyMonitor == nil else { return }
        macKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handleMacKeyDown(event) {
                return nil
            }
            return event
        }
    }

    func removeMacKeyMonitor() {
        guard let macKeyMonitor else { return }
        NSEvent.removeMonitor(macKeyMonitor)
        self.macKeyMonitor = nil
    }

    func handleMacKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 53, modifiers.isEmpty { // Escape
            guard !event.isARepeat else { return true }
            switch macPlayerEscapeAction(isMenuPresented: selectedMenu != nil,
                                         isFullScreen: macWindowBridge.isFullScreen,
                                         hasCloseAction: onClose != nil) {
            case .closeMenu:
                closeMenu()
            case .exitFullScreen:
                _ = macWindowBridge.exitFullScreenIfNeeded()
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
    var macControls: some View {
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

    var macControlsHeader: some View {
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

    var macTitleLabel: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 160, idealWidth: 300, maxWidth: 460, alignment: .leading)
            .layoutPriority(1)
            .accessibilityLabel(title)
    }

    var macTransportControls: some View {
        HStack(spacing: 7) {
            macSkipButton(seconds: -30)
            macSkipButton(seconds: -10)
            macPlayPauseButton
            macSkipButton(seconds: 10)
            macSkipButton(seconds: 30)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var macPlayPauseButton: some View {
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

    func macSkipButton(seconds: Int) -> some View {
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

    var macMenuStrip: some View {
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
}

/// Weak bridge from SwiftUI chrome to the AppKit window that hosts the custom player.
///
/// The fullscreen action intentionally uses the native macOS window transition for the
/// whole SwiftUI/AVPlayerLayer surface rather than introducing AVKit's stock
/// `AVPlayerView`/fullscreen controller.
@MainActor
final class MacPlayerWindowBridge {
    weak var window: NSWindow?

    var isFullScreen: Bool {
        (window ?? NSApp.keyWindow)?.styleMask.contains(.fullScreen) == true
    }

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

struct MacPlayerWindowReader: NSViewRepresentable {
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

final class MacPlayerWindowReaderView: NSView {
    weak var bridge: MacPlayerWindowBridge?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bridge?.window = window
    }
}
