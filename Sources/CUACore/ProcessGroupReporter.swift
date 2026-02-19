import Foundation

// MARK: - Milestone Event

/// Milestone events derived from process state transitions
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

    /// Derive a milestone event from a state transition
    public static func from(oldState: String, newState: String, exitCode: Int?) -> MilestoneEvent? {
        switch newState {
        case "STARTING":
            return .started
        case "BUILDING":
            return .building
        case "TESTING":
            return .testing
        case "IDLE":
            return .idle
        case "ERROR":
            return .error
        case "DONE":
            if oldState == "TESTING" {
                return .testsPassed
            }
            return .complete
        case "FAILED":
            if oldState == "TESTING" {
                return .testsFailed
            }
            return .failed
        default:
            return nil
        }
    }
}

// MARK: - Milestone Record

/// A single milestone record written as NDJSON
public struct MilestoneRecord: Codable {
    public let timestamp: String
    public let group: String
    public let pid: Int32
    public let label: String
    public let event: String
    public let detail: String?

    public init(timestamp: String, group: String, pid: Int32, label: String, event: String, detail: String?) {
        self.timestamp = timestamp
        self.group = group
        self.pid = pid
        self.label = label
        self.event = event
        self.detail = detail
    }
}

// MARK: - Process Group Config

/// Configuration for process group features
public struct ProcessGroupConfig: Codable {
    public let reporter: ReporterConfig?

    public init(reporter: ReporterConfig? = nil) {
        self.reporter = reporter
    }

    public struct ReporterConfig: Codable {
        public let defaultOutput: String?

        public init(defaultOutput: String? = nil) {
            self.defaultOutput = defaultOutput
        }

        enum CodingKeys: String, CodingKey {
            case defaultOutput = "default_output"
        }
    }
}

// MARK: - Process Group Reporter

/// Watches process group state changes and writes milestone NDJSON records
public final class ProcessGroupReporter {
    private let groupName: String
    private let outputPath: String?
    private var subscriptionId: String?
    private var trackedPIDs: Set<Int32> = []
    private var completionCallback: (() -> Void)?
    private let lock = NSLock()

    public private(set) var isActive: Bool = false

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedPIDs.count
    }

    public init(groupName: String, outputPath: String?) {
        self.groupName = groupName
        self.outputPath = outputPath
    }

    /// Start listening for process.group.state_change events
    public func start(eventBus: EventBus, activePIDs: Set<Int32>, completion: (() -> Void)? = nil) {
        lock.lock()
        trackedPIDs = activePIDs
        completionCallback = completion
        isActive = true
        lock.unlock()

        let typeFilters: Set<String> = [CUAEventType.processGroupStateChange.rawValue]
        subscriptionId = eventBus.subscribe(typeFilters: typeFilters) { [weak self] event in
            self?.handleStateChange(event)
        }
    }

    /// Stop listening
    public func stop() {
        isActive = false
    }

    /// Encode a milestone record as a JSON string (one NDJSON line)
    public static func encodeMilestone(_ record: MilestoneRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private

    private func handleStateChange(_ event: CUAEvent) {
        guard let pid = event.pid else { return }

        lock.lock()
        guard trackedPIDs.contains(pid) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let oldState = event.details?["old_state"]?.value as? String ?? ""
        let newState = event.details?["new_state"]?.value as? String ?? ""
        let label = event.details?["label"]?.value as? String ?? ""
        let detail = event.details?["last_detail"]?.value as? String

        guard let milestone = MilestoneEvent.from(oldState: oldState, newState: newState, exitCode: nil) else {
            return
        }

        let record = MilestoneRecord(
            timestamp: event.timestamp,
            group: groupName,
            pid: pid,
            label: label,
            event: milestone.rawValue,
            detail: detail
        )

        // Write to file if configured
        if let outputPath = outputPath, let line = Self.encodeMilestone(record) {
            appendToFile(line: line, path: outputPath)
        }

        // Check for terminal states
        if newState == "DONE" || newState == "FAILED" {
            lock.lock()
            trackedPIDs.remove(pid)
            let remaining = trackedPIDs.count
            let callback = remaining == 0 ? completionCallback : nil
            lock.unlock()

            if let callback = callback {
                callback()
            }
        }
    }

    private func appendToFile(line: String, path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let lineWithNewline = line + "\n"
        if fm.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(lineWithNewline.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? lineWithNewline.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
