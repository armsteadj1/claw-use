import Foundation

// MARK: - CUA Configuration

/// Full CUA configuration loaded from ~/.cua/config.json
public struct CUAConfig: Codable {
    public let gatewayUrl: String?
    public let gatewayToken: String?
    public let hooksToken: String?
    public let wakeEndpoint: String?

    public init(gatewayUrl: String? = nil, gatewayToken: String? = nil, hooksToken: String? = nil,
                wakeEndpoint: String? = nil) {
        self.gatewayUrl = gatewayUrl
        self.gatewayToken = gatewayToken
        self.hooksToken = hooksToken
        self.wakeEndpoint = wakeEndpoint
    }

    enum CodingKeys: String, CodingKey {
        case gatewayUrl = "gateway_url"
        case gatewayToken = "gateway_token"
        case hooksToken = "hooks_token"
        case wakeEndpoint = "wake_endpoint"
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
