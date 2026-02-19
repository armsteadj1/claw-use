import Foundation

// MARK: - Event File Configuration

/// User-facing configuration for the event file feature
public struct EventFileConfig: Codable {
    public let enabled: Bool?
    public let path: String?
    public let priority: [String]?
    public let sessionKey: String?

    public init(enabled: Bool? = nil, path: String? = nil, priority: [String]? = nil, sessionKey: String? = nil) {
        self.enabled = enabled
        self.path = path
        self.priority = priority
        self.sessionKey = sessionKey
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case path
        case priority
        case sessionKey = "session_key"
    }
}

/// Resolved configuration with defaults applied
public struct ResolvedEventFileConfig {
    public let enabled: Bool
    public let path: String
    public let priority: Set<String>
    public let sessionKey: String

    public init(enabled: Bool, path: String, priority: Set<String>, sessionKey: String) {
        self.enabled = enabled
        self.path = path
        self.priority = priority
        self.sessionKey = sessionKey
    }
}

// MARK: - Event File Payload

/// JSON payload written to the event file
public struct EventFilePayload: Codable {
    public let type: String
    public let timestamp: String
    public let data: [String: AnyCodable]
    public let deliver: DeliverInfo

    public init(type: String, timestamp: String, data: [String: AnyCodable], deliver: DeliverInfo) {
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.deliver = deliver
    }

    public struct DeliverInfo: Codable {
        public let sessionKey: String

        public init(sessionKey: String) {
            self.sessionKey = sessionKey
        }
    }
}

// MARK: - Event File Writer

/// Watches EventBus for high-priority events and writes them to a JSON file
public final class EventFileWriter {
    private let config: ResolvedEventFileConfig
    private var subscriptionId: String?
    public private(set) var isActive: Bool = false

    public init(config: ResolvedEventFileConfig) {
        self.config = config
    }

    /// Start listening for priority events
    public func start(eventBus: EventBus) {
        guard config.enabled else { return }
        isActive = true

        subscriptionId = eventBus.subscribe { [weak self] event in
            self?.handleEvent(event)
        }
    }

    /// Stop listening
    public func stop() {
        isActive = false
    }

    private func handleEvent(_ event: CUAEvent) {
        // Check if the event type matches any priority pattern
        let matched = config.priority.contains { pattern in
            EventBus.typeFilterMatches(filter: pattern, eventType: event.type)
        }
        guard matched else { return }

        // Build payload
        var data: [String: AnyCodable] = [:]
        if let pid = event.pid { data["pid"] = AnyCodable(pid) }
        if let app = event.app { data["app"] = AnyCodable(app) }
        if let details = event.details {
            for (key, value) in details {
                data[key] = value
            }
        }

        let payload = EventFilePayload(
            type: "cua.\(event.type)",
            timestamp: event.timestamp,
            data: data,
            deliver: EventFilePayload.DeliverInfo(sessionKey: config.sessionKey)
        )

        // Write to file (overwrite)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(payload) else { return }
        try? jsonData.write(to: URL(fileURLWithPath: config.path), options: .atomic)
    }
}
