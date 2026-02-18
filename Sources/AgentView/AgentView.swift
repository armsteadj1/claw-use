import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

@main
struct AgentView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentview",
        abstract: "Read macOS Accessibility APIs and expose structured UI state to AI agents.",
        version: "0.2.0",
        subcommands: [List.self, Raw.self, Snapshot.self, Act.self, Open.self, Focus.self, Restore.self, Pipe.self]
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

    @Option(name: .long, help: "Timeout in seconds for script action (default: 3)")
    var timeout: Int = 3

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

            let outPipe = Foundation.Pipe()
            let errPipe = Foundation.Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Run with a timeout
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
                    "error": AnyCodable("AppleScript timed out after \(timeoutSeconds)s. The app may not respond while the screen is locked."),
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

    @Flag(name: .long, help: "Include full snapshot in output")
    var includeSnapshot: Bool = false

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        // eval and script don't need AX or matching — fast path
        if action.lowercased() == "eval" || action.lowercased() == "script" {
            // Delegate to Act command
            var actCmd = Act()
            actCmd.app = app
            actCmd.action = action
            actCmd.expr = expr
            actCmd.port = port
            actCmd.timeout = timeout
            actCmd.pid = pid
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

        // Step 1: Snapshot (builds ref map)
        let enricher = Enricher()
        let refMap = RefMap()
        let snapshot = enricher.snapshot(app: runningApp, refMap: refMap)

        // Step 2: Fuzzy match
        guard let matchStr = match else {
            fputs("Error: --match is required for pipe \(action)\n", stderr)
            throw ExitCode.failure
        }

        let needle = matchStr.lowercased()
        var bestMatch: (ref: String, score: Int, label: String)?

        // Search through all sections and elements
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

        // Also check inferred actions
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
                "error": AnyCodable("No element matching '\(matchStr)' found. Available elements: \(snapshot.content.sections.flatMap { $0.elements }.map { "\($0.ref):\($0.label ?? $0.role)" }.joined(separator: ", "))"),
                "app": AnyCodable(snapshot.app),
                "snapshot": includeSnapshot ? AnyCodable(encodableToAny(snapshot)) : AnyCodable(nil),
            ]
            try JSONOutput.print(output, pretty: pretty)
            throw ExitCode.failure
        }

        // Step 3: Act (or read)
        if action.lowercased() == "read" {
            // Just return the matched element + snapshot context
            let matchedElement = snapshot.content.sections
                .flatMap { $0.elements }
                .first { $0.ref == matched.ref }

            var output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(snapshot.app),
                "action": AnyCodable("read"),
                "matched_ref": AnyCodable(matched.ref),
                "matched_label": AnyCodable(matched.label),
                "match_score": AnyCodable(matched.score),
            ]
            if let el = matchedElement {
                output["element"] = AnyCodable([
                    "ref": AnyCodable(el.ref),
                    "role": AnyCodable(el.role),
                    "label": AnyCodable(el.label),
                    "value": el.value ?? AnyCodable(nil),
                    "enabled": AnyCodable(el.enabled),
                    "focused": AnyCodable(el.focused),
                    "actions": AnyCodable(el.actions.map { AnyCodable($0) }),
                ] as [String: AnyCodable])
            }
            if includeSnapshot {
                output["snapshot"] = AnyCodable(encodableToAny(snapshot))
            }
            try JSONOutput.print(output, pretty: pretty)
            return
        }

        // For click, fill, etc. — execute the action
        guard let actionType = ActionExecutor.ActionType(rawValue: action.lowercased()) else {
            fputs("Error: Unknown action '\(action)'. Valid: click, fill, read, eval, script\n", stderr)
            throw ExitCode.failure
        }

        let executor = ActionExecutor(refMap: refMap)
        let result = executor.execute(
            action: actionType,
            ref: matched.ref,
            value: value,
            on: runningApp,
            enricher: enricher
        )

        // Wrap result with match info
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
        if includeSnapshot {
            output["snapshot"] = AnyCodable(encodableToAny(snapshot))
        }
        try JSONOutput.print(output, pretty: pretty)

        if !result.success {
            throw ExitCode.failure
        }
    }

    /// Fuzzy scoring: higher = better match
    private func fuzzyScore(needle: String, element: Element, sectionLabel: String?) -> Int {
        var score = 0
        let label = (element.label ?? "").lowercased()
        let role = element.role.lowercased()
        let valStr = stringValue(element.value).lowercased()
        let secLabel = (sectionLabel ?? "").lowercased()

        // Exact label match
        if label == needle { score += 100 }
        // Label contains needle
        else if label.contains(needle) { score += 80 }
        // Needle contains label (partial)
        else if !label.isEmpty && needle.contains(label) { score += 40 }

        // Role match
        if role.contains(needle) { score += 30 }

        // Value match
        if valStr.contains(needle) { score += 20 }

        // Section label match
        if secLabel.contains(needle) { score += 10 }

        // Boost for actionable elements
        if !element.actions.isEmpty && score > 0 { score += 5 }

        return score
    }

    private func stringValue(_ v: AnyCodable?) -> String {
        guard let val = v?.value else { return "" }
        if let s = val as? String { return s }
        return "\(val)"
    }

    /// Convert Encodable to Any for AnyCodable wrapping
    private func encodableToAny<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONOutput.encoder.encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) else {
            return "encoding_error"
        }
        return dict
    }
}
