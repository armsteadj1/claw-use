import CryptoKit
import CUACore
import Foundation
import Network

// MARK: - RemoteServer
// tailscaleIP() and isTailscaleRange() are defined in CUACore/RemoteClient.swift

/// Minimal HTTP proxy that lets a remote agent drive a local cuad over Tailscale.
///
/// Endpoints:
///   GET  /handshake  — issues a one-time 32-byte hex challenge (no auth)
///   POST /auth       — verifies HMAC-SHA256, returns a session token
///   POST /rpc        — proxies authenticated JSON-RPC to local cuad UDS socket
public final class RemoteServer {

    // MARK: - Internal Types

    private struct ChallengeEntry {
        let nonce: String
        let expiry: Date
    }

    private struct SessionEntry {
        let token: String
        let expiry: Date
    }

    // MARK: - Properties

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuad.remote-server", qos: .userInitiated)

    private var challenges: [String: ChallengeEntry] = [:]  // nonce → entry
    private var sessions: [String: SessionEntry] = [:]       // token → entry
    private let stateLock = NSLock()

    private let config: RemoteServerConfig

    /// Called when the listener is ready; receives the actual bound port.
    public var onReady: ((UInt16) -> Void)?
    public private(set) var actualPort: UInt16?

    // MARK: - Init

    public init(config: RemoteServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func start() throws {
        let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: UInt16(config.port))!
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let bound = self.listener?.port?.rawValue ?? UInt16(self.config.port)
                self.actualPort = bound
                log("[remote-server] Listening on port \(bound) (bind: \(self.config.bind))")
                self.onReady?(bound)
            case .failed(let error):
                log("[remote-server] Failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        // IP-level filtering based on bind config
        if let remote = remoteHost(from: connection.endpoint) {
            switch config.bind {
            case "localhost":
                guard remote == "127.0.0.1" || remote == "::1" else {
                    connection.cancel(); return
                }
            case "tailscale":
                guard isTailscaleRange(remote) else {
                    connection.cancel(); return
                }
            default:
                break // "0.0.0.0" — accept all
            }
        }

        connection.start(queue: queue)
        readRequest(from: connection, accumulated: Data()) { [weak self] req in
            guard let self = self else { connection.cancel(); return }
            guard let req = req else { connection.cancel(); return }
            self.route(req, on: connection)
        }
    }

    private func remoteHost(from endpoint: NWEndpoint) -> String? {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return nil
    }

    // MARK: - HTTP Parsing

    private func readRequest(
        from connection: NWConnection,
        accumulated: Data,
        completion: @escaping (HTTPRequest?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { completion(nil); return }

            var buf = accumulated
            if let d = data { buf.append(d) }

            let sep = Data("\r\n\r\n".utf8)
            guard let headerEnd = buf.range(of: sep) else {
                if isComplete || error != nil { completion(nil); return }
                self.readRequest(from: connection, accumulated: buf, completion: completion)
                return
            }

            let headerData = buf[..<headerEnd.lowerBound]
            let bodyStart = headerEnd.upperBound

            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                completion(nil); return
            }

            let lines = headerStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { completion(nil); return }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { completion(nil); return }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
                let k = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let bodySlice = buf[bodyStart...]

            if bodySlice.count >= contentLength {
                let body = Data(bodySlice.prefix(contentLength))
                completion(HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body))
            } else if isComplete || error != nil {
                completion(nil)
            } else {
                self.readRequest(from: connection, accumulated: buf, completion: completion)
            }
        }
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequest, on conn: NWConnection) {
        let path = req.path.components(separatedBy: "?")[0]
        switch (req.method, path) {
        case ("GET", "/handshake"):
            handleHandshake(on: conn)
        case ("POST", "/auth"):
            handleAuth(req: req, on: conn)
        case ("POST", "/rpc"):
            handleRPC(req: req, on: conn)
        default:
            sendJSON(on: conn, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: - GET /handshake

    private func handleHandshake(on conn: NWConnection) {
        let nonce = randomHex(32)
        let entry = ChallengeEntry(nonce: nonce, expiry: Date().addingTimeInterval(30))

        stateLock.lock()
        evictExpiredChallenges()
        // Evict oldest if over capacity
        if challenges.count >= 100 {
            let oldest = challenges.min { $0.value.expiry < $1.value.expiry }?.key
            if let k = oldest { challenges.removeValue(forKey: k) }
        }
        challenges[nonce] = entry
        stateLock.unlock()

        sendJSON(on: conn, status: 200, body: ["challenge": nonce, "expires_in": 30])
    }

    // MARK: - POST /auth

    private func handleAuth(req: HTTPRequest, on conn: NWConnection) {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let sig       = body["sig"]       as? String,
              let challenge = body["challenge"] as? String,
              let ts        = body["ts"]        as? Int
        else {
            sendJSON(on: conn, status: 400, body: ["error": "invalid request"])
            return
        }

        // Replay protection: ts must be within ±30 s of now
        let now = Int(Date().timeIntervalSince1970)
        guard abs(now - ts) <= 30 else {
            sendJSON(on: conn, status: 401, body: ["error": "unauthorized"])
            return
        }

        // Consume challenge (single-use)
        stateLock.lock()
        evictExpiredChallenges()
        let entry = challenges[challenge]
        if entry != nil { challenges.removeValue(forKey: challenge) }
        stateLock.unlock()

        guard let entry = entry, entry.expiry > Date() else {
            sendJSON(on: conn, status: 401, body: ["error": "unauthorized"])
            return
        }

        // Verify HMAC-SHA256(secret, challenge + ":" + ts)
        let key = SymmetricKey(data: Data(config.secret.utf8))
        let msg = Data("\(challenge):\(ts)".utf8)
        let expected = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        let expectedHex = expected.map { String(format: "%02x", $0) }.joined()

        guard sig == expectedHex else {
            sendJSON(on: conn, status: 401, body: ["error": "unauthorized"])
            return
        }

        // Issue session token
        let token = randomHex(64)
        let tokenEntry = SessionEntry(
            token: token,
            expiry: Date().addingTimeInterval(TimeInterval(config.tokenTtl))
        )

        stateLock.lock()
        sessions[token] = tokenEntry
        stateLock.unlock()

        sendJSON(on: conn, status: 200, body: ["token": token, "ttl": config.tokenTtl])
    }

    // MARK: - POST /rpc

    private let allowedMethods: Set<String> = [
        "ping", "list", "snapshot", "act", "pipe",
        "screenshot", "status", "events", "health",
    ]

    private func handleRPC(req: HTTPRequest, on conn: NWConnection) {
        // Validate Bearer token
        guard let auth = req.headers["authorization"], auth.hasPrefix("Bearer ") else {
            sendJSON(on: conn, status: 401, body: ["error": "unauthorized"])
            return
        }
        let token = String(auth.dropFirst("Bearer ".count))

        stateLock.lock()
        let session = sessions[token]
        stateLock.unlock()

        guard let session = session, session.expiry > Date() else {
            sendJSON(on: conn, status: 401, body: ["error": "unauthorized"])
            return
        }

        // Parse the JSON-RPC body
        guard let rpc = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let method = rpc["method"] as? String
        else {
            sendJSON(on: conn, status: 400, body: ["error": "invalid rpc body"])
            return
        }

        // Only allow whitelisted methods
        guard allowedMethods.contains(method) else {
            sendJSON(on: conn, status: 403, body: ["error": "method not allowed"])
            return
        }

        // Check blocked_apps
        if !config.blockedApps.isEmpty,
           let params = rpc["params"] as? [String: Any],
           let app = params["app"] as? String {
            let blocked = config.blockedApps.contains { $0.lowercased() == app.lowercased() }
            if blocked {
                sendJSON(on: conn, status: 403, body: ["error": "app blocked"])
                return
            }
        }

        // Forward to local cuad UDS socket
        guard let responseData = forwardToLocalDaemon(data: req.body) else {
            sendJSON(on: conn, status: 502, body: ["error": "daemon unavailable"])
            return
        }

        sendRaw(on: conn, status: 200, contentType: "application/json", body: responseData)
        _ = session // suppress unused warning
    }

    // MARK: - UDS Forwarding

    private func forwardToLocalDaemon(data: Data) -> Data? {
        let socketPath = NSHomeDirectory() + "/.cua/sock"
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strncpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    cstr,
                    maxLen
                )
            }
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return nil }

        // Send request + newline delimiter
        var sendData = data
        sendData.append(0x0A)
        let sent = sendData.withUnsafeBytes { ptr -> Int in
            send(sock, ptr.baseAddress!, ptr.count, 0)
        }
        guard sent == sendData.count else { return nil }

        // Read until newline (JSON-RPC is newline-delimited)
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buf.prefix(n))
            if response.last == 0x0A { break }
        }
        return response.isEmpty ? nil : response
    }

    // MARK: - Helpers

    private func evictExpiredChallenges() {
        // Must be called with stateLock held
        let now = Date()
        challenges = challenges.filter { $0.value.expiry > now }
    }

    private func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP Response

    private func sendJSON(on conn: NWConnection, status: Int, body: [String: Any]) {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            conn.cancel(); return
        }
        sendRaw(on: conn, status: status, contentType: "application/json", body: bodyData)
    }

    private func sendRaw(on conn: NWConnection, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 502: statusText = "Bad Gateway"
        default:  statusText = "Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
                     "Content-Type: \(contentType)\r\n" +
                     "Content-Length: \(body.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}
