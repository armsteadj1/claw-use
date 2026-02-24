import CryptoKit
import CUACore
import Foundation
import Network

/// Minimal HTTP request parsed from raw TCP data.
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

/// HTTP server for the remote-ingest endpoint (receiver / agent-machine side).
///
/// Listens on a configurable TCP port and handles:
/// - `POST /remote-handshake` – HMAC auth, issues session token (single-use pairing key)
/// - `POST /remote-ingest`    – receive snapshots from an authenticated sender
/// - `GET  /remote-ping`      – health check
public final class RemoteHTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuad.remote-http")
    public let store: RemoteStore

    /// Pending one-time pairing keys: peerId -> 32-byte secret.
    /// Cleared on first successful handshake.
    private var pendingKeys: [String: Data] = [:]
    private let pairingLock = NSLock()

    /// Called on the server's dispatch queue once the listener is ready.
    /// Receives the actual bound port number (useful when port 0 is requested).
    public var onReady: ((UInt16) -> Void)?

    /// The port the server is actually listening on (set when listener reaches .ready).
    public private(set) var actualPort: UInt16?

    public init(store: RemoteStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    public func start(port: UInt16) throws {
        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let boundPort = self.listener?.port?.rawValue ?? port
                self.actualPort = boundPort
                log("[remote] HTTP server listening on port \(boundPort)")
                self.onReady?(boundPort)
            case .failed(let error):
                log("[remote] HTTP server failed: \(error)")
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

    public var isRunning: Bool { listener != nil }

    // MARK: - Pairing Key Management

    /// Allocate a fresh one-time pairing key. Returns (peerId, base64Secret).
    public func registerPairingKey() -> (peerId: String, secretBase64: String) {
        let peerId = UUID().uuidString
        let (secretData, secretBase64) = RemoteCrypto.generateKey()

        pairingLock.lock()
        pendingKeys[peerId] = secretData
        pairingLock.unlock()

        return (peerId, secretBase64)
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(from: connection, accumulated: Data()) { [weak self] request in
            guard let self = self else { connection.cancel(); return }
            guard let request = request else { connection.cancel(); return }
            self.route(request: request, on: connection)
        }
    }

    /// Accumulate TCP data until we have a complete HTTP/1.1 request (headers + body).
    private func readHTTPRequest(
        from connection: NWConnection,
        accumulated: Data,
        completion: @escaping (HTTPRequest?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { completion(nil); return }

            var buffer = accumulated
            if let data = data { buffer.append(data) }

            let sep = Data("\r\n\r\n".utf8)
            if let headerEnd = buffer.range(of: sep) {
                let headerData = buffer[..<headerEnd.lowerBound]
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
                    guard !line.isEmpty, let colonIdx = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<colonIdx]).lowercased()
                        .trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colonIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }

                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let bodySlice = buffer[bodyStart...]

                if bodySlice.count >= contentLength {
                    let body = Data(bodySlice.prefix(contentLength))
                    completion(HTTPRequest(method: parts[0], path: parts[1],
                                           headers: headers, body: body))
                } else if isComplete || error != nil {
                    completion(nil)
                } else {
                    self.readHTTPRequest(from: connection, accumulated: buffer, completion: completion)
                }
            } else if isComplete || error != nil {
                completion(nil)
            } else {
                self.readHTTPRequest(from: connection, accumulated: buffer, completion: completion)
            }
        }
    }

    // MARK: - Routing

    private func route(request: HTTPRequest, on connection: NWConnection) {
        // Strip query string from path
        let path = request.path.components(separatedBy: "?")[0]

        switch (request.method, path) {
        case ("GET", "/remote-ping"):
            sendJSON(on: connection, status: 200, body: ["ok": true])
        case ("POST", "/remote-handshake"):
            handleHandshake(request: request, on: connection)
        case ("POST", "/remote-ingest"):
            handleIngest(request: request, on: connection)
        default:
            sendJSON(on: connection, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: - Handshake

    private func handleHandshake(request: HTTPRequest, on connection: NWConnection) {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let peerId   = body["peer_id"]   as? String,
              let peerName = body["peer_name"] as? String,
              let timestamp = body["timestamp"] as? Int,
              let hmacHex  = body["hmac"]      as? String
        else {
            sendJSON(on: connection, status: 400, body: ["error": "invalid request body"])
            return
        }

        // Consume the one-time key (single-use)
        pairingLock.lock()
        let secretData = pendingKeys[peerId]
        if secretData != nil { pendingKeys.removeValue(forKey: peerId) }
        pairingLock.unlock()

        guard let secretData = secretData else {
            sendJSON(on: connection, status: 401, body: ["error": "unknown peer or key expired"])
            return
        }

        // Reject timestamps older than 5 minutes to prevent replay
        let now = Int(Date().timeIntervalSince1970)
        guard abs(now - timestamp) < 300 else {
            sendJSON(on: connection, status: 401, body: ["error": "timestamp out of range"])
            return
        }

        // Verify HMAC
        let message = "\(peerId):\(timestamp)"
        guard RemoteCrypto.verifyHMAC(message: message, secret: secretData, expectedHex: hmacHex) else {
            sendJSON(on: connection, status: 401, body: ["error": "invalid HMAC"])
            return
        }

        // Issue session token
        let sessionToken = UUID().uuidString
        let session = RemoteSession(
            peerId: peerId,
            peerName: peerName,
            sessionToken: sessionToken,
            lastUsed: Date()
        )
        store.addSession(session)

        log("[remote] Handshake OK – peer '\(peerName)' (\(peerId))")
        sendJSON(on: connection, status: 200, body: [
            "session_token": sessionToken,
            "peer_id": peerId,
        ])
    }

    // MARK: - Ingest

    private func handleIngest(request: HTTPRequest, on connection: NWConnection) {
        guard let authHeader = request.headers["authorization"],
              authHeader.hasPrefix("Bearer ") else {
            sendJSON(on: connection, status: 401, body: ["error": "missing authorization header"])
            return
        }
        let token = String(authHeader.dropFirst("Bearer ".count))

        guard let session = store.session(forToken: token) else {
            sendJSON(on: connection, status: 401, body: ["error": "invalid session token"])
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var record = try? decoder.decode(RemoteSnapshotRecord.self, from: request.body) else {
            sendJSON(on: connection, status: 400, body: ["error": "invalid snapshot payload"])
            return
        }

        // Server-side: silently drop snapshots from blocked apps (returns 200 with ok:false).
        let bundleId = record.snapshot.bundleId ?? ""
        if RemoteScrubber.isBlocked(bundleId: bundleId) {
            sendJSON(on: connection, status: 200, body: ["ok": false, "blocked": true])
            return
        }

        // Server-side scrubbing: blank secure text field values before storage.
        let scrubbed = RemoteScrubber.scrub(record.snapshot)
        record = RemoteSnapshotRecord(
            timestamp: record.timestamp,
            peerId: record.peerId,
            peerName: record.peerName,
            snapshot: scrubbed,
            appList: record.appList
        )

        store.appendSnapshot(record)
        store.updateSessionLastUsed(session.peerId)

        sendJSON(on: connection, status: 200, body: ["ok": true, "peer_id": session.peerId])
    }

    // MARK: - HTTP Response Helper

    private func sendJSON(on connection: NWConnection, status: Int, body: [String: Any]) {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            connection.cancel(); return
        }
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\n" +
                     "Content-Type: application/json\r\n" +
                     "Content-Length: \(bodyData.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
