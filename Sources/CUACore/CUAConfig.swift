import Foundation

// MARK: - Stream Config (sender side: the Mac being observed)

/// Configuration for the privacy-filtered event push stream on the observed Mac.
public struct StreamConfig: Codable {
    /// Whether the stream is enabled.
    public var enabled: Bool
    /// URL of the agent's RemoteServer to push events to (e.g. "http://100.80.200.51:4567").
    public var pushTo: String
    /// Shared HMAC secret (matches the agent's remote.secret).
    public var secret: String
    /// Flush interval in seconds (default: 5).
    public var flushInterval: Int
    /// Per-app event level (0–3). Use "*" for the default level.
    public var appLevels: [String: Int]
    /// App names that produce no events at all.
    public var blockedApps: [String]

    /// Level for apps not explicitly listed.
    public var defaultLevel: Int { appLevels["*"] ?? 0 }

    public init(
        enabled: Bool = false,
        pushTo: String = "",
        secret: String = "",
        flushInterval: Int = 5,
        appLevels: [String: Int] = ["*": 0],
        blockedApps: [String] = []
    ) {
        self.enabled = enabled
        self.pushTo = pushTo
        self.secret = secret
        self.flushInterval = flushInterval
        self.appLevels = appLevels
        self.blockedApps = blockedApps
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case pushTo = "push_to"
        case secret
        case flushInterval = "flush_interval"
        case appLevels = "app_levels"
        case blockedApps = "blocked_apps"
    }
}

// MARK: - Remote Server Config (server side: the Mac being observed)

/// Configuration for the remote HTTP proxy server on the observed Mac.
public struct RemoteServerConfig: Codable {
    /// Whether the remote HTTP server is enabled.
    public var enabled: Bool
    /// TCP port to listen on (default: 4567).
    public var port: Int
    /// Bind address: "tailscale" (100.x.x.x), "localhost" (127.0.0.1), or "0.0.0.0".
    public var bind: String
    /// Shared HMAC secret (hex or plain string).
    public var secret: String
    /// Session token TTL in seconds (default: 3600).
    public var tokenTtl: Int
    /// App names that cannot be accessed remotely.
    public var blockedApps: [String]

    public init(
        enabled: Bool = false,
        port: Int = 4567,
        bind: String = "tailscale",
        secret: String = "",
        tokenTtl: Int = 3600,
        blockedApps: [String] = []
    ) {
        self.enabled = enabled
        self.port = port
        self.bind = bind
        self.secret = secret
        self.tokenTtl = tokenTtl
        self.blockedApps = blockedApps
    }

    enum CodingKeys: String, CodingKey {
        case enabled, port, bind, secret
        case tokenTtl = "token_ttl"
        case blockedApps = "blocked_apps"
    }
}

// MARK: - Remote Target Config (client side: the agent machine)

/// A named remote target the agent machine can connect to.
public struct RemoteTarget: Codable {
    /// Base URL of the remote server (e.g. "http://100.80.200.51:4567").
    public var url: String
    /// Shared HMAC secret matching the server config.
    public var secret: String

    public init(url: String, secret: String) {
        self.url = url
        self.secret = secret
    }
}

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
    /// Remote HTTP proxy server config (server side — the Mac being observed).
    public let remote: RemoteServerConfig?
    /// Named remote targets (client side — the agent machine).
    public let remoteTargets: [String: RemoteTarget]?
    /// Privacy-filtered event push stream config (sender side — the Mac being observed).
    public let stream: StreamConfig?

    public init(gatewayUrl: String? = nil, gatewayToken: String? = nil, hooksToken: String? = nil,
                wakeEndpoint: String? = nil, processGroup: ProcessGroupConfig? = nil,
                eventFile: EventFileConfig? = nil, stableRefs: Bool? = nil,
                remote: RemoteServerConfig? = nil, remoteTargets: [String: RemoteTarget]? = nil,
                stream: StreamConfig? = nil) {
        self.gatewayUrl = gatewayUrl
        self.gatewayToken = gatewayToken
        self.hooksToken = hooksToken
        self.wakeEndpoint = wakeEndpoint
        self.processGroup = processGroup
        self.eventFile = eventFile
        self.stableRefs = stableRefs
        self.remote = remote
        self.remoteTargets = remoteTargets
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case gatewayUrl = "gateway_url"
        case gatewayToken = "gateway_token"
        case hooksToken = "hooks_token"
        case wakeEndpoint = "wake_endpoint"
        case processGroup = "process_group"
        case eventFile = "event_file"
        case stableRefs = "stable_refs"
        case remote
        case remoteTargets = "remote_targets"
        case stream
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
