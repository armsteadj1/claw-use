import AppKit
import Foundation
import AgentViewCore

/// JSON-RPC method router — dispatches to the appropriate handler
/// Now uses the Transport layer with self-healing fallback chain
final class Router {
    private let startTime = Date()
    private let screenState: ScreenState
    private let cdpPool: CDPConnectionPool
    private let transportRouter: TransportRouter

    init(screenState: ScreenState, cdpPool: CDPConnectionPool, transportRouter: TransportRouter) {
        self.screenState = screenState
        self.cdpPool = cdpPool
        self.transportRouter = transportRouter
    }

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let params = request.params ?? [:]

        switch request.method {
        case "ping":
            return handlePing(id: request.id)
        case "list":
            return handleList(params: params, id: request.id)
        case "snapshot":
            return handleSnapshot(params: params, id: request.id)
        case "act":
            return handleAct(params: params, id: request.id)
        case "pipe":
            return handlePipe(params: params, id: request.id)
        case "status":
            return handleStatus(id: request.id)
        default:
            return JSONRPCResponse(error: .methodNotFound, id: request.id)
        }
    }

    // MARK: - ping

    private func handlePing(id: AnyCodable?) -> JSONRPCResponse {
        return JSONRPCResponse(result: AnyCodable(["pong": AnyCodable(true)] as [String: AnyCodable]), id: id)
    }

    // MARK: - list

    private func handleList(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let apps = AXBridge.listApps()
        let encoded = apps.map { app in
            [
                "name": AnyCodable(app.name),
                "pid": AnyCodable(app.pid),
                "bundle_id": AnyCodable(app.bundleId),
            ] as [String: AnyCodable]
        }
        return JSONRPCResponse(result: AnyCodable(encoded.map { AnyCodable($0) }), id: id)
    }

    // MARK: - snapshot (routed through transport layer)

    private func handleSnapshot(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appName = params["app"]?.value as? String
        let pid = params["pid"]?.value as? Int
        let depth = (params["depth"]?.value as? Int) ?? 50

        guard let runningApp = resolveApp(name: appName, pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "App not found"), id: id)
        }

        let action = TransportAction(
            type: "snapshot",
            app: runningApp.localizedName ?? "Unknown",
            bundleId: runningApp.bundleIdentifier,
            pid: runningApp.processIdentifier,
            depth: depth
        )

        let result = transportRouter.execute(action: action)
        return transportResultToResponse(result, id: id)
    }

    // MARK: - act (routed through transport layer with fallback)

    private func handleAct(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appName = params["app"]?.value as? String
        let pid = params["pid"]?.value as? Int
        let actionStr = params["action"]?.value as? String ?? ""
        let ref = params["ref"]?.value as? String
        let value = params["value"]?.value as? String
        let expr = params["expr"]?.value as? String
        let port = (params["port"]?.value as? Int) ?? 9222
        let timeout = (params["timeout"]?.value as? Int) ?? 3

        guard let runningApp = resolveApp(name: appName, pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "App not found"), id: id)
        }

        let action = TransportAction(
            type: actionStr.lowercased(),
            app: runningApp.localizedName ?? "Unknown",
            bundleId: runningApp.bundleIdentifier,
            pid: runningApp.processIdentifier,
            ref: ref,
            value: value,
            expr: expr,
            port: port,
            timeout: timeout
        )

        let result = transportRouter.execute(action: action)
        return transportResultToResponse(result, id: id)
    }

    // MARK: - pipe

    private func handlePipe(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appName = params["app"]?.value as? String
        let pid = params["pid"]?.value as? Int
        let actionStr = params["action"]?.value as? String ?? ""
        let matchStr = params["match"]?.value as? String
        let value = params["value"]?.value as? String

        // eval/script fast-path — route through transport layer
        if actionStr.lowercased() == "eval" || actionStr.lowercased() == "script" {
            return handleAct(params: params, id: id)
        }

        guard AXBridge.checkAccessibilityPermission() else {
            return JSONRPCResponse(error: JSONRPCError(code: -1, message: "Accessibility permission not granted"), id: id)
        }

        guard let runningApp = resolveApp(name: appName, pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "App not found"), id: id)
        }

        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, refMap: refMap)

        guard let matchStr = matchStr else {
            return JSONRPCResponse(error: JSONRPCError(code: -5, message: "--match required for pipe"), id: id)
        }

        let needle = matchStr.lowercased()
        var bestMatch: (ref: String, score: Int, label: String)?

        for section in snapshot.content.sections {
            for element in section.elements {
                let score = fuzzyScore(needle: needle, element: element, sectionLabel: section.label)
                if score > 0 {
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (ref: element.ref, score: score, label: element.label ?? element.role)
                    }
                }
            }
        }

        for inferredAction in snapshot.actions {
            if let ref = inferredAction.ref {
                let haystack = "\(inferredAction.name) \(inferredAction.description)".lowercased()
                if haystack.contains(needle) {
                    let score = 50
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (ref: ref, score: score, label: inferredAction.name)
                    }
                }
            }
        }

        guard let matched = bestMatch else {
            let available = snapshot.content.sections.flatMap { $0.elements }
                .map { "\($0.ref):\($0.label ?? $0.role)" }.joined(separator: ", ")
            return JSONRPCResponse(
                error: JSONRPCError(code: -6, message: "No element matching '\(matchStr)'. Available: \(available)"),
                id: id
            )
        }

        if actionStr.lowercased() == "read" {
            let result: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(snapshot.app),
                "action": AnyCodable("read"),
                "matched_ref": AnyCodable(matched.ref),
                "matched_label": AnyCodable(matched.label),
                "match_score": AnyCodable(matched.score),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        }

        guard let actionType = ActionExecutor.ActionType(rawValue: actionStr.lowercased()) else {
            return JSONRPCResponse(error: JSONRPCError(code: -3, message: "Unknown action: \(actionStr)"), id: id)
        }

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(action: actionType, ref: matched.ref, value: value, on: runningApp, enricher: enricher)

        let output: [String: AnyCodable] = [
            "success": AnyCodable(result.success),
            "app": AnyCodable(snapshot.app),
            "action": AnyCodable(actionStr),
            "matched_ref": AnyCodable(matched.ref),
            "matched_label": AnyCodable(matched.label),
            "match_score": AnyCodable(matched.score),
            "error": AnyCodable(result.error),
        ]

        return JSONRPCResponse(result: AnyCodable(output), id: id)
    }

    // MARK: - status (Issue #19: per-app transport health)

    private func handleStatus(id: AnyCodable?) -> JSONRPCResponse {
        let uptime = Int(Date().timeIntervalSince(startTime))
        let state = screenState.currentState()
        let apps = AXBridge.listApps()
        let cdpConns = cdpPool.connectionInfos()

        // Per-app transport health
        let appHealths = transportRouter.appTransportHealths(apps: apps)
        let appHealthEncoded = appHealths.map { health in
            AnyCodable([
                "name": AnyCodable(health.name),
                "bundle_id": AnyCodable(health.bundleId),
                "available_transports": AnyCodable(health.availableTransports.map { AnyCodable($0) }),
                "current_health": AnyCodable(
                    health.currentHealth.reduce(into: [String: AnyCodable]()) { dict, kv in
                        dict[kv.key] = AnyCodable(kv.value)
                    }
                ),
                "last_used_transport": AnyCodable(health.lastUsedTransport),
                "success_rate": AnyCodable(
                    health.successRate.reduce(into: [String: AnyCodable]()) { dict, kv in
                        dict[kv.key] = AnyCodable(kv.value)
                    }
                ),
            ] as [String: AnyCodable])
        }

        // Transport-level health summary
        let transportHealth = transportRouter.transportHealthSummary()
        let transportHealthEncoded = transportHealth.reduce(into: [String: AnyCodable]()) { dict, kv in
            dict[kv.key] = AnyCodable(kv.value)
        }

        let result: [String: AnyCodable] = [
            "daemon": AnyCodable("running"),
            "pid": AnyCodable(ProcessInfo.processInfo.processIdentifier),
            "uptime_s": AnyCodable(uptime),
            "screen": AnyCodable(state.screen),
            "display": AnyCodable(state.display),
            "frontmost_app": AnyCodable(state.frontmostApp),
            "app_count": AnyCodable(apps.count),
            "transport_health": AnyCodable(transportHealthEncoded),
            "apps": AnyCodable(appHealthEncoded),
            "cdp_connections": AnyCodable(cdpConns.map { conn in
                AnyCodable([
                    "port": AnyCodable(conn.port),
                    "health": AnyCodable(conn.health),
                    "page_count": AnyCodable(conn.pageCount),
                    "last_ping_ms": AnyCodable(conn.lastPingMs),
                ] as [String: AnyCodable])
            }),
            "cache": AnyCodable([
                "entries": AnyCodable(0),
                "hit_rate": AnyCodable(0.0),
            ] as [String: AnyCodable]),
        ]

        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    // MARK: - Helpers

    private func resolveApp(name: String?, pid: Int?) -> NSRunningApplication? {
        if let pid = pid {
            return AXBridge.findApp(pid: pid_t(pid))
        }
        if let name = name {
            return AXBridge.findApp(named: name)
        }
        return nil
    }

    private func transportResultToResponse(_ result: TransportResult, id: AnyCodable?) -> JSONRPCResponse {
        if let data = result.data {
            var output = data
            output["transport_used"] = AnyCodable(result.transportUsed)
            return JSONRPCResponse(result: AnyCodable(output), id: id)
        }
        if result.success {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "transport_used": AnyCodable(result.transportUsed),
            ]
            return JSONRPCResponse(result: AnyCodable(output), id: id)
        }
        return JSONRPCResponse(
            error: JSONRPCError(code: -10, message: result.error ?? "Transport execution failed"),
            id: id
        )
    }

    private func fuzzyScore(needle: String, element: Element, sectionLabel: String?) -> Int {
        var score = 0
        let label = (element.label ?? "").lowercased()
        let role = element.role.lowercased()
        let valStr = stringValue(element.value).lowercased()
        let secLabel = (sectionLabel ?? "").lowercased()

        if label == needle { score += 100 }
        else if label.contains(needle) { score += 80 }
        else if !label.isEmpty && needle.contains(label) { score += 40 }
        if role.contains(needle) { score += 30 }
        if valStr.contains(needle) { score += 20 }
        if secLabel.contains(needle) { score += 10 }
        if !element.actions.isEmpty && score > 0 { score += 5 }

        return score
    }

    private func stringValue(_ v: AnyCodable?) -> String {
        guard let val = v?.value else { return "" }
        if let s = val as? String { return s }
        return "\(val)"
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
