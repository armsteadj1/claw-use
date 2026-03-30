import Foundation
import Network
import CUACore

/// UDS client that connects to the cuad daemon and sends JSON-RPC requests
struct DaemonClient {
    private static var versionCheckDone = false
    static let cuaDir = NSHomeDirectory() + "/.cua"
    static let socketPath = cuaDir + "/sock"
    static let pidFilePath = cuaDir + "/pid"

    /// Ensure the daemon is running. If not, start it and wait for readiness.
    /// Shared helper — every CLI command calls this before connecting.
    static func ensureDaemon() throws {
        // Print version notice once per process (reads from cache — fast, no network)
        if !versionCheckDone {
            versionCheckDone = true
            VersionNotice.printIfNeeded()
            VersionNotice.checkInBackground()
        }
        if isDaemonRunning() { return }
        try startDaemon()
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

    /// Send a JSON-RPC request to the daemon, return the response
    static func call(method: String, params: [String: AnyCodable]? = nil) throws -> JSONRPCResponse {
        try ensureDaemon()

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

    /// Resolve the path to the cuad binary — check same dir as CLI, then PATH, then common locations.
    static func resolveDaemonBinary() throws -> String {
        let fm = FileManager.default
        var daemonPath = ""

        // 1. Next to current binary (full path)
        let currentExe = CommandLine.arguments[0]
        let sameDir = (currentExe as NSString).deletingLastPathComponent + "/cuad"
        if fm.isExecutableFile(atPath: sameDir) {
            daemonPath = sameDir
        }

        // 2. Resolve via /usr/bin/which
        if daemonPath.isEmpty {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["cuad"]
            let pipe = Foundation.Pipe()
            which.standardOutput = pipe
            try? which.run()
            which.waitUntilExit()
            let resolved = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if fm.isExecutableFile(atPath: resolved) {
                daemonPath = resolved
            }
        }

        // 3. Common locations
        if daemonPath.isEmpty {
            let home = fm.homeDirectoryForCurrentUser.path
            for candidate in ["\(home)/.local/bin/cuad", "/usr/local/bin/cuad"] {
                if fm.isExecutableFile(atPath: candidate) {
                    daemonPath = candidate
                    break
                }
            }
        }

        guard fm.isExecutableFile(atPath: daemonPath) else {
            throw ClientError.daemonBinaryNotFound(daemonPath)
        }
        return daemonPath
    }

    /// Auto-start the daemon via fork+exec
    static func startDaemon() throws {
        let daemonPath = try resolveDaemonBinary()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = []

        // Detach the daemon from our process group
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
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

    /// Send a subscribe request and stream events as JSONL to stdout.
    /// Blocks until the connection is closed or SIGINT.
    static func stream(params: [String: AnyCodable]? = nil) throws {
        try ensureDaemon()

        let request = JSONRPCRequest(method: "subscribe", params: params)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var requestData = try encoder.encode(request)
        requestData.append(contentsOf: [0x0A])

        var connectionError: Error?

        let endpoint = NWEndpoint.unix(path: socketPath)
        let nwParams = NWParameters()
        nwParams.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let connection = NWConnection(to: endpoint, using: nwParams)

        // Use a dispatch source for SIGINT instead of signal() to avoid closure capture issues
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)  // Ignore default handler so dispatch source works
        sigSource.setEventHandler {
            connection.cancel()
        }
        sigSource.resume()

        let semaphore = DispatchSemaphore(value: 0)

        func readLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    // Print each line of data to stdout
                    if let str = String(data: data, encoding: .utf8) {
                        // May contain multiple newline-delimited messages
                        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
                            Swift.print(line)
                            fflush(stdout)
                        }
                    }
                }
                if isComplete || error != nil {
                    semaphore.signal()
                    return
                }
                readLoop()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Send subscribe request
                connection.send(content: requestData, completion: .contentProcessed({ error in
                    if let error = error {
                        connectionError = error
                        semaphore.signal()
                        return
                    }
                    // Start reading events
                    readLoop()
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

        let queue = DispatchQueue(label: "cua.stream")
        connection.start(queue: queue)

        // Block until disconnected or SIGINT
        semaphore.wait()
        sigSource.cancel()
        connection.cancel()

        if let error = connectionError {
            throw error
        }
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

        let queue = DispatchQueue(label: "cua.client")
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
            case .daemonStartFailed: return "Failed to start cuad daemon"
            case .daemonBinaryNotFound(let path): return "cuad not found at \(path)"
            case .timeout: return "Daemon request timed out"
            case .emptyResponse: return "Empty response from daemon"
            }
        }
    }
}
