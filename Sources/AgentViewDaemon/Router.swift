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
    let snapshotCache: SnapshotCache
    let eventBus: EventBus
    private let safariTransport: SafariTransport
    let processMonitor: ProcessMonitor
    let processGroup: ProcessGroupManager

    init(screenState: ScreenState, cdpPool: CDPConnectionPool, transportRouter: TransportRouter,
         snapshotCache: SnapshotCache, eventBus: EventBus, safariTransport: SafariTransport,
         processGroup: ProcessGroupManager) {
        self.screenState = screenState
        self.cdpPool = cdpPool
        self.transportRouter = transportRouter
        self.snapshotCache = snapshotCache
        self.eventBus = eventBus
        self.safariTransport = safariTransport
        self.processMonitor = ProcessMonitor(eventBus: eventBus)
        self.processGroup = processGroup
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
        case "subscribe":
            return handleSubscribe(params: params, id: request.id)
        case "events":
            return handleEvents(params: params, id: request.id)
        case "web.tabs":
            return handleWebTabs(id: request.id)
        case "web.navigate":
            return handleWebNavigate(params: params, id: request.id)
        case "web.snapshot":
            return handleWebSnapshot(id: request.id)
        case "web.click":
            return handleWebClick(params: params, id: request.id)
        case "web.fill":
            return handleWebFill(params: params, id: request.id)
        case "web.extract":
            return handleWebExtract(id: request.id)
        case "web.switchTab":
            return handleWebSwitchTab(params: params, id: request.id)
        case "screenshot":
            return handleScreenshot(params: params, id: request.id)
        case "process.watch":
            return handleProcessWatch(params: params, id: request.id)
        case "process.unwatch":
            return handleProcessUnwatch(params: params, id: request.id)
        case "process.list":
            return handleProcessList(id: request.id)
        case "process.group.add":
            return handleProcessGroupAdd(params: params, id: request.id)
        case "process.group.remove":
            return handleProcessGroupRemove(params: params, id: request.id)
        case "process.group.clear":
            return handleProcessGroupClear(id: request.id)
        case "process.group.status":
            return handleProcessGroupStatus(id: request.id)
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
        let noCache = params["no_cache"]?.value as? Bool ?? false

        guard let runningApp = resolveApp(name: appName, pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "App not found"), id: id)
        }

        let resolvedName = runningApp.localizedName ?? "Unknown"

        // Check cache first (unless explicitly bypassed)
        if !noCache, let cached = snapshotCache.get(app: resolvedName) {
            // Return cached snapshot with cache metadata
            if let data = snapshotToData(cached.snapshot) {
                var output = data
                output["cache_hit"] = AnyCodable(true)
                output["cache_age_ms"] = AnyCodable(cached.ageMs)
                output["transport_used"] = AnyCodable(cached.transport)
                return JSONRPCResponse(result: AnyCodable(output), id: id)
            }
        }

        let action = TransportAction(
            type: "snapshot",
            app: resolvedName,
            bundleId: runningApp.bundleIdentifier,
            pid: runningApp.processIdentifier,
            depth: depth
        )

        var result = transportRouter.execute(action: action)

        // If AX returned empty (0 enriched elements / no sections), try fallback transports.
        // This happens when the display is off or the screen is locked.
        if result.success, result.transportUsed == "ax" {
            let isEmpty: Bool
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let data = result.data,
               let snapshotData = try? JSONOutput.encode(AnyCodable(data)),
               let snapshot = try? decoder.decode(AppSnapshot.self, from: snapshotData) {
                isEmpty = snapshot.stats.enrichedElements == 0 || snapshot.content.sections.isEmpty
            } else {
                isEmpty = true
            }

            if isEmpty {
                let isSafari = runningApp.bundleIdentifier?.lowercased().contains("safari") == true
                    || resolvedName.lowercased().contains("safari")
                if isSafari {
                    // Safari: use SafariTransport.pageSnapshot() which works even when screen is locked
                    let fallback = safariTransport.pageSnapshot()
                    if fallback.success {
                        result = fallback
                    }
                } else {
                    // Non-Safari: try AppleScript transport via the router (skip AX)
                    let scriptAction = TransportAction(
                        type: "script", app: resolvedName,
                        bundleId: runningApp.bundleIdentifier,
                        pid: runningApp.processIdentifier, depth: depth
                    )
                    let fallback = transportRouter.execute(action: scriptAction)
                    if fallback.success {
                        result = fallback
                    }
                }
            }
        }

        // Cache successful snapshot results
        if result.success, let data = result.data,
           let snapshotData = try? JSONOutput.encode(AnyCodable(data)),
           let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: snapshotData) {
            let _ = snapshotCache.put(app: resolvedName, snapshot: snapshot, transport: result.transportUsed)
        }

        return transportResultToResponse(result, id: id)
    }

    private func snapshotToData(_ snapshot: AppSnapshot) -> [String: AnyCodable]? {
        guard let data = try? JSONOutput.encode(snapshot),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else {
            return nil
        }
        return dict
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

        // Check if AX snapshot is empty (display off / screen locked)
        let axEmpty = snapshot.stats.enrichedElements == 0 || snapshot.content.sections.isEmpty
        let resolvedName = runningApp.localizedName ?? "Unknown"
        let isSafari = runningApp.bundleIdentifier?.lowercased().contains("safari") == true
            || resolvedName.lowercased().contains("safari")

        // If AX is empty and app is Safari, fall back to Safari transport for the entire pipe flow
        if axEmpty && isSafari {
            let action = actionStr.lowercased()
            if action == "click" {
                let clickResult = safariTransport.clickElement(match: matchStr)
                return transportResultToResponse(clickResult, id: id)
            } else if action == "fill" {
                let fillResult = safariTransport.fillElement(match: matchStr, value: value)
                return transportResultToResponse(fillResult, id: id)
            } else if action == "read" {
                // For read, get a Safari page snapshot and return basic info
                let snapResult = safariTransport.pageSnapshot()
                return transportResultToResponse(snapResult, id: id)
            }
        }

        // If AX is empty and non-Safari, try AppleScript transport via the router
        if axEmpty && !isSafari {
            let scriptAction = TransportAction(
                type: "script", app: resolvedName,
                bundleId: runningApp.bundleIdentifier,
                pid: runningApp.processIdentifier
            )
            let fallback = transportRouter.execute(action: scriptAction)
            if fallback.success {
                return transportResultToResponse(fallback, id: id)
            }
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
                "entries": AnyCodable(snapshotCache.stats.entries),
                "hits": AnyCodable(snapshotCache.stats.hits),
                "misses": AnyCodable(snapshotCache.stats.misses),
                "hit_rate": AnyCodable(snapshotCache.stats.hitRate),
            ] as [String: AnyCodable]),
            "events": AnyCodable([
                "recent_count": AnyCodable(eventBus.eventCount),
                "subscribers": AnyCodable(eventBus.subscriberCount),
            ] as [String: AnyCodable]),
            "process_monitor": AnyCodable([
                "watched_pids": AnyCodable(processMonitor.watchedPIDs.map { AnyCodable(Int($0)) }),
                "watch_count": AnyCodable(processMonitor.watchCount),
            ] as [String: AnyCodable]),
        ]

        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    // MARK: - subscribe (returns subscription ID, streaming handled by Server)

    private func handleSubscribe(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appFilter = params["app"]?.value as? String
        let typesStr = params["types"]?.value as? String
        let filterStr = params["filter"]?.value as? String

        // Return subscription parameters for Server to wire up streaming
        let result: [String: AnyCodable] = [
            "streaming": AnyCodable(true),
            "app_filter": AnyCodable(appFilter),
            "type_filters": AnyCodable(typesStr ?? filterStr),
        ]
        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    // MARK: - events (get recent events)

    private func handleEvents(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let appFilter = params["app"]?.value as? String
        let typesStr = params["types"]?.value as? String
        let filterStr = params["filter"]?.value as? String
        let limit = params["limit"]?.value as? Int
        let rawFilter = typesStr ?? filterStr
        let typeFilters: Set<String>? = rawFilter.map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }

        let events = eventBus.getRecentEvents(appFilter: appFilter, typeFilters: typeFilters, limit: limit)

        let encoded = events.map { event -> AnyCodable in
            var dict: [String: AnyCodable] = [
                "timestamp": AnyCodable(event.timestamp),
                "type": AnyCodable(event.type),
            ]
            if let app = event.app { dict["app"] = AnyCodable(app) }
            if let bid = event.bundleId { dict["bundle_id"] = AnyCodable(bid) }
            if let pid = event.pid { dict["pid"] = AnyCodable(Int(pid)) }
            if let details = event.details { dict["details"] = AnyCodable(details) }
            return AnyCodable(dict)
        }

        return JSONRPCResponse(result: AnyCodable(encoded.map { $0 }), id: id)
    }

    // MARK: - web.* handlers (Safari Transport)

    private func handleWebTabs(id: AnyCodable?) -> JSONRPCResponse {
        let result = safariTransport.listTabs()
        return transportResultToResponse(result, id: id)
    }

    private func handleWebNavigate(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let url = params["url"]?.value as? String
        let result = safariTransport.navigate(url: url)
        return transportResultToResponse(result, id: id)
    }

    private func handleWebSnapshot(id: AnyCodable?) -> JSONRPCResponse {
        let result = safariTransport.pageSnapshot()
        return transportResultToResponse(result, id: id)
    }

    private func handleWebClick(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let match = params["match"]?.value as? String
        let result = safariTransport.clickElement(match: match)
        return webJSResultToResponse(result, id: id)
    }

    private func handleWebFill(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let match = params["match"]?.value as? String
        let value = params["value"]?.value as? String
        let result = safariTransport.fillElement(match: match, value: value)
        return webJSResultToResponse(result, id: id)
    }

    private func handleWebExtract(id: AnyCodable?) -> JSONRPCResponse {
        let result = safariTransport.extractContent()
        return transportResultToResponse(result, id: id)
    }

    private func handleWebSwitchTab(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        let match = params["match"]?.value as? String
        let result = safariTransport.switchTab(match: match)
        return transportResultToResponse(result, id: id)
    }

    // MARK: - screenshot

    private func handleScreenshot(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard let appName = params["app"]?.value as? String else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "screenshot requires 'app' parameter"), id: id)
        }
        let outputPath = params["output"]?.value as? String
        let result = ScreenCapture.capture(appName: appName, outputPath: outputPath)
        if result.success {
            var output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "path": AnyCodable(result.path),
                "width": AnyCodable(result.width),
                "height": AnyCodable(result.height),
            ]
            output["transport_used"] = AnyCodable("screencapture")
            return JSONRPCResponse(result: AnyCodable(output), id: id)
        }
        return JSONRPCResponse(error: JSONRPCError(code: -10, message: result.error ?? "Screenshot failed"), id: id)
    }

    // MARK: - process.* handlers

    private func handleProcessWatch(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard let pidValue = params["pid"]?.value as? Int else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "process.watch requires 'pid' parameter"), id: id)
        }
        let pid = Int32(pidValue)
        let logPath = params["log"]?.value as? String
        let idleTimeout = (params["idle_timeout"]?.value as? Int).map { TimeInterval($0) } ?? 300

        let started = processMonitor.watch(pid: pid, logPath: logPath, idleTimeout: idleTimeout)

        if started {
            let result: [String: AnyCodable] = [
                "watching": AnyCodable(true),
                "pid": AnyCodable(Int(pid)),
                "log_path": AnyCodable(logPath),
                "idle_timeout_s": AnyCodable(Int(idleTimeout)),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        } else {
            if processMonitor.isWatching(pid: pid) {
                return JSONRPCResponse(error: JSONRPCError(code: -11, message: "Already watching pid \(pid)"), id: id)
            }
            return JSONRPCResponse(error: JSONRPCError(code: -12, message: "Process \(pid) not found or not accessible"), id: id)
        }
    }

    private func handleProcessUnwatch(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard let pidValue = params["pid"]?.value as? Int else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "process.unwatch requires 'pid' parameter"), id: id)
        }
        let pid = Int32(pidValue)

        guard processMonitor.isWatching(pid: pid) else {
            return JSONRPCResponse(error: JSONRPCError(code: -13, message: "Not watching pid \(pid)"), id: id)
        }

        processMonitor.unwatch(pid: pid)
        let result: [String: AnyCodable] = [
            "unwatched": AnyCodable(true),
            "pid": AnyCodable(Int(pid)),
        ]
        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    private func handleProcessList(id: AnyCodable?) -> JSONRPCResponse {
        let pids = processMonitor.watchedPIDs
        let result: [String: AnyCodable] = [
            "watched_pids": AnyCodable(pids.map { AnyCodable(Int($0)) }),
            "count": AnyCodable(pids.count),
        ]
        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    // MARK: - process.group.* handlers

    private func handleProcessGroupAdd(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard let pidValue = params["pid"]?.value as? Int else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "process.group.add requires 'pid' parameter"), id: id)
        }
        let pid = Int32(pidValue)
        let label = params["label"]?.value as? String ?? "PID \(pid)"

        let added = processGroup.add(pid: pid, label: label)

        if added {
            let result: [String: AnyCodable] = [
                "added": AnyCodable(true),
                "pid": AnyCodable(Int(pid)),
                "label": AnyCodable(label),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        } else {
            return JSONRPCResponse(error: JSONRPCError(code: -14, message: "PID \(pid) is already tracked in process group"), id: id)
        }
    }

    private func handleProcessGroupRemove(params: [String: AnyCodable], id: AnyCodable?) -> JSONRPCResponse {
        guard let pidValue = params["pid"]?.value as? Int else {
            return JSONRPCResponse(error: JSONRPCError(code: -2, message: "process.group.remove requires 'pid' parameter"), id: id)
        }
        let pid = Int32(pidValue)

        let removed = processGroup.remove(pid: pid)

        if removed {
            let result: [String: AnyCodable] = [
                "removed": AnyCodable(true),
                "pid": AnyCodable(Int(pid)),
            ]
            return JSONRPCResponse(result: AnyCodable(result), id: id)
        } else {
            return JSONRPCResponse(error: JSONRPCError(code: -15, message: "PID \(pid) not found in process group"), id: id)
        }
    }

    private func handleProcessGroupClear(id: AnyCodable?) -> JSONRPCResponse {
        let removed = processGroup.clear()
        let result: [String: AnyCodable] = [
            "cleared": AnyCodable(true),
            "removed_count": AnyCodable(removed),
            "remaining_count": AnyCodable(processGroup.count),
        ]
        return JSONRPCResponse(result: AnyCodable(result), id: id)
    }

    private func handleProcessGroupStatus(id: AnyCodable?) -> JSONRPCResponse {
        let processes = processGroup.status()
        let json = ProcessGroupManager.jsonStatus(processes: processes)
        let result: [String: AnyCodable] = [
            "processes": AnyCodable(json.map { AnyCodable($0) }),
            "count": AnyCodable(processes.count),
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

    /// Parse JS JSON result from web click/fill and flatten into response dict.
    /// The JS IIFE returns a JSON string in the "result" key; we parse it and merge top-level.
    private func webJSResultToResponse(_ result: TransportResult, id: AnyCodable?) -> JSONRPCResponse {
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String,
              let jsonData = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: jsonData) else {
            return transportResultToResponse(result, id: id)
        }
        var output = parsed
        output["transport_used"] = AnyCodable(result.transportUsed)
        return JSONRPCResponse(result: AnyCodable(output), id: id)
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
