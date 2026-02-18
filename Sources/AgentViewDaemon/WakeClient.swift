import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends wake events to the OpenClaw gateway so the agent gets notified of UI changes
struct WakeClient {
    let gatewayUrl: String
    let gatewayToken: String
    let enabled: Bool

    struct Config: Codable {
        let gatewayUrl: String?
        let gatewayToken: String?
        let wakeEvents: WakeEventConfig?

        enum CodingKeys: String, CodingKey {
            case gatewayUrl = "gateway_url"
            case gatewayToken = "gateway_token"
            case wakeEvents = "wake_events"
        }
    }

    struct WakeEventConfig: Codable {
        let screenUnlock: Bool?
        let screenLock: Bool?
        let appCrash: Bool?
        let cdpDisconnect: Bool?

        enum CodingKeys: String, CodingKey {
            case screenUnlock = "screen_unlock"
            case screenLock = "screen_lock"
            case appCrash = "app_crash"
            case cdpDisconnect = "cdp_disconnect"
        }
    }

    /// Load config from ~/.agentview/config.json
    static func fromConfig() -> WakeClient {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentview/config.json").path

        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              let url = config.gatewayUrl, !url.isEmpty,
              let token = config.gatewayToken, !token.isEmpty else {
            fputs("[wake] No gateway config found at ~/.agentview/config.json — wake disabled\n", stderr)
            return WakeClient(gatewayUrl: "", gatewayToken: "", enabled: false)
        }

        fputs("[wake] Gateway configured: \(url) — wake enabled\n", stderr)
        return WakeClient(gatewayUrl: url, gatewayToken: token, enabled: true)
    }

    /// Send a wake event to the OpenClaw gateway
    func wake(text: String, mode: String = "now") {
        guard enabled else { return }

        let payload: [String: Any] = [
            "text": text,
            "mode": mode
        ]

        guard let url = URL(string: "\(gatewayUrl)/api/cron/wake"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            fputs("[wake] Failed to construct wake request\n", stderr)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 5

        // Fire and forget — don't block the daemon
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                fputs("[wake] Failed to send wake: \(error.localizedDescription)\n", stderr)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                fputs("[wake] Sent: \(text)\n", stderr)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                fputs("[wake] Wake returned status \(code)\n", stderr)
            }
        }
        task.resume()
    }

    // MARK: - Convenience methods for common events

    func screenUnlocked() {
        wake(text: "🔓 Screen unlocked — AX transport now available for all apps. Full UI access restored.")
    }

    func screenLocked() {
        wake(text: "🔒 Screen locked — AX transport unavailable. Using CDP/AppleScript fallbacks only.")
    }

    func appCrashed(name: String, pid: Int32) {
        wake(text: "💥 \(name) (PID \(pid)) appears to have crashed. Consider running `agentview restore \"\(name)\"` to recover.")
    }

    func cdpDisconnected(port: Int) {
        wake(text: "⚠️ CDP connection lost on port \(port). Electron app may have restarted. Auto-reconnect attempting.")
    }

    func cdpReconnected(port: Int) {
        wake(text: "✅ CDP connection restored on port \(port). Electron app accessible again.")
    }

    func appLaunched(name: String, pid: Int32) {
        wake(text: "📱 \(name) launched (PID \(pid)). New app available for AgentView control.")
    }

    func appTerminated(name: String) {
        wake(text: "🚫 \(name) terminated. Removing from available apps.")
    }
}
