import Foundation

/// AppleScript Transport — executes osascript with timeout, kill-and-retry logic
///
/// Issue #18: AppleScript Retry Logic with Kill-and-Retry
/// - Execute osascript with configurable timeout (default 3s)
/// - On timeout: kill hung osascript process, retry once
/// - Track success/failure rates for health reporting
/// - App-specific script templates
public final class AppleScriptTransport: Transport {
    public let name = "applescript"
    public let stats = TransportStats()

    private let defaultTimeout: Int

    public init(defaultTimeout: Int = 3) {
        self.defaultTimeout = defaultTimeout
    }

    public func canHandle(app: String, bundleId: String?) -> Bool {
        // AppleScript can handle most apps for data-level operations
        return true
    }

    public func health() -> TransportHealth {
        if stats.totalAttempts > 5 && stats.successRate < 0.2 {
            return .dead
        }
        if stats.totalAttempts > 3 && stats.successRate < 0.5 {
            return .degraded
        }
        return .healthy
    }

    public func execute(action: TransportAction) -> TransportResult {
        guard action.type == "script" else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "AppleScript transport only supports 'script' action", transportUsed: name)
        }

        guard let expression = action.expr else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "script requires --expr", transportUsed: name)
        }

        let timeout = action.timeout ?? defaultTimeout
        let script = buildScript(expression: expression, app: action.app, bundleId: action.bundleId)

        // First attempt
        let result = runOsascript(script: script, timeout: timeout, app: action.app)

        if result.success {
            stats.recordSuccess()
            return result
        }

        // On timeout: kill and retry once
        if result.error?.contains("timed out") == true {
            let retryResult = runOsascript(script: script, timeout: timeout, app: action.app)
            if retryResult.success {
                stats.recordSuccess()
            } else {
                stats.recordFailure()
            }
            return retryResult
        }

        stats.recordFailure()
        return result
    }

    // MARK: - Script Templates

    /// Build the full AppleScript based on app-specific templates
    private func buildScript(expression: String, app: String, bundleId: String?) -> String {
        // If the expression already starts with "tell application", use it directly
        if expression.lowercased().hasPrefix("tell application") {
            return expression
        }

        // Pick app-specific template
        let template = scriptTemplate(for: app, bundleId: bundleId)
        return template(expression, app)
    }

    /// Returns an app-specific script template function
    private func scriptTemplate(for app: String, bundleId: String?) -> (String, String) -> String {
        let lower = app.lowercased()
        let bid = bundleId?.lowercased() ?? ""

        // Notes
        if lower.contains("notes") || bid.contains("com.apple.notes") {
            return notesTemplate
        }

        // Safari
        if lower.contains("safari") || bid.contains("com.apple.safari") {
            return safariTemplate
        }

        // Generic template
        return genericTemplate
    }

    /// Generic: wrap expression in tell application block
    private func genericTemplate(expression: String, app: String) -> String {
        return """
        tell application "\(app)"
        \(expression)
        end tell
        """
    }

    /// Notes: special handling for Notes.app data access
    private func notesTemplate(expression: String, app: String) -> String {
        return """
        tell application "Notes"
        \(expression)
        end tell
        """
    }

    /// Safari: special handling for Safari scripting
    private func safariTemplate(expression: String, app: String) -> String {
        return """
        tell application "Safari"
        \(expression)
        end tell
        """
    }

    // MARK: - osascript Execution with Timeout + Kill

    private func runOsascript(script: String, timeout: Int, app: String) -> TransportResult {
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
            return TransportResult(
                success: false, data: nil,
                error: "Failed to launch osascript: \(error)",
                transportUsed: name
            )
        }

        let deadline = DispatchTime.now() + .seconds(timeout)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            // Kill the hung process
            process.terminate()
            // Give it a moment to die, then force kill if needed
            let killGroup = DispatchGroup()
            killGroup.enter()
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                killGroup.leave()
            }
            _ = killGroup.wait(timeout: .now() + 1.0)

            let data: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "app": AnyCodable(app),
                "action": AnyCodable("script"),
                "error": AnyCodable("AppleScript timed out after \(timeout)s"),
            ]
            return TransportResult(success: false, data: data, error: "AppleScript timed out after \(timeout)s", transportUsed: name)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errorMsg = stderrStr.isEmpty ? "Exit code \(process.terminationStatus)" : stderrStr
            let data: [String: AnyCodable] = [
                "success": AnyCodable(false),
                "app": AnyCodable(app),
                "action": AnyCodable("script"),
                "error": AnyCodable(errorMsg),
            ]
            return TransportResult(success: false, data: data, error: errorMsg, transportUsed: name)
        }

        let data: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "app": AnyCodable(app),
            "action": AnyCodable("script"),
            "result": AnyCodable(stdout),
        ]
        return TransportResult(success: true, data: data, error: nil, transportUsed: name)
    }
}
