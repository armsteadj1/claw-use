import Foundation

/// Self-healing transport router with auto-fallback chain
///
/// Issue #16: Transport Router with Auto-Fallback Chain
/// - Picks best transport per app with fallback chain (AX > CDP > AppleScript)
/// - On failure, automatically tries next transport in chain
/// - Configurable per-app preferences (e.g., Obsidian prefers CDP, Finder prefers AX)
public final class TransportRouter {
    private var transports: [Transport] = []
    private var preferences: [TransportPreference] = []
    private let lock = NSLock()

    /// Track which transport was last used per app
    private var lastUsedTransport: [String: String] = [:]

    /// Default transport order: AX > CDP > AppleScript
    private let defaultOrder = ["ax", "cdp", "applescript"]

    public init() {}

    /// Register a transport
    public func register(transport: Transport) {
        lock.lock()
        transports.append(transport)
        lock.unlock()
    }

    /// Add per-app transport preference
    public func addPreference(_ preference: TransportPreference) {
        lock.lock()
        preferences.append(preference)
        lock.unlock()
    }

    /// Set up default per-app preferences
    public func configureDefaults() {
        // Obsidian: prefer CDP (Electron app, richer API via DevTools)
        addPreference(TransportPreference(
            appNamePattern: "Obsidian",
            bundleIdPattern: "md.obsidian",
            preferredOrder: ["cdp", "ax", "applescript"]
        ))

        // VS Code: prefer CDP
        addPreference(TransportPreference(
            appNamePattern: "Code",
            bundleIdPattern: "com.microsoft.VSCode",
            preferredOrder: ["cdp", "ax", "applescript"]
        ))

        // Chrome: prefer CDP
        addPreference(TransportPreference(
            appNamePattern: "Chrome",
            bundleIdPattern: "com.google.Chrome",
            preferredOrder: ["cdp", "ax", "applescript"]
        ))

        // Finder: prefer AX (native macOS, best AX support)
        addPreference(TransportPreference(
            appNamePattern: "Finder",
            bundleIdPattern: "com.apple.finder",
            preferredOrder: ["ax", "applescript"]
        ))

        // Notes: prefer AppleScript (rich scripting API)
        addPreference(TransportPreference(
            appNamePattern: "Notes",
            bundleIdPattern: "com.apple.Notes",
            preferredOrder: ["applescript", "ax"]
        ))

        // Safari: prefer AppleScript (do JavaScript support)
        addPreference(TransportPreference(
            appNamePattern: "Safari",
            bundleIdPattern: "com.apple.Safari",
            preferredOrder: ["applescript", "ax"]
        ))
    }

    /// Execute an action, trying transports in preference order with auto-fallback
    public func execute(action: TransportAction) -> TransportResult {
        let chain = transportChain(for: action.app, bundleId: action.bundleId, actionType: action.type)

        if chain.isEmpty {
            return TransportResult(
                success: false, data: nil,
                error: "No transport available for app '\(action.app)' action '\(action.type)'",
                transportUsed: "none"
            )
        }

        var lastError: String?

        for transport in chain {
            let result = transport.execute(action: action)
            if result.success {
                lock.lock()
                lastUsedTransport[action.app] = transport.name
                lock.unlock()
                return result
            }
            lastError = result.error
        }

        // All transports failed
        return TransportResult(
            success: false, data: nil,
            error: "All transports failed for '\(action.app)'. Last error: \(lastError ?? "unknown")",
            transportUsed: "none"
        )
    }

    /// Get the ordered list of transports for an app, filtered to those that can handle the action
    public func transportChain(for app: String, bundleId: String?, actionType: String) -> [Transport] {
        lock.lock()
        let allTransports = transports
        let allPreferences = preferences
        lock.unlock()

        // Determine preferred order
        let order: [String]
        if let pref = allPreferences.first(where: { $0.matches(app: app, bundleId: bundleId) }) {
            order = pref.preferredOrder
        } else {
            order = defaultOrder
        }

        // Build chain: ordered transports that can handle this app
        var chain: [Transport] = []
        for transportName in order {
            if let transport = allTransports.first(where: { $0.name == transportName }) {
                if transport.canHandle(app: app, bundleId: bundleId) && transport.health() != .dead {
                    // Filter by action compatibility
                    if isCompatible(transport: transport, actionType: actionType) {
                        chain.append(transport)
                    }
                }
            }
        }

        // Add any remaining healthy transports not in the preference as fallbacks
        for transport in allTransports {
            if !chain.contains(where: { $0.name == transport.name }) &&
               transport.canHandle(app: app, bundleId: bundleId) &&
               transport.health() != .dead &&
               isCompatible(transport: transport, actionType: actionType) {
                chain.append(transport)
            }
        }

        return chain
    }

    /// Check if a transport type is compatible with an action type
    private func isCompatible(transport: Transport, actionType: String) -> Bool {
        switch transport.name {
        case "ax":
            return ["snapshot", "click", "focus", "fill", "clear", "toggle", "select"].contains(actionType)
        case "cdp":
            return actionType == "eval"
        case "applescript":
            return actionType == "script"
        default:
            return true
        }
    }

    // MARK: - Status / Health

    /// Get per-app transport health for all running apps
    public func appTransportHealths(apps: [AppInfo]) -> [AppTransportHealth] {
        lock.lock()
        let allTransports = transports
        let allPreferences = preferences
        let lastUsed = lastUsedTransport
        lock.unlock()

        return apps.map { app in
            let available = allTransports.filter { $0.canHandle(app: app.name, bundleId: app.bundleId) }

            var currentHealth: [String: String] = [:]
            var successRates: [String: Double] = [:]
            for transport in available {
                currentHealth[transport.name] = transport.health().rawValue
                if let statsTransport = transport as? AXTransport {
                    successRates[transport.name] = statsTransport.stats.successRate
                } else if let statsTransport = transport as? CDPTransport {
                    successRates[transport.name] = statsTransport.stats.successRate
                } else if let statsTransport = transport as? AppleScriptTransport {
                    successRates[transport.name] = statsTransport.stats.successRate
                }
            }

            // Determine preferred order for this app
            let preferredOrder: [String]
            if let pref = allPreferences.first(where: { $0.matches(app: app.name, bundleId: app.bundleId) }) {
                preferredOrder = pref.preferredOrder
            } else {
                preferredOrder = available.map { $0.name }
            }

            return AppTransportHealth(
                name: app.name,
                bundleId: app.bundleId,
                availableTransports: preferredOrder,
                currentHealth: currentHealth,
                lastUsedTransport: lastUsed[app.name],
                successRate: successRates
            )
        }
    }

    /// Get all registered transport names and their health
    public func transportHealthSummary() -> [String: String] {
        lock.lock()
        let allTransports = transports
        lock.unlock()

        var summary: [String: String] = [:]
        for transport in allTransports {
            summary[transport.name] = transport.health().rawValue
        }
        return summary
    }

    /// Get last used transport for an app
    public func lastTransport(for app: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastUsedTransport[app]
    }
}
