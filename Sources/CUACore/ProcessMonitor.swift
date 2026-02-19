import Foundation

// MARK: - Process Event Types

/// Event types emitted by the process monitor
public enum ProcessEventType: String, CaseIterable {
    case toolStart = "process.tool_start"
    case toolEnd = "process.tool_end"
    case message = "process.message"
    case error = "process.error"
    case idle = "process.idle"
    case exit = "process.exit"
}

// MARK: - NDJSON Line Parser

/// Parses Claude Code NDJSON output lines into typed process events
public struct NDJSONParser {

    /// Parse a single NDJSON line into a process event type + details
    public static func parse(line: String, pid: Int32) -> CUAEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Non-JSON output → raw message
            return CUAEvent(
                type: ProcessEventType.message.rawValue,
                pid: pid,
                details: ["raw": AnyCodable(trimmed)]
            )
        }

        let jsonType = json["type"] as? String ?? ""

        switch jsonType {
        case "tool_use", "tool_call":
            let toolName = json["name"] as? String ?? json["tool"] as? String ?? "unknown"
            var details: [String: AnyCodable] = [
                "tool": AnyCodable(toolName),
            ]
            if let input = json["input"] as? [String: Any] {
                // Extract file_path if present (common in file edit tools)
                if let filePath = input["file_path"] as? String {
                    details["file_path"] = AnyCodable(filePath)
                }
                if let command = input["command"] as? String {
                    details["command"] = AnyCodable(command)
                }
            }
            return CUAEvent(
                type: ProcessEventType.toolStart.rawValue,
                pid: pid,
                details: details
            )

        case "tool_result":
            let toolName = json["name"] as? String ?? json["tool"] as? String ?? "unknown"
            let isError = json["is_error"] as? Bool ?? false
            var details: [String: AnyCodable] = [
                "tool": AnyCodable(toolName),
                "success": AnyCodable(!isError),
            ]
            if let durationMs = json["duration_ms"] as? Int {
                details["duration_ms"] = AnyCodable(durationMs)
            }
            if isError {
                if let errorMsg = json["error"] as? String {
                    details["error"] = AnyCodable(errorMsg)
                }
            }
            return CUAEvent(
                type: ProcessEventType.toolEnd.rawValue,
                pid: pid,
                details: details
            )

        case "text", "assistant", "content_block_delta":
            let text = json["text"] as? String
                ?? (json["delta"] as? [String: Any])?["text"] as? String
                ?? ""
            return CUAEvent(
                type: ProcessEventType.message.rawValue,
                pid: pid,
                details: ["text": AnyCodable(text)]
            )

        case "error":
            let errorMsg = json["error"] as? String
                ?? (json["error"] as? [String: Any])?["message"] as? String
                ?? "unknown error"
            return CUAEvent(
                type: ProcessEventType.error.rawValue,
                pid: pid,
                details: ["error": AnyCodable(errorMsg)]
            )

        case "result":
            let text = json["result"] as? String ?? ""
            return CUAEvent(
                type: ProcessEventType.message.rawValue,
                pid: pid,
                details: ["text": AnyCodable(text), "final": AnyCodable(true)]
            )

        default:
            // Unknown JSON type → emit as message with the raw JSON type
            var details: [String: AnyCodable] = ["raw_type": AnyCodable(jsonType)]
            if let text = json["text"] as? String {
                details["text"] = AnyCodable(text)
            }
            return CUAEvent(
                type: ProcessEventType.message.rawValue,
                pid: pid,
                details: details
            )
        }
    }
}

// MARK: - Process Watcher

/// Watches a single process by tailing its log file output
public final class ProcessWatcher {
    public let pid: Int32
    public let logPath: String?
    public let idleTimeout: TimeInterval

    private let eventBus: EventBus
    private var fileHandle: FileHandle?
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var procExitSource: DispatchSourceProcess?
    private var pollTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivityTime: Date
    private var stopped = false
    private let lock = NSLock()
    private var lineBuffer = ""
    /// Exit code captured by kqueue (NOTE_EXITSTATUS), nil if not yet available
    private var kqueueExitCode: Int32?

    public init(pid: Int32, logPath: String?, idleTimeout: TimeInterval = 300, eventBus: EventBus) {
        self.pid = pid
        self.logPath = logPath
        self.idleTimeout = idleTimeout
        self.eventBus = eventBus
        self.lastActivityTime = Date()
    }

    /// Start watching the process
    public func start() {
        // Use kqueue (EVFILT_PROC + NOTE_EXITSTATUS) for reliable exit code
        // detection on macOS — works for ANY process, not just children.
        startKqueueExitWatch()

        if let logPath = logPath {
            startLogTailing(path: logPath)
        } else {
            // Without a log path, poll for process liveness only
            startProcessPolling()
        }
        startIdleDetection()
    }

    /// Stop watching
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()

        procExitSource?.cancel()
        procExitSource = nil
        dispatchSource?.cancel()
        dispatchSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }

    /// Check if this watcher is still active
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    // MARK: - Log File Tailing

    private func startLogTailing(path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            // File doesn't exist yet — poll until it does
            startFileWait(path: path)
            return
        }

        openAndTailFile(path: path)
    }

    private func startFileWait(path: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else {
                timer.cancel()
                return
            }
            if FileManager.default.fileExists(atPath: path) {
                timer.cancel()
                self.openAndTailFile(path: path)
            }
        }
        self.pollTimer = timer
        timer.resume()
    }

    private func openAndTailFile(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        self.fileHandle = fh

        // Seek to end — only read new content
        fh.seekToEndOfFile()

        // Use a dispatch source to watch for file writes
        let fd = fh.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }
        self.dispatchSource = source
        source.resume()

        // Also poll periodically as a backup (dispatch sources can miss events)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            self.readAvailableData()
            self.checkProcessAlive()
        }
        self.pollTimer = timer
        timer.resume()
    }

    private func readAvailableData() {
        guard let fh = fileHandle else { return }
        let data = fh.availableData
        guard !data.isEmpty else { return }

        guard let text = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        lineBuffer += text
        lock.unlock()

        processLineBuffer()
    }

    private func processLineBuffer() {
        lock.lock()
        let buffer = lineBuffer
        lock.unlock()

        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)

        // Keep the last segment if it doesn't end with newline (incomplete line)
        let completeLines: [String]
        let remainder: String

        if buffer.hasSuffix("\n") {
            completeLines = lines.dropLast().map(String.init) // dropLast removes empty string after trailing \n
            remainder = ""
        } else {
            completeLines = lines.dropLast().map(String.init)
            remainder = String(lines.last ?? "")
        }

        lock.lock()
        lineBuffer = remainder
        lastActivityTime = Date()
        lock.unlock()

        for line in completeLines {
            if let event = NDJSONParser.parse(line: line, pid: pid) {
                eventBus.publish(event)
            }
        }
    }

    // MARK: - kqueue Exit Watch (reliable exit code for any process)

    /// Use macOS kqueue EVFILT_PROC with NOTE_EXIT | NOTE_EXITSTATUS to get
    /// the real exit status of any process — not just children.
    /// This replaces waitpid() which only works for child processes.
    private func startKqueueExitWatch() {
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            // DispatchSource.makeProcessSource uses NOTE_EXIT under the hood.
            // To get the actual exit status we need NOTE_EXITSTATUS which
            // DispatchSource doesn't expose directly. Use the kqueue fd.
            let exitCode = self.readKqueueExitStatus() ?? self.waitForExitCode()

            self.lock.lock()
            self.kqueueExitCode = exitCode
            self.lock.unlock()

            let event = CUAEvent(
                type: ProcessEventType.exit.rawValue,
                pid: self.pid,
                details: ["exit_code": AnyCodable(exitCode)]
            )
            self.eventBus.publish(event)
            self.stop()
        }

        source.setCancelHandler { /* nothing */ }
        self.procExitSource = source
        source.resume()
    }

    /// Use raw kqueue to read exit status with NOTE_EXITSTATUS.
    /// Returns the exit code (0-255) or nil if unable to determine.
    private func readKqueueExitStatus() -> Int32? {
        let kq = kqueue()
        guard kq >= 0 else { return nil }
        defer { close(kq) }

        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(bitPattern: NOTE_EXITSTATUS),
            data: 0,
            udata: nil
        )

        // Register — if the process is already dead this may fail, that's OK
        let reg = kevent(kq, &change, 1, nil, 0, nil)
        if reg == -1 { return nil }

        // Poll immediately (non-blocking) — process may already be dead
        var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000) // 100ms
        var event = kevent()
        let n = kevent(kq, nil, 0, &event, 1, &timeout)
        guard n > 0 else { return nil }

        let status = Int32(event.data)
        // Parse wait-style status
        if (status & 0x7f) == 0 {
            // Normal exit: WEXITSTATUS
            return (status >> 8) & 0xff
        } else {
            // Killed by signal: return negative signal number (convention)
            return -(status & 0x7f)
        }
    }

    // MARK: - Process Polling (no log file mode)

    private func startProcessPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            self.checkProcessAlive()
        }
        self.pollTimer = timer
        timer.resume()
    }

    private func checkProcessAlive() {
        guard isActive else { return }
        if kill(pid, 0) != 0 {
            // Process has exited — check if kqueue already handled it
            lock.lock()
            let alreadyHandled = kqueueExitCode != nil
            lock.unlock()

            if alreadyHandled {
                // kqueue exit handler already fired — don't double-publish
                return
            }

            // Fallback: kqueue didn't fire (race condition or unsupported)
            let exitCode = waitForExitCode()
            let event = CUAEvent(
                type: ProcessEventType.exit.rawValue,
                pid: pid,
                details: ["exit_code": AnyCodable(exitCode)]
            )
            eventBus.publish(event)
            stop()
        }
    }

    private func waitForExitCode() -> Int32 {
        // First check if kqueue captured the exit code
        lock.lock()
        if let kqCode = kqueueExitCode {
            lock.unlock()
            return kqCode
        }
        lock.unlock()

        // Try kqueue one more time (process just died)
        if let kqCode = readKqueueExitStatus() {
            return kqCode
        }

        // Last resort: waitpid (only works for child processes)
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result > 0 {
            if (status & 0x7f) == 0 {
                return (status >> 8) & 0xff
            }
        }
        return -1 // Truly unknown exit code
    }

    // MARK: - Idle Detection

    private func startIdleDetection() {
        guard idleTimeout > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let checkInterval = max(idleTimeout / 4, 5.0) // Check at least every idle/4 or 5s
        timer.schedule(deadline: .now() + .seconds(Int(checkInterval)), repeating: .seconds(Int(checkInterval)))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }
            self.lock.lock()
            let elapsed = Date().timeIntervalSince(self.lastActivityTime)
            self.lock.unlock()

            if elapsed >= self.idleTimeout {
                let event = CUAEvent(
                    type: ProcessEventType.idle.rawValue,
                    pid: self.pid,
                    details: ["idle_seconds": AnyCodable(Int(elapsed))]
                )
                self.eventBus.publish(event)
                // Reset so we don't spam idle events
                self.lock.lock()
                self.lastActivityTime = Date()
                self.lock.unlock()
            }
        }
        self.idleTimer = timer
        timer.resume()
    }
}

// MARK: - Process Monitor (manages multiple watchers)

/// Manages multiple simultaneous process watchers
public final class ProcessMonitor {
    private var watchers: [Int32: ProcessWatcher] = [:]
    private let lock = NSLock()
    private let eventBus: EventBus

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Start watching a process. Returns true if watch was started.
    @discardableResult
    public func watch(pid: Int32, logPath: String? = nil, idleTimeout: TimeInterval = 300) -> Bool {
        lock.lock()
        if watchers[pid] != nil {
            lock.unlock()
            return false // Already watching
        }

        let watcher = ProcessWatcher(pid: pid, logPath: logPath, idleTimeout: idleTimeout, eventBus: eventBus)
        watchers[pid] = watcher
        lock.unlock()

        // Verify process exists before starting
        guard kill(pid, 0) == 0 else {
            lock.lock()
            watchers.removeValue(forKey: pid)
            lock.unlock()
            return false
        }

        watcher.start()
        return true
    }

    /// Stop watching a process
    public func unwatch(pid: Int32) {
        lock.lock()
        guard let watcher = watchers.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        lock.unlock()
        watcher.stop()
    }

    /// Stop all watchers
    public func unwatchAll() {
        lock.lock()
        let allWatchers = watchers
        watchers.removeAll()
        lock.unlock()

        for (_, watcher) in allWatchers {
            watcher.stop()
        }
    }

    /// List currently watched PIDs
    public var watchedPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return Array(watchers.keys).sorted()
    }

    /// Number of active watchers
    public var watchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return watchers.count
    }

    /// Check if a PID is being watched
    public func isWatching(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watchers[pid] != nil
    }

    /// Clean up watchers for processes that have exited
    public func cleanupDead() {
        lock.lock()
        let pids = Array(watchers.keys)
        lock.unlock()

        for pid in pids {
            if kill(pid, 0) != 0 {
                unwatch(pid: pid)
            }
        }
    }
}
