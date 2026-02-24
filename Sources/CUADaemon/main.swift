import Foundation
import CUACore
import CUADaemonLib

// MARK: - Configuration

let cuaDir = NSHomeDirectory() + "/.cua"
let socketPath = cuaDir + "/sock"
let pidFilePath = cuaDir + "/pid"

// MARK: - PID file management

func writePidFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let fm = FileManager.default
    if !fm.fileExists(atPath: cuaDir) {
        try? fm.createDirectory(atPath: cuaDir, withIntermediateDirectories: true)
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

func setupSignalHandlers(server: Server, screenState: ScreenState, cdpPool: CDPConnectionPool, eventBus: EventBus) {
    let signalCallback: @convention(c) (Int32) -> Void = { sig in
        log("Received signal \(sig), shutting down...")
        removePidFile()
        removeSocketFile()
        exit(0)
    }

    signal(SIGTERM, signalCallback)
    signal(SIGINT, signalCallback)
}

// MARK: - Restart count (persists across daemon restarts for launchd health)

func incrementRestartCount() {
    let path = cuaDir + "/restart_count"
    let current = (try? String(contentsOfFile: path, encoding: .utf8))
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    try? "\(current + 1)".write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Main

log("cuad starting...")
incrementRestartCount()

// Initialize wake client (connects to OpenClaw gateway)
let wakeClient = WakeClient.fromConfig()

// Initialize components
let screenState = ScreenState()
let eventBus = EventBus()
let snapshotCache = SnapshotCache()

// Wire screen state changes to wake events AND event bus
screenState.onChange = { event, state in
    log("Screen event: \(event) — screen=\(state.screen), display=\(state.display)")

    // Publish to event bus
    eventBus.publishScreenEvent(event, state: state)

    // Notify gateway
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
screenState.startPolling(interval: 0.5)  // 500ms poll — fast detection
log("Screen state polling active (500ms interval)")

// Start event bus monitoring (app lifecycle + AX notifications)
eventBus.startMonitoring()

let cdpPool = CDPConnectionPool()
cdpPool.start()
// On daemon startup, attempt reconnection to any previously known CDP ports
cdpPool.reconnectDead()

// Initialize transport layer
let transportRouter = TransportRouter()
let axTransport = AXTransport()
let cdpTransport = CDPTransport(pool: cdpPool)
let appleScriptTransport = AppleScriptTransport()
let safariTransport = SafariTransport()

transportRouter.register(transport: axTransport)
transportRouter.register(transport: cdpTransport)
transportRouter.register(transport: appleScriptTransport)
transportRouter.register(transport: safariTransport)
transportRouter.configureDefaults()

// Initialize browser router (pluggable browser transport layer — Issue #67)
let browserRouter = BrowserRouter()
let chromeBrowserTransport = ChromeBrowserTransport()
browserRouter.register(safariTransport)   // Safari first (default)
browserRouter.register(chromeBrowserTransport) // Chrome/Chromium second

// Initialize process group manager (tracked process state machine)
let processGroup = ProcessGroupManager()
processGroup.cleanupDead()
processGroup.startListening(eventBus: eventBus)
log("ProcessGroup: \(processGroup.count) processes loaded, dead PIDs cleaned")

let router = Router(screenState: screenState, cdpPool: cdpPool, transportRouter: transportRouter,
                    snapshotCache: snapshotCache, eventBus: eventBus, safariTransport: safariTransport,
                    browserRouter: browserRouter,
                    processGroup: processGroup)
let server = Server(router: router)

// Write PID file
writePidFile()

// Setup signal handlers
setupSignalHandlers(server: server, screenState: screenState, cdpPool: cdpPool, eventBus: eventBus)

// Start server
do {
    try server.start(socketPath: socketPath)
} catch {
    log("Failed to start server: \(error)")
    removePidFile()
    exit(1)
}

// Start remote HTTP proxy server if configured
let cuaConfig = CUAConfig.load()
if let remoteConfig = cuaConfig.remote, remoteConfig.enabled, !remoteConfig.secret.isEmpty {
    let remoteServer = RemoteServer(config: remoteConfig)
    do {
        try remoteServer.start()
        let bindDesc: String
        switch remoteConfig.bind {
        case "tailscale":
            let ip = tailscaleIP() ?? "(tailscale not found)"
            bindDesc = "tailscale \(ip)"
        case "localhost":
            bindDesc = "localhost"
        default:
            bindDesc = remoteConfig.bind
        }
        log("  remote HTTP server: port \(remoteConfig.port) bind=\(bindDesc) ttl=\(remoteConfig.tokenTtl)s")
    } catch {
        log("  remote HTTP server: failed to start — \(error)")
    }
}

// Start event stream shipper if configured
if let streamConfig = cuaConfig.stream, streamConfig.enabled, !streamConfig.pushTo.isEmpty, !streamConfig.secret.isEmpty {
    let shipper = EventShipper(config: streamConfig)
    shipper.start(eventBus: eventBus)
    log("  event stream shipper: push_to=\(streamConfig.pushTo) flush=\(streamConfig.flushInterval)s")
}

log("cuad ready (pid \(ProcessInfo.processInfo.processIdentifier))")
log("  transports: ax, cdp, applescript, safari")
log("  browser transports: safari, chrome (auto-detect enabled)")
log("  event bus: monitoring app lifecycle + AX notifications")
log("  cache: TTL ax=\(snapshotCache.axTTL)s cdp=\(snapshotCache.cdpTTL)s applescript=\(snapshotCache.applescriptTTL)s")

// Run the event loop
RunLoop.main.run()
