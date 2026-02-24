import Foundation

// MARK: - StreamEvent

/// A privacy-filtered event ready to be shipped to the agent's stream endpoint.
public struct StreamEvent: Codable {
    public let ts: String
    public let type: String
    public let app: String?
    public let pid: Int32?
    public let level: Int
    public let domain: String?
    public let title: String?
    public let summary: String?
    public let elementCount: Int?
    public let pageType: String?
    public let duration: Int?

    public init(
        ts: String,
        type: String,
        app: String? = nil,
        pid: Int32? = nil,
        level: Int,
        domain: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        elementCount: Int? = nil,
        pageType: String? = nil,
        duration: Int? = nil
    ) {
        self.ts = ts
        self.type = type
        self.app = app
        self.pid = pid
        self.level = level
        self.domain = domain
        self.title = title
        self.summary = summary
        self.elementCount = elementCount
        self.pageType = pageType
        self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case ts, type, app, pid, level, domain, title, summary, duration
        case elementCount = "element_count"
        case pageType = "page_type"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encode(level, forKey: .level)
        try c.encodeIfPresent(domain, forKey: .domain)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(elementCount, forKey: .elementCount)
        try c.encodeIfPresent(pageType, forKey: .pageType)
        try c.encodeIfPresent(duration, forKey: .duration)
    }
}

// MARK: - EventStreamFilter

/// Applies privacy-level rules to convert raw CUAEvents into StreamEvents.
///
/// Rules:
/// - Blocked apps → nil (nothing emitted)
/// - Level 0 (always): app.launched, app.terminated, app.activated, screen events
/// - Level 1 (opt-in): app.deactivated, window.focused (from ax.window_created)
/// - Level 2 (opt-in): snapshot (generated externally, passed via filterSnapshot)
/// - AXSecureTextField values are ALWAYS omitted from snapshot summaries
public struct EventStreamFilter {
    public let config: StreamConfig

    public init(config: StreamConfig) {
        self.config = config
    }

    // MARK: - CUAEvent → StreamEvent

    /// Filter a CUAEvent to a StreamEvent, or nil if the event should not be emitted.
    public func filter(_ event: CUAEvent) -> StreamEvent? {
        // Screen events: always emit (no app filter applies)
        let screenTypes: Set<String> = [
            "screen.locked", "screen.unlocked",
            "screen.display_sleep", "screen.display_wake",
        ]
        if screenTypes.contains(event.type) {
            return StreamEvent(ts: event.timestamp, type: event.type, level: 0)
        }

        // All remaining events require an app name
        guard let app = event.app else { return nil }

        // Blocked apps produce nothing
        if isBlocked(app: app) { return nil }

        let level = levelFor(app: app)

        switch event.type {
        case "app.launched", "app.terminated", "app.activated":
            // Level 0 — always emit if app is not blocked
            return StreamEvent(ts: event.timestamp, type: event.type, app: app, pid: event.pid, level: 0)

        case "app.deactivated":
            // Level 1 — opt-in
            guard level >= 1 else { return nil }
            return StreamEvent(ts: event.timestamp, type: event.type, app: app, pid: event.pid, level: 1)

        case "ax.window_created":
            // Level 1 — surface as window.focused
            guard level >= 1 else { return nil }
            let title = event.details?["title"]?.value as? String
            return StreamEvent(ts: event.timestamp, type: "window.focused",
                               app: app, pid: event.pid, level: 1, title: title)

        default:
            // ax.focus_changed, ax.value_changed, ax.element_destroyed, process.* — skip
            return nil
        }
    }

    // MARK: - Snapshot → StreamEvent (level 2)

    /// Convert an AppSnapshot to a level-2 snapshot StreamEvent, scrubbing secure fields.
    /// Returns nil if the app is blocked or the app level < 2.
    public func filterSnapshot(_ snapshot: AppSnapshot) -> StreamEvent? {
        if isBlocked(app: snapshot.app) { return nil }
        guard levelFor(app: snapshot.app) >= 2 else { return nil }
        let summary = scrubSnapshot(snapshot, level: 2)
        let elementCount = snapshot.stats.enrichedElements
        return StreamEvent(
            ts: snapshot.timestamp,
            type: "snapshot",
            app: snapshot.app,
            pid: snapshot.pid,
            level: 2,
            summary: summary,
            elementCount: elementCount
        )
    }

    // MARK: - Helpers

    /// Return the configured event level for an app, falling back to the wildcard default.
    public func levelFor(app: String) -> Int {
        if let level = config.appLevels[app] { return level }
        return config.defaultLevel
    }

    /// Return true if the app is in the blocked list (case-insensitive).
    public func isBlocked(app: String) -> Bool {
        let lower = app.lowercased()
        return config.blockedApps.contains { $0.lowercased() == lower }
    }

    /// Generate a 1-line summary from an AppSnapshot, always omitting AXSecureTextField values.
    public func scrubSnapshot(_ snapshot: AppSnapshot, level: Int) -> String {
        let windowTitle = snapshot.window.title ?? ""
        let elementCount = snapshot.stats.enrichedElements

        // Collect non-secure element labels for context
        var hasSecureField = false
        for section in snapshot.content.sections {
            for element in section.elements {
                let roleLower = element.role.lowercased()
                if roleLower.contains("secure") || roleLower.contains("password") {
                    hasSecureField = true
                }
            }
        }

        var summary: String
        if !windowTitle.isEmpty {
            summary = "\(windowTitle) (\(elementCount) elements)"
        } else {
            summary = "\(elementCount) elements"
        }
        if hasSecureField {
            summary += " [password fields omitted]"
        }
        return summary
    }
}
