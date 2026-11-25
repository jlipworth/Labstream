import Foundation

/// Decisions for the finished body of a forward-only (opaque) transfer (F1 #472, F3 #474).
///
/// A forward-only stream cannot be fetched again by range, so its finished body is the whole
/// download and, for a transcode, a whole server render. Once the delegate holds it, only a
/// cancel, a delete or a failing verdict may discard it: not a crash, and not a pause.
public enum ForwardOnlyFinishedBodyPolicy {
    /// Why a finished response is not a media body at all.
    public enum ResponseRejection: Sendable, Equatable {
        case httpStatus(Int)
        /// An HTML, JSON or XML page (a server error page), lowercased.
        case nonMediaMIME(String)
    }

    /// The HTTP checks that need only the response. A response that is not HTTP has no status to
    /// judge and is left to the playability probe, as before.
    public static func responseRejection(httpStatus: Int?, mimeType: String?) -> ResponseRejection? {
        guard let httpStatus else { return nil }
        guard (200...299).contains(httpStatus) else { return .httpStatus(httpStatus) }
        if let mime = mimeType?.lowercased(),
           mime.hasPrefix("text/") || mime.contains("application/json")
            || mime.contains("application/xml") {
            return .nonMediaMIME(mime)
        }
        return nil
    }

    public enum Custody: Sendable, Equatable {
        /// Move the body to the attempt's capture path and record `bodyCaptured`: the row
        /// references the file, so no sweep removes it and a relaunch publishes it (F1).
        case durableCapture
        /// A rejected response is never a download. It keeps the in-memory `tmp/` stash only
        /// until the queued publication fails the row with the server's reason.
        case volatileStash
    }

    /// Where the delegate moves a finished body before it returns. Only a response that passed
    /// the HTTP checks is captured durably: after a relaunch the response is gone, so a captured
    /// body is published without them.
    public static func custody(responseRejection: ResponseRejection?) -> Custody {
        responseRejection == nil ? .durableCapture : .volatileStash
    }

    public enum PublicationStep: Sendable, Equatable {
        /// The body is at its capture (or stash) path: move it onto the working path.
        case moveBody
        /// The body is gone from its capture path and the working path holds a body: another
        /// publication of the same attempt already moved it. Nothing is left to do, and the
        /// working file must not be touched.
        case alreadyPublished
        /// Neither path holds the body. The move fails and fails the row, as before.
        case bodyMissing
    }

    /// What a publication does once it holds the working path's lease. Publication is
    /// idempotent: the lease serializes two publications of one attempt, and the second finds
    /// the body already moved. It used to clear the working path before it noticed, which
    /// deleted the only copy of the body and then failed the row.
    public static func publicationStep(bodyExistsAtCapturePath: Bool,
                                       workingBodyBytes: Int) -> PublicationStep {
        if bodyExistsAtCapturePath { return .moveBody }
        return workingBodyBytes > 0 ? .alreadyPublished : .bodyMissing
    }

    public enum Publication: Sendable, Equatable {
        case publish
        case discard
    }

    /// Whether the queued publication of a finished body to the working path still runs.
    ///
    /// A cancel (or delete) discards the body, as does a stale attempt or a torn-down transfer.
    /// A pause never does (F3): installing a pause halt also advances the retry generation, and
    /// neither is a reason to drop a finished body. With no halt, a newer generation means the
    /// same attempt was started again and that start owns the working path.
    public static func publication(attemptAdmitsWork: Bool,
                                   trainEpochIsCurrent: Bool,
                                   retryGenerationIsCurrent: Bool,
                                   haltKind: StaticRangeHaltKind?) -> Publication {
        guard attemptAdmitsWork, trainEpochIsCurrent else { return .discard }
        switch haltKind {
        case .cancel: return .discard
        case .pause: return .publish
        case nil: return retryGenerationIsCurrent ? .publish : .discard
        }
    }
}
