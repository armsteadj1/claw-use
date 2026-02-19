import Foundation

// MARK: - Owlet State Machine

/// Derived state of an owlet (watched process) based on process events
public enum OwletState: String, Codable, CaseIterable {
    case starting = "STARTING"
    case building = "BUILDING"
    case testing = "TESTING"
    case idle = "IDLE"
    case error = "ERROR"
    case done = "DONE"
    case failed = "FAILED"
}

// MARK: - Owlet Model

/// A tracked owlet in the parliament
public struct Owlet: Codable {
    public let pid: Int32
    public var label: String
    public var state: OwletState
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

// MARK: - Parliament Store (persistence)

/// Persisted parliament state
public struct ParliamentStore: Codable {
    public var owlets: [Int32: Owlet]

    public init() {
        self.owlets = [:]
    }
}

// MARK: - Parliament

/// Manages owlet tracking, state derivation from events, and persistence
public final class Parliament {
    private let lock = NSLock()
    private var store: ParliamentStore
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
        let path = filePath ?? (NSHomeDirectory() + "/.agentview/parliament.json")
        self.filePath = path
        self.store = ParliamentStore()
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

    /// Add an owlet to the parliament
    @discardableResult
    public func add(pid: Int32, label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if store.owlets[pid] != nil {
            return false // Already tracked
        }
        store.owlets[pid] = Owlet(pid: pid, label: label)
        save()
        return true
    }

    /// Remove an owlet from the parliament
    @discardableResult
    public func remove(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard store.owlets.removeValue(forKey: pid) != nil else {
            return false
        }
        save()
        return true
    }

    /// Clear completed/exited owlets (DONE or FAILED)
    public func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }

        let before = store.owlets.count
        store.owlets = store.owlets.filter { _, owlet in
            owlet.state != .done && owlet.state != .failed
        }
        let removed = before - store.owlets.count
        if removed > 0 { save() }
        return removed
    }

    /// Get all owlets sorted by PID
    public func status() -> [Owlet] {
        lock.lock()
        defer { lock.unlock() }
        return store.owlets.values.sorted { $0.pid < $1.pid }
    }

    /// Number of tracked owlets
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return store.owlets.count
    }

    /// Auto-clean owlets whose PIDs no longer exist
    public func cleanupDead() {
        lock.lock()
        var changed = false
        for (pid, var owlet) in store.owlets {
            // Skip already-terminal states
            if owlet.state == .done || owlet.state == .failed { continue }
            if kill(pid, 0) != 0 {
                // Process is gone — mark as failed (unknown exit)
                owlet.state = .failed
                owlet.lastEvent = "process.exit"
                owlet.lastEventTime = ISO8601DateFormatter().string(from: Date())
                owlet.lastDetail = "PID no longer exists (cleaned on startup)"
                store.owlets[pid] = owlet
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
        guard var owlet = store.owlets[pid] else {
            lock.unlock()
            return
        }

        // Don't update terminal states
        if owlet.state == .done || owlet.state == .failed {
            lock.unlock()
            return
        }

        let oldState = owlet.state
        owlet.lastEvent = event.type
        owlet.lastEventTime = event.timestamp

        switch event.type {
        case ProcessEventType.toolStart.rawValue:
            let tool = event.details?["tool"]?.value as? String ?? ""
            let command = event.details?["command"]?.value as? String ?? ""
            if isTestCommand(command) || isTestCommand(tool) {
                owlet.state = .testing
                owlet.lastDetail = command.isEmpty ? tool : command
            } else {
                owlet.state = .building
                owlet.lastDetail = tool
            }

        case ProcessEventType.toolEnd.rawValue:
            let tool = event.details?["tool"]?.value as? String ?? ""
            let success = event.details?["success"]?.value as? Bool ?? true
            if !success {
                let errorMsg = event.details?["error"]?.value as? String
                owlet.lastDetail = errorMsg ?? "\(tool) failed"
            } else {
                owlet.lastDetail = "\(tool) completed"
            }

        case ProcessEventType.message.rawValue:
            // Messages don't change state, but update detail
            let text = event.details?["text"]?.value as? String ?? ""
            if !text.isEmpty {
                owlet.lastDetail = String(text.prefix(80))
            }

        case ProcessEventType.error.rawValue:
            owlet.state = .error
            let errorMsg = event.details?["error"]?.value as? String ?? "unknown error"
            owlet.lastDetail = errorMsg

        case ProcessEventType.idle.rawValue:
            owlet.state = .idle
            let seconds = event.details?["idle_seconds"]?.value as? Int ?? 0
            owlet.lastDetail = "no output for \(seconds / 60)m"

        case ProcessEventType.exit.rawValue:
            let exitCode: Int
            if let ec = event.details?["exit_code"]?.value as? Int {
                exitCode = ec
            } else if let ec = event.details?["exit_code"]?.value as? Int32 {
                exitCode = Int(ec)
            } else {
                exitCode = -1
            }
            owlet.exitCode = exitCode
            owlet.state = exitCode == 0 ? .done : .failed
            owlet.lastDetail = "exit code \(exitCode)"

        default:
            break
        }

        store.owlets[pid] = owlet
        let changed = owlet.state != oldState
        lock.unlock()

        if changed {
            save()
            // Emit parliament.state_change event
            eventBus?.publish(AgentViewEvent(
                type: AgentViewEventType.parliamentStateChange.rawValue,
                pid: pid,
                details: [
                    "label": AnyCodable(owlet.label),
                    "old_state": AnyCodable(oldState.rawValue),
                    "new_state": AnyCodable(owlet.state.rawValue),
                    "last_detail": AnyCodable(owlet.lastDetail),
                ]
            ))
        }
    }

    private func isTestCommand(_ str: String) -> Bool {
        let lower = str.lowercased()
        return Parliament.testPatterns.contains { lower.contains($0) }
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
        if let loaded = try? decoder.decode(ParliamentStore.self, from: data) {
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

    /// Human-readable parliament status with emoji indicators
    public static func formatStatus(owlets: [Owlet]) -> String {
        if owlets.isEmpty {
            return "🦉 Parliament Status (0 owlets)\n──────────────────────────────────────────\n  (no owlets tracked)"
        }

        var lines: [String] = []
        lines.append("🦉 Parliament Status (\(owlets.count) owlet\(owlets.count == 1 ? "" : "s"))")
        lines.append("──────────────────────────────────────────")

        for owlet in owlets {
            let emoji = stateEmoji(owlet.state)
            let stateStr = owlet.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let detail = owlet.lastDetail ?? ""
            let detailStr = detail.isEmpty ? "" : " \(detail)"
            let durationStr = durationSince(owlet.startedAt)

            let labelTruncated = String(owlet.label.prefix(24))
            let labelPadded = labelTruncated.padding(toLength: 24, withPad: " ", startingAt: 0)

            lines.append("\(owlet.pid)  \(labelPadded) \(emoji) \(stateStr)\(detailStr) (\(durationStr))")
        }

        lines.append("──────────────────────────────────────────")
        return lines.joined(separator: "\n")
    }

    /// JSON output for programmatic consumption
    public static func jsonStatus(owlets: [Owlet]) -> [[String: AnyCodable]] {
        return owlets.map { owlet in
            var dict: [String: AnyCodable] = [
                "pid": AnyCodable(Int(owlet.pid)),
                "label": AnyCodable(owlet.label),
                "state": AnyCodable(owlet.state.rawValue),
                "started_at": AnyCodable(owlet.startedAt),
            ]
            if let lastEvent = owlet.lastEvent { dict["last_event"] = AnyCodable(lastEvent) }
            if let lastEventTime = owlet.lastEventTime { dict["last_event_time"] = AnyCodable(lastEventTime) }
            if let lastDetail = owlet.lastDetail { dict["last_detail"] = AnyCodable(lastDetail) }
            if let exitCode = owlet.exitCode { dict["exit_code"] = AnyCodable(exitCode) }

            let durationStr = durationSince(owlet.startedAt)
            dict["duration"] = AnyCodable(durationStr)

            return dict
        }
    }

    private static func stateEmoji(_ state: OwletState) -> String {
        switch state {
        case .starting: return "🔄"
        case .building: return "🔨"
        case .testing:  return "🧪"
        case .idle:     return "⚠️ "
        case .error:    return "❌"
        case .done:     return "✅"
        case .failed:   return "💀"
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
