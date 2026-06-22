import Foundation
import PMSKit

/// Privacy-safe browse/grid diagnostics for active library debugging.
///
/// These helpers deliberately avoid raw titles, library names, URLs, tokens, local paths, and
/// backend item ids. Stable hashes are enough to prove whether rows are duplicated or reused
/// while keeping exported diagnostics safe to share.
enum BrowseDiagnostics {
    struct Summary {
        let fields: [String: DiagnosticFieldValue]
        let consoleLine: String
    }

    static func libraryGridPage(items: [MediaItem],
                                backend: String,
                                sourceID: String,
                                sourceName: String,
                                sourceKind: String?,
                                recursive: Bool,
                                includeItemTypes: String,
                                startIndex: Int,
                                limit: Int,
                                total: Int?) -> Summary {
        let facts = facts(for: items)
        let fields: [String: DiagnosticFieldValue] = [
            "backend": .label(backend),
            "source_id": .identifier(sourceID),
            "source_name_sig": .label(signature(sourceName)),
            "source_kind": .label(sourceKind ?? "unknown"),
            "recursive": .bool(recursive),
            "include_item_types": .label(includeItemTypes),
            "start_index": .int(startIndex),
            "limit": .int(limit),
            "total_count": .int(total ?? -1),
            "item_count": .int(items.count),
            "unique_item_ids": .int(facts.uniqueItemIDs),
            "unique_rows": .int(facts.uniqueRows),
            "duplicate_item_ids": .label(facts.duplicateItemIDs),
            "duplicate_rows": .label(facts.duplicateRows),
            "sample": .label(sample(items, startingAt: startIndex, limit: 16)),
        ]
        let line = [
            "backend=\(safeToken(backend))",
            "source=\(signature(sourceID))",
            "sourceName=\(signature(sourceName))",
            "kind=\(safeToken(sourceKind ?? "unknown"))",
            "recursive=\(recursive)",
            "types=\(safeToken(includeItemTypes))",
            "start=\(startIndex)",
            "limit=\(limit)",
            "total=\(total.map(String.init) ?? "unknown")",
            "count=\(items.count)",
            "uniqueIDs=\(facts.uniqueItemIDs)",
            "uniqueRows=\(facts.uniqueRows)",
            "dupIDs=\(facts.duplicateItemIDs)",
            "dupRows=\(facts.duplicateRows)",
            "sample=\(sample(items, startingAt: startIndex, limit: 16))",
        ].joined(separator: " ")
        return Summary(fields: fields, consoleLine: line)
    }

    static func containerChildren(rawItems: [MediaItem],
                                  normalizedItems: [MediaItem],
                                  backend: String,
                                  container: MediaItem,
                                  childrenAreEpisodes: Bool) -> Summary {
        let facts = facts(for: rawItems)
        let fields: [String: DiagnosticFieldValue] = [
            "backend": .label(backend),
            "container_id": .identifier(container.ratingKey),
            "container_name_sig": .label(signature(container.title)),
            "container_kind": .label(container.type),
            "children_are_episodes": .bool(childrenAreEpisodes),
            "raw_count": .int(rawItems.count),
            "normalized_count": .int(normalizedItems.count),
            "unique_item_ids": .int(facts.uniqueItemIDs),
            "unique_rows": .int(facts.uniqueRows),
            "duplicate_item_ids": .label(facts.duplicateItemIDs),
            "duplicate_rows": .label(facts.duplicateRows),
            "sample": .label(sample(rawItems, startingAt: 0, limit: 12)),
        ]
        let line = [
            "backend=\(safeToken(backend))",
            "container=\(signature(container.ratingKey))",
            "containerName=\(signature(container.title))",
            "kind=\(safeToken(container.type))",
            "episodes=\(childrenAreEpisodes)",
            "rawCount=\(rawItems.count)",
            "normalizedCount=\(normalizedItems.count)",
            "uniqueIDs=\(facts.uniqueItemIDs)",
            "uniqueRows=\(facts.uniqueRows)",
            "dupIDs=\(facts.duplicateItemIDs)",
            "dupRows=\(facts.duplicateRows)",
            "sample=\(sample(rawItems, startingAt: 0, limit: 12))",
        ].joined(separator: " ")
        return Summary(fields: fields, consoleLine: line)
    }

    private struct Facts {
        let uniqueItemIDs: Int
        let uniqueRows: Int
        let duplicateItemIDs: String
        let duplicateRows: String
    }

    private static func facts(for items: [MediaItem]) -> Facts {
        let itemIDs = items.map(\.ratingKey)
        let rows = items.map(rowIdentity)
        return Facts(uniqueItemIDs: Set(itemIDs).count,
                     uniqueRows: Set(rows).count,
                     duplicateItemIDs: duplicateSummary(for: itemIDs),
                     duplicateRows: duplicateSummary(for: rows))
    }

    private static func duplicateSummary(for values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        let duplicates = counts
            .filter { $0.value > 1 }
            .map { (signature($0.key), $0.value) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0 < rhs.0
            }
            .prefix(5)
            .map { "\($0.0)x\($0.1)" }
            .joined(separator: "|")
        return duplicates.isEmpty ? "none" : duplicates
    }

    private static func sample(_ items: [MediaItem], startingAt start: Int, limit: Int) -> String {
        let rows = items.prefix(limit).enumerated().map { offset, item in
            rowSignature(item, absoluteIndex: start + offset)
        }
        return rows.isEmpty ? "empty" : rows.joined(separator: " || ")
    }

    private static func rowSignature(_ item: MediaItem, absoluteIndex: Int) -> String {
        [
            "#\(absoluteIndex)",
            "id=\(signature(item.ratingKey))",
            "kind=\(safeToken(item.type))",
            "show=\(signature(item.grandparentRatingKey))",
            "season=\(signature(item.parentRatingKey))",
            "S\(item.parentIndex.map(String.init) ?? "?")",
            "E\(item.index.map(String.init) ?? "?")",
            "name=\(signature(item.title))",
        ].joined(separator: ":")
    }

    private static func rowIdentity(_ item: MediaItem) -> String {
        [
            item.ratingKey,
            item.type,
            item.grandparentRatingKey,
            item.parentRatingKey,
            item.parentIndex.map(String.init),
            item.index.map(String.init),
            item.title,
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }

    private static func signature(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return DiagnosticRedactor.stableIdentifier(for: value)
    }

    private static func safeToken(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95, 44: // 0-9 A-Z a-z - . : _ ,
                output.unicodeScalars.append(scalar)
            default:
                output.append("_")
            }
        }
        return output.isEmpty ? "unknown" : output
    }
}
