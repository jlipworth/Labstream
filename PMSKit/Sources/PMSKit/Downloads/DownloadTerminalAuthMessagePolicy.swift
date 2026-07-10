import Foundation

/// Maps the transfer engine's terminal "Server returned HTTP <code>." failure text to auth-dead
/// intent (audit lens 8, A-3) at the manager boundary, without touching the session file: a range
/// rehydration that exhausted on persistent 401/403 should surface a sign-in-again affordance,
/// not a generic HTTP failure the user cannot act on.
public enum DownloadTerminalAuthMessagePolicy {
    /// The exact terminal messages the background session emits for an auth-rejected transfer.
    /// Deliberately exact-match: broader parsing would risk remapping unrelated failure text.
    public static func isAuthDeadTransferMessage(_ message: String) -> Bool {
        message == "Server returned HTTP 401." || message == "Server returned HTTP 403."
    }
}
