import AppKit
import Foundation

/// AX Transport — wraps AXBridge/AXTreeWalker/Enricher for Accessibility API access
public final class AXTransport: Transport {
    public let name = "ax"
    public let stats = TransportStats()

    public init() {}

    public func canHandle(app: String, bundleId: String?) -> Bool {
        // AX can handle any app when the screen is unlocked and accessibility is granted
        return AXBridge.checkAccessibilityPermission()
    }

    public func health() -> TransportHealth {
        if !AXBridge.checkAccessibilityPermission() {
            return .dead
        }
        if stats.totalAttempts > 5 && stats.successRate < 0.3 {
            return .degraded
        }
        return .healthy
    }

    public func execute(action: TransportAction) -> TransportResult {
        guard AXBridge.checkAccessibilityPermission() else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "Accessibility permission not granted", transportUsed: name)
        }

        guard let runningApp = resolveApp(name: action.app, pid: action.pid) else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "App not found: \(action.app)", transportUsed: name)
        }

        switch action.type {
        case "snapshot":
            return executeSnapshot(app: runningApp, depth: action.depth ?? 50)
        case "click", "focus", "fill", "clear", "toggle", "select":
            return executeAction(action: action, app: runningApp)
        default:
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "AX transport does not support action: \(action.type)", transportUsed: name)
        }
    }

    // MARK: - Private

    private func executeSnapshot(app: NSRunningApplication, depth: Int) -> TransportResult {
        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: app, maxDepth: depth, refMap: refMap)

        // If AX returned 0 enriched elements, report as empty — lets Router trigger fallback
        if snapshot.stats.enrichedElements == 0 {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "AX returned 0 elements (screen may be off/locked)", transportUsed: name)
        }

        guard let data = try? JSONOutput.encode(snapshot),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "Failed to encode snapshot", transportUsed: name)
        }

        stats.recordSuccess()
        return TransportResult(success: true, data: convertDict(dict), error: nil, transportUsed: name)
    }

    private func executeAction(action: TransportAction, app: NSRunningApplication) -> TransportResult {
        guard let actionType = ActionExecutor.ActionType(rawValue: action.type) else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "Unknown action: \(action.type)", transportUsed: name)
        }

        guard let ref = action.ref else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "--ref required for \(action.type)", transportUsed: name)
        }

        let enricher = Enricher()
        let refMap = RefMap()
        _ = enricher.snapshot(app: app, refMap: refMap)

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(action: actionType, ref: ref, value: action.value, on: app, enricher: enricher)

        guard let data = try? JSONOutput.encode(result),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "Failed to encode result", transportUsed: name)
        }

        if result.success {
            stats.recordSuccess()
        } else {
            stats.recordFailure()
        }

        return TransportResult(success: result.success, data: convertDict(dict), error: result.error, transportUsed: name)
    }

    private func resolveApp(name: String, pid: Int32) -> NSRunningApplication? {
        if pid > 0 {
            return AXBridge.findApp(pid: pid_t(pid))
        }
        return AXBridge.findApp(named: name)
    }

    private func convertDict(_ value: Any) -> [String: AnyCodable]? {
        guard let dict = value as? [String: Any] else { return nil }
        var result: [String: AnyCodable] = [:]
        for (k, v) in dict {
            result[k] = convertToAnyCodable(v)
        }
        return result
    }

    private func convertToAnyCodable(_ value: Any) -> AnyCodable {
        if let dict = value as? [String: Any] {
            var result: [String: AnyCodable] = [:]
            for (k, v) in dict {
                result[k] = convertToAnyCodable(v)
            }
            return AnyCodable(result)
        } else if let arr = value as? [Any] {
            return AnyCodable(arr.map { convertToAnyCodable($0) })
        } else {
            return AnyCodable(value)
        }
    }
}
