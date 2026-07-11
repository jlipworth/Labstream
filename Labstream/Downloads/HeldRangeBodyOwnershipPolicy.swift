import Foundation
import PMSKit

/// Pure file-ownership decisions for held-body manifest replacement. The session applies these
/// plans while holding its map lock, then performs filesystem deletion after unlocking.
enum HeldRangeBodyOwnershipPolicy {
    struct ReplacementPlan: Sendable, Equatable {
        let installNewBody: Bool
        let retainPredecessors: Set<URL>
        let deleteBodies: Set<URL>
    }

    static func replacementPlan(
        haltKind: StaticRangeHaltKind?,
        manifestCommitted: Bool,
        newBody: URL,
        predecessors: Set<URL>,
        alreadyRetained: Set<URL>
    ) -> ReplacementPlan {
        let priorGenerations = predecessors.union(alreadyRetained).subtracting([newBody])
        if haltKind == .cancel {
            return ReplacementPlan(
                installNewBody: false,
                retainPredecessors: [],
                deleteBodies: priorGenerations.union([newBody])
            )
        }
        if manifestCommitted {
            return ReplacementPlan(
                installNewBody: true,
                retainPredecessors: [],
                deleteBodies: priorGenerations
            )
        }
        return ReplacementPlan(
            installNewBody: true,
            retainPredecessors: priorGenerations,
            deleteBodies: []
        )
    }

    static func removalBodies(
        current: URL?,
        persisted: URL?,
        fallback: Set<URL>,
        retainedPredecessors: Set<URL>
    ) -> Set<URL> {
        var bodies = fallback.union(retainedPredecessors)
        if let current { bodies.insert(current) }
        if let persisted { bodies.insert(persisted) }
        return bodies
    }

    static func purgeBodies(
        current: [URL],
        persisted: [URL],
        retainedPredecessors: [Set<URL>]
    ) -> Set<URL> {
        var bodies = Set(current).union(persisted)
        for retained in retainedPredecessors { bodies.formUnion(retained) }
        return bodies
    }
}
