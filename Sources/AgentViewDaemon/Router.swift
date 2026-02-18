import AppKit
import Foundation
import AgentViewCore

/// JSON-RPC method router — dispatches to the appropriate handler
final class Router {
    private let startTime = Date()
    private let screenState: ScreenState
    private let cdpPool: CDPConnectionPool

    init(screenState: ScreenState, cdpPool: CDPConnectionPool) {
        self.screenState = screenState
        self.cdpPool = cdpPool
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

    // MARK: - snapshot

    private func handleSnapshot(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard AXBridge.checkAccessibilityPermission() else {
            return JSONRPCResponse(error: JSONRPCError(code: -1, message: "Accessibility permission not granted"), id: id)
        }

        let appName = params["app"]?.value as? String
        let pid = params["pid"]?.value as? Int
        let depth = (params["depth"]?.value as? Int) ?? 50

        guard let runningApp = resolveApp(name: appName, pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "App not found"), id: id)
        }

        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, maxDepth: depth, refMap: refMap)

        guard let data = try? JSONOutput.encode(snapshot),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JSONRPCResponse(error: .internalError, id: id)
        }

        return JSONRPCResponse(result: convertToAnyCodable(dict), id: id)
    }

    // MARK: - act

    private func handleAct(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard AXBridge.checkAccessibilityPermission() else {
            return JSONRPCResponse(error: JSONRPCError(code: -1, message: "Accessibility permission not granted"), id: id)
        }

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

        // Handle script action
        if actionStr.lowercased() == "script" {
            return handleScript(app: runningApp, expr: expr, timeout: timeout, id: id)
        }

        // Handle eval action — try persistent pool first
        if actionStr.lowercased() == "eval" {
            return handleEval(app: runningApp, expr: expr, port: port, id: id)
        }

        // Standard AX actions
        guard let actionType = ActionExecutor.ActionType(rawValue: actionStr.lowercased()) else {
            return JSONRPCResponse(error: JSONRPCError(code: -3, message: "Unknown action: \(actionStr)"), id: id)
        }

        guard let ref = ref else {
            return JSONRPCResponse(error: JSONRPCError(code: -4, message: "--ref required for \(actionStr)"), id: id)
        }

        let enricher = Enricher()
        let refMap = RefMap()
        _ = enricher.snapshot(app: runningApp, refMap: refMap)

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(action: actionType, ref: ref, value: value, on: runningApp, enricher: enricher)

        guard let data = try? JSONOutput.encode(result),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JSONRPCResponse(error: .internalError, id: id)
        }

        return JSONRPCResponse(result: convertToAnyCodable(dict), id: id)
    }

    // MARK: - pipe

    private func handlePipe(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appName = params["app"]?.value as? String
        let pid = params["pid"]?.value as? Int
        let actionStr = params["action"]?.value as? String ?? ""
        let matchStr = params["match"]?.value as? String
        let value = params["value"]?.value as? String
        // expr, port, timeout handled by handleAct for eval/script fast-path

        // eval/script fast-path
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

    // MARK: - status

    private func handleStatus(id: AnyCodable?) -> JSONRPCResponse {
        let uptime = Int(Date().timeIntervalSince(startTime))
        let state = screenState.currentState()
        let apps = AXBridge.listApps()
        let cdpConns = cdpPool.connectionInfos()

        let result: [String: AnyCodable] = [
            "daemon": AnyCodable("running"),
            "pid": AnyCodable(ProcessInfo.processInfo.processIdentifier),
            "uptime_s": AnyCodable(uptime),
            "screen": AnyCodable(state.screen),
            "display": AnyCodable(state.display),
            "frontmost_app": AnyCodable(state.frontmostApp),
            "app_count": AnyCodable(apps.count),
            "cdp_connections": AnyCodable(cdpConns.map { conn in
                AnyCodable([
                    "port": AnyCodable(conn.port),
                    "health": AnyCodable(conn.health),
                    "page_count": AnyCodable(conn.pageCount),
                    "last_ping_ms": AnyCodable(conn.lastPingMs),
                ] as [String: AnyCodable])
            }),
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

    private func handleScript(app: NSRunningApplication, expr: String?, timeout: Int, id: AnyCodable?) -> JSONRPCResponse {
        guard let expression = expr else {
            return JSONRPCResponse(error: JSONRPCError(code: -4, message: "script requires --expr"), id: id)
        }

        let appName = app.localizedName ?? "Unknown"
        let script: String
        if expression.lowercased().hasPrefix("tell application") {
            script = expression
        } else {
            script = "tell application \"\(appName)\"\n\(expression)\nend tell"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return JSONRPCResponse(error: JSONRPCError(code: -7, message: "Failed to launch osascript: \(error)"), id: id)
        }

        let deadline = DispatchTime.now() + .seconds(timeout)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            let result: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "app": AnyCodable(appName),
                "action": AnyCodable("script"),
                "error": AnyCodable("AppleScript timed out after \(timeout)s"),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let result: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "app": AnyCodable(appName),
                "action": AnyCodable("script"),
                "error": AnyCodable(stderrStr.isEmpty ? "Exit code \(process.terminationStatus)" : stderrStr),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        }

        let result: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "app": AnyCodable(appName),
            "action": AnyCodable("script"),
            "result": AnyCodable(stdout),
        ]
        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    private func handleEval(app: NSRunningApplication, expr: String?, port: Int, id: AnyCodable?) -> JSONRPCResponse {
        guard let expression = expr else {
            return JSONRPCResponse(error: JSONRPCError(code: -4, message: "eval requires --expr"), id: id)
        }

        let appName = app.localizedName ?? "Unknown"

        do {
            // Try persistent pool first
            let resultValue = try cdpPool.evaluate(port: port, expression: expression)
            let result: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(appName),
                "pid": AnyCodable(app.processIdentifier),
                "action": AnyCodable("eval"),
                "result": AnyCodable(resultValue ?? "undefined"),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        } catch {
            let result: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "error": AnyCodable("CDP eval failed: \(error)"),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        }
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
