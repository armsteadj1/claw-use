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

// Initialize wake client (connects to OpenClaw gateway)
let wakeClient = WakeClient.fromConfig()

// Initialize components
let screenState = ScreenState()

// Wire screen state changes to wake events
screenState.onChange = { event, state in
    log("Screen event: \(event) — screen=\(state.screen), display=\(state.display)")
    switch event {
    case "screen_unlocked":
        wakeClient.screenUnlocked()
    case "screen_locked":
        wakeClient.screenLocked()
    case "display_wake":
        log("Display woke up")
    case "display_sleep":
        log("Display sleeping")
    default:
        break
    }
}

screenState.startObserving()

let cdpPool = CDPConnectionPool()
cdpPool.start()

// Initialize transport layer
let transportRouter = TransportRouter()
let axTransport = AXTransport()
let cdpTransport = CDPTransport(pool: cdpPool)
let appleScriptTransport = AppleScriptTransport()

transportRouter.register(transport: axTransport)
transportRouter.register(transport: cdpTransport)
transportRouter.register(transport: appleScriptTransport)
transportRouter.configureDefaults()

let router = Router(screenState: screenState, cdpPool: cdpPool, transportRouter: transportRouter)
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
log("  transports: ax, cdp, applescript")

// Run the event loop
RunLoop.main.run()
