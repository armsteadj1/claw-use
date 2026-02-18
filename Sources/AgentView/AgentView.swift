import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct AgentView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentview",
        abstract: "Read macOS Accessibility APIs and expose structured UI state to AI agents.",
        version: "0.1.0",
        subcommands: [List.self, Raw.self, Snapshot.self, Act.self, Open.self, Focus.self, Restore.self]
    )
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all running GUI apps"
    )

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let apps = AXBridge.listApps()
        try JSONOutput.print(apps, pretty: pretty)
    }
}

// MARK: - raw

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

        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, maxDepth: depth, refMap: refMap)
        try JSONOutput.print(snapshot, pretty: pretty)
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

    @Option(name: .long, help: "App PID")
    var pid: Int32?

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

        // Handle script action separately — uses AppleScript, no ref needed
        if action.lowercased() == "script" {
            guard let expression = expr else {
                fputs("Error: script action requires --expr\n", stderr)
                throw ExitCode.failure
            }
            let appName = runningApp.localizedName ?? "Unknown"
            let script: String
            if expression.lowercased().hasPrefix("tell application") {
                // User provided a full tell block — run as-is
                script = expression
            } else {
                // Wrap in tell application block
                script = "tell application \"\(appName)\"\n\(expression)\nend tell"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Run with a timeout
            try process.run()

            let deadline = DispatchTime.now() + .seconds(15)
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
                    "error": AnyCodable("AppleScript timed out after 15 seconds. The app may not support this operation (e.g., screen is locked)."),
                ]
                try JSONOutput.print(output, pretty: pretty)
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
                try JSONOutput.print(output, pretty: pretty)
                throw ExitCode.failure
            }

            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(appName),
                "pid": AnyCodable(runningApp.processIdentifier),
                "action": AnyCodable("script"),
                "result": AnyCodable(stdout),
            ]
            try JSONOutput.print(output, pretty: pretty)
            return
        }

        guard let actionType = ActionExecutor.ActionType(rawValue: action.lowercased()) else {
            fputs("Error: Unknown action '\(action)'. Valid actions: click, focus, fill, clear, toggle, select, eval, script\n", stderr)
            throw ExitCode.failure
        }

        // Handle eval action separately — uses CDP, no ref needed
        if actionType == .eval {
            guard let expression = expr else {
                fputs("Error: eval action requires --expr\n", stderr)
                throw ExitCode.failure
            }
            let cdp = CDPHelper(port: port)
            do {
                let pages = try cdp.listPages()
                guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
                    fputs("Error: No CDP pages found. Is the app running with --remote-debugging-port=\(port)?\n", stderr)
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
                try JSONOutput.print(output, pretty: pretty)
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

        // First, take a snapshot to build the ref map
        let enricher = Enricher()
        let refMap = RefMap()
        _ = enricher.snapshot(app: runningApp, refMap: refMap)

        // Execute the action
        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(
            action: actionType,
            ref: ref,
            value: value,
            on: runningApp,
            enricher: enricher
        )

        try JSONOutput.print(result, pretty: pretty)

        if !result.success {
            throw ExitCode.failure
        }
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
        // Use macOS `open` command — simple, reliable, handles everything
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var args = ["-a", app]
        if wait { args.insert("-W", at: 0) }
        if let urlStr = url { args.append(urlStr) }
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            fputs("Error: \(errorStr)", stderr)
            throw ExitCode.failure
        }

        // Wait a moment for app to register, then find it
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

        // Also raise the first window via AX
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
