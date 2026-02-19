import Foundation

// MARK: - AgentView Configuration

/// Event file configuration section in ~/.agentview/config.json
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
        case enabled, path, priority
        case sessionKey = "session_key"
    }
}

/// Full AgentView configuration loaded from ~/.agentview/config.json
public struct AgentViewConfig: Codable {
    public let gatewayUrl: String?
    public let gatewayToken: String?
    public let hooksToken: String?
    public let wakeEndpoint: String?
    public let eventFile: EventFileConfig?

    public init(gatewayUrl: String? = nil, gatewayToken: String? = nil, hooksToken: String? = nil,
                wakeEndpoint: String? = nil, eventFile: EventFileConfig? = nil) {
        self.gatewayUrl = gatewayUrl
        self.gatewayToken = gatewayToken
        self.hooksToken = hooksToken
        self.wakeEndpoint = wakeEndpoint
        self.eventFile = eventFile
    }

    enum CodingKeys: String, CodingKey {
        case gatewayUrl = "gateway_url"
        case gatewayToken = "gateway_token"
        case hooksToken = "hooks_token"
        case wakeEndpoint = "wake_endpoint"
        case eventFile = "eventFile"
    }

    /// Default high-priority event types for the event file
    public static let defaultPriorityEvents: [String] = [
        "process.error",
        "process.exit",
        "process.idle",
        "parliament.state_change",
    ]

    /// Default event file path
    public static let defaultEventFilePath = "~/.agentview/pending-event.json"

    /// Resolved event file settings (applies defaults)
    public var resolvedEventFile: ResolvedEventFileConfig {
        let config = eventFile
        let enabled = config?.enabled ?? false
        let rawPath = config?.path ?? AgentViewConfig.defaultEventFilePath
        let path = (rawPath as NSString).expandingTildeInPath
        let priority = config?.priority ?? AgentViewConfig.defaultPriorityEvents
        let sessionKey = config?.sessionKey ?? "main"
        return ResolvedEventFileConfig(enabled: enabled, path: path, priority: Set(priority), sessionKey: sessionKey)
    }

    /// Load configuration from the default path
    public static func load(from path: String? = nil) -> AgentViewConfig {
        let configPath = path ?? (NSHomeDirectory() + "/.agentview/config.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(AgentViewConfig.self, from: data) else {
            return AgentViewConfig()
        }
        return config
    }
}

/// Resolved event file configuration with defaults applied
public struct ResolvedEventFileConfig {
    public let enabled: Bool
    public let path: String
    public let priority: Set<String>
    public let sessionKey: String
}
