import Foundation
import Network
import AgentViewCore

/// UDS client that connects to the agentviewd daemon and sends JSON-RPC requests
struct DaemonClient {
    static let agentviewDir = NSHomeDirectory() + "/.agentview"
    static let socketPath = agentviewDir + "/sock"
    static let pidFilePath = agentviewDir + "/pid"

    /// Send a JSON-RPC request to the daemon, return the response
    static func call(method: String, params: [String: AnyCodable]? = nil) throws -> JSONRPCResponse {
        // Ensure daemon is running
        if !isDaemonRunning() {
            try startDaemon()
            // Wait for daemon to be ready
            var ready = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.25)
                if isDaemonRunning() {
                    ready = true
                    break
                }
            }
            if !ready {
                throw ClientError.daemonStartFailed
            }
        }

        let request = JSONRPCRequest(method: method, params: params)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var requestData = try encoder.encode(request)
        requestData.append(contentsOf: [0x0A]) // newline delimiter

        return try sendViaSocket(data: requestData)
    }

    /// Check if daemon is running by checking PID file and process
    static func isDaemonRunning() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        // Check if process is alive
        return kill(pid, 0) == 0
    }

    /// Get the daemon PID
    static func daemonPID() -> Int32? {
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return kill(pid, 0) == 0 ? pid : nil
    }

    /// Auto-start the daemon via fork+exec
    static func startDaemon() throws {
        // Find agentviewd binary next to the current binary
        let currentExe = CommandLine.arguments[0]
        let dir = (currentExe as NSString).deletingLastPathComponent
        let daemonPath = dir + "/agentviewd"

        // Check if the daemon binary exists
        guard FileManager.default.isExecutableFile(atPath: daemonPath) else {
            throw ClientError.daemonBinaryNotFound(daemonPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = []

        // Detach the daemon from our process group
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Keep stderr for debugging
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Don't wait — it's a daemon
    }

    /// Stop the daemon
    static func stopDaemon() -> Bool {
        guard let pid = daemonPID() else { return false }
        kill(pid, SIGTERM)
        // Wait for it to exit
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.2)
            if kill(pid, 0) != 0 { return true }
        }
        // Force kill
        kill(pid, SIGKILL)
        return true
    }

    // MARK: - Private

    private static func sendViaSocket(data: Data) throws -> JSONRPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var connectionError: Error?

        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Send the request
                connection.send(content: data, completion: .contentProcessed({ error in
                    if let error = error {
                        connectionError = error
                        semaphore.signal()
                        return
                    }

                    // Read response
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, error in
                        if let error = error {
                            connectionError = error
                        }
                        if let data = data {
                            responseData = data
                        }
                        semaphore.signal()
                    }
                }))
            case .failed(let error):
                connectionError = error
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        let queue = DispatchQueue(label: "agentview.client")
        connection.start(queue: queue)

        let result = semaphore.wait(timeout: .now() + 30)
        connection.cancel()

        if result == .timedOut {
            throw ClientError.timeout
        }
        if let error = connectionError {
            throw error
        }

        guard !responseData.isEmpty else {
            throw ClientError.emptyResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(JSONRPCResponse.self, from: responseData)
    }

    enum ClientError: Error, CustomStringConvertible {
        case daemonStartFailed
        case daemonBinaryNotFound(String)
        case timeout
        case emptyResponse

        var description: String {
            switch self {
            case .daemonStartFailed: return "Failed to start agentviewd daemon"
            case .daemonBinaryNotFound(let path): return "agentviewd not found at \(path)"
            case .timeout: return "Daemon request timed out"
            case .emptyResponse: return "Empty response from daemon"
            }
        }
    }
}
