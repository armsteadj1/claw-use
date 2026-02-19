import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import AgentViewCore

@main
struct AgentView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentview",
        abstract: "Read macOS Accessibility APIs and expose structured UI state to AI agents.",
        version: "0.3.0",
        subcommands: [List.self, Raw.self, Snapshot.self, Act.self, Open.self, Focus.self, Restore.self, Pipe.self, Daemon.self, Status.self, Watch.self, Web.self, Screenshot.self, ProcessCmd.self]
    )
}

// MARK: - Helper: route through daemon or fallback to direct

/// Try daemon first; if unavailable, run directly via AgentViewCore
private func callDaemon(method: String, params: [String: AnyCodable]? = nil) throws -> JSONRPCResponse {
    do {
        return try DaemonClient.call(method: method, params: params)
    } catch {
        // Daemon unavailable — not an error for the user, just means direct mode
        throw error
    }
}

private func printResponse(_ response: JSONRPCResponse, pretty: Bool) throws {
    if let error = response.error {
        fputs("Error: \(error.message)\n", stderr)
        throw ExitCode.failure
    }
    guard let result = response.result else {
        print("{}")
        return
    }
    let enc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
    let data = try enc.encode(result)
    print(String(data: data, encoding: .utf8)!)
}

/// Print a daemon response with format + pagination support.
/// If format is "compact", the `compactFn` closure is called with the decoded dict to produce compact output.
/// If format is "json", adds pagination metadata to the JSON if present.
private func printFormattedResponse(
    _ response: JSONRPCResponse,
    format: String,
    pretty: Bool,
    pagination: PaginationResult? = nil,
    compactFn: (([String: AnyCodable], PaginationResult?) -> String)? = nil
) throws {
    if let error = response.error {
        fputs("Error: \(error.message)\n", stderr)
        throw ExitCode.failure
    }
    guard let result = response.result else {
        if format == "compact" { print("(empty)") } else { print("{}") }
        return
    }

    if format == "compact", let dict = result.value as? [String: AnyCodable], let fn = compactFn {
        print(fn(dict, pagination))
    } else {
        // JSON mode — inject pagination if present
        if let pagination = pagination, var dict = result.value as? [String: AnyCodable] {
            for (k, v) in pagination.jsonDict {
                dict[k] = v
            }
            let enc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
            let data = try enc.encode(AnyCodable(dict))
            print(String(data: data, encoding: .utf8)!)
        } else {
            let enc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
            let data = try enc.encode(result)
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

// MARK: - daemon

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the agentviewd daemon",
        subcommands: [DaemonStart.self, DaemonStop.self, DaemonStatus.self]
    )
}

struct DaemonStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the daemon")

    func run() throws {
        if DaemonClient.isDaemonRunning() {
            let pid = DaemonClient.daemonPID() ?? 0
            print("{\"status\":\"already_running\",\"pid\":\(pid)}")
            return
        }
        try DaemonClient.startDaemon()
        // Wait for ready
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if DaemonClient.isDaemonRunning() {
                let pid = DaemonClient.daemonPID() ?? 0
                print("{\"status\":\"started\",\"pid\":\(pid)}")
                return
            }
        }
        fputs("Error: Daemon failed to start\n", stderr)
        throw ExitCode.failure
    }
}

struct DaemonStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the daemon")

    func run() throws {
        if DaemonClient.stopDaemon() {
            print("{\"status\":\"stopped\"}")
        } else {
            print("{\"status\":\"not_running\"}")
        }
    }
}

struct DaemonStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Check daemon status")

    func run() throws {
        if DaemonClient.isDaemonRunning() {
            let pid = DaemonClient.daemonPID() ?? 0
            print("{\"status\":\"running\",\"pid\":\(pid)}")
        } else {
            print("{\"status\":\"not_running\"}")
        }
    }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full system status (daemon, screen, CDP)")

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "status")
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatStatus(data: dict)
        }
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all running GUI apps"
    )

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Try daemon first
        do {
            let response = try callDaemon(method: "list")
            if format == "compact" {
                // Decode the list response into AppInfo array
                if let error = response.error {
                    fputs("Error: \(error.message)\n", stderr)
                    throw ExitCode.failure
                }
                if let result = response.result, let arr = result.value as? [AnyCodable] {
                    let apps = arr.compactMap { item -> AppInfo? in
                        guard let dict = item.value as? [String: AnyCodable] else { return nil }
                        let name = dict["name"]?.value as? String ?? ""
                        let pid = dict["pid"]?.value as? Int ?? 0
                        let bundleId = dict["bundle_id"]?.value as? String ?? dict["bundleId"]?.value as? String
                        return AppInfo(name: name, pid: Int32(pid), bundleId: bundleId)
                    }
                    print(CompactFormatter.formatList(apps: apps))
                } else {
                    print("Apps (0):")
                }
            } else {
                try printResponse(response, pretty: pretty)
            }
            return
        } catch {}

        // Fallback: direct
        let apps = AXBridge.listApps()
        if format == "compact" {
            print(CompactFormatter.formatList(apps: apps))
        } else {
            try JSONOutput.print(apps, pretty: pretty)
        }
    }
}

// MARK: - raw (always direct — no daemon equivalent)

struct Raw: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump the raw AX tree of an app as JSON"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    @Option(name: .long, help: "Max tree depth (default: 50)")
    var depth: Int = 50

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        guard AXBridge.checkAccessibilityPermission() else {
            fputs("Error: Accessibility permission not granted.\n", stderr)
            fputs("Enable in: System Settings → Privacy & Security → Accessibility\n", stderr)
            AXBridge.requestPermission()
            throw ExitCode.failure
        }

        guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
            throw ExitCode.failure
        }

        let axApp = AXBridge.appElement(for: runningApp)
        var visited = Set<UInt>()
        guard let tree = AXTreeWalker.walk(axApp, maxDepth: depth, visited: &visited) else {
            fputs("Error: Could not read AX tree for \(runningApp.localizedName ?? "app")\n", stderr)
            throw ExitCode.failure
        }

        try JSONOutput.print(tree, pretty: pretty)
    }
}

// MARK: - snapshot

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enriched snapshot of an app's UI state"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    @Option(name: .long, help: "Max tree depth (default: 50)")
    var depth: Int = 50

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Option(name: .long, help: "Continue from cursor position (e.g. e50)")
    var after: String?

    @Option(name: .long, help: "Max elements per page (default: 50)")
    var limit: Int = PaginationDefaults.axSnapshotLimit

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Try daemon
        do {
            var params: [String: AnyCodable] = [:]
            if let app = app { params["app"] = AnyCodable(app) }
            if let pid = pid { params["pid"] = AnyCodable(Int(pid)) }
            params["depth"] = AnyCodable(depth)
            let response = try callDaemon(method: "snapshot", params: params)

            if format == "compact" {
                if let error = response.error {
                    fputs("Error: \(error.message)\n", stderr)
                    throw ExitCode.failure
                }
                // Daemon returns JSON; decode into AppSnapshot for compact format
                if let result = response.result {
                    let enc = JSONOutput.encoder
                    let data = try enc.encode(result)
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let snapshot = try decoder.decode(AppSnapshot.self, from: data)
                    let pagParams = PaginationParams(after: after, limit: limit)
                    let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)
                    print(CompactFormatter.formatSnapshot(snapshot: paginated, pagination: pagResult))
                } else {
                    print("(empty)")
                }
            } else {
                // JSON mode — still paginate
                if let result = response.result {
                    let enc = JSONOutput.encoder
                    let data = try enc.encode(result)
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let snapshot = try decoder.decode(AppSnapshot.self, from: data)
                    let pagParams = PaginationParams(after: after, limit: limit)
                    let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)
                    // Encode paginated snapshot with pagination metadata
                    let outEnc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
                    var snapshotData = try outEnc.encode(paginated)
                    // Append pagination info
                    if var dict = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] {
                        dict["truncated"] = pagResult.hasMore
                        dict["total"] = pagResult.total
                        dict["returned"] = pagResult.returned
                        if let cursor = pagResult.cursor { dict["cursor"] = cursor }
                        snapshotData = try JSONSerialization.data(withJSONObject: dict, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
                    }
                    print(String(data: snapshotData, encoding: .utf8)!)
                } else {
                    try printResponse(response, pretty: pretty)
                }
            }
            return
        } catch {}

        // Fallback: direct
        guard AXBridge.checkAccessibilityPermission() else {
            fputs("Error: Accessibility permission not granted.\n", stderr)
            AXBridge.requestPermission()
            throw ExitCode.failure
        }

        guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
            throw ExitCode.failure
        }

        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, maxDepth: depth, refMap: refMap)

        let pagParams = PaginationParams(after: after, limit: limit)
        let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)

        if format == "compact" {
            print(CompactFormatter.formatSnapshot(snapshot: paginated, pagination: pagResult))
        } else {
            try JSONOutput.print(paginated, pretty: pretty)
        }
    }
}

// MARK: - act

struct Act: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform an action on an app element"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Argument(help: "Action: click, focus, fill, clear, toggle, select, eval, script")
    var action: String

    @Option(name: .long, help: "Element ref (e.g., e4)")
    var ref: String?

    @Option(name: .long, help: "Value for fill/select actions")
    var value: String?

    @Option(name: .long, help: "JavaScript expression for eval action")
    var expr: String?

    @Option(name: .long, help: "CDP port (default: 9222)")
    var port: Int = 9222

    @Option(name: .long, help: "Timeout in seconds for script action (default: 3)")
    var timeout: Int = 3

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Try daemon
        do {
            var params: [String: AnyCodable] = [
                "action": AnyCodable(action),
            ]
            if let app = app { params["app"] = AnyCodable(app) }
            if let pid = pid { params["pid"] = AnyCodable(Int(pid)) }
            if let ref = ref { params["ref"] = AnyCodable(ref) }
            if let value = value { params["value"] = AnyCodable(value) }
            if let expr = expr { params["expr"] = AnyCodable(expr) }
            params["port"] = AnyCodable(port)
            params["timeout"] = AnyCodable(timeout)
            let response = try callDaemon(method: "act", params: params)
            try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
                CompactFormatter.formatActResult(data: dict)
            }
            return
        } catch {}

        // Fallback: direct execution
        guard AXBridge.checkAccessibilityPermission() else {
            fputs("Error: Accessibility permission not granted.\n", stderr)
            AXBridge.requestPermission()
            throw ExitCode.failure
        }

        guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
            throw ExitCode.failure
        }

        // Handle script action
        if action.lowercased() == "script" {
            guard let expression = expr else {
                fputs("Error: script action requires --expr\n", stderr)
                throw ExitCode.failure
            }
            let appName = runningApp.localizedName ?? "Unknown"
            let script: String
            if expression.lowercased().hasPrefix("tell application") {
                script = expression
            } else {
                script = "tell application \"\(appName)\"\n\(expression)\nend tell"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outPipe = Foundation.Pipe()
            let errPipe = Foundation.Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            let timeoutSeconds = timeout
            let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }

            if group.wait(timeout: deadline) == .timedOut {
                process.terminate()
                let output: [String: AnyCodable] = [
                    "success": AnyCodable(false),
                    "app": AnyCodable(appName),
                    "pid": AnyCodable(runningApp.processIdentifier),
                    "action": AnyCodable("script"),
                    "error": AnyCodable("AppleScript timed out after \(timeoutSeconds)s."),
                ]
                if format == "compact" {
                    print(CompactFormatter.formatActResult(data: output))
                } else {
                    try JSONOutput.print(output, pretty: pretty)
                }
                throw ExitCode.failure
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr_str = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                let output: [String: AnyCodable] = [
                    "success": AnyCodable(false),
                    "app": AnyCodable(appName),
                    "pid": AnyCodable(runningApp.processIdentifier),
                    "action": AnyCodable("script"),
                    "error": AnyCodable(stderr_str.isEmpty ? "AppleScript failed with exit code \(process.terminationStatus)" : stderr_str),
                ]
                if format == "compact" {
                    print(CompactFormatter.formatActResult(data: output))
                } else {
                    try JSONOutput.print(output, pretty: pretty)
                }
                throw ExitCode.failure
            }

            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(appName),
                "pid": AnyCodable(runningApp.processIdentifier),
                "action": AnyCodable("script"),
                "result": AnyCodable(stdout),
            ]
            if format == "compact" {
                print(CompactFormatter.formatActResult(data: output))
            } else {
                try JSONOutput.print(output, pretty: pretty)
            }
            return
        }

        guard let actionType = ActionExecutor.ActionType(rawValue: action.lowercased()) else {
            fputs("Error: Unknown action '\(action)'. Valid actions: click, focus, fill, clear, toggle, select, eval, script\n", stderr)
            throw ExitCode.failure
        }

        // Handle eval action
        if actionType == .eval {
            guard let expression = expr else {
                fputs("Error: eval action requires --expr\n", stderr)
                throw ExitCode.failure
            }
            let cdp = CDPHelper(port: port)
            do {
                let pages = try cdp.listPages()
                guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
                    fputs("Error: No CDP pages found.\n", stderr)
                    throw ExitCode.failure
                }
                let evalResult = try cdp.evaluate(pageWsUrl: wsUrl, expression: expression)
                let output: [String: AnyCodable] = [
                    "success": AnyCodable(true),
                    "app": AnyCodable(runningApp.localizedName ?? "Unknown"),
                    "pid": AnyCodable(runningApp.processIdentifier),
                    "action": AnyCodable("eval"),
                    "result": AnyCodable(evalResult ?? "undefined"),
                ]
                if format == "compact" {
                    print(CompactFormatter.formatActResult(data: output))
                } else {
                    try JSONOutput.print(output, pretty: pretty)
                }
            } catch {
                let output = ActionResultOutput(success: false, error: "CDP eval failed: \(error)", snapshot: nil)
                try JSONOutput.print(output, pretty: pretty)
                throw ExitCode.failure
            }
            return
        }

        guard let ref = ref else {
            fputs("Error: --ref is required for \(action) action\n", stderr)
            throw ExitCode.failure
        }

        let enricher = Enricher()
        let refMap = RefMap()
        _ = enricher.snapshot(app: runningApp, refMap: refMap)

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(action: actionType, ref: ref, value: value, on: runningApp, enricher: enricher)

        if format == "compact" {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(result.success),
                "app": AnyCodable(runningApp.localizedName ?? "Unknown"),
                "action": AnyCodable(action),
                "error": AnyCodable(result.error as Any),
            ]
            print(CompactFormatter.formatActResult(data: output))
        } else {
            try JSONOutput.print(result, pretty: pretty)
        }
        if !result.success { throw ExitCode.failure }
    }
}

// MARK: - open

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open/launch an application by name or bundle ID"
    )

    @Argument(help: "App name (e.g., 'Safari', 'Obsidian') or bundle ID (e.g., 'md.obsidian')")
    var app: String

    @Option(name: .long, help: "URL or file to open with the app")
    var url: String?

    @Flag(name: .long, help: "Wait for app to launch before returning")
    var wait: Bool = false

    func run() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var args = ["-a", app]
        if wait { args.insert("-W", at: 0) }
        if let urlStr = url { args.append(urlStr) }
        process.arguments = args

        let errPipe = Foundation.Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            fputs("Error: \(errorStr)", stderr)
            throw ExitCode.failure
        }

        Thread.sleep(forTimeInterval: 1.0)

        let workspace = NSWorkspace.shared
        let runningApp = workspace.runningApplications.first {
            $0.localizedName?.lowercased().contains(app.lowercased()) ?? false
            || $0.bundleIdentifier?.lowercased() == app.lowercased()
        }

        let result: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "app": AnyCodable(runningApp?.localizedName ?? app),
            "pid": AnyCodable(runningApp?.processIdentifier ?? 0),
            "bundleId": AnyCodable(runningApp?.bundleIdentifier ?? ""),
        ]
        try JSONOutput.print(result, pretty: false)
    }
}

// MARK: - focus

struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bring an app to the front / activate it"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    func run() throws {
        guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
            throw ExitCode.failure
        }

        runningApp.activate()

        let axApp = AXBridge.appElement(for: runningApp)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef) == .success {
            AXUIElementPerformAction(windowRef as! AXUIElement, kAXRaiseAction as CFString)
        }

        let result: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "app": AnyCodable(runningApp.localizedName ?? "Unknown"),
            "pid": AnyCodable(runningApp.processIdentifier),
        ]
        try JSONOutput.print(result, pretty: false)
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore Electron app windows via CDP (e.g., reopen Obsidian vault)"
    )

    @Argument(help: "App name (default: Obsidian)")
    var app: String = "Obsidian"

    @Option(name: .long, help: "CDP remote debugging port (default: 9222)")
    var port: Int = 9222

    @Option(name: .long, help: "Vault name to open (default: first available)")
    var vault: String?

    @Flag(name: .long, help: "Launch app if not running")
    var launch: Bool = false

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let workspace = NSWorkspace.shared

        var runningApp = workspace.runningApplications.first {
            $0.localizedName?.lowercased().contains(app.lowercased()) ?? false
        }

        if runningApp == nil {
            if launch {
                fputs("App '\(app)' not running. Launching with CDP on port \(port)...\n", stderr)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", app, "--args", "--remote-debugging-port=\(port)"]
                try proc.run()
                proc.waitUntilExit()

                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1.0)
                    runningApp = workspace.runningApplications.first {
                        $0.localizedName?.lowercased().contains(app.lowercased()) ?? false
                    }
                    if runningApp != nil { break }
                }

                guard runningApp != nil else {
                    fputs("Error: Failed to launch '\(app)'\n", stderr)
                    throw ExitCode.failure
                }
            } else {
                fputs("Error: '\(app)' is not running. Use --launch to start it.\n", stderr)
                throw ExitCode.failure
            }
        }

        fputs("Found \(runningApp!.localizedName ?? app) (pid \(runningApp!.processIdentifier))\n", stderr)

        let cdp = CDPHelper(port: port)

        var pages: [CDPHelper.PageInfo] = []
        for attempt in 1...5 {
            do {
                pages = try cdp.listPages()
                if !pages.isEmpty { break }
            } catch {
                if attempt == 5 {
                    fputs("Error: Cannot connect to CDP on port \(port).\n", stderr)
                    throw ExitCode.failure
                }
                fputs("CDP not ready, retrying (\(attempt)/5)...\n", stderr)
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        guard let page = pages.first else {
            fputs("Error: No CDP pages found\n", stderr)
            throw ExitCode.failure
        }

        fputs("CDP page: \(page.title) → \(page.url)\n", stderr)

        if page.url.contains("starter.html") {
            fputs("On vault picker. Attempting to open vault...\n", stderr)

            guard let wsUrl = page.webSocketDebuggerUrl else {
                fputs("Error: No websocket URL available\n", stderr)
                throw ExitCode.failure
            }

            let selector: String
            if let vaultName = vault {
                selector = "document.querySelector('.recent-vaults-list-item-name')?.closest('.recent-vaults-list-item')?.click() || document.querySelectorAll('.recent-vaults-list-item').forEach(el => { if (el.textContent.includes('\(vaultName)')) el.click() })"
            } else {
                selector = "document.querySelector('.recent-vaults-list-item').click()"
            }

            _ = try cdp.evaluate(pageWsUrl: wsUrl, expression: selector)
            fputs("Clicked vault. Waiting for load...\n", stderr)

            Thread.sleep(forTimeInterval: 3.0)

            let newPages = try cdp.listPages()
            let mainPage = newPages.first { !$0.url.contains("starter.html") } ?? newPages.first
            let success = mainPage != nil && !mainPage!.url.contains("starter.html")

            let result: [String: AnyCodable] = [
                "success": AnyCodable(success),
                "app": AnyCodable(runningApp!.localizedName ?? app),
                "pid": AnyCodable(runningApp!.processIdentifier),
                "action": AnyCodable("vault_opened"),
                "page_url": AnyCodable(mainPage?.url ?? "unknown"),
                "page_title": AnyCodable(mainPage?.title ?? "unknown"),
            ]
            try JSONOutput.print(result, pretty: pretty)
        } else {
            fputs("Already in vault, no restore needed.\n", stderr)
            let result: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(runningApp!.localizedName ?? app),
                "pid": AnyCodable(runningApp!.processIdentifier),
                "action": AnyCodable("already_open"),
                "page_url": AnyCodable(page.url),
                "page_title": AnyCodable(page.title),
            ]
            try JSONOutput.print(result, pretty: pretty)
        }
    }
}

// MARK: - pipe

struct Pipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Snapshot + fuzzy match + act in one call (~200ms total)"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Argument(help: "Action: click, fill, read, eval, script")
    var action: String

    @Option(name: .long, help: "Fuzzy match string for element label/role/value")
    var match: String?

    @Option(name: .long, help: "Value for fill action")
    var value: String?

    @Option(name: .long, help: "JavaScript expression for eval/script actions")
    var expr: String?

    @Option(name: .long, help: "CDP port (default: 9222)")
    var port: Int = 9222

    @Option(name: .long, help: "Timeout in seconds for script action (default: 3)")
    var timeout: Int = 3

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Include full snapshot in output")
    var includeSnapshot: Bool = false

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Try daemon
        do {
            var params: [String: AnyCodable] = [
                "action": AnyCodable(action),
            ]
            if let app = app { params["app"] = AnyCodable(app) }
            if let pid = pid { params["pid"] = AnyCodable(Int(pid)) }
            if let match = match { params["match"] = AnyCodable(match) }
            if let value = value { params["value"] = AnyCodable(value) }
            if let expr = expr { params["expr"] = AnyCodable(expr) }
            params["port"] = AnyCodable(port)
            params["timeout"] = AnyCodable(timeout)
            let response = try callDaemon(method: "pipe", params: params)
            try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
                CompactFormatter.formatActResult(data: dict)
            }
            return
        } catch {}

        // Fallback: direct
        if action.lowercased() == "eval" || action.lowercased() == "script" {
            var actCmd = Act()
            actCmd.app = app
            actCmd.action = action
            actCmd.expr = expr
            actCmd.port = port
            actCmd.timeout = timeout
            actCmd.pid = pid
            actCmd.format = format
            actCmd.pretty = pretty
            try actCmd.run()
            return
        }

        guard AXBridge.checkAccessibilityPermission() else {
            fputs("Error: Accessibility permission not granted.\n", stderr)
            AXBridge.requestPermission()
            throw ExitCode.failure
        }

        guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
            throw ExitCode.failure
        }

        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, refMap: refMap)

        guard let matchStr = match else {
            fputs("Error: --match is required for pipe \(action)\n", stderr)
            throw ExitCode.failure
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
            let output: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "error": AnyCodable("No element matching '\(matchStr)' found."),
                "app": AnyCodable(snapshot.app),
            ]
            if format == "compact" {
                print(CompactFormatter.formatActResult(data: output))
            } else {
                try JSONOutput.print(output, pretty: pretty)
            }
            throw ExitCode.failure
        }

        if action.lowercased() == "read" {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(snapshot.app),
                "action": AnyCodable("read"),
                "matched_ref": AnyCodable(matched.ref),
                "matched_label": AnyCodable(matched.label),
                "match_score": AnyCodable(matched.score),
            ]
            if format == "compact" {
                print(CompactFormatter.formatActResult(data: output))
            } else {
                try JSONOutput.print(output, pretty: pretty)
            }
            return
        }

        guard let actionType = ActionExecutor.ActionType(rawValue: action.lowercased()) else {
            fputs("Error: Unknown action '\(action)'\n", stderr)
            throw ExitCode.failure
        }

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(action: actionType, ref: matched.ref, value: value, on: runningApp, enricher: enricher)

        var output: [String: AnyCodable] = [
            "success": AnyCodable(result.success),
            "app": AnyCodable(snapshot.app),
            "action": AnyCodable(action),
            "matched_ref": AnyCodable(matched.ref),
            "matched_label": AnyCodable(matched.label),
            "match_score": AnyCodable(matched.score),
        ]
        if let err = result.error {
            output["error"] = AnyCodable(err)
        }
        if format == "compact" {
            print(CompactFormatter.formatActResult(data: output))
        } else {
            try JSONOutput.print(output, pretty: pretty)
        }
        if !result.success { throw ExitCode.failure }
    }

    private func fuzzyScore(needle: String, element: Element, sectionLabel: String?) -> Int {
        var score = 0
        let label = (element.label ?? "").lowercased()
        let role = element.role.lowercased()
        let valStr: String = {
            guard let val = element.value?.value else { return "" }
            if let s = val as? String { return s }
            return "\(val)"
        }().lowercased()
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
}

// MARK: - watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream events from the daemon as JSONL (one event per line)"
    )

    @Option(name: .long, help: "Filter events by app name (partial match)")
    var app: String?

    @Option(name: .long, help: "Filter by event types (comma-separated, e.g. app.launched,ax.focus_changed)")
    var types: String?

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let app = app { params["app"] = AnyCodable(app) }
        if let types = types { params["types"] = AnyCodable(types) }

        try DaemonClient.stream(params: params)
    }
}

// MARK: - web

struct Web: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Safari web automation commands",
        subcommands: [WebTabs.self, WebNavigate.self, WebSnapshot.self, WebClick.self, WebFill.self, WebExtract.self, WebTab.self]
    )
}

struct WebTabs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tabs", abstract: "List all open Safari tabs")

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "web.tabs")
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebTabs(data: dict)
        }
    }
}

struct WebNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "navigate", abstract: "Navigate Safari to a URL")

    @Argument(help: "URL to navigate to")
    var url: String

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = ["url": AnyCodable(url)]
        let response = try callDaemon(method: "web.navigate", params: params)
        try printResponse(response, pretty: pretty)
    }
}

struct WebSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Semantic snapshot of the current Safari page")

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Option(name: .long, help: "Continue from cursor position (link offset)")
    var after: String?

    @Option(name: .long, help: "Max links per page (default: 15)")
    var limit: Int = PaginationDefaults.webSnapshotLimit

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "web.snapshot")
        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = response.result, let dict = result.value as? [String: AnyCodable] else {
            if format == "compact" { print("(empty)") } else { print("{}") }
            return
        }

        let pagParams = PaginationParams(after: after, limit: limit)
        let (paginated, pagResult) = Paginator.paginateWebSnapshot(dict, params: pagParams)

        if format == "compact" {
            print(CompactFormatter.formatWebSnapshot(data: paginated, pagination: pagResult))
        } else {
            var output = paginated
            for (k, v) in pagResult.jsonDict { output[k] = v }
            let enc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
            let data = try enc.encode(AnyCodable(output))
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

struct WebClick: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click a web element by fuzzy match")

    @Argument(help: "Text to fuzzy match (button text, link text, aria-label)")
    var match: String

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = ["match": AnyCodable(match)]
        let response = try callDaemon(method: "web.click", params: params)
        try printResponse(response, pretty: pretty)
    }
}

struct WebFill: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fill", abstract: "Fill a form field by fuzzy match")

    @Argument(help: "Field to match (placeholder, label, name, id)")
    var match: String

    @Option(name: .long, help: "Value to fill")
    var value: String

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = [
            "match": AnyCodable(match),
            "value": AnyCodable(value),
        ]
        let response = try callDaemon(method: "web.fill", params: params)
        try printResponse(response, pretty: pretty)
    }
}

struct WebExtract: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "extract", abstract: "Extract page content as markdown")

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Option(name: .long, help: "Continue from cursor position (char offset)")
    var after: String?

    @Option(name: .long, help: "Max chars per chunk (default: 2000)")
    var limit: Int = PaginationDefaults.webExtractLimit

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "web.extract")
        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = response.result, let dict = result.value as? [String: AnyCodable] else {
            if format == "compact" { print("(empty)") } else { print("{}") }
            return
        }

        let pagParams = PaginationParams(after: after, limit: limit)
        let (paginated, pagResult) = Paginator.paginateWebExtract(dict, params: pagParams)

        if format == "compact" {
            print(CompactFormatter.formatWebExtract(data: paginated, pagination: pagResult))
        } else {
            var output = paginated
            for (k, v) in pagResult.jsonDict { output[k] = v }
            let enc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
            let data = try enc.encode(AnyCodable(output))
            print(String(data: data, encoding: .utf8)!)
        }
    }
}

struct WebTab: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tab", abstract: "Switch to a Safari tab by fuzzy match")

    @Argument(help: "Tab title or URL to match")
    var match: String

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = ["match": AnyCodable(match)]
        let response = try callDaemon(method: "web.switchTab", params: params)
        try printResponse(response, pretty: pretty)
    }
}

// MARK: - screenshot

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a window screenshot of an application"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String

    @Option(name: .long, help: "Output file path (default: /tmp/agentview-screenshot-<app>-<timestamp>.png)")
    var output: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Try daemon first
        do {
            var params: [String: AnyCodable] = ["app": AnyCodable(app)]
            if let output = output { params["output"] = AnyCodable(output) }
            let response = try callDaemon(method: "screenshot", params: params)
            try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
                CompactFormatter.formatScreenshotDict(data: dict)
            }
            return
        } catch {}

        // Fallback: direct
        let result = ScreenCapture.capture(appName: app, outputPath: output)
        if format == "compact" {
            print(CompactFormatter.formatScreenshot(data: result))
        } else {
            try JSONOutput.print(result, pretty: pretty)
        }
        if !result.success { throw ExitCode.failure }
    }
}

// MARK: - process

struct ProcessCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Monitor running processes and parse their output into structured events",
        subcommands: [ProcessWatch.self, ProcessUnwatch.self, ProcessList.self]
    )
}

struct ProcessWatch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Attach to a process and emit structured events from its output")

    @Argument(help: "Process ID to watch")
    var pid: Int32

    @Option(name: .long, help: "Path to log file to tail (instead of stdout/stderr)")
    var log: String?

    @Option(name: .long, help: "Idle timeout in seconds (default: 300)")
    var idleTimeout: Int = 300

    @Flag(name: .long, help: "Output events as NDJSON (one JSON object per line)")
    var json: Bool = false

    @Flag(name: .long, help: "Stream events via daemon (for subscribers to receive)")
    var stream: Bool = false

    func run() throws {
        // Register watch via daemon
        var params: [String: AnyCodable] = [
            "pid": AnyCodable(Int(pid)),
            "idle_timeout": AnyCodable(idleTimeout),
        ]
        if let log = log { params["log"] = AnyCodable(log) }

        let response = try callDaemon(method: "process.watch", params: params)

        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }

        if json || stream {
            // Stream events filtered to this PID's process.* events
            let streamParams: [String: AnyCodable] = [
                "types": AnyCodable("process.tool_start,process.tool_end,process.message,process.error,process.idle,process.exit"),
            ]
            try DaemonClient.stream(params: streamParams)
        } else {
            // Print confirmation and exit
            let enc = JSONOutput.encoder
            if let result = response.result {
                let data = try enc.encode(result)
                print(String(data: data, encoding: .utf8)!)
            }
        }
    }
}

struct ProcessUnwatch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unwatch", abstract: "Stop watching a process")

    @Argument(help: "Process ID to stop watching")
    var pid: Int32

    func run() throws {
        let params: [String: AnyCodable] = ["pid": AnyCodable(Int(pid))]
        let response = try callDaemon(method: "process.unwatch", params: params)
        try printResponse(response, pretty: false)
    }
}

struct ProcessList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List currently watched processes")

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "process.list")
        try printResponse(response, pretty: pretty)
    }
}
