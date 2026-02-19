import Foundation

/// Safari Transport — AppleScript + `do JavaScript` hybrid for web browsing
///
/// Issue #23: Safari Transport
/// - Tab management via AppleScript (list, switch, open, close)
/// - Page content via `do JavaScript` (execute JS, get title/URL/HTML/text)
/// - Navigation: open URL, go back/forward, reload
/// - Works even when screen is locked (all via osascript)
public final class SafariTransport: Transport {
    public let name = "safari"
    public let stats = TransportStats()

    private let defaultTimeout: Int

    public init(defaultTimeout: Int = 5) {
        self.defaultTimeout = defaultTimeout
    }

    public func canHandle(app: String, bundleId: String?) -> Bool {
        let lower = app.lowercased()
        let bid = bundleId?.lowercased() ?? ""
        return lower.contains("safari") || bid.contains("com.apple.safari")
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
        let supportedActions = [
            "safari_tabs", "safari_switch_tab", "safari_open_tab", "safari_close_tab",
            "safari_navigate", "safari_back", "safari_forward", "safari_reload",
            "safari_js", "safari_title", "safari_url", "safari_html", "safari_text",
            "safari_snapshot", "safari_click", "safari_fill", "safari_extract",
            "safari_elements",
        ]

        guard supportedActions.contains(action.type) else {
            stats.recordFailure()
            return TransportResult(
                success: false, data: nil,
                error: "Safari transport does not support '\(action.type)'. Supported: \(supportedActions.joined(separator: ", "))",
                transportUsed: name
            )
        }

        let result: TransportResult
        switch action.type {
        case "safari_tabs":
            result = listTabs()
        case "safari_switch_tab":
            result = switchTab(match: action.value)
        case "safari_open_tab":
            result = openTab(url: action.value)
        case "safari_close_tab":
            result = closeTab()
        case "safari_navigate":
            result = navigate(url: action.value)
        case "safari_back":
            result = goBack()
        case "safari_forward":
            result = goForward()
        case "safari_reload":
            result = reload()
        case "safari_js":
            result = executeJS(expr: action.expr, timeout: action.timeout ?? defaultTimeout)
        case "safari_title":
            result = getPageTitle()
        case "safari_url":
            result = getPageURL()
        case "safari_html":
            result = getPageHTML()
        case "safari_text":
            result = getPageText()
        case "safari_snapshot":
            result = pageSnapshot()
        case "safari_click":
            result = clickElement(match: action.value)
        case "safari_fill":
            result = fillElement(match: action.value, value: action.expr)
        case "safari_extract":
            result = extractContent()
        case "safari_elements":
            result = getInteractiveElements()
        default:
            result = TransportResult(success: false, data: nil, error: "Unhandled action: \(action.type)", transportUsed: name)
        }

        if result.success {
            stats.recordSuccess()
        } else {
            stats.recordFailure()
        }
        return result
    }

    // MARK: - Tab Management

    /// List all open tabs across all Safari windows
    public func listTabs() -> TransportResult {
        let script = """
        tell application "Safari"
            set tabOutput to ""
            set winIndex to 0
            repeat with w in windows
                set winIndex to winIndex + 1
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    set tabURL to URL of t
                    set tabName to name of t
                    if tabOutput is not "" then
                        set tabOutput to tabOutput & ":::"
                    end if
                    set tabOutput to tabOutput & (winIndex as text) & "|||" & (tabIndex as text) & "|||" & tabURL & "|||" & tabName
                end repeat
            end repeat
            return tabOutput
        end tell
        """
        let result = runOsascript(script: script, timeout: defaultTimeout)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        // Parse tab list using ::: between tabs and ||| between fields
        var tabs: [[String: AnyCodable]] = []
        if !raw.isEmpty {
            let entries = raw.components(separatedBy: ":::")
            for entry in entries {
                let parts = entry.components(separatedBy: "|||")
                if parts.count >= 4 {
                    tabs.append([
                        "window": AnyCodable(Int(parts[0]) ?? 1),
                        "tab": AnyCodable(Int(parts[1]) ?? 1),
                        "url": AnyCodable(parts[2]),
                        "title": AnyCodable(parts[3...].joined(separator: "|||")),
                    ])
                }
            }
        }

        let output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "tabs": AnyCodable(tabs.map { AnyCodable($0) }),
            "count": AnyCodable(tabs.count),
        ]
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    /// Switch to a tab by fuzzy title/URL match
    public func switchTab(match: String?) -> TransportResult {
        guard let match = match, !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "switchTab requires --value with tab title or URL", transportUsed: name)
        }

        let escapedMatch = match.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            set matchText to "\(escapedMatch)"
            set matchLower to do shell script "echo " & quoted form of matchText & " | tr '[:upper:]' '[:lower:]'"
            repeat with w in windows
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    set tabName to name of t
                    set tabURL to URL of t
                    set nameLower to do shell script "echo " & quoted form of tabName & " | tr '[:upper:]' '[:lower:]'"
                    set urlLower to do shell script "echo " & quoted form of tabURL & " | tr '[:upper:]' '[:lower:]'"
                    if nameLower contains matchLower or urlLower contains matchLower then
                        set current tab of w to t
                        set index of w to 1
                        return "switched\\t" & tabName & "\\t" & tabURL
                    end if
                end repeat
            end repeat
            return "not_found"
        end tell
        """
        let result = runOsascript(script: script, timeout: defaultTimeout)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        if raw == "not_found" {
            return TransportResult(
                success: false, data: nil,
                error: "No tab matching '\(match)' found",
                transportUsed: name
            )
        }

        let parts = raw.components(separatedBy: "\t")
        let output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("switch_tab"),
            "title": AnyCodable(parts.count > 1 ? parts[1] : ""),
            "url": AnyCodable(parts.count > 2 ? parts[2] : ""),
        ]
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    /// Open a new tab with a URL
    public func openTab(url: String?) -> TransportResult {
        guard let url = url, !url.isEmpty else {
            return TransportResult(success: false, data: nil, error: "openTab requires --value with URL", transportUsed: name)
        }

        let script = """
        tell application "Safari"
            activate
            tell window 1
                set newTab to make new tab with properties {URL:"\(url)"}
                set current tab to newTab
            end tell
            return "opened"
        end tell
        """
        let result = runOsascript(script: script, timeout: defaultTimeout)
        if result.success {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("open_tab"),
                "url": AnyCodable(url),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: name)
        }
        return result
    }

    /// Close the current tab
    public func closeTab() -> TransportResult {
        let script = """
        tell application "Safari"
            close current tab of window 1
            return "closed"
        end tell
        """
        return runOsascript(script: script, timeout: defaultTimeout)
    }

    // MARK: - Navigation

    /// Navigate current tab to a URL (or switch to existing tab)
    public func navigate(url: String?) -> TransportResult {
        guard let url = url, !url.isEmpty else {
            return TransportResult(success: false, data: nil, error: "navigate requires URL", transportUsed: name)
        }

        // First check if any tab already has this URL
        let escapedUrl = url.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Safari"
            -- Check if any tab already has this URL
            repeat with w in windows
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    if URL of t starts with "\(escapedUrl)" then
                        set current tab of w to t
                        set index of w to 1
                        return "switched\\t" & URL of t & "\\t" & name of t
                    end if
                end repeat
            end repeat
            -- No existing tab, navigate current tab
            activate
            set URL of current tab of window 1 to "\(escapedUrl)"
            delay 0.5
            return "navigated\\t" & URL of current tab of window 1 & "\\t" & name of current tab of window 1
        end tell
        """
        let result = runOsascript(script: script, timeout: defaultTimeout + 2)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        let parts = raw.components(separatedBy: "\t")
        let action = parts.first ?? "navigated"
        let output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable(action),
            "url": AnyCodable(parts.count > 1 ? parts[1] : url),
            "title": AnyCodable(parts.count > 2 ? parts[2] : ""),
        ]
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    /// Go back in browser history
    public func goBack() -> TransportResult {
        return executeJS(expr: "history.back()", timeout: defaultTimeout)
    }

    /// Go forward in browser history
    public func goForward() -> TransportResult {
        return executeJS(expr: "history.forward()", timeout: defaultTimeout)
    }

    /// Reload current page
    public func reload() -> TransportResult {
        return executeJS(expr: "location.reload()", timeout: defaultTimeout)
    }

    // MARK: - Page Content via do JavaScript

    /// Execute arbitrary JavaScript in the current tab
    public func executeJS(expr: String?, timeout: Int = 5) -> TransportResult {
        guard let expr = expr, !expr.isEmpty else {
            return TransportResult(success: false, data: nil, error: "JS execution requires expression", transportUsed: name)
        }

        // Write JS to temp file to avoid AppleScript string escaping hell
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmpJSFile = "/tmp/cua-js-\(pid).js"
        let tmpScriptFile = "/tmp/cua-scpt-\(pid).applescript"
        do {
            try expr.write(toFile: tmpJSFile, atomically: true, encoding: .utf8)
            let scpt = """
            set jsCode to read (POSIX file "\(tmpJSFile)") as «class utf8»
            tell application "Safari"
                try
                    set jsResult to (do JavaScript jsCode in current tab of window 1)
                    if jsResult is missing value then
                        return ""
                    end if
                    return jsResult as text
                on error errMsg
                    return "CUA_JS_ERROR:" & errMsg
                end try
            end tell
            """
            try scpt.write(toFile: tmpScriptFile, atomically: true, encoding: .utf8)
        } catch {
            return TransportResult(success: false, data: nil, error: "Failed to write temp files: \(error)", transportUsed: name)
        }
        defer {
            // skip cleanup
            // skip cleanup
        }

        let result = runOsascriptFile(path: tmpScriptFile, timeout: timeout)
        return result
    }

    /// Get current page title
    public func getPageTitle() -> TransportResult {
        let script = """
        tell application "Safari"
            return name of current tab of window 1
        end tell
        """
        return runOsascript(script: script, timeout: defaultTimeout)
    }

    /// Get current page URL
    public func getPageURL() -> TransportResult {
        let script = """
        tell application "Safari"
            return URL of current tab of window 1
        end tell
        """
        return runOsascript(script: script, timeout: defaultTimeout)
    }

    /// Get page HTML
    public func getPageHTML() -> TransportResult {
        return executeJS(expr: "document.documentElement.outerHTML", timeout: defaultTimeout + 5)
    }

    /// Get page text content
    public func getPageText() -> TransportResult {
        return executeJS(expr: "document.body.innerText", timeout: defaultTimeout)
    }

    // MARK: - Semantic Page Operations

    /// Full semantic page snapshot (uses PageAnalyzer JS)
    public func pageSnapshot() -> TransportResult {
        let js = PageAnalyzer.analysisScript
        let result = executeJS(expr: js, timeout: defaultTimeout + 5)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        // Parse the JSON result from JS
        guard let jsonData = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: jsonData) else {
            // Return raw text if JSON parsing fails
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("snapshot"),
                "raw": AnyCodable(raw),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: name)
        }

        var output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("snapshot"),
        ]
        for (key, value) in parsed {
            output[key] = value
        }
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    /// Click element by fuzzy match
    public func clickElement(match: String?) -> TransportResult {
        guard let match = match, !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "click requires --value with match text", transportUsed: name)
        }

        let escapedMatch = match
            .replacingOccurrences(of: "'", with: "\\'")

        let js = WebElementMatcher.clickScript(match: escapedMatch)
        return executeJS(expr: js, timeout: defaultTimeout)
    }

    /// Fill element by fuzzy match
    public func fillElement(match: String?, value: String?) -> TransportResult {
        guard let match = match, !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "fill requires --value with match text", transportUsed: name)
        }
        guard let value = value, !value.isEmpty else {
            return TransportResult(success: false, data: nil, error: "fill requires value", transportUsed: name)
        }

        let escapedMatch = match
            .replacingOccurrences(of: "'", with: "\\'")

        let escapedValue = value
            .replacingOccurrences(of: "'", with: "\\'")

        let js = WebElementMatcher.fillScript(match: escapedMatch, value: escapedValue)
        return executeJS(expr: js, timeout: defaultTimeout)
    }

    /// Extract main page content as markdown
    public func extractContent() -> TransportResult {
        let js = PageAnalyzer.extractionScript
        let result = executeJS(expr: js, timeout: defaultTimeout + 5)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        // The extraction script returns raw markdown text, not JSON.
        // Wrap it in a proper JSON response object.
        let output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("extract"),
            "content": AnyCodable(raw),
            "length": AnyCodable(raw.count),
        ]
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    /// Get all interactive elements with refs
    public func getInteractiveElements() -> TransportResult {
        let js = WebElementMatcher.enumerationScript
        let result = executeJS(expr: js, timeout: defaultTimeout)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        guard let jsonData = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: jsonData) else {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("elements"),
                "raw": AnyCodable(raw),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: name)
        }

        var output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("elements"),
        ]
        for (key, value) in parsed {
            output[key] = value
        }
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    // MARK: - osascript Execution

    private func runOsascriptFile(path: String, timeout: Int) -> TransportResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [path]

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
            process.terminate()
            return TransportResult(
                success: false, data: nil,
                error: "Safari AppleScript timed out after \(timeout)s",
                transportUsed: name
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            return TransportResult(
                success: false, data: nil,
                error: stderr.isEmpty ? "osascript exited with code \(process.terminationStatus)" : stderr,
                transportUsed: name
            )
        }

        let output: [String: AnyCodable] = ["result": AnyCodable(stdout)]
        return TransportResult(success: true, data: output, error: nil, transportUsed: name)
    }

    private func runOsascript(script: String, timeout: Int) -> TransportResult {
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
            process.terminate()
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

            return TransportResult(
                success: false, data: nil,
                error: "Safari AppleScript timed out after \(timeout)s",
                transportUsed: name
            )
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errorMsg = stderrStr.isEmpty ? "Exit code \(process.terminationStatus)" : stderrStr
            return TransportResult(
                success: false,
                data: ["success": AnyCodable(false), "error": AnyCodable(errorMsg)],
                error: errorMsg,
                transportUsed: name
            )
        }

        let data: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "result": AnyCodable(stdout),
        ]
        return TransportResult(success: true, data: data, error: nil, transportUsed: name)
    }
}
