import Foundation

// MARK: - Transport Protocol

/// Health status of a transport
public enum TransportHealth: String, Codable {
    case healthy
    case degraded
    case reconnecting
    case dead
    case unknown
}

/// Result of a transport action execution
public struct TransportResult {
    public let success: Bool
    public let data: [String: AnyCodable]?
    public let error: String?
    public let transportUsed: String

    public init(success: Bool, data: [String: AnyCodable]?, error: String?, transportUsed: String) {
        self.success = success
        self.data = data
        self.error = error
        self.transportUsed = transportUsed
    }
}

/// Action request for transports to execute
public struct TransportAction {
    public let type: String          // "snapshot", "click", "fill", "eval", "script", etc.
    public let app: String
    public let bundleId: String?
    public let pid: Int32
    public let ref: String?
    public let value: String?
    public let expr: String?
    public let port: Int?
    public let timeout: Int?
    public let depth: Int?

    public init(type: String, app: String, bundleId: String?, pid: Int32,
                ref: String? = nil, value: String? = nil, expr: String? = nil,
                port: Int? = nil, timeout: Int? = nil, depth: Int? = nil) {
        self.type = type
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
        self.ref = ref
        self.value = value
        self.expr = expr
        self.port = port
        self.timeout = timeout
        self.depth = depth
    }
}

/// Per-app transport health info for the status command
public struct AppTransportHealth: Codable {
    public let name: String
    public let bundleId: String?
    public let availableTransports: [String]
    public let currentHealth: [String: String]
    public let lastUsedTransport: String?
    public let successRate: [String: Double]

    public init(name: String, bundleId: String?, availableTransports: [String],
                currentHealth: [String: String], lastUsedTransport: String?,
                successRate: [String: Double]) {
        self.name = name
        self.bundleId = bundleId
        self.availableTransports = availableTransports
        self.currentHealth = currentHealth
        self.lastUsedTransport = lastUsedTransport
        self.successRate = successRate
    }
}

/// Protocol all transports must conform to
public protocol Transport: AnyObject {
    /// Unique name of this transport (e.g., "ax", "cdp", "applescript")
    var name: String { get }

    /// Whether this transport can handle the given app
    func canHandle(app: String, bundleId: String?) -> Bool

    /// Current health of this transport
    func health() -> TransportHealth

    /// Execute an action via this transport
    func execute(action: TransportAction) -> TransportResult
}

// MARK: - Transport Configuration

/// Per-app transport preference configuration
public struct TransportPreference {
    public let appNamePattern: String
    public let bundleIdPattern: String?
    public let preferredOrder: [String]

    public init(appNamePattern: String, bundleIdPattern: String? = nil, preferredOrder: [String]) {
        self.appNamePattern = appNamePattern
        self.bundleIdPattern = bundleIdPattern
        self.preferredOrder = preferredOrder
    }

    public func matches(app: String, bundleId: String?) -> Bool {
        let appLower = app.lowercased()
        let patternLower = appNamePattern.lowercased()
        if appLower.contains(patternLower) || patternLower.contains(appLower) {
            return true
        }
        if let bid = bundleId, let bp = bundleIdPattern {
            return bid.lowercased().contains(bp.lowercased())
        }
        return false
    }
}

// MARK: - Transport Statistics Tracking

/// Tracks success/failure rates for a transport
public final class TransportStats {
    private let lock = NSLock()
    private var successes: Int = 0
    private var failures: Int = 0
    private var _lastUsed: Date?

    public init() {}

    public func recordSuccess() {
        lock.lock()
        successes += 1
        _lastUsed = Date()
        lock.unlock()
    }

    public func recordFailure() {
        lock.lock()
        failures += 1
        _lastUsed = Date()
        lock.unlock()
    }

    public var successRate: Double {
        lock.lock()
        defer { lock.unlock() }
        let total = successes + failures
        guard total > 0 else { return 1.0 }
        return Double(successes) / Double(total)
    }

    public var totalAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return successes + failures
    }

    public var lastUsed: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastUsed
    }

    public func reset() {
        lock.lock()
        successes = 0
        failures = 0
        _lastUsed = nil
        lock.unlock()
    }
}
