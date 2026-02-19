import Foundation

/// Pagination parameters for cursor-based pagination.
public struct PaginationParams {
    /// Cursor to continue from (e.g. "e50" for AX, "15" for web links, "2000" for extract)
    public let after: String?
    /// Maximum items per page
    public let limit: Int

    public init(after: String? = nil, limit: Int) {
        self.after = after
        self.limit = limit
    }

    /// Parse the cursor as an element ref number (e.g. "e50" -> 50)
    public var afterRefNumber: Int? {
        guard let after = after else { return nil }
        let stripped = after.hasPrefix("e") ? String(after.dropFirst()) : after
        return Int(stripped)
    }

    /// Parse the cursor as a plain integer offset
    public var afterOffset: Int? {
        guard let after = after else { return nil }
        return Int(after)
    }
}

/// Pagination result metadata included in every response.
public struct PaginationResult {
    public let hasMore: Bool
    public let cursor: String?
    public let total: Int
    public let returned: Int

    public init(hasMore: Bool, cursor: String? = nil, total: Int, returned: Int) {
        self.hasMore = hasMore
        self.cursor = cursor
        self.total = total
        self.returned = returned
    }

    /// Compact format line: `more: true | cursor: e50` or `more: false`
    public var compactLine: String {
        if hasMore, let cursor = cursor {
            return "more: true | cursor: \(cursor)"
        }
        return "more: false"
    }

    /// JSON dict for inclusion in JSON responses
    public var jsonDict: [String: AnyCodable] {
        var d: [String: AnyCodable] = [
            "truncated": AnyCodable(hasMore),
            "total": AnyCodable(total),
            "returned": AnyCodable(returned),
        ]
        if let cursor = cursor {
            d["cursor"] = AnyCodable(cursor)
        }
        return d
    }
}

// MARK: - Default limits

public enum PaginationDefaults {
    /// Default elements per page for AX snapshots
    public static let axSnapshotLimit = 50
    /// Default links per page for web snapshots
    public static let webSnapshotLimit = 15
    /// Default chars per chunk for web extract
    public static let webExtractLimit = 2000
}

// MARK: - Paginator helpers

public enum Paginator {

    /// Paginate an AX snapshot's elements by ref number.
    /// Returns (paginated snapshot, pagination result).
    public static func paginateSnapshot(_ snapshot: AppSnapshot, params: PaginationParams) -> (AppSnapshot, PaginationResult) {
        let allElements = snapshot.content.sections.flatMap { $0.elements }
        let total = allElements.count

        // Determine start index based on cursor
        let startIndex: Int
        if let afterRef = params.afterRefNumber {
            // Find the first element after the cursor ref
            startIndex = allElements.firstIndex(where: {
                guard let refNum = refNumber($0.ref) else { return false }
                return refNum > afterRef
            }) ?? total
        } else {
            startIndex = 0
        }

        let limit = params.limit
        let endIndex = min(startIndex + limit, total)
        let pageElements = Array(allElements[startIndex..<endIndex])
        let hasMore = endIndex < total
        let lastRef = pageElements.last?.ref

        // Rebuild sections with only page elements
        let pageRefSet = Set(pageElements.map { $0.ref })
        let newSections = snapshot.content.sections.compactMap { section -> Section? in
            let filtered = section.elements.filter { pageRefSet.contains($0.ref) }
            return filtered.isEmpty ? nil : Section(role: section.role, label: section.label, elements: filtered)
        }

        let newContent = ContentTree(summary: snapshot.content.summary, sections: newSections)
        let paginated = AppSnapshot(
            app: snapshot.app,
            bundleId: snapshot.bundleId,
            pid: snapshot.pid,
            timestamp: snapshot.timestamp,
            window: snapshot.window,
            meta: snapshot.meta,
            content: newContent,
            actions: snapshot.actions,
            stats: snapshot.stats
        )

        let result = PaginationResult(
            hasMore: hasMore,
            cursor: hasMore ? lastRef : nil,
            total: total,
            returned: pageElements.count
        )

        return (paginated, result)
    }

    /// Paginate web snapshot links.
    /// Returns (modified data dict, pagination result).
    public static func paginateWebSnapshot(_ data: [String: AnyCodable], params: PaginationParams) -> ([String: AnyCodable], PaginationResult) {
        var result = data

        guard let links = data["links"]?.value as? [AnyCodable] else {
            return (data, PaginationResult(hasMore: false, total: 0, returned: 0))
        }

        let total = links.count
        let startIndex = params.afterOffset ?? 0
        let limit = params.limit
        let endIndex = min(startIndex + limit, total)
        let pageLinks = Array(links[min(startIndex, total)..<endIndex])
        let hasMore = endIndex < total

        result["links"] = AnyCodable(pageLinks)

        let pagination = PaginationResult(
            hasMore: hasMore,
            cursor: hasMore ? "\(endIndex)" : nil,
            total: total,
            returned: pageLinks.count
        )

        return (result, pagination)
    }

    /// Paginate web extract content by character offset.
    /// Returns (modified data dict, pagination result).
    public static func paginateWebExtract(_ data: [String: AnyCodable], params: PaginationParams) -> ([String: AnyCodable], PaginationResult) {
        var result = data

        let fullContent = data["content"]?.value as? String ?? data["markdown"]?.value as? String ?? ""
        let total = fullContent.count
        let startIndex = params.afterOffset ?? 0
        let limit = params.limit
        let endIndex = min(startIndex + limit, total)

        let safeStart = min(startIndex, total)
        let startStr = fullContent.index(fullContent.startIndex, offsetBy: safeStart)
        let endStr = fullContent.index(fullContent.startIndex, offsetBy: endIndex)
        let chunk = String(fullContent[startStr..<endStr])
        let hasMore = endIndex < total

        // Put chunk back into result
        if data["content"] != nil {
            result["content"] = AnyCodable(chunk)
        } else {
            result["markdown"] = AnyCodable(chunk)
        }

        let pagination = PaginationResult(
            hasMore: hasMore,
            cursor: hasMore ? "\(endIndex)" : nil,
            total: total,
            returned: chunk.count
        )

        return (result, pagination)
    }

    /// Extract ref number from "e42" -> 42
    private static func refNumber(_ ref: String) -> Int? {
        guard ref.hasPrefix("e") else { return nil }
        return Int(ref.dropFirst())
    }
}
