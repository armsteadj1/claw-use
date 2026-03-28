import CryptoKit
import Darwin
import Foundation

// MARK: - Tailscale Helpers (public, used by cua CLI and cuad)

/// Find the first IPv4 address in the Tailscale CGNAT range (100.64.0.0/10).
public func tailscaleIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var current = ifaddr
    while let ptr = current {
        defer { current = ptr.pointee.ifa_next }
        let ifa = ptr.pointee
        guard ifa.ifa_addr != nil,
              ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(
            ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
        )
        guard rc == 0 else { continue }
        let ip = String(cString: hostname)
        if isTailscaleRange(ip) { return ip }
    }
    return nil
}

/// Returns true when `ip` falls within 100.64.0.0/10 (Tailscale CGNAT range).
public func isTailscaleRange(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4 else { return false }
    let addr = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    let lo: UInt32 = (100 << 24) | (64 << 16)
    let hi: UInt32 = (100 << 24) | (127 << 16) | (255 << 8) | 255
    return addr >= lo && addr <= hi
}

// MARK: - Disk-cached session

private struct CachedSession: Codable {
    let token: String
    let expiry: TimeInterval  // Unix timestamp
}

// MARK: - RemoteClient

/// HTTP client for talking to a RemoteServer on a remote cuad.
///
/// Handles the full HMAC challenge-response auth flow and caches the
/// resulting session token to disk so each CLI invocation reuses it.
public final class RemoteClient {

    // MARK: Properties

    public let targetName: String
    public let target: RemoteTarget

    private var sessionToken: String?
    private var tokenExpiry: Date?

    private var sessionCachePath: String {
        let dir = NSHomeDirectory() + "/.cua/remote-sessions"
        return dir + "/\(targetName).json"
    }

    // MARK: Init

    public init(name: String, target: RemoteTarget) {
        self.targetName = name
        self.target = target
        loadCachedSession()
    }

    // MARK: - Public API

    /// Authenticate (or re-use cached token) and return a valid Bearer token.
    public func authenticate() throws -> String {
        // Use cached token if it has >60 s remaining
        if let token = sessionToken, let expiry = tokenExpiry, expiry.timeIntervalSinceNow > 60 {
            return token
        }

        // --- Step 1: GET /handshake ---
        let handshakeURL = target.url + "/handshake"
        let (hsStatus, hsBody) = try syncHTTP(method: "GET", urlString: handshakeURL)
        guard hsStatus == 200,
              let challenge = hsBody["challenge"] as? String
        else {
            throw RemoteClientError.authFailed("handshake failed (status \(hsStatus))")
        }

        // --- Step 2: compute HMAC-SHA256(secret, challenge:ts) ---
        let ts = Int(Date().timeIntervalSince1970)
        let key = SymmetricKey(data: Data(target.secret.utf8))
        let msg = Data("\(challenge):\(ts)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        let sig = mac.map { String(format: "%02x", $0) }.joined()

        // --- Step 3: POST /auth ---
        let authBody: [String: Any] = ["sig": sig, "challenge": challenge, "ts": ts]
        let authBodyData = try JSONSerialization.data(withJSONObject: authBody)
        let authURL = target.url + "/auth"
        let (authStatus, authResp) = try syncHTTP(method: "POST", urlString: authURL, body: authBodyData)

        guard authStatus == 200,
              let token = authResp["token"] as? String
        else {
            throw RemoteClientError.authFailed("auth failed (status \(authStatus))")
        }

        let ttl = authResp["ttl"] as? Int ?? 3600
        sessionToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
        saveCachedSession(token: token, expiry: tokenExpiry!)

        return token
    }

    /// Execute a JSON-RPC call on the remote cuad and return the raw response data.
    public func rpc(method: String, params: [String: Any]) throws -> Data {
        let token = try authenticate()

        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: rpcBody)
        let rpcURL = target.url + "/rpc"

        let (status, _, rawData) = try syncHTTPRaw(
            method: "POST",
            urlString: rpcURL,
            headers: ["Authorization": "Bearer \(token)"],
            body: bodyData
        )

        guard status == 200 else {
            throw RemoteClientError.rpcFailed("HTTP \(status)")
        }
        return rawData
    }

    // MARK: - Session Caching

    private func loadCachedSession() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionCachePath)),
              let cached = try? JSONDecoder().decode(CachedSession.self, from: data)
        else { return }

        let expiry = Date(timeIntervalSince1970: cached.expiry)
        if expiry.timeIntervalSinceNow > 60 {
            sessionToken = cached.token
            tokenExpiry = expiry
        }
    }

    private func saveCachedSession(token: String, expiry: Date) {
        let dir = NSHomeDirectory() + "/.cua/remote-sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cached = CachedSession(token: token, expiry: expiry.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: URL(fileURLWithPath: sessionCachePath))
        }
    }

    // MARK: - HTTP Helpers

    /// Synchronous HTTP call; returns (statusCode, parsed JSON body).
    private func syncHTTP(
        method: String,
        urlString: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> (Int, [String: Any]) {
        let (status, _, data) = try syncHTTPRaw(method: method, urlString: urlString, headers: headers, body: body)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (status, json)
    }

    /// Synchronous HTTP call; returns (statusCode, headers, raw body).
    private func syncHTTPRaw(
        method: String,
        urlString: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> (Int, [String: String], Data) {
        guard let url = URL(string: urlString) else {
            throw RemoteClientError.invalidURL(urlString)
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        var callError: Error?

        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error = error { callError = error; return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = (status, data ?? Data())
        }.resume()

        semaphore.wait()

        if let error = callError { throw error }
        guard let (status, data) = result else {
            throw RemoteClientError.noResponse
        }
        return (status, [:], data)
    }
}

// MARK: - RemoteClient Factory

extension RemoteClient {
    /// Load a RemoteClient from the named target in the current CUA config.
    public static func forTarget(name: String) throws -> RemoteClient {
        let config = CUAConfig.load()
        guard let targets = config.remoteTargets,
              let target = targets[name]
        else {
            throw RemoteClientError.targetNotFound(name)
        }
        return RemoteClient(name: name, target: target)
    }
}

// MARK: - Errors

public enum RemoteClientError: Error, CustomStringConvertible {
    case invalidURL(String)
    case authFailed(String)
    case rpcFailed(String)
    case noResponse
    case targetNotFound(String)

    public var description: String {
        switch self {
        case .invalidURL(let u):       return "Invalid URL: \(u)"
        case .authFailed(let m):       return "Remote auth failed: \(m)"
        case .rpcFailed(let m):        return "Remote RPC failed: \(m)"
        case .noResponse:              return "No response from remote server"
        case .targetNotFound(let n):   return "Remote target '\(n)' not found in config"
        }
    }
}
