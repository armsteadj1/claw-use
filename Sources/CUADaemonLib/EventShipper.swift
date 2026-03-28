import CryptoKit
import CUACore
import Foundation

// MARK: - EventShipper

/// Subscribes to the EventBus, privacy-filters events, and POSTs batches to the
/// agent's RemoteServer at the configured `stream.push_to` URL.
///
/// Uses the same HMAC challenge-response auth as RemoteClient (GET /handshake + POST /auth).
/// Buffers up to 1000 events; flushes every `flush_interval` seconds or when 100 events accumulate.
public final class EventShipper {

    private let config: StreamConfig
    private let filter: EventStreamFilter

    private var buffer: [StreamEvent] = []
    private let lock = NSLock()
    private var flushTimer: DispatchSourceTimer?
    private var subscriptionId: String?

    private var sessionToken: String?
    private var tokenExpiry: Date?

    private let maxBuffer = 1000
    private let flushThreshold = 100

    public init(config: StreamConfig) {
        self.config = config
        self.filter = EventStreamFilter(config: config)
    }

    // MARK: - Lifecycle

    public func start(eventBus: EventBus) {
        subscriptionId = eventBus.subscribe { [weak self] event in
            self?.receive(event: event)
        }

        let interval = max(1, config.flushInterval)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cuad.event-shipper", qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer

        log("[stream-shipper] started — push_to=\(config.pushTo) flush=\(interval)s")
    }

    public func stop() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: - Event Ingestion

    private func receive(event: CUAEvent) {
        guard let streamEvent = filter.filter(event) else { return }

        lock.lock()
        buffer.append(streamEvent)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
        let shouldFlush = buffer.count >= flushThreshold
        lock.unlock()

        if shouldFlush { flush() }
    }

    // MARK: - Flush

    func flush() {
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        let batch = buffer
        lock.unlock()

        guard let token = getOrRefreshToken() else {
            log("[stream-shipper] auth failed — keeping \(batch.count) events for retry")
            return
        }

        let body = encodeNDJSON(batch)
        guard !body.isEmpty, let url = URL(string: config.pushTo + "/stream/push") else {
            log("[stream-shipper] invalid push_to: \(config.pushTo)")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let sem = DispatchSemaphore(value: 0)
        var success = false

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            defer { sem.signal() }
            if let error = error {
                log("[stream-shipper] push error: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                success = true
            case 401:
                self?.sessionToken = nil
                self?.tokenExpiry = nil
                log("[stream-shipper] 401 — will re-auth on next flush")
            default:
                log("[stream-shipper] push failed: HTTP \(status)")
            }
        }.resume()

        sem.wait()

        if success {
            lock.lock()
            buffer.removeFirst(min(batch.count, buffer.count))
            lock.unlock()
        }
    }

    // MARK: - Auth (HMAC challenge-response, mirrors RemoteClient)

    private func getOrRefreshToken() -> String? {
        if let token = sessionToken, let expiry = tokenExpiry, expiry.timeIntervalSinceNow > 60 {
            return token
        }
        return authenticate()
    }

    private func authenticate() -> String? {
        // Step 1: GET /handshake
        guard let handshakeURL = URL(string: config.pushTo + "/handshake") else { return nil }
        var hsReq = URLRequest(url: handshakeURL, timeoutInterval: 10)
        hsReq.httpMethod = "GET"

        let hsSem = DispatchSemaphore(value: 0)
        var challenge: String?

        URLSession.shared.dataTask(with: hsReq) { data, response, _ in
            defer { hsSem.signal() }
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ch = json["challenge"] as? String
            else { return }
            challenge = ch
        }.resume()
        hsSem.wait()

        guard let ch = challenge else {
            log("[stream-shipper] handshake failed")
            return nil
        }

        // Step 2: compute HMAC-SHA256(secret, challenge:ts)
        let ts = Int(Date().timeIntervalSince1970)
        let key = SymmetricKey(data: Data(config.secret.utf8))
        let msg = Data("\(ch):\(ts)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        let sig = mac.map { String(format: "%02x", $0) }.joined()

        // Step 3: POST /auth  (include our name so the server can label our stream files)
        let myName = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first ?? ProcessInfo.processInfo.hostName
        let authBody: [String: Any] = ["sig": sig, "challenge": ch, "ts": ts, "name": myName]
        guard let authBodyData = try? JSONSerialization.data(withJSONObject: authBody),
              let authURL = URL(string: config.pushTo + "/auth") else { return nil }

        var authReq = URLRequest(url: authURL, timeoutInterval: 10)
        authReq.httpMethod = "POST"
        authReq.httpBody = authBodyData
        authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let authSem = DispatchSemaphore(value: 0)
        var token: String?
        var ttl = 3600

        URLSession.shared.dataTask(with: authReq) { data, response, _ in
            defer { authSem.signal() }
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = json["token"] as? String
            else { return }
            token = t
            ttl = json["ttl"] as? Int ?? 3600
        }.resume()
        authSem.wait()

        if let t = token {
            sessionToken = t
            tokenExpiry = Date().addingTimeInterval(TimeInterval(ttl))
            log("[stream-shipper] authenticated (ttl=\(ttl)s)")
        } else {
            log("[stream-shipper] auth failed")
        }
        return token
    }

    // MARK: - Encoding

    private func encodeNDJSON(_ events: [StreamEvent]) -> Data {
        let encoder = JSONEncoder()
        var lines: [String] = []
        for event in events {
            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
