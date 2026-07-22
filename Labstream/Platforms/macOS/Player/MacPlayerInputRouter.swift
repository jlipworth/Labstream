/// The single action a physical Escape press should request from the Mac player.
///
/// Keeping this decision separate from AppKit event handling makes the priority explicit while
/// leaving presentation effects (closing a menu, toggling the window, or dismissing playback) with
/// the chrome that owns them.
enum MacPlayerEscapeAction: Equatable {
    case closeMenu
    case exitFullScreen
    case closePlayer
    case passThrough
}

/// Resolves a physical Escape press without performing presentation side effects.
///
/// Escape unwinds the most local player presentation first: an open menu, then native fullscreen,
/// then the player itself. If there is nothing for the player to dismiss, AppKit receives the event.
func macPlayerEscapeAction(isMenuPresented: Bool,
                           isFullScreen: Bool,
                           hasCloseAction: Bool) -> MacPlayerEscapeAction {
    if isMenuPresented { return .closeMenu }
    if isFullScreen { return .exitFullScreen }
    if hasCloseAction { return .closePlayer }
    return .passThrough
}
