import ArgumentParser
import Foundation

@main
struct AgentView: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentview",
        abstract: "Read macOS Accessibility APIs and expose structured UI state to AI agents.",
        version: "0.1.0",
        subcommands: [List.self, Raw.self, Snapshot.self, Act.self]
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

    @Argument(help: "Action: click, focus, fill, clear, toggle, select")
    var action: String

    @Option(name: .long, help: "Element ref (e.g., e4)")
    var ref: String

    @Option(name: .long, help: "Value for fill/select actions")
    var value: String?

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

        guard let actionType = ActionExecutor.ActionType(rawValue: action.lowercased()) else {
            fputs("Error: Unknown action '\(action)'. Valid actions: click, focus, fill, clear, toggle, select\n", stderr)
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
