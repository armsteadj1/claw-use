import AppKit
import Foundation

/// Chrome Browser Transport — communicates via Chrome DevTools Protocol (CDP).
///
/// Issue #67: Pluggable browser transport layer
/// Supports Chrome, Arc, Brave, Edge, and any Chromium-based browser
/// that exposes CDP on `--remote-debugging-port=9222`.
///
/// Key CDP domains used:
/// - Runtime: JavaScript evaluation
/// - Page: Navigation
/// - Input: Click and keyboard events
/// - DOM: Element queries
public final class ChromeBrowserTransport: BrowserTransport {
    public let browserName = "chrome"
    public let stats = TransportStats()

    private let defaultPort: Int
    private let defaultTimeout: Int

    /// Bundle IDs for Chromium-based browsers
    private static let chromiumBundleIds: [String] = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",         // Edge
        "com.microsoft.edgemac.Dev",
    ]

    public init(port: Int = 9222, defaultTimeout: Int = 10) {
        self.defaultPort = port
        self.defaultTimeout = defaultTimeout
    }

    public func isAvailable() -> Bool {
        // Check if any Chromium-based browser is running
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
        let hasChromium = running.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return Self.chromiumBundleIds.contains(bid)
        }
        guard hasChromium else { return false }

        // Also verify CDP is reachable
        let cdp = CDPHelper(port: defaultPort)
        do {
            let pages = try cdp.listPages()
            return !pages.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - BrowserTransport

    public func pageSnapshot() -> TransportResult {
        let js = PageAnalyzer.analysisScript
        let result = evaluateJS(expression: js, timeout: defaultTimeout)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        // Parse JSON from JS result
        guard let jsonData = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: jsonData) else {
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("snapshot"),
                "raw": AnyCodable(raw),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
        }

        var output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("snapshot"),
        ]
        for (key, value) in parsed {
            output[key] = value
        }
        return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
    }

    public func clickElement(match: String) -> TransportResult {
        guard !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "click requires match text", transportUsed: browserName)
        }
        let escapedMatch = match.replacingOccurrences(of: "'", with: "\\'")
        let js = WebElementMatcher.clickScript(match: escapedMatch)
        return evaluateJS(expression: js, timeout: defaultTimeout)
    }

    public func fillElement(match: String, value: String) -> TransportResult {
        guard !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "fill requires match text", transportUsed: browserName)
        }
        guard !value.isEmpty else {
            return TransportResult(success: false, data: nil, error: "fill requires value", transportUsed: browserName)
        }
        let escapedMatch = match.replacingOccurrences(of: "'", with: "\\'")
        let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")
        let js = WebElementMatcher.fillScript(match: escapedMatch, value: escapedValue)
        return evaluateJS(expression: js, timeout: defaultTimeout)
    }

    public func evaluateJS(expression: String, timeout: Int) -> TransportResult {
        guard !expression.isEmpty else {
            return TransportResult(success: false, data: nil, error: "JS expression is empty", transportUsed: browserName)
        }

        let cdp = CDPHelper(port: defaultPort)
        do {
            let pages = try cdp.listPages()
            guard let page = pages.first(where: { $0.url != "chrome://newtab/" && !$0.url.starts(with: "devtools://") }),
                  let wsUrl = page.webSocketDebuggerUrl else {
                // Fall back to any page
                guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
                    stats.recordFailure()
                    return TransportResult(success: false, data: nil, error: "No CDP pages found. Is Chrome running with --remote-debugging-port=\(defaultPort)?", transportUsed: browserName)
                }
                return evaluateOnPage(cdp: cdp, wsUrl: wsUrl, expression: expression)
            }
            return evaluateOnPage(cdp: cdp, wsUrl: wsUrl, expression: expression)
        } catch {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP connection failed: \(error)", transportUsed: browserName)
        }
    }

    public func navigate(url: String) -> TransportResult {
        guard !url.isEmpty else {
            return TransportResult(success: false, data: nil, error: "navigate requires URL", transportUsed: browserName)
        }

        // Use Page.navigate via CDP
        let cdp = CDPHelper(port: defaultPort)
        do {
            let pages = try cdp.listPages()
            guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
                stats.recordFailure()
                return TransportResult(success: false, data: nil, error: "No CDP pages found", transportUsed: browserName)
            }

            // Navigate via JS (simpler and more reliable than Page.navigate CDP command)
            let js = "window.location.href = '\(url.replacingOccurrences(of: "'", with: "\\'"))'; 'navigated'"
            let result = try cdp.evaluate(pageWsUrl: wsUrl, expression: js)
            stats.recordSuccess()

            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("navigated"),
                "url": AnyCodable(url),
                "result": AnyCodable(result ?? ""),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
        } catch {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP navigate failed: \(error)", transportUsed: browserName)
        }
    }

    public func listTabs() -> TransportResult {
        let cdp = CDPHelper(port: defaultPort)
        do {
            let pages = try cdp.listPages()
            let tabs: [[String: AnyCodable]] = pages.enumerated().map { (index, page) in
                [
                    "window": AnyCodable(1),
                    "tab": AnyCodable(index + 1),
                    "url": AnyCodable(page.url),
                    "title": AnyCodable(page.title),
                    "id": AnyCodable(page.id),
                ]
            }
            stats.recordSuccess()
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "tabs": AnyCodable(tabs.map { AnyCodable($0) }),
                "count": AnyCodable(tabs.count),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
        } catch {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP listTabs failed: \(error)", transportUsed: browserName)
        }
    }

    public func switchTab(match: String) -> TransportResult {
        guard !match.isEmpty else {
            return TransportResult(success: false, data: nil, error: "switchTab requires match text", transportUsed: browserName)
        }

        let cdp = CDPHelper(port: defaultPort)
        do {
            let pages = try cdp.listPages()
            let matchLower = match.lowercased()

            // Fuzzy match on title or URL
            guard let target = pages.first(where: {
                $0.title.lowercased().contains(matchLower) || $0.url.lowercased().contains(matchLower)
            }) else {
                stats.recordFailure()
                return TransportResult(success: false, data: nil, error: "No tab matching '\(match)' found", transportUsed: browserName)
            }

            // Activate the target via CDP Target.activateTarget
            activateTarget(cdp: cdp, targetId: target.id)

            stats.recordSuccess()
            let output: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("switch_tab"),
                "title": AnyCodable(target.title),
                "url": AnyCodable(target.url),
            ]
            return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
        } catch {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP switchTab failed: \(error)", transportUsed: browserName)
        }
    }

    public func extractContent() -> TransportResult {
        let js = PageAnalyzer.extractionScript
        let result = evaluateJS(expression: js, timeout: defaultTimeout)
        guard result.success, let data = result.data,
              let raw = data["result"]?.value as? String else {
            return result
        }

        let output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("extract"),
            "content": AnyCodable(raw),
            "length": AnyCodable(raw.count),
        ]
        return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
    }

    public func getInteractiveElements() -> TransportResult {
        let js = WebElementMatcher.enumerationScript
        let result = evaluateJS(expression: js, timeout: defaultTimeout)
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
            return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
        }

        var output: [String: AnyCodable] = [
            "success": AnyCodable(true),
            "action": AnyCodable("elements"),
        ]
        for (key, value) in parsed {
            output[key] = value
        }
        return TransportResult(success: true, data: output, error: nil, transportUsed: browserName)
    }

    // MARK: - Private Helpers

    private func evaluateOnPage(cdp: CDPHelper, wsUrl: String, expression: String) -> TransportResult {
        do {
            let resultValue = try cdp.evaluate(pageWsUrl: wsUrl, expression: expression)
            stats.recordSuccess()
            let data: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "action": AnyCodable("eval"),
                "result": AnyCodable(resultValue ?? "undefined"),
            ]
            return TransportResult(success: true, data: data, error: nil, transportUsed: browserName)
        } catch {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP eval failed: \(error)", transportUsed: browserName)
        }
    }

    /// Activate a CDP target (bring tab to front) via HTTP endpoint
    private func activateTarget(cdp: CDPHelper, targetId: String) {
        guard let url = URL(string: "http://localhost:\(defaultPort)/json/activate/\(targetId)") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { _, _, _ in
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
    }
}
