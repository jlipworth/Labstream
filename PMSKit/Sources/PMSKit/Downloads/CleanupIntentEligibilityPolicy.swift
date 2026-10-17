import Foundation

/// When a journaled server-cleanup intent may run (downloads overhaul P2.3). The journal entry's
/// presence alone never authorizes a cancel: eligibility depends on why the intent exists and on
/// where its attempt's row stands. The ownership recheck (no other live row claims the resource)
/// is a separate gate applied immediately before the server call.
public enum CleanupIntentEligibilityPolicy {
    /// The intent attempt's row, as the store reports it.
    public enum RowState: Equatable, Sendable {
        /// The row exists and is not being deleted.
        /// - isTerminal: complete, unverified or failed.
        /// - protectsResource: a failed row whose Retry resumes this exact server job (B44/B49).
        case present(isTerminal: Bool, protectsResource: Bool)
        /// A deletion is staged, its terminal commit is in flight, or it failed and may be retried.
        case retiring
        /// The row is gone and the removal is durable.
        case committedAbsent
        /// The store cannot tell (index unreadable or startup recovery not ready).
        case unknown
    }

    public enum Decision: Equatable, Sendable {
        case run
        /// Keep the intent journaled and re-evaluate on a later pass.
        case wait
    }

    public static func decision(
        provenance: DurableDownloadCleanupIntent.Provenance?,
        rowState: RowState
    ) -> Decision {
        switch (provenance, rowState) {
        case (_, .unknown), (_, .retiring):
            return .wait
        case (.rowDeletion, .committedAbsent), (.terminalRelease, .committedAbsent):
            return .run
        case (.terminalRelease, .present(let isTerminal, let protectsResource)):
            return isTerminal && !protectsResource ? .run : .wait
        case (.rowDeletion, .present):
            // Delete journals before it submits removal; a row that is still present and not
            // retiring means the deletion never reached the store, so its server work stays.
            return .wait
        case (.abandonment, .present), (.abandonment, .committedAbsent):
            // The originating attempt gave the resource up; whether another row still claims it
            // is the ownership recheck's decision.
            return .run
        case (nil, _):
            return .wait
        }
    }

    /// One-time classification for entries journaled before provenance existed. Pre-P2 producers
    /// wrote intents only for deleted rows and for handles terminal rows still referenced, so a
    /// gone row is a deletion and a present terminal row is a terminal release. Anything else stays
    /// unclassified and is re-examined on the next pass.
    public static func legacyProvenance(
        for rowState: RowState
    ) -> DurableDownloadCleanupIntent.Provenance? {
        switch rowState {
        case .committedAbsent: return .rowDeletion
        case .present(let isTerminal, _): return isTerminal ? .terminalRelease : nil
        case .retiring, .unknown: return nil
        }
    }
}

/// Retry pacing and retention bounds for journaled cleanup (P2.3/P2.6).
public enum CleanupIntentRetryPolicy {
    public static let initialBackoffSeconds: Double = 30
    public static let maximumBackoffSeconds: Double = 30 * 60
    /// After a day of non-actionable Plex responses the runner slows down…
    public static let slowPlexAfterSeconds: Double = 24 * 60 * 60
    public static let slowPlexBackoffSeconds: Double = 6 * 60 * 60
    /// …and after a week it retires the intent with a diagnostic.
    public static let plexRetentionSeconds: Double = 7 * 24 * 60 * 60

    /// Exponential backoff after `failures` consecutive unsuccessful runs (1-based).
    public static func backoffSeconds(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(initialBackoffSeconds * pow(2, exponent), maximumBackoffSeconds)
    }

    public enum PlexRetention: Equatable, Sendable {
        case retire
        case retain(minimumDelaySeconds: Double)
    }

    /// For a Plex queue response that cannot cancel or retire the intent on its own: an absent
    /// item whose create PUT is unresolved, a malformed list, or an uncertain match. `absent` with
    /// a confirmed create retires immediately and never reaches this function.
    public static func plexRetention(
        recordedAtEpochSeconds: Double?,
        nowEpochSeconds: Double
    ) -> PlexRetention {
        // Every Plex intent this build writes is timestamped; one without a timestamp is never
        // auto-retired.
        guard let recorded = recordedAtEpochSeconds else {
            return .retain(minimumDelaySeconds: 0)
        }
        let age = nowEpochSeconds - recorded
        if age >= plexRetentionSeconds { return .retire }
        return .retain(minimumDelaySeconds: age >= slowPlexAfterSeconds ? slowPlexBackoffSeconds : 0)
    }
}
