import Foundation
import AgentViewCore

// MARK: - Configuration

let agentviewDir = NSHomeDirectory() + "/.agentview"
let socketPath = agentviewDir + "/sock"
let pidFilePath = agentviewDir + "/pid"

// MARK: - PID file management

func writePidFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let fm = FileManager.default
    if !fm.fileExists(atPath: agentviewDir) {
        try? fm.createDirectory(atPath: agentviewDir, withIntermediateDirectories: true)
    }
    try? "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
}

func removePidFile() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
}

func removeSocketFile() {
    try? FileManager.default.removeItem(atPath: socketPath)
}

// MARK: - Signal handling

func setupSignalHandlers(server: Server, screenState: ScreenState, cdpPool: CDPConnectionPool) {
    let signalCallback: @convention(c) (Int32) -> Void = { sig in
        log("Received signal \(sig), shutting down...")
        removePidFile()
        removeSocketFile()
        exit(0)
    }

    signal(SIGTERM, signalCallback)
    signal(SIGINT, signalCallback)
}

// MARK: - Main

log("agentviewd starting...")

// Initialize components
let screenState = ScreenState()
screenState.startObserving()

let cdpPool = CDPConnectionPool()
cdpPool.start()

let router = Router(screenState: screenState, cdpPool: cdpPool)
let server = Server(router: router)

// Write PID file
writePidFile()

// Setup signal handlers
setupSignalHandlers(server: server, screenState: screenState, cdpPool: cdpPool)

// Start server
do {
    try server.start(socketPath: socketPath)
} catch {
    log("Failed to start server: \(error)")
    removePidFile()
    exit(1)
}

log("agentviewd ready (pid \(ProcessInfo.processInfo.processIdentifier))")

// Run the event loop
RunLoop.main.run()
