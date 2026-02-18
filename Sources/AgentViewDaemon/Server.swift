import Foundation
import Network
import AgentViewCore

/// UDS server that accepts connections and dispatches JSON-RPC requests.
/// Supports streaming for event subscriptions.
final class Server {
    private var listener: NWListener?
    private let router: Router
    private let queue = DispatchQueue(label: "agentviewd.server")

    /// Active streaming connections: subscription ID -> connection
    private var streamingConnections: [String: NWConnection] = [:]
    private let streamLock = NSLock()

    init(router: Router) {
        self.router = router
    }

    func start(socketPath: String) throws {
        // Remove stale socket file
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        // Create parent directory
        let dir = (socketPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log("Server listening on \(socketPath)")
            case .failed(let error):
                log("Server failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        // Clean up streaming connections
        streamLock.lock()
        for (subId, _) in streamingConnections {
            router.eventBus.unsubscribe(subId)
        }
        streamingConnections.removeAll()
        streamLock.unlock()

        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        // Read until we get a complete JSON message (newline-delimited)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.processData(data, on: connection)
            }

            if isComplete || error != nil {
                self.cleanupConnection(connection)
                connection.cancel()
                return
            }

            // Continue reading
            self.receiveMessage(on: connection)
        }
    }

    private func processData(_ data: Data, on connection: NWConnection) {
        let request: JSONRPCRequest
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            request = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            sendResponse(JSONRPCResponse(error: .parseError, id: nil), on: connection)
            return
        }

        // Handle subscribe specially — sets up streaming
        if request.method == "subscribe" {
            setupStreaming(request: request, on: connection)
            return
        }

        let response = router.handle(request)
        sendResponse(response, on: connection)
    }

    private func setupStreaming(request: JSONRPCRequest, on connection: NWConnection) {
        let params = request.params ?? [:]
        let appFilter = params["app"]?.value as? String
        let typesStr = params["types"]?.value as? String
        let typeFilters: Set<String>? = typesStr.map {
            Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }

        // Subscribe to events and stream them to the connection
        let subId = router.eventBus.subscribe(appFilter: appFilter, typeFilters: typeFilters) { [weak self] event in
            self?.sendEvent(event, on: connection)
        }

        streamLock.lock()
        streamingConnections[subId] = connection
        streamLock.unlock()

        // Send initial ack response
        let ack: [String: AnyCodable] = [
            "subscribed": AnyCodable(true),
            "subscription_id": AnyCodable(subId),
            "app_filter": AnyCodable(appFilter),
            "type_filters": AnyCodable(typesStr),
        ]
        sendResponse(JSONRPCResponse(result: AnyCodable(ack), id: request.id), on: connection)

        // Keep reading to detect disconnect
        receiveMessage(on: connection)
    }

    private func sendEvent(_ event: AgentViewEvent, on connection: NWConnection) {
        do {
            var eventData = try JSONOutput.encode(event)
            eventData.append(contentsOf: [0x0A]) // newline
            connection.send(content: eventData, completion: .contentProcessed({ error in
                if let error = error {
                    log("Event send error: \(error)")
                }
            }))
        } catch {
            log("Event encode error: \(error)")
        }
    }

    private func sendResponse(_ response: JSONRPCResponse, on connection: NWConnection) {
        do {
            var responseData = try JSONOutput.encode(response)
            responseData.append(contentsOf: [0x0A]) // newline delimiter
            connection.send(content: responseData, completion: .contentProcessed({ error in
                if let error = error {
                    log("Send error: \(error)")
                }
            }))
        } catch {
            log("Response encode error: \(error)")
        }
    }

    private func cleanupConnection(_ connection: NWConnection) {
        streamLock.lock()
        let matchingIds = streamingConnections.filter { $0.value === connection }.map { $0.key }
        for subId in matchingIds {
            streamingConnections.removeValue(forKey: subId)
            router.eventBus.unsubscribe(subId)
        }
        streamLock.unlock()
    }
}

func log(_ message: String) {
    fputs("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n", stderr)
}
