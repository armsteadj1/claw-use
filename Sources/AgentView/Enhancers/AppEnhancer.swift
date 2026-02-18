import AppKit
import Foundation

/// Protocol for app-specific enrichment logic
protocol AppEnhancer {
    /// Bundle IDs this enhancer handles (empty = generic fallback)
    var bundleIdentifiers: [String] { get }

    /// Enhance a raw tree into an enriched snapshot
    func enhance(rawTree: RawAXNode, app: NSRunningApplication, refMap: RefMap?) -> AppSnapshot

    /// Extract app-specific metadata
    func extractMeta(rawTree: RawAXNode) -> [String: AnyCodable]
}
