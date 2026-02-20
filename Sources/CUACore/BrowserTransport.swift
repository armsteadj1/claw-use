import Foundation

// MARK: - Browser Transport Protocol

/// Protocol for pluggable browser communication.
///
/// Issue #67: Pluggable browser transport layer
/// This abstraction lets `cua web` talk to multiple browsers (Safari, Chrome, etc.)
/// through a common interface. Each browser transport implements snapshot, click,
/// type, JS eval, navigate, and tab management.
public protocol BrowserTransport: AnyObject {
    /// Display name of this browser (e.g., "safari", "chrome")
    var browserName: String { get }

    /// Check if this browser is currently available (running and reachable)
    func isAvailable() -> Bool

    /// Full semantic page snapshot (structured page analysis)
    func pageSnapshot() -> TransportResult

    /// Click element by fuzzy text match
    func clickElement(match: String) -> TransportResult

    /// Fill/type into a form element by fuzzy match
    func fillElement(match: String, value: String) -> TransportResult

    /// Execute JavaScript expression and return result
    func evaluateJS(expression: String, timeout: Int) -> TransportResult

    /// Navigate to a URL
    func navigate(url: String) -> TransportResult

    /// List all open tabs
    func listTabs() -> TransportResult

    /// Switch to a tab by fuzzy title/URL match
    func switchTab(match: String) -> TransportResult

    /// Extract page content as markdown
    func extractContent() -> TransportResult

    /// Get all interactive elements with refs
    func getInteractiveElements() -> TransportResult
}

// MARK: - Browser Router

/// Routes `cua web` commands to the correct browser transport.
///
/// Handles auto-detection of running browsers and explicit `--browser` overrides.
/// Priority: explicit flag > detected Chrome-family > detected Safari.
public final class BrowserRouter {
    private var transports: [BrowserTransport] = []
    private let lock = NSLock()

    public init() {}

    /// Register a browser transport
    public func register(_ transport: BrowserTransport) {
        lock.lock()
        transports.append(transport)
        lock.unlock()
    }

    /// Get the active browser transport.
    ///
    /// - Parameter browser: Explicit browser name from `--browser` flag, or nil for auto-detect.
    /// - Returns: The matching BrowserTransport, or nil if none available.
    public func activeBrowser(explicit: String? = nil) -> BrowserTransport? {
        lock.lock()
        let all = transports
        lock.unlock()

        // Explicit --browser flag
        if let name = explicit?.lowercased() {
            return all.first { $0.browserName.lowercased() == name }
        }

        // Auto-detect: return first available transport
        // Priority order is registration order (Safari first, then Chrome, etc.)
        return all.first { $0.isAvailable() }
    }

    /// List all registered browser transport names and their availability
    public func availableBrowsers() -> [(name: String, available: Bool)] {
        lock.lock()
        let all = transports
        lock.unlock()
        return all.map { ($0.browserName, $0.isAvailable()) }
    }
}
