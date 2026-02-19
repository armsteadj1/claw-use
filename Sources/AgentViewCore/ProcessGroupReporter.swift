import Foundation

// MARK: - Milestone Event Mapping

/// Maps process group state changes to milestone event names for external consumers
public enum MilestoneEvent: String, CaseIterable {
    case started = "group.process.started"
    case building = "group.process.building"
    case testing = "group.process.testing"
    case testsPassed = "group.process.tests_passed"
    case testsFailed = "group.process.tests_failed"
    case idle = "group.process.idle"
    case error = "group.process.error"
    case complete = "group.process.complete"
    case failed = "group.process.failed"

    /// Derive milestone from a state change
    public static func from(oldState: String, newState: String, exitCode: Int?) -> MilestoneEvent? {
        switch newState {
        case TrackedProcessState.starting.rawValue:
            return .started
        case TrackedProcessState.building.rawValue:
            return .building
        case TrackedProcessState.testing.rawValue:
            return .testing
        case TrackedProcessState.idle.rawValue:
            return .idle
        case TrackedProcessState.error.rawValue:
            return .error
        case TrackedProcessState.done.rawValue:
            // If previous state was testing, it means tests passed
            if oldState == TrackedProcessState.testing.rawValue {
                return .testsPassed
            }
            return .complete
        case TrackedProcessState.failed.rawValue:
            // If previous state was testing, it means tests failed
            if oldState == TrackedProcessState.testing.rawValue {
                return .testsFailed
            }
            return .failed
        default:
            return nil
        }
    }
}

// MARK: - NDJSON Milestone Record

/// A single milestone update emitted as one line of NDJSON
public struct MilestoneRecord: Codable {
    public let timestamp: String
    public let group: String
    public let pid: Int
    public let label: String
    public let event: String
    public let detail: String

    public init(timestamp: String, group: String, pid: Int, label: String, event: String, detail: String) {
        self.timestamp = timestamp
        self.group = group
        self.pid = pid
        self.label = label
        self.event = event
        self.detail = detail
    }
}

// MARK: - ProcessGroupReporter

/// Subscribes to process group state change events and writes milestone-only
/// NDJSON updates for external consumers (Slack bots, CI dashboards, etc.).
public final class ProcessGroupReporter {
    private let lock = NSLock()
    private var subscriptionId: String?
    private weak var eventBus: EventBus?
    private let groupName: String
    private let outputPath: String?  // nil = stdout
    private let fileHandle: FileHandle?
    private var activePIDs: Set<Int32> = []
    private var completionCallback: (() -> Void)?

    /// Encoder for NDJSON output (compact, sorted keys)
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.keyEncodingStrategy = .convertToSnakeCase
        return enc
    }()

    /// Create a reporter
    /// - Parameters:
    ///   - groupName: Process group to watch (used in output records)
    ///   - outputPath: File path to append NDJSON to, or nil for stdout
    public init(groupName: String, outputPath: String?) {
        self.groupName = groupName
        self.outputPath = outputPath

        if let path = outputPath {
            let expanded = (path as NSString).expandingTildeInPath
            let dir = (expanded as NSString).deletingLastPathComponent
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: expanded) {
                fm.createFile(atPath: expanded, contents: nil)
            }
            self.fileHandle = FileHandle(forWritingAtPath: expanded)
            self.fileHandle?.seekToEndOfFile()
        } else {
            self.fileHandle = nil
        }
    }

    deinit {
        stop()
        fileHandle?.closeFile()
    }

    /// Start listening for state change events and emitting milestones
    public func start(eventBus: EventBus, activePIDs: Set<Int32> = [], onAllComplete: (() -> Void)? = nil) {
        self.eventBus = eventBus
        self.completionCallback = onAllComplete

        lock.lock()
        self.activePIDs = activePIDs
        lock.unlock()

        // Subscribe to process group state change events only
        subscriptionId = eventBus.subscribe(typeFilters: Set(["process.group.state_change"])) { [weak self] event in
            self?.handleStateChange(event)
        }
    }

    /// Stop listening
    public func stop() {
        if let id = subscriptionId, let bus = eventBus {
            bus.unsubscribe(id)
        }
        subscriptionId = nil
    }

    /// Whether the reporter is actively listening
    public var isActive: Bool {
        return subscriptionId != nil
    }

    /// Number of PIDs still being tracked as active (not terminal)
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activePIDs.count
    }

    // MARK: - Event Handling

    private func handleStateChange(_ event: AgentViewEvent) {
        guard let pid = event.pid,
              let details = event.details,
              let label = details["label"]?.value as? String,
              let oldState = details["old_state"]?.value as? String,
              let newState = details["new_state"]?.value as? String else {
            return
        }

        let lastDetail = details["last_detail"]?.value as? String ?? ""

        // Derive milestone
        let exitCode = details["exit_code"]?.value as? Int
        guard let milestone = MilestoneEvent.from(oldState: oldState, newState: newState, exitCode: exitCode) else {
            return
        }

        let record = MilestoneRecord(
            timestamp: event.timestamp,
            group: groupName,
            pid: Int(pid),
            label: label,
            event: milestone.rawValue,
            detail: lastDetail
        )

        writeLine(record)

        // Track completion for active PIDs
        let isTerminal = newState == TrackedProcessState.done.rawValue || newState == TrackedProcessState.failed.rawValue
        if isTerminal {
            lock.lock()
            activePIDs.remove(pid)
            let remaining = activePIDs.count
            lock.unlock()

            if remaining == 0 {
                completionCallback?()
            }
        }
    }

    // MARK: - Output

    private func writeLine(_ record: MilestoneRecord) {
        guard let data = try? Self.encoder.encode(record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"

        if let fh = fileHandle {
            // File output mode: append
            if let lineData = line.data(using: .utf8) {
                fh.write(lineData)
            }
        } else {
            // Stdout mode
            print(line, terminator: "")
            fflush(stdout)
        }
    }

    /// Encode a milestone record to NDJSON string (for testing)
    public static func encodeMilestone(_ record: MilestoneRecord) -> String? {
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
