import Foundation

/// Persistent CDP WebSocket connection pool for the daemon
public final class CDPConnectionPool {
    public enum ConnectionHealth: String, Codable {
        case connected
        case reconnecting
        case dead
    }

    public struct ConnectionInfo: Codable {
        public let port: Int
        public let health: String
        public let pageCount: Int
        public let lastPingMs: Int?
    }

    private struct PoolEntry {
        let port: Int
        var wsTask: URLSessionWebSocketTask?
        var pageWsUrl: String?
        var health: ConnectionHealth
        var lastPingTime: Date?
        var lastPingMs: Int?
        var session: URLSession
        var messageId: Int = 0
    }

    private var connections: [Int: PoolEntry] = [:]
    private let lock = NSLock()
    private var keepAliveTimer: Timer?
    private var discoveryTimer: Timer?
    private let defaultPorts = [9222, 9229]

    public init() {}

    /// Start the connection pool: discover Electron apps and begin keep-alive
    public func start() {
        discoverAndConnect()

        // Keep-alive every 30s
        DispatchQueue.main.async { [weak self] in
            self?.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.pingAll()
            }
            // Re-discover every 60s
            self?.discoveryTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.discoverAndConnect()
            }
        }
    }

    public func stop() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        discoveryTimer?.invalidate()
        discoveryTimer = nil

        lock.lock()
        for (_, entry) in connections {
            entry.wsTask?.cancel(with: .goingAway, reason: nil)
        }
        connections.removeAll()
        lock.unlock()
    }

    /// Evaluate JS on a CDP connection, reusing existing WebSocket
    public func evaluate(port: Int, expression: String) throws -> String? {
        lock.lock()
        var entry = connections[port]
        lock.unlock()

        // If no connection exists, try to establish one
        if entry == nil {
            try connectToPort(port)
            lock.lock()
            entry = connections[port]
            lock.unlock()
        }

        guard var entry = entry, let pageWsUrl = entry.pageWsUrl else {
            // Fall back to cold CDP
            let cdp = CDPHelper(port: port)
            let pages = try cdp.listPages()
            guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
                throw CDPHelper.CDPError.noPages
            }
            return try cdp.evaluate(pageWsUrl: wsUrl, expression: expression)
        }

        // If we have a live WebSocket, use it
        if let wsTask = entry.wsTask, wsTask.state == .running {
            entry.messageId += 1
            let msgId = entry.messageId
            lock.lock()
            connections[port] = entry
            lock.unlock()
            return try evaluateOnWs(wsTask: wsTask, expression: expression, id: msgId)
        }

        // WebSocket is dead, reconnect
        lock.lock()
        connections[port]?.health = .reconnecting
        lock.unlock()

        guard let url = URL(string: pageWsUrl) else {
            throw CDPHelper.CDPError.invalidUrl(pageWsUrl)
        }

        let session = entry.session
        let newWsTask = session.webSocketTask(with: url)
        newWsTask.resume()

        entry.wsTask = newWsTask
        entry.health = .connected
        entry.messageId += 1
        let msgId = entry.messageId

        lock.lock()
        connections[port] = entry
        lock.unlock()

        return try evaluateOnWs(wsTask: newWsTask, expression: expression, id: msgId)
    }

    /// Get connection info for all tracked ports
    public func connectionInfos() -> [ConnectionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return connections.map { (port, entry) in
            ConnectionInfo(
                port: port,
                health: entry.health.rawValue,
                pageCount: entry.pageWsUrl != nil ? 1 : 0,
                lastPingMs: entry.lastPingMs
            )
        }
    }

    // MARK: - Private

    private func discoverAndConnect() {
        for port in defaultPorts {
            lock.lock()
            let exists = connections[port] != nil
            lock.unlock()
            if !exists {
                try? connectToPort(port)
            }
        }
    }

    private func connectToPort(_ port: Int) throws {
        let cdp = CDPHelper(port: port)
        let pages: [CDPHelper.PageInfo]
        do {
            pages = try cdp.listPages()
        } catch {
            return // Port not listening, skip
        }

        guard let page = pages.first, let wsUrl = page.webSocketDebuggerUrl else {
            return
        }

        let session = URLSession(configuration: .default)
        guard let url = URL(string: wsUrl) else { return }

        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        let entry = PoolEntry(
            port: port,
            wsTask: wsTask,
            pageWsUrl: wsUrl,
            health: .connected,
            lastPingTime: Date(),
            lastPingMs: nil,
            session: session,
            messageId: 0
        )

        lock.lock()
        connections[port] = entry
        lock.unlock()
    }

    private func pingAll() {
        lock.lock()
        let ports = Array(connections.keys)
        lock.unlock()

        for port in ports {
            lock.lock()
            guard let entry = connections[port], let wsTask = entry.wsTask else {
                lock.unlock()
                continue
            }
            lock.unlock()

            let start = DispatchTime.now()
            let semaphore = DispatchSemaphore(value: 0)
            var alive = false

            wsTask.sendPing { error in
                alive = (error == nil)
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + 5)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

            lock.lock()
            if result == .timedOut || !alive {
                connections[port]?.health = .dead
                connections[port]?.wsTask?.cancel(with: .goingAway, reason: nil)
                connections[port]?.wsTask = nil
            } else {
                connections[port]?.health = .connected
                connections[port]?.lastPingTime = Date()
                connections[port]?.lastPingMs = elapsed
            }
            lock.unlock()
        }
    }

    private func evaluateOnWs(wsTask: URLSessionWebSocketTask, expression: String, id: Int) throws -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var resultValue: String?
        var wsError: Error?

        let msg: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: msg)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        wsTask.send(.string(jsonString)) { error in
            if let error = error {
                wsError = error
                semaphore.signal()
                return
            }

            wsTask.receive { result in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let resultObj = json["result"] as? [String: Any],
                           let innerResult = resultObj["result"] as? [String: Any] {
                            resultValue = innerResult["value"] as? String
                        }
                    default:
                        break
                    }
                case .failure(let error):
                    wsError = error
                }
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 10)

        if let error = wsError {
            throw error
        }
        return resultValue
    }
}
