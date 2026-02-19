import Foundation

/// CDP Transport — wraps CDPConnectionPool with auto-reconnect and exponential backoff
///
/// Issue #17: CDP Auto-Reconnect with Exponential Backoff
/// - Exponential backoff: 1s, 2s, 4s, 8s, max 30s
/// - Max 3 retries before marking connection dead
/// - Health status: connected, reconnecting, dead
/// - Auto-rediscover on reconnect failure (port may change)
public final class CDPTransport: Transport {
    public let name = "cdp"
    public let stats = TransportStats()

    private let pool: CDPConnectionPool
    private let lock = NSLock()

    // Reconnect state per port
    private struct ReconnectState {
        var retryCount: Int = 0
        var lastAttempt: Date?
        var backoffSeconds: Double = 1.0
    }
    private var reconnectStates: [Int: ReconnectState] = [:]
    private let maxRetries = 3
    private let maxBackoff: Double = 30.0

    /// Bundle IDs known to support CDP (Electron apps, Chrome-based browsers)
    private let cdpBundleIds: Set<String> = [
        "md.obsidian",
        "com.microsoft.VSCode",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.electron",
    ]

    public init(pool: CDPConnectionPool) {
        self.pool = pool
    }

    public func canHandle(app: String, bundleId: String?) -> Bool {
        if let bid = bundleId, cdpBundleIds.contains(bid) {
            return true
        }
        // Check by app name patterns
        let lower = app.lowercased()
        return lower.contains("obsidian") || lower.contains("code") ||
               lower.contains("chrome") || lower.contains("chromium") ||
               lower.contains("electron") || lower.contains("brave") ||
               lower.contains("vivaldi")
    }

    public func health() -> TransportHealth {
        let infos = pool.connectionInfos()
        if infos.isEmpty {
            return .unknown
        }
        let hasConnected = infos.contains { $0.health == "connected" }
        let hasReconnecting = infos.contains { $0.health == "reconnecting" }
        let allDead = infos.allSatisfy { $0.health == "dead" }

        if hasConnected { return .healthy }
        if hasReconnecting { return .reconnecting }
        if allDead { return .dead }
        return .degraded
    }

    public func execute(action: TransportAction) -> TransportResult {
        guard action.type == "eval" else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "CDP transport only supports 'eval' action", transportUsed: name)
        }

        guard let expression = action.expr else {
            stats.recordFailure()
            return TransportResult(success: false, data: nil, error: "eval requires --expr", transportUsed: name)
        }

        let port = action.port ?? 9222
        return executeWithRetry(port: port, expression: expression, app: action.app)
    }

    // MARK: - Reconnect with Exponential Backoff

    private func executeWithRetry(port: Int, expression: String, app: String) -> TransportResult {
        lock.lock()
        var state = reconnectStates[port] ?? ReconnectState()
        lock.unlock()

        // Try up to maxRetries + 1 attempts (initial + retries)
        for attempt in 0...maxRetries {
            // Check backoff timing (skip for first attempt)
            if attempt > 0 {
                let backoff = min(state.backoffSeconds, maxBackoff)
                Thread.sleep(forTimeInterval: backoff)
                state.backoffSeconds *= 2
                state.retryCount = attempt
                state.lastAttempt = Date()

                lock.lock()
                reconnectStates[port] = state
                lock.unlock()
            }

            do {
                let resultValue = try pool.evaluate(port: port, expression: expression)

                // Success — reset reconnect state
                lock.lock()
                reconnectStates[port] = ReconnectState()
                lock.unlock()

                stats.recordSuccess()
                let data: [String: AnyCodable] = [
                    "success": AnyCodable(true),
                    "app": AnyCodable(app),
                    "action": AnyCodable("eval"),
                    "result": AnyCodable(resultValue ?? "undefined"),
                ]
                return TransportResult(success: true, data: data, error: nil, transportUsed: name)
            } catch {
                if attempt == maxRetries {
                    // All retries exhausted — mark dead
                    lock.lock()
                    state.retryCount = maxRetries
                    reconnectStates[port] = state
                    lock.unlock()

                    // Try auto-rediscovery (port may have changed)
                    if let result = tryRediscovery(expression: expression, app: app, excludePort: port) {
                        return result
                    }

                    stats.recordFailure()
                    return TransportResult(
                        success: false, data: nil,
                        error: "CDP eval failed after \(maxRetries) retries: \(error)",
                        transportUsed: name
                    )
                }
                // Continue to next attempt with backoff
                continue
            }
        }

        stats.recordFailure()
        return TransportResult(success: false, data: nil, error: "CDP eval exhausted all retries", transportUsed: name)
    }

    /// Try to find the app on a different port (ports can change on restart)
    private func tryRediscovery(expression: String, app: String, excludePort: Int) -> TransportResult? {
        let discoveryPorts = [9222, 9229, 9223, 9230]
        for port in discoveryPorts where port != excludePort {
            do {
                let resultValue = try pool.evaluate(port: port, expression: expression)

                lock.lock()
                reconnectStates[port] = ReconnectState()
                lock.unlock()

                stats.recordSuccess()
                let data: [String: AnyCodable] = [
                    "success": AnyCodable(true),
                    "app": AnyCodable(app),
                    "action": AnyCodable("eval"),
                    "result": AnyCodable(resultValue ?? "undefined"),
                    "rediscovered_port": AnyCodable(port),
                ]
                return TransportResult(success: true, data: data, error: nil, transportUsed: name)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Get connection health info for all ports
    public func connectionInfos() -> [CDPConnectionPool.ConnectionInfo] {
        return pool.connectionInfos()
    }
}
