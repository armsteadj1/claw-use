import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import Network
import CUACore

@main
struct CUA: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cua",
        abstract: "Allowing claws to make better use of any application.",
        version: "0.3.0",
        subcommands: [List.self, Raw.self, Snapshot.self, Act.self, Open.self, Focus.self, Restore.self, Pipe.self, Wait.self, Assert.self, Daemon.self, Status.self, Web.self, Screenshot.self, ProcessCmd.self, MilestonesCmd.self, RemoteCmd.self, RemoteSenderDaemon.self]
    )
}

// MARK: - Helper: route through daemon or fallback to direct

/// Try daemon first; if unavailable, run directly via CUACore
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
        abstract: "Manage the cuad daemon",
        subcommands: [DaemonStart.self, DaemonStop.self, DaemonStatus.self, DaemonHealth.self, DaemonInstall.self, DaemonUninstall.self]
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

struct DaemonHealth: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "health", abstract: "Health check: uptime, last snapshot, connections, restarts")

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "health")
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            var lines: [String] = ["Daemon Health"]
            lines.append("──────────────────────────────────────────")
            let status = dict["status"]?.value as? String ?? "unknown"
            let pid = dict["pid"]?.value as? Int ?? 0
            let uptime = dict["uptime_s"]?.value as? Int ?? 0
            let connections = dict["connection_count"]?.value as? Int ?? 0
            let restarts = dict["restart_count"]?.value as? Int ?? 0
            let lastSnapshot = dict["last_snapshot_at"]?.value as? String ?? "(none)"

            let hours = uptime / 3600
            let mins = (uptime % 3600) / 60
            let secs = uptime % 60
            let uptimeStr = hours > 0 ? "\(hours)h \(mins)m \(secs)s" : mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"

            lines.append("  status:         \(status)")
            lines.append("  pid:            \(pid)")
            lines.append("  uptime:         \(uptimeStr)")
            lines.append("  last snapshot:  \(lastSnapshot)")
            lines.append("  connections:    \(connections)")
            lines.append("  restarts:       \(restarts)")
            return lines.joined(separator: "\n")
        }
    }
}

struct DaemonInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install launchd plist for persistent daemon (KeepAlive)")

    func run() throws {
        let daemonPath = try DaemonClient.resolveDaemonBinary()

        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clawuse.cuad.plist"
        let logPath = NSHomeDirectory() + "/.cua/cuad.log"

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.clawuse.cuad</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """

        // Ensure LaunchAgents directory exists
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let fm = FileManager.default
        if !fm.fileExists(atPath: launchAgentsDir) {
            try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        }

        // Stop existing daemon if running via CLI (so launchd takes over)
        if DaemonClient.isDaemonRunning() {
            _ = DaemonClient.stopDaemon()
            Thread.sleep(forTimeInterval: 0.5)
        }

        try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath]
        let errPipe = Foundation.Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("{\"status\":\"installed\",\"plist\":\"\(plistPath)\",\"daemon\":\"\(daemonPath)\"}")
        } else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            fputs("Error: launchctl load failed: \(errStr)\n", stderr)
            throw ExitCode.failure
        }
    }
}

struct DaemonUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstall launchd plist and stop persistent daemon")

    func run() throws {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.clawuse.cuad.plist"
        let fm = FileManager.default

        guard fm.fileExists(atPath: plistPath) else {
            print("{\"status\":\"not_installed\"}")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath]
        try process.run()
        process.waitUntilExit()

        try? fm.removeItem(atPath: plistPath)

        print("{\"status\":\"uninstalled\"}")
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

    @Flag(name: .long, help: "Enable stable refs: elements keep the same ref across consecutive snapshots (tracked by AX identifier or role+label fingerprint; disappeared refs tombstoned for 60 s)")
    var stableRefs: Bool = false

    func run() throws {
        // Try daemon
        do {
            var params: [String: AnyCodable] = [:]
            if let app = app { params["app"] = AnyCodable(app) }
            if let pid = pid { params["pid"] = AnyCodable(Int(pid)) }
            params["depth"] = AnyCodable(depth)
            if stableRefs { params["stable_refs"] = AnyCodable(true) }
            let response = try callDaemon(method: "snapshot", params: params)

            if let error = response.error {
                fputs("Error: \(error.message)\n", stderr)
                throw ExitCode.failure
            }

            guard let result = response.result else {
                print("(empty)")
                return
            }

            let enc = JSONOutput.encoder
            let data = try enc.encode(result)

            // Try to decode as AppSnapshot (AX result)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let snapshot = try? decoder.decode(AppSnapshot.self, from: data),
               snapshot.stats.enrichedElements > 0 || !snapshot.content.sections.isEmpty {
                // Valid AX snapshot with content
                if format == "compact" {
                    let pagParams = PaginationParams(after: after, limit: limit)
                    let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)
                    print(CompactFormatter.formatSnapshot(snapshot: paginated, pagination: pagResult))
                } else {
                    let pagParams = PaginationParams(after: after, limit: limit)
                    let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)
                    let outEnc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
                    var snapshotData = try outEnc.encode(paginated)
                    if var dict = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] {
                        dict["truncated"] = pagResult.hasMore
                        dict["total"] = pagResult.total
                        dict["returned"] = pagResult.returned
                        if let cursor = pagResult.cursor { dict["cursor"] = cursor }
                        snapshotData = try JSONSerialization.data(withJSONObject: dict, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
                    }
                    print(String(data: snapshotData, encoding: .utf8)!)
                }
            } else {
                // Fallback: might be a Safari web snapshot or empty AX snapshot
                // Check if it has web snapshot fields (pageType, links, etc.)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   dict["pageType"] != nil || dict["links"] != nil {
                    // This is a Safari web snapshot returned as fallback
                    if format == "compact" {
                        if let resultDict = result.value as? [String: AnyCodable] {
                            print(CompactFormatter.formatWebSnapshot(data: resultDict))
                        } else {
                            print(String(data: data, encoding: .utf8)!)
                        }
                    } else {
                        let outEnc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
                        print(String(data: try outEnc.encode(result), encoding: .utf8)!)
                    }
                } else {
                    // Empty AX snapshot with no fallback available
                    if format == "compact" {
                        if let snapshot = try? decoder.decode(AppSnapshot.self, from: data) {
                            let pagParams = PaginationParams(after: after, limit: limit)
                            let (paginated, pagResult) = Paginator.paginateSnapshot(snapshot, params: pagParams)
                            print(CompactFormatter.formatSnapshot(snapshot: paginated, pagination: pagResult))
                        } else {
                            print(String(data: data, encoding: .utf8)!)
                        }
                    } else {
                        let outEnc = pretty ? JSONOutput.prettyEncoder : JSONOutput.encoder
                        print(String(data: try outEnc.encode(result), encoding: .utf8)!)
                    }
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

    @Argument(help: "Action: click, focus, fill, clear, toggle, select, select-row, eval, script")
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

    @Option(name: .long, help: "Coordinate click: x,y (e.g., --at 150,350)")
    var at: String?

    @Flag(name: .long, help: "Treat --at coordinates as window-relative")
    var relative: Bool = false

    @Option(name: .long, help: "Row index for select-row action")
    var index: Int?

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // Handle coordinate click (#2)
        if let coords = at {
            let parts = coords.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else {
                fputs("Error: --at requires x,y format (e.g., --at 150,350)\n", stderr)
                throw ExitCode.failure
            }
            let x = parts[0], y = parts[1]

            if relative {
                guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
                    throw ExitCode.failure
                }
                let result = ActionExecutor.clickAtRelativeCoordinate(x: x, y: y, app: runningApp)
                let output: [String: AnyCodable] = [
                    "success": AnyCodable(result.success),
                    "app": AnyCodable(runningApp.localizedName ?? "Unknown"),
                    "action": AnyCodable("click"),
                    "at": AnyCodable("\(x),\(y)"),
                    "relative": AnyCodable(true),
                    "error": AnyCodable(result.error as Any),
                ]
                if format == "compact" {
                    print(CompactFormatter.formatActResult(data: output))
                } else {
                    try JSONOutput.print(output, pretty: pretty)
                }
                if !result.success { throw ExitCode.failure }
                return
            } else {
                let result = ActionExecutor.clickAtCoordinate(x: x, y: y)
                let output: [String: AnyCodable] = [
                    "success": AnyCodable(result.success),
                    "action": AnyCodable("click"),
                    "at": AnyCodable("\(x),\(y)"),
                    "error": AnyCodable(result.error as Any),
                ]
                if format == "compact" {
                    print(CompactFormatter.formatActResult(data: output))
                } else {
                    try JSONOutput.print(output, pretty: pretty)
                }
                if !result.success { throw ExitCode.failure }
                return
            }
        }

        // Handle select-row action (#7)
        if action.lowercased() == "select-row" {
            guard let rowIndex = index else {
                fputs("Error: select-row requires --index\n", stderr)
                throw ExitCode.failure
            }
            guard let runningApp = AXBridge.resolveApp(name: app, pid: pid) else {
                throw ExitCode.failure
            }
            let result = ActionExecutor.selectRowByIndex(index: rowIndex, app: runningApp)
            let output: [String: AnyCodable] = [
                "success": AnyCodable(result.success),
                "app": AnyCodable(runningApp.localizedName ?? "Unknown"),
                "action": AnyCodable("select-row"),
                "index": AnyCodable(rowIndex),
                "error": AnyCodable(result.error as Any),
            ]
            if format == "compact" {
                print(CompactFormatter.formatActResult(data: output))
            } else {
                try JSONOutput.print(output, pretty: pretty)
            }
            if !result.success { throw ExitCode.failure }
            return
        }

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
        abstract: "Open/launch an application by name, bundle ID, or file path"
    )

    @Argument(help: "App name, bundle ID, or path to .app bundle or executable")
    var app: String

    @Argument(help: "Additional arguments passed to the binary (only for direct path launches)")
    var extraArgs: [String] = []

    @Option(name: .long, help: "URL or file to open with the app (registry launches only)")
    var url: String?

    @Flag(name: .long, help: "Wait for app to launch/exit before returning")
    var wait: Bool = false

    func run() throws {
        // Detect if app is a file path
        let isPath = app.hasPrefix("/") || app.hasPrefix("./") || app.hasPrefix("~")
        let resolvedPath = isPath ? (app as NSString).expandingTildeInPath : app

        if isPath {
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                fputs("Error: File not found: \(resolvedPath)\n", stderr)
                throw ExitCode.failure
            }
            do {
                let launched = try PathLauncher.launch(
                    path: resolvedPath,
                    extraArgs: extraArgs,
                    wait: wait
                )
                let result: [String: AnyCodable] = [
                    "success": AnyCodable(true),
                    "app": AnyCodable(launched.app),
                    "pid": AnyCodable(launched.pid),
                    "bundleId": AnyCodable(launched.bundleId),
                    "path": AnyCodable(launched.path),
                ]
                try JSONOutput.print(result, pretty: false)
            } catch let e as PathLaunchError {
                fputs("Error: \(e.localizedDescription)\n", stderr)
                throw ExitCode.failure
            }
            return
        }

        // Standard app name / bundle ID launch via `open -a`
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

    @Flag(name: .long, help: "Fail if match confidence is below threshold")
    var strict: Bool = false

    @Option(name: .long, help: "Confidence threshold for --strict mode (0.0-1.0, default: 0.7)")
    var threshold: Double = 0.7

    @Flag(name: .long, help: "Show match details and runner-up matches")
    var verbose: Bool = false

    /// Normalize a raw fuzzy score to a 0-1 confidence value.
    private static func normalizeScore(_ raw: Int) -> Double {
        min(Double(raw) / 100.0, 1.0)
    }

    /// Ambiguity delta — top two scores within this range trigger a warning.
    private static let ambiguityDelta: Double = 0.1

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
            if strict { params["strict"] = AnyCodable(true) }
            if threshold != 0.7 { params["threshold"] = AnyCodable(threshold) }
            if verbose { params["verbose"] = AnyCodable(true) }
            let response = try callDaemon(method: "pipe", params: params)
            // In verbose mode, print extra match details to stderr before the normal output
            if verbose, let dict = response.result?.value as? [String: Any] {
                let label = dict["matched_label"] as? String ?? "?"
                let conf = dict["match_confidence"] as? Double ?? 0
                var msg = "matched \"\(label)\" (\(String(format: "%.2f", conf)))"
                if let runners = dict["runner_ups"] as? [[String: Any]], let first = runners.first {
                    let rLabel = first["label"] as? String ?? "?"
                    let rConf = first["confidence"] as? Double ?? 0
                    msg += ", runner-up: \"\(rLabel)\" (\(String(format: "%.2f", rConf)))"
                }
                fputs("\(msg)\n", stderr)
            }
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
        var allMatches: [(ref: String, score: Int, label: String)] = []

        for section in snapshot.content.sections {
            for element in section.elements {
                let score = fuzzyScore(needle: needle, element: element, sectionLabel: section.label)
                if score > 0 {
                    allMatches.append((ref: element.ref, score: score, label: element.label ?? element.role))
                }
            }
        }

        for inferredAction in snapshot.actions {
            if let ref = inferredAction.ref {
                let haystack = "\(inferredAction.name) \(inferredAction.description)".lowercased()
                if haystack.contains(needle) {
                    allMatches.append((ref: ref, score: 50, label: inferredAction.name))
                }
            }
        }

        // Sort by score descending
        allMatches.sort { $0.score > $1.score }

        guard let matched = allMatches.first else {
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

        let bestConfidence = Self.normalizeScore(matched.score)

        // Ambiguity detection
        var ambiguityWarning: String? = nil
        if allMatches.count >= 2 {
            let runnerConfidence = Self.normalizeScore(allMatches[1].score)
            if bestConfidence - runnerConfidence < Self.ambiguityDelta {
                ambiguityWarning = "ambiguous match: \"\(matched.label)\" (\(String(format: "%.2f", bestConfidence))) vs \"\(allMatches[1].label)\" (\(String(format: "%.2f", runnerConfidence)))"
            }
        }

        // Strict mode checks
        if strict {
            if bestConfidence < threshold {
                fputs("ERROR: strict mode: best match \"\(matched.label)\" confidence \(String(format: "%.2f", bestConfidence)) is below threshold \(String(format: "%.2f", threshold))\n", stderr)
                throw ExitCode.failure
            }
            if let warning = ambiguityWarning {
                fputs("ERROR: strict mode: \(warning), specify further\n", stderr)
                throw ExitCode.failure
            }
        }

        // Build runner-ups (top 5 excluding best)
        let runnerUps: [AnyCodable] = Array(allMatches.dropFirst().prefix(5)).map { m in
            AnyCodable([
                "ref": AnyCodable(m.ref),
                "label": AnyCodable(m.label),
                "score": AnyCodable(m.score),
                "confidence": AnyCodable(Self.normalizeScore(m.score)),
            ] as [String: AnyCodable])
        }

        // Verbose stderr output
        if verbose {
            var msg = "matched \"\(matched.label)\" (\(String(format: "%.2f", bestConfidence)))"
            if allMatches.count >= 2 {
                let r = allMatches[1]
                msg += ", runner-up: \"\(r.label)\" (\(String(format: "%.2f", Self.normalizeScore(r.score))))"
            }
            fputs("\(msg)\n", stderr)
        }

        // Helper to build output dictionary
        func buildOutput(success: Bool, actionName: String, error: String? = nil) -> [String: AnyCodable] {
            var out: [String: AnyCodable] = [
                "success": AnyCodable(success),
                "app": AnyCodable(snapshot.app),
                "action": AnyCodable(actionName),
                "matched_ref": AnyCodable(matched.ref),
                "matched_label": AnyCodable(matched.label),
                "match_score": AnyCodable(matched.score),
                "match_confidence": AnyCodable(bestConfidence),
            ]
            if let warning = ambiguityWarning {
                out["ambiguity_warning"] = AnyCodable(warning)
            }
            if verbose || !runnerUps.isEmpty {
                out["runner_ups"] = AnyCodable(runnerUps)
            }
            if let err = error {
                out["error"] = AnyCodable(err)
            }
            return out
        }

        if action.lowercased() == "read" {
            let output = buildOutput(success: true, actionName: "read")
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

        let output = buildOutput(success: result.success, actionName: action, error: result.error)
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

// MARK: - wait (#3)

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Poll until an element appears in an app's UI"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Option(name: .long, help: "Wait for element matching this string to appear")
    var match: String?

    @Option(name: .long, help: "Wait for element matching this string to disappear")
    var matchGone: String?

    @Option(name: .long, help: "Timeout in seconds (default: 10)")
    var timeout: Double = 10

    @Option(name: .long, help: "Poll interval in milliseconds (default: 200)")
    var interval: Int = 200

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    func run() throws {
        guard match != nil || matchGone != nil else {
            fputs("Error: --match or --match-gone is required\n", stderr)
            throw ExitCode.failure
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

        if let matchStr = match {
            // Wait for element to appear
            let result = WaitEngine.wait(match: matchStr, timeout: timeout, intervalMs: interval) {
                let refMap = RefMap()
                return enricher.snapshot(app: runningApp, refMap: refMap)
            }
            if result.found {
                let ref = result.ref ?? "?"
                let elapsed = String(format: "%.1f", result.elapsedSeconds)
                print("\u{2713} found \"\(matchStr)\" [\(ref)] after \(elapsed)s")
            } else {
                print("\u{2717} timeout after \(timeout)s \u{2014} \"\(matchStr)\" not found")
                throw ExitCode.failure
            }
            return
        }

        if let goneStr = matchGone {
            // Wait for element to disappear — poll until fuzzy match returns nothing
            let start = Date()
            let deadline = start.addingTimeInterval(timeout)
            let intervalSec = Double(interval) / 1000.0
            let needle = goneStr.lowercased()
            var gone = false

            while Date() < deadline {
                let refMap = RefMap()
                let snapshot = enricher.snapshot(app: runningApp, refMap: refMap)
                let stillPresent = snapshot.content.sections.flatMap { $0.elements }.contains { el in
                    WaitEngine.fuzzyScore(needle: needle, element: el, sectionLabel: nil) > 0
                }
                if !stillPresent {
                    gone = true
                    break
                }
                Thread.sleep(forTimeInterval: intervalSec)
            }

            if gone {
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                print("\u{2713} gone \"\(goneStr)\" after \(elapsed)s")
            } else {
                print("\u{2717} timeout after \(timeout)s \u{2014} \"\(goneStr)\" still present")
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - assert (#6)

struct Assert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check if an element exists in an app's UI (exits 0 if found, 1 if not)"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String?

    @Option(name: .long, help: "Element text to search for")
    var match: String

    @Option(name: .long, help: "App PID")
    var pid: Int32?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    func run() throws {
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
        let allElements = snapshot.content.sections.flatMap { $0.elements }

        let needle = match.lowercased()
        let found = allElements.contains { el in
            let label = (el.label ?? "").lowercased()
            let valStr = (el.value?.value as? String ?? "").lowercased()
            let role = el.role.lowercased()
            return label.contains(needle) || valStr.contains(needle) || role.contains(needle)
        }

        if format == "json" {
            let output: [String: AnyCodable] = [
                "found": AnyCodable(found),
                "match": AnyCodable(match),
                "app": AnyCodable(snapshot.app),
            ]
            try JSONOutput.print(output, pretty: false)
        } else {
            if found {
                print("assert: \"\(match)\" found in \(snapshot.app)")
            } else {
                print("assert: \"\(match)\" NOT found in \(snapshot.app)")
            }
        }

        if !found { throw ExitCode.failure }
    }
}

// MARK: - web

struct Web: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Browser web automation commands (Safari, Chrome, auto-detect)",
        subcommands: [WebTabs.self, WebNavigate.self, WebSnapshot.self, WebClick.self, WebFill.self, WebExtract.self, WebTab.self, WebEval.self]
    )
}

struct WebTabs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tabs", abstract: "List all open browser tabs")

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.tabs", params: params.isEmpty ? nil : params)
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebTabs(data: dict)
        }
    }
}

struct WebNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "navigate", abstract: "Navigate browser to a URL")

    @Argument(help: "URL to navigate to")
    var url: String

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = ["url": AnyCodable(url)]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.navigate", params: params)
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebNavigate(data: dict)
        }
    }
}

struct WebSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Semantic snapshot of the current browser page")

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Option(name: .long, help: "Continue from cursor position (link offset)")
    var after: String?

    @Option(name: .long, help: "Max links per page (default: 15)")
    var limit: Int = PaginationDefaults.webSnapshotLimit

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.snapshot", params: params.isEmpty ? nil : params)
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

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = ["match": AnyCodable(match)]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.click", params: params)
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebClick(data: dict)
        }
    }
}

struct WebFill: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fill", abstract: "Fill a form field by fuzzy match")

    @Argument(help: "Field to match (placeholder, label, name, id)")
    var match: String

    @Option(name: .long, help: "Value to fill")
    var value: String

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [
            "match": AnyCodable(match),
            "value": AnyCodable(value),
        ]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.fill", params: params)
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebFill(data: dict)
        }
    }
}

struct WebExtract: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "extract", abstract: "Extract page content as markdown")

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Option(name: .long, help: "Continue from cursor position (char offset)")
    var after: String?

    @Option(name: .long, help: "Max chars per chunk (default: 2000)")
    var limit: Int = PaginationDefaults.webExtractLimit

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.extract", params: params.isEmpty ? nil : params)
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
    static let configuration = CommandConfiguration(commandName: "tab", abstract: "Switch to a browser tab by fuzzy match")

    @Argument(help: "Tab title or URL to match")
    var match: String

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "compact"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = ["match": AnyCodable(match)]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.switchTab", params: params)
        if format == "compact", let error = response.error {
            print("❌ \(error.message)")
            throw ExitCode.failure
        }
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebSwitchTab(data: dict)
        }
    }
}

struct WebEval: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "eval", abstract: "Execute JavaScript in the browser and return the result")

    @Argument(help: "JavaScript expression to evaluate")
    var expression: String

    @Option(name: .long, help: "Browser to use (safari, chrome). Auto-detects if omitted.")
    var browser: String?

    @Option(name: .long, help: "Timeout in seconds (default: 10)")
    var timeout: Int = 10

    @Option(name: .long, help: "Output format (compact or json)")
    var format: String = "json"

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [
            "expression": AnyCodable(expression),
            "timeout": AnyCodable(timeout),
        ]
        if let browser = browser { params["browser"] = AnyCodable(browser) }
        let response = try callDaemon(method: "web.eval", params: params)
        try printFormattedResponse(response, format: format, pretty: pretty) { dict, _ in
            CompactFormatter.formatWebEval(data: dict)
        }
    }
}

// MARK: - screenshot

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture a window screenshot of an application"
    )

    @Argument(help: "App name (partial match, case-insensitive)")
    var app: String

    @Option(name: .long, help: "Output file path (default: /tmp/cua-screenshot-<app>-<timestamp>.png)")
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
        subcommands: [ProcessWatch.self, ProcessUnwatch.self, ProcessList.self, ProcessGroupCmd.self]
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

    @Option(name: .long, help: "Milestone preset name or path to milestone YAML file")
    var milestones: String?

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
        if let milestones = milestones { params["milestones"] = AnyCodable(milestones) }

        let response = try callDaemon(method: "process.watch", params: params)

        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }

        if json || stream {
            // Stream events filtered to this PID's process.* events + milestones
            let streamParams: [String: AnyCodable] = [
                "types": AnyCodable("process.tool_start,process.tool_end,process.message,process.error,process.idle,process.exit,process.milestone"),
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

// MARK: - process group

struct ProcessGroupCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Multi-process dashboard for tracking parallel processes",
        subcommands: [ProcessGroupAdd.self, ProcessGroupRemove.self, ProcessGroupClear.self, ProcessGroupStatus.self]
    )
}

struct ProcessGroupAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Register a process to track")

    @Argument(help: "Process ID to track")
    var pid: Int32

    @Option(name: .long, help: "Label for this process (e.g. \"Issue #42: Add login\")")
    var label: String?

    @Option(name: .long, help: "Group name (default: \"default\")")
    var group: String = "default"

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = [
            "pid": AnyCodable(Int(pid)),
            "label": AnyCodable(label ?? "PID \(pid)"),
            "group": AnyCodable(group),
        ]
        let response = try callDaemon(method: "process.group.add", params: params)

        if json {
            try printResponse(response, pretty: false)
        } else {
            if let error = response.error {
                fputs("Error: \(error.message)\n", stderr)
                throw ExitCode.failure
            }
            print("Added process PID \(pid) (\(label ?? "PID \(pid)"))")
        }
    }
}

struct ProcessGroupRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop tracking a process")

    @Argument(help: "Process ID to stop tracking")
    var pid: Int32

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let params: [String: AnyCodable] = ["pid": AnyCodable(Int(pid))]
        let response = try callDaemon(method: "process.group.remove", params: params)

        if json {
            try printResponse(response, pretty: false)
        } else {
            if let error = response.error {
                fputs("Error: \(error.message)\n", stderr)
                throw ExitCode.failure
            }
            print("Removed process PID \(pid)")
        }
    }
}

struct ProcessGroupClear: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove all completed/exited processes")

    @Option(name: .long, help: "Group name (default: \"default\")")
    var group: String = "default"

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let response = try callDaemon(method: "process.group.clear")

        if json {
            try printResponse(response, pretty: false)
        } else {
            if let error = response.error {
                fputs("Error: \(error.message)\n", stderr)
                throw ExitCode.failure
            }
            if let result = response.result, let dict = result.value as? [String: AnyCodable] {
                let removed = dict["removed_count"]?.value as? Int ?? 0
                let remaining = dict["remaining_count"]?.value as? Int ?? 0
                print("Cleared \(removed) completed process\(removed == 1 ? "" : "es"), \(remaining) remaining")
            }
        }
    }
}

struct ProcessGroupStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show all tracked processes and their current state")

    @Option(name: .long, help: "Group name (default: \"default\")")
    var group: String = "default"

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let response = try callDaemon(method: "process.group.status")

        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }

        guard let result = response.result, let dict = result.value as? [String: AnyCodable] else {
            if json { print("{}") } else { print("Process Group Status (0 processes)") }
            return
        }

        if json {
            try printResponse(response, pretty: false)
            return
        }

        // Decode processes from response and format
        guard let processesArr = dict["processes"]?.value as? [AnyCodable] else {
            print(ProcessGroupManager.formatStatus(processes: []))
            return
        }

        let processes: [TrackedProcess] = processesArr.compactMap { item in
            guard let d = item.value as? [String: AnyCodable] else { return nil }
            let pid = (d["pid"]?.value as? Int).map { Int32($0) } ?? 0
            let label = d["label"]?.value as? String ?? ""
            let stateStr = d["state"]?.value as? String ?? "STARTING"
            let state = TrackedProcessState(rawValue: stateStr) ?? .starting

            var process = TrackedProcess(pid: pid, label: label)
            process.state = state
            process.lastEvent = d["last_event"]?.value as? String
            process.lastEventTime = d["last_event_time"]?.value as? String
            process.lastDetail = d["last_detail"]?.value as? String
            if let startedAt = d["started_at"]?.value as? String {
                process.startedAt = startedAt
            }
            if let exitCode = d["exit_code"]?.value as? Int {
                process.exitCode = exitCode
            }
            return process
        }

        print(ProcessGroupManager.formatStatus(processes: processes))
    }
}

// MARK: - milestones

struct MilestonesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "milestones",
        abstract: "Manage milestone definitions for process watching",
        subcommands: [MilestonesList.self, MilestonesValidate.self]
    )
}

struct MilestonesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available milestone presets")

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let available = MilestonePresets.listAvailable()

        if json {
            let encoded = available.map { item -> [String: AnyCodable] in
                [
                    "name": AnyCodable(item.name),
                    "description": AnyCodable(item.description),
                    "source": AnyCodable(item.source),
                ]
            }
            try JSONOutput.print(encoded.map { AnyCodable($0) }, pretty: false)
            return
        }

        print("Available Milestone Presets (\(available.count))")
        print("──────────────────────────────────────────")
        for item in available {
            let tag = item.source == "builtin" ? "[builtin]" : "[custom]"
            let nameStr = item.name.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("  \(nameStr) \(tag)  \(item.description)")
        }
        print("")
        print("Usage: cua process watch <PID> --log <FILE> --milestones <NAME>")
    }
}

struct MilestonesValidate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate a milestone definition file")

    @Argument(help: "Path to milestone YAML or JSON file, or preset name")
    var path: String

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let definition: MilestoneDefinition
        do {
            definition = try MilestonePresets.load(nameOrPath: path)
        } catch {
            if json {
                let output: [String: AnyCodable] = [
                    "valid": AnyCodable(false),
                    "error": AnyCodable("\(error)"),
                ]
                try JSONOutput.print(output, pretty: false)
            } else {
                fputs("Error: \(error)\n", stderr)
            }
            throw ExitCode.failure
        }

        let issues = MilestoneYAMLParser.validate(definition)
        let errors = issues.filter { $0.hasPrefix("error:") }
        let warnings = issues.filter { $0.hasPrefix("warning:") }
        let valid = errors.isEmpty

        if json {
            let output: [String: AnyCodable] = [
                "valid": AnyCodable(valid),
                "name": AnyCodable(definition.name),
                "description": AnyCodable(definition.description),
                "format": AnyCodable(definition.format.rawValue),
                "pattern_count": AnyCodable(definition.patterns.count),
                "errors": AnyCodable(errors.map { AnyCodable($0) }),
                "warnings": AnyCodable(warnings.map { AnyCodable($0) }),
            ]
            try JSONOutput.print(output, pretty: false)
        } else {
            if valid {
                print("Valid: \(definition.name)")
                print("  Description: \(definition.description)")
                print("  Format: \(definition.format.rawValue)")
                print("  Patterns: \(definition.patterns.count)")
                for pattern in definition.patterns {
                    let msg = pattern.message ?? pattern.messageTemplate ?? ""
                    print("    \(pattern.emoji) \(pattern.type) [\(pattern.dedupe.rawValue)] \(msg)")
                }
            } else {
                fputs("Invalid: \(definition.name)\n", stderr)
            }

            for issue in issues {
                let prefix = issue.hasPrefix("error:") ? "  [!]" : "  [~]"
                print("\(prefix) \(issue)")
            }
        }

        if !valid { throw ExitCode.failure }
    }
}

// MARK: - remote

struct RemoteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Push-based remote AX visibility (read-only, laptop → agent machine)",
        subcommands: [
            RemoteAccept.self,
            RemoteSend.self,
            RemoteStop.self,
            RemoteRevoke.self,
            RemoteSnapshot.self,
            RemoteHistory.self,
            RemoteList.self,
        ]
    )
}

// MARK: remote accept

struct RemoteAccept: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accept",
        abstract: "Start receiving AX snapshots from a paired laptop"
    )

    @Option(name: .long, help: "HTTP port to listen on")
    var port: Int = 9876

    @Option(name: .long, help: "Snapshot retention duration (e.g. 1d, 7d, 1h)")
    var retain: String = "1d"

    func run() throws {
        let params: [String: AnyCodable] = [
            "port":   AnyCodable(port),
            "retain": AnyCodable(retain),
        ]
        let response = try callDaemon(method: "remote.accept", params: params)
        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = response.result,
              let dict = result.value as? [String: AnyCodable] else {
            fputs("Error: unexpected response\n", stderr)
            throw ExitCode.failure
        }
        let url   = dict["pairing_url"]?.value as? String ?? ""
        let peerID = dict["peer_id"]?.value as? String ?? ""
        print("Remote accept ready. Run on your laptop:")
        print("")
        print("  cua remote send '\(url)'")
        print("")
        print("Pairing URL : \(url)")
        print("Peer ID     : \(peerID)")
        print("Port        : \(port)")
        print("Retention   : \(retain)")
    }
}

// MARK: remote send

struct RemoteSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Pair with a receiver and start pushing AX snapshots in the background"
    )

    @Argument(help: "Pairing URL printed by `cua remote accept`")
    var url: String

    @Option(name: .long, help: "Push interval (e.g. 5s, 10s)")
    var interval: String = "5s"

    func run() throws {
        // Parse cua:// URL by rewriting scheme so URLComponents handles it
        guard let components = URLComponents(string: url.replacingOccurrences(of: "cua://", with: "http://")),
              let host = components.host,
              let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
              let peerId = components.queryItems?.first(where: { $0.name == "peer" })?.value
        else {
            fputs("Error: invalid pairing URL (expected cua://<host>:<port>?key=...&peer=...&v=1)\n", stderr)
            throw ExitCode.failure
        }
        let port = components.port ?? 9876
        let intervalSeconds = RemoteConfig.parseDuration(interval)

        // Decode HMAC secret
        guard let secretData = Data(base64Encoded: key) else {
            fputs("Error: invalid base64 key in pairing URL\n", stderr)
            throw ExitCode.failure
        }

        // Compute HMAC for handshake: HMAC-SHA256(peerId:timestamp, secret)
        let timestamp = Int(Date().timeIntervalSince1970)
        let message   = "\(peerId):\(timestamp)"
        let hmacHex   = RemoteCrypto.hmacSHA256(message: message, secret: secretData)
        let peerName  = ProcessInfo.processInfo.hostName

        let handshakeBody: [String: Any] = [
            "peer_id":   peerId,
            "peer_name": peerName,
            "timestamp": timestamp,
            "hmac":      hmacHex,
        ]

        // POST /remote-handshake
        guard let sessionToken = performRemoteHandshake(host: host, port: port, body: handshakeBody) else {
            fputs("Error: handshake failed — check the pairing URL and that the receiver is running\n", stderr)
            throw ExitCode.failure
        }

        // Save sender state for the background daemon
        let stateDir = NSHomeDirectory() + "/.cua/remote"
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let statePath = stateDir + "/sender.json"
        let state = RemoteSenderState(
            host: host, port: port, peerId: peerId,
            sessionToken: sessionToken, intervalSeconds: intervalSeconds
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }

        // Stop any existing sender daemon
        let pidPath = stateDir + "/sender.pid"
        if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }

        // Fork background sender daemon (re-exec this binary with hidden subcommand)
        let cuaPath = CommandLine.arguments[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cuaPath)
        process.arguments = ["_remote-sender-daemon"]
        process.standardOutput = FileHandle.nullDevice
        process.standardInput  = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        try process.run()

        print("{\"status\":\"sending\",\"peer_id\":\"\(peerId)\",\"host\":\"\(host)\",\"port\":\(port),\"interval\":\(intervalSeconds)}")
    }
}

/// Perform the HMAC handshake against the receiver's HTTP server.
/// Returns the session token on success, nil on failure.
private func performRemoteHandshake(host: String, port: Int, body: [String: Any]) -> String? {
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
          let url = URL(string: "http://\(host):\(port)/remote-handshake") else { return nil }

    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod  = "POST"
    request.httpBody    = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let sem = DispatchSemaphore(value: 0)
    var result: String?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { sem.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["session_token"] as? String else { return }
        result = token
    }.resume()
    sem.wait()
    return result
}

/// Push a RemoteSnapshotRecord to the receiver's HTTP ingest endpoint.
private func pushRemoteSnapshot(_ record: RemoteSnapshotRecord, host: String, port: Int, sessionToken: String) -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let bodyData = try? encoder.encode(record),
          let url = URL(string: "http://\(host):\(port)/remote-ingest") else { return false }

    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod  = "POST"
    request.httpBody    = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

    let sem = DispatchSemaphore(value: 0)
    var success = false
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { sem.signal() }
        if let http = response as? HTTPURLResponse, http.statusCode == 200 { success = true }
    }.resume()
    sem.wait()
    return success
}

// MARK: remote stop

struct RemoteStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the background sender daemon"
    )

    func run() throws {
        let pidPath = NSHomeDirectory() + "/.cua/remote/sender.pid"
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("{\"status\":\"not_running\"}")
            return
        }
        if kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(atPath: pidPath)
            print("{\"status\":\"not_running\"}")
            return
        }
        kill(pid, SIGTERM)
        // Brief wait
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.1)
            if kill(pid, 0) != 0 { break }
        }
        try? FileManager.default.removeItem(atPath: pidPath)
        print("{\"status\":\"stopped\",\"pid\":\(pid)}")
    }
}

// MARK: remote revoke

struct RemoteRevoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke pairing and delete snapshots for a peer (receiver side)"
    )

    @Option(name: .long, help: "Peer ID to revoke (omit to revoke all)")
    var peer: String?

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let p = peer { params["peer"] = AnyCodable(p) }
        let response = try callDaemon(method: "remote.revoke", params: params)
        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = response.result else { print("{}"); return }
        let enc = JSONOutput.encoder
        let data = try enc.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}

// MARK: remote snapshot

struct RemoteSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Show the latest AX snapshot from a paired peer (receiver side)"
    )

    @Option(name: .long, help: "Peer ID (defaults to most-recently-seen peer)")
    var peer: String?

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let p = peer { params["peer"] = AnyCodable(p) }
        let response = try callDaemon(method: "remote.snapshot", params: params)
        try printResponse(response, pretty: pretty)
    }
}

// MARK: remote history

struct RemoteHistory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Query rolling snapshot history from a paired peer (receiver side)"
    )

    @Option(name: .long, help: "Peer ID (defaults to most-recently-seen peer)")
    var peer: String?

    @Option(name: .long, help: "Show snapshots from the last N (e.g. 1h, 30m)")
    var since: String?

    @Option(name: .long, help: "Filter to a specific app name")
    var app: String?

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        var params: [String: AnyCodable] = [:]
        if let p = peer  { params["peer"]  = AnyCodable(p) }
        if let s = since { params["since"] = AnyCodable(s) }
        if let a = app   { params["app"]   = AnyCodable(a) }
        let response = try callDaemon(method: "remote.history", params: params)
        try printResponse(response, pretty: pretty)
    }
}

// MARK: remote list

struct RemoteList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all paired peers with last-seen timestamp (receiver side)"
    )

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let response = try callDaemon(method: "remote.list")
        if let error = response.error {
            fputs("Error: \(error.message)\n", stderr)
            throw ExitCode.failure
        }
        guard let result = response.result,
              let dict = result.value as? [String: AnyCodable],
              let peers = dict["peers"]?.value as? [AnyCodable] else {
            print("No paired peers.")
            return
        }
        if pretty {
            try printResponse(response, pretty: true)
            return
        }
        if peers.isEmpty {
            print("No paired peers.")
            return
        }
        print("Paired Peers (\(peers.count))")
        print("──────────────────────────────────────────")
        for peer in peers {
            guard let p = peer.value as? [String: AnyCodable] else { continue }
            let id       = p["peer_id"]?.value  as? String ?? "?"
            let name     = p["name"]?.value     as? String ?? "?"
            let lastSeen = p["last_seen"]?.value as? String ?? "?"
            let idShort  = String(id.prefix(8))
            print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(idShort)  last: \(lastSeen)")
        }
    }
}

// MARK: - remote sender daemon (hidden, forked by `cua remote send`)

struct RemoteSenderDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_remote-sender-daemon",
        shouldDisplay: false
    )

    // Hard-blocked bundle IDs — no snapshot taken for these apps (delegated to RemoteScrubber)
    private static var blockedBundleIds: Set<String> { RemoteScrubber.blockedBundleIds }

    func run() throws {
        let stateDir  = NSHomeDirectory() + "/.cua/remote"
        let statePath = stateDir + "/sender.json"
        let pidPath   = stateDir + "/sender.pid"
        let logPath   = stateDir + "/sender.log"

        // Load saved pairing state
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let state = try? decoder.decode(RemoteSenderState.self, from: data) else {
            fputs("Error: no sender state at \(statePath)\n", stderr)
            throw ExitCode.failure
        }

        // Write PID file
        let myPID = ProcessInfo.processInfo.processIdentifier
        try? "\(myPID)".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // Open log file
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            fputs("Error: cannot open log at \(logPath)\n", stderr)
            throw ExitCode.failure
        }

        func slog(_ msg: String) {
            let ts   = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(msg)\n"
            logHandle.seekToEndOfFile()
            logHandle.write(Data(line.utf8))
        }

        slog("Sender daemon started — peer=\(state.peerId) host=\(state.host):\(state.port) interval=\(state.intervalSeconds)s")

        var retryDelay = TimeInterval(state.intervalSeconds)
        let peerName   = ProcessInfo.processInfo.hostName

        while true {
            do {
                // Get running app list from local cuad
                var appList: [String] = []
                if let listResp = try? DaemonClient.call(method: "list"),
                   let arr = listResp.result?.value as? [AnyCodable] {
                    appList = arr.compactMap { item -> String? in
                        guard let d = item.value as? [String: AnyCodable] else { return nil }
                        let name     = d["name"]?.value      as? String ?? ""
                        let bundleId = (d["bundle_id"]?.value as? String ?? "").lowercased()
                        if RemoteSenderDaemon.blockedBundleIds.contains(bundleId) { return nil }
                        return name
                    }
                }

                // Determine frontmost app
                var frontmostApp: (name: String, bundleId: String)?
                if let front = NSWorkspace.shared.frontmostApplication {
                    let bid = (front.bundleIdentifier ?? "").lowercased()
                    if !RemoteSenderDaemon.blockedBundleIds.contains(bid) {
                        frontmostApp = (front.localizedName ?? front.bundleIdentifier ?? "", bid)
                    }
                }

                guard let activeApp = frontmostApp, !activeApp.name.isEmpty else {
                    Thread.sleep(forTimeInterval: TimeInterval(state.intervalSeconds))
                    continue
                }

                // Get snapshot from local cuad
                let snapResp = try DaemonClient.call(
                    method: "snapshot",
                    params: ["app": AnyCodable(activeApp.name), "no_cache": AnyCodable(true)]
                )

                if let snapResult = snapResp.result {
                    let snapDecoder = JSONDecoder()
                    snapDecoder.keyDecodingStrategy = .convertFromSnakeCase
                    if let snapData = try? JSONOutput.encode(snapResult),
                       let snapshot = try? snapDecoder.decode(AppSnapshot.self, from: snapData) {

                        let scrubbed = RemoteScrubber.scrub(snapshot)
                        let record   = RemoteSnapshotRecord(
                            timestamp: Date(),
                            peerId:    state.peerId,
                            peerName:  peerName,
                            snapshot:  scrubbed,
                            appList:   appList
                        )

                        let ok = pushRemoteSnapshot(
                            record,
                            host: state.host,
                            port: state.port,
                            sessionToken: state.sessionToken
                        )
                        if ok {
                            retryDelay = TimeInterval(state.intervalSeconds)
                            slog("Pushed snapshot: app=\(activeApp.name)")
                        } else {
                            retryDelay = min(retryDelay * 2, 30)
                            slog("Push failed — retry in \(Int(retryDelay))s")
                        }
                    }
                }
            } catch {
                retryDelay = min(retryDelay * 2, 30)
                slog("Error: \(error) — retry in \(Int(retryDelay))s")
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }
    }

}
