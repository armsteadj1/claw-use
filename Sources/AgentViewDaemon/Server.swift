import Foundation
import Network
import AgentViewCore

/// UDS server that accepts connections and dispatches JSON-RPC requests
final class Server {
    private var listener: NWListener?
    private let router: Router
    private let queue = DispatchQueue(label: "agentviewd.server")

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
                connection.cancel()
                return
            }

            // Continue reading
            self.receiveMessage(on: connection)
        }
    }

    private func processData(_ data: Data, on connection: NWConnection) {
        let response: JSONRPCResponse

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let request = try decoder.decode(JSONRPCRequest.self, from: data)
            response = router.handle(request)
        } catch {
            response = JSONRPCResponse(error: .parseError, id: nil)
        }

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
}

func log(_ message: String) {
    fputs("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n", stderr)
}
