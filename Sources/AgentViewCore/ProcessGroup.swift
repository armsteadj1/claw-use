import Foundation

// MARK: - Tracked Process State Machine

/// Derived state of a tracked process based on process events
public enum TrackedProcessState: String, Codable, CaseIterable {
    case starting = "STARTING"
    case building = "BUILDING"
    case testing = "TESTING"
    case idle = "IDLE"
    case error = "ERROR"
    case done = "DONE"
    case failed = "FAILED"
}

// MARK: - Tracked Process Model

/// A tracked process in a process group
public struct TrackedProcess: Codable {
    public let pid: Int32
    public var label: String
    public var state: TrackedProcessState
    public var lastEvent: String?
    public var lastEventTime: String?
    public var lastDetail: String?
    public var startedAt: String
    public var exitCode: Int?

    public init(pid: Int32, label: String) {
        self.pid = pid
        self.label = label
        self.state = .starting
        self.lastEvent = nil
        self.lastEventTime = nil
        self.lastDetail = nil
        self.startedAt = ISO8601DateFormatter().string(from: Date())
        self.exitCode = nil
    }
}

// MARK: - Process Group Store (persistence)

/// Persisted process group state
public struct ProcessGroupStore: Codable {
    public var processes: [Int32: TrackedProcess]

    public init() {
        self.processes = [:]
    }
}

// MARK: - ProcessGroupManager

/// Manages tracked processes, state derivation from events, and persistence
public final class ProcessGroupManager {
    private let lock = NSLock()
    private var store: ProcessGroupStore
    private let filePath: String
    private var subscriptionId: String?
    private weak var eventBus: EventBus?

    /// Test runner command patterns
    private static let testPatterns = [
        "cargo test", "npm test", "yarn test", "pnpm test",
        "pytest", "python -m pytest", "go test", "swift test",
        "jest", "vitest", "mocha", "rspec", "bundle exec rspec",
        "mix test", "gradle test", "mvn test", "dotnet test",
        "make test", "zig test",
    ]

    public init(filePath: String? = nil) {
        let path = filePath ?? (NSHomeDirectory() + "/.agentview/process-groups.json")
        self.filePath = path
        self.store = ProcessGroupStore()
        load()
    }

    // MARK: - Event Bus Wiring

    /// Subscribe to process events to drive state machine
    public func startListening(eventBus: EventBus) {
        self.eventBus = eventBus
        let processTypes: Set<String> = [
            ProcessEventType.toolStart.rawValue,
            ProcessEventType.toolEnd.rawValue,
            ProcessEventType.message.rawValue,
            ProcessEventType.error.rawValue,
            ProcessEventType.idle.rawValue,
            ProcessEventType.exit.rawValue,
        ]
        subscriptionId = eventBus.subscribe(typeFilters: processTypes) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    /// Unsubscribe from events
    public func stopListening() {
        if let id = subscriptionId, let bus = eventBus {
            bus.unsubscribe(id)
        }
        subscriptionId = nil
    }

    // MARK: - Commands

    /// Add a tracked process to the group
    @discardableResult
    public func add(pid: Int32, label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if store.processes[pid] != nil {
            return false // Already tracked
        }
        store.processes[pid] = TrackedProcess(pid: pid, label: label)
        save()
        return true
    }

    /// Remove a tracked process from the group
    @discardableResult
    public func remove(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard store.processes.removeValue(forKey: pid) != nil else {
            return false
        }
        save()
        return true
    }

    /// Clear completed/exited processes (DONE or FAILED)
    public func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }

        let before = store.processes.count
        store.processes = store.processes.filter { _, process in
            process.state != .done && process.state != .failed
        }
        let removed = before - store.processes.count
        if removed > 0 { save() }
        return removed
    }

    /// Get all tracked processes sorted by PID
    public func status() -> [TrackedProcess] {
        lock.lock()
        defer { lock.unlock() }
        return store.processes.values.sorted { $0.pid < $1.pid }
    }

    /// Number of tracked processes
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.processes.count
    }

    /// Auto-clean processes whose PIDs no longer exist
    public func cleanupDead() {
        lock.lock()
        var changed = false
        for (pid, var process) in store.processes {
            // Skip already-terminal states
            if process.state == .done || process.state == .failed { continue }
            if kill(pid, 0) != 0 {
                // Process is gone — mark as failed (unknown exit)
                process.state = .failed
                process.lastEvent = "process.exit"
                process.lastEventTime = ISO8601DateFormatter().string(from: Date())
                process.lastDetail = "PID no longer exists (cleaned on startup)"
                store.processes[pid] = process
                changed = true
            }
        }
        lock.unlock()
        if changed { save() }
    }

    // MARK: - State Machine

    private func handleEvent(_ event: AgentViewEvent) {
        guard let pid = event.pid else { return }

        lock.lock()
        guard var process = store.processes[pid] else {
            lock.unlock()
            return
        }

        // Don't update terminal states
        if process.state == .done || process.state == .failed {
            lock.unlock()
            return
        }

        let oldState = process.state
        process.lastEvent = event.type
        process.lastEventTime = event.timestamp

        switch event.type {
        case ProcessEventType.toolStart.rawValue:
            let tool = event.details?["tool"]?.value as? String ?? ""
            let command = event.details?["command"]?.value as? String ?? ""
            if isTestCommand(command) || isTestCommand(tool) {
                process.state = .testing
                process.lastDetail = command.isEmpty ? tool : command
            } else {
                process.state = .building
                process.lastDetail = tool
            }

        case ProcessEventType.toolEnd.rawValue:
            let tool = event.details?["tool"]?.value as? String ?? ""
            let success = event.details?["success"]?.value as? Bool ?? true
            if !success {
                let errorMsg = event.details?["error"]?.value as? String
                process.lastDetail = errorMsg ?? "\(tool) failed"
            } else {
                process.lastDetail = "\(tool) completed"
            }

        case ProcessEventType.message.rawValue:
            // Messages don't change state, but update detail
            let text = event.details?["text"]?.value as? String ?? ""
            if !text.isEmpty {
                process.lastDetail = String(text.prefix(80))
            }

        case ProcessEventType.error.rawValue:
            process.state = .error
            let errorMsg = event.details?["error"]?.value as? String ?? "unknown error"
            process.lastDetail = errorMsg

        case ProcessEventType.idle.rawValue:
            process.state = .idle
            let seconds = event.details?["idle_seconds"]?.value as? Int ?? 0
            process.lastDetail = "no output for \(seconds / 60)m"

        case ProcessEventType.exit.rawValue:
            let exitCode: Int
            if let ec = event.details?["exit_code"]?.value as? Int {
                exitCode = ec
            } else if let ec = event.details?["exit_code"]?.value as? Int32 {
                exitCode = Int(ec)
            } else {
                exitCode = -1
            }
            process.exitCode = exitCode
            process.state = exitCode == 0 ? .done : .failed
            process.lastDetail = "exit code \(exitCode)"

        default:
            break
        }

        store.processes[pid] = process
        let changed = process.state != oldState
        lock.unlock()

        if changed {
            save()
            // Emit process.group.state_change event
            eventBus?.publish(AgentViewEvent(
                type: AgentViewEventType.processGroupStateChange.rawValue,
                pid: pid,
                details: [
                    "label": AnyCodable(process.label),
                    "old_state": AnyCodable(oldState.rawValue),
                    "new_state": AnyCodable(process.state.rawValue),
                    "last_detail": AnyCodable(process.lastDetail),
                ]
            ))
        }
    }

    private func isTestCommand(_ str: String) -> Bool {
        let lower = str.lowercased()
        return ProcessGroupManager.testPatterns.contains { lower.contains($0) }
    }

    // MARK: - Persistence

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath),
              let data = fm.contents(atPath: filePath) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let loaded = try? decoder.decode(ProcessGroupStore.self, from: data) {
            store = loaded
        }
    }

    private func save() {
        let fm = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(store) {
            try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    // MARK: - Formatted Output

    /// Human-readable process group status with state indicators
    public static func formatStatus(processes: [TrackedProcess]) -> String {
        if processes.isEmpty {
            return "Process Group Status (0 processes)\n──────────────────────────────────────────\n  (no processes tracked)"
        }

        var lines: [String] = []
        lines.append("Process Group Status (\(processes.count) process\(processes.count == 1 ? "" : "es"))")
        lines.append("──────────────────────────────────────────")

        for process in processes {
            let indicator = stateIndicator(process.state)
            let stateStr = process.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let detail = process.lastDetail ?? ""
            let detailStr = detail.isEmpty ? "" : " \(detail)"
            let durationStr = durationSince(process.startedAt)

            let labelTruncated = String(process.label.prefix(24))
            let labelPadded = labelTruncated.padding(toLength: 24, withPad: " ", startingAt: 0)

            lines.append("\(process.pid)  \(labelPadded) \(indicator) \(stateStr)\(detailStr) (\(durationStr))")
        }

        lines.append("──────────────────────────────────────────")
        return lines.joined(separator: "\n")
    }

    /// JSON output for programmatic consumption
    public static func jsonStatus(processes: [TrackedProcess]) -> [[String: AnyCodable]] {
        return processes.map { process in
            var dict: [String: AnyCodable] = [
                "pid": AnyCodable(Int(process.pid)),
                "label": AnyCodable(process.label),
                "state": AnyCodable(process.state.rawValue),
                "started_at": AnyCodable(process.startedAt),
            ]
            if let lastEvent = process.lastEvent { dict["last_event"] = AnyCodable(lastEvent) }
            if let lastEventTime = process.lastEventTime { dict["last_event_time"] = AnyCodable(lastEventTime) }
            if let lastDetail = process.lastDetail { dict["last_detail"] = AnyCodable(lastDetail) }
            if let exitCode = process.exitCode { dict["exit_code"] = AnyCodable(exitCode) }

            let durationStr = durationSince(process.startedAt)
            dict["duration"] = AnyCodable(durationStr)

            return dict
        }
    }

    private static func stateIndicator(_ state: TrackedProcessState) -> String {
        switch state {
        case .starting: return "[~]"
        case .building: return "[B]"
        case .testing:  return "[T]"
        case .idle:     return "[I]"
        case .error:    return "[E]"
        case .done:     return "[+]"
        case .failed:   return "[-]"
        }
    }

    private static func durationSince(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let startDate = formatter.date(from: isoString) else { return "?" }
        let elapsed = Int(Date().timeIntervalSince(startDate))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }
}
