import Foundation

// MARK: - CUA Configuration

/// Full CUA configuration loaded from ~/.cua/config.json
public struct CUAConfig: Codable {
    public let gatewayUrl: String?
    public let gatewayToken: String?
    public let hooksToken: String?
    public let wakeEndpoint: String?
    public let processGroup: ProcessGroupConfig?
    public let eventFile: EventFileConfig?
    /// When true, all snapshots use stable refs (AX identifier or role+label fingerprint).
    /// Can also be enabled per-call via the `--stable-refs` CLI flag.
    public let stableRefs: Bool?

    public init(gatewayUrl: String? = nil, gatewayToken: String? = nil, hooksToken: String? = nil,
                wakeEndpoint: String? = nil, processGroup: ProcessGroupConfig? = nil,
                eventFile: EventFileConfig? = nil, stableRefs: Bool? = nil) {
        self.gatewayUrl = gatewayUrl
        self.gatewayToken = gatewayToken
        self.hooksToken = hooksToken
        self.wakeEndpoint = wakeEndpoint
        self.processGroup = processGroup
        self.eventFile = eventFile
        self.stableRefs = stableRefs
    }

    enum CodingKeys: String, CodingKey {
        case gatewayUrl = "gateway_url"
        case gatewayToken = "gateway_token"
        case hooksToken = "hooks_token"
        case wakeEndpoint = "wake_endpoint"
        case processGroup = "process_group"
        case eventFile = "event_file"
        case stableRefs = "stable_refs"
    }

    /// Default priority event types for the event file feature
    public static let defaultPriorityEvents: Set<String> = [
        "process.error",
        "process.exit",
        "process.idle",
        "process.group.state_change",
    ]

    /// Resolve event file configuration with defaults
    public var resolvedEventFile: ResolvedEventFileConfig {
        let defaultPath = NSHomeDirectory() + "/.cua/pending-event.json"
        return ResolvedEventFileConfig(
            enabled: eventFile?.enabled ?? false,
            path: eventFile?.path ?? defaultPath,
            priority: eventFile?.priority.map { Set($0) } ?? Self.defaultPriorityEvents,
            sessionKey: eventFile?.sessionKey ?? "main"
        )
    }

    /// Load configuration from the default path
    public static func load(from path: String? = nil) -> CUAConfig {
        let configPath = path ?? (NSHomeDirectory() + "/.cua/config.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(CUAConfig.self, from: data) else {
            return CUAConfig()
        }
        return config
    }
}
