import Foundation

// MARK: - Event File Model

/// The event file format matching OpenClaw convention
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

        enum CodingKeys: String, CodingKey {
            case sessionKey
        }
    }
}

// MARK: - EventFileWriter

/// Subscribes to high-priority events on the EventBus and writes them
/// to ~/.agentview/pending-event.json for polling-based consumption.
public final class EventFileWriter {
    private let config: ResolvedEventFileConfig
    private let lock = NSLock()
    private var subscriptionId: String?
    private weak var eventBus: EventBus?

    public init(config: ResolvedEventFileConfig) {
        self.config = config
    }

    /// Start listening for high-priority events and writing them to the event file
    public func start(eventBus: EventBus) {
        guard config.enabled else { return }
        self.eventBus = eventBus

        // Subscribe to all events and filter by priority set
        let priorityTypes = config.priority
        subscriptionId = eventBus.subscribe(typeFilters: priorityTypes) { [weak self] event in
            self?.writeEvent(event)
        }
    }

    /// Stop listening
    public func stop() {
        if let id = subscriptionId, let bus = eventBus {
            bus.unsubscribe(id)
        }
        subscriptionId = nil
    }

    /// Write an event to the event file (atomic write)
    private func writeEvent(_ event: AgentViewEvent) {
        lock.lock()
        defer { lock.unlock() }

        // Build data dict from event
        var data: [String: AnyCodable] = [:]
        if let pid = event.pid { data["pid"] = AnyCodable(Int(pid)) }
        if let app = event.app { data["app"] = AnyCodable(app) }
        if let bundleId = event.bundleId { data["bundle_id"] = AnyCodable(bundleId) }
        if let details = event.details {
            for (key, value) in details {
                data[key] = value
            }
        }

        let payload = EventFilePayload(
            type: "agentview.\(event.type)",
            timestamp: event.timestamp,
            data: data,
            deliver: EventFilePayload.DeliverInfo(sessionKey: config.sessionKey)
        )

        // Encode and write atomically
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(payload) else { return }

        let filePath = config.path
        let dir = (filePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        try? jsonData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    /// Check if the writer is active
    public var isActive: Bool {
        return config.enabled && subscriptionId != nil
    }
}
