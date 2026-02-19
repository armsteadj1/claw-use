import AppKit
import ApplicationServices
import Foundation

// MARK: - Event Model

/// An event from CUA's monitoring system
public struct CUAEvent: Codable {
    public let timestamp: String
    public let type: String
    public let app: String?
    public let bundleId: String?
    public let pid: Int32?
    public let details: [String: AnyCodable]?

    public init(type: String, app: String? = nil, bundleId: String? = nil, pid: Int32? = nil, details: [String: AnyCodable]? = nil) {
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.type = type
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
        self.details = details
    }
}

// MARK: - Event Types

public enum CUAEventType: String, CaseIterable {
    // App lifecycle
    case appLaunched = "app.launched"
    case appTerminated = "app.terminated"
    case appActivated = "app.activated"
    case appDeactivated = "app.deactivated"

    // AX notifications
    case focusChanged = "ax.focus_changed"
    case valueChanged = "ax.value_changed"
    case windowCreated = "ax.window_created"
    case elementDestroyed = "ax.element_destroyed"

    // Screen state
    case screenLocked = "screen.locked"
    case screenUnlocked = "screen.unlocked"
    case displaySleep = "screen.display_sleep"
    case displayWake = "screen.display_wake"

    // Process monitoring
    case processToolStart = "process.tool_start"
    case processToolEnd = "process.tool_end"
    case processMessage = "process.message"
    case processError = "process.error"
    case processIdle = "process.idle"
    case processExit = "process.exit"

    // Process Group
    case processGroupStateChange = "process.group.state_change"
}

// MARK: - Subscriber

/// A subscription to events with optional filters
public struct EventSubscription {
    public let id: String
    public let appFilter: String?
    public let typeFilters: Set<String>?
    public let callback: (CUAEvent) -> Void

    public init(id: String, appFilter: String? = nil, typeFilters: Set<String>? = nil, callback: @escaping (CUAEvent) -> Void) {
        self.id = id
        self.appFilter = appFilter
        self.typeFilters = typeFilters
        self.callback = callback
    }

    /// Check if an event passes this subscription's filters
    func matches(_ event: CUAEvent) -> Bool {
        // App filter
        if let appFilter = appFilter {
            let filter = appFilter.lowercased()
            let eventApp = (event.app ?? "").lowercased()
            if !eventApp.contains(filter) {
                return false
            }
        }
        // Type filter (supports glob patterns like "process.*")
        if let typeFilters = typeFilters, !typeFilters.isEmpty {
            let matched = typeFilters.contains { filter in
                EventBus.typeFilterMatches(filter: filter, eventType: event.type)
            }
            if !matched { return false }
        }
        return true
    }
}

// MARK: - EventBus

/// Central event bus that monitors app lifecycle, AX notifications, and screen state.
/// Stores recent events and supports subscriber callbacks.
public final class EventBus {
    private let lock = NSLock()

    /// Recent events (last 100)
    private var recentEvents: [CUAEvent] = []
    private let maxRecentEvents = 100

    /// Active subscribers
    private var subscribers: [String: EventSubscription] = [:]

    /// AX observers per app PID
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Subscriber ID counter
    private var nextSubscriberId = 0

    public init() {}

    // MARK: - Lifecycle

    /// Start monitoring all event sources
    public func startMonitoring() {
        observeWorkspaceNotifications()
        observeRunningApps()
    }

    /// Stop monitoring
    public func stopMonitoring() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        lock.lock()
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        axObservers.removeAll()
        lock.unlock()
    }

    // MARK: - Event Publishing

    /// Publish an event to all matching subscribers and store in recent
    public func publish(_ event: CUAEvent) {
        lock.lock()
        recentEvents.append(event)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }
        let subs = Array(subscribers.values)
        lock.unlock()

        for sub in subs {
            if sub.matches(event) {
                sub.callback(event)
            }
        }
    }

    // MARK: - Subscriptions

    /// Subscribe to events with optional filters. Returns subscription ID.
    @discardableResult
    public func subscribe(appFilter: String? = nil, typeFilters: Set<String>? = nil, callback: @escaping (CUAEvent) -> Void) -> String {
        lock.lock()
        let id = "sub_\(nextSubscriberId)"
        nextSubscriberId += 1
        subscribers[id] = EventSubscription(id: id, appFilter: appFilter, typeFilters: typeFilters, callback: callback)
        lock.unlock()
        return id
    }

    /// Unsubscribe
    public func unsubscribe(_ id: String) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Get recent events, optionally filtered
    public func getRecentEvents(appFilter: String? = nil, typeFilters: Set<String>? = nil, limit: Int? = nil) -> [CUAEvent] {
        lock.lock()
        var events = recentEvents
        lock.unlock()

        if let appFilter = appFilter {
            let filter = appFilter.lowercased()
            events = events.filter { ($0.app ?? "").lowercased().contains(filter) }
        }
        if let predicate = EventBus.typeFilterPredicate(from: typeFilters) {
            events = events.filter { predicate($0.type) }
        }
        if let limit = limit {
            events = Array(events.suffix(limit))
        }
        return events
    }

    /// Check if a glob-style filter matches an event type.
    /// Supports: exact match, "*" (all), and "prefix.*" (e.g. "process.*" matches "process.error").
    public static func typeFilterMatches(filter: String, eventType: String) -> Bool {
        if filter == "*" { return true }
        if filter == eventType { return true }
        if filter.hasSuffix(".*") {
            let prefix = String(filter.dropLast(2))
            return eventType.hasPrefix(prefix + ".")
        }
        return false
    }

    /// Expand a set of type filters (which may contain globs) into a predicate.
    /// Returns nil if filters are nil or empty (meaning "match all").
    public static func typeFilterPredicate(from filters: Set<String>?) -> ((String) -> Bool)? {
        guard let filters = filters, !filters.isEmpty else { return nil }
        // If any filter is "*", match everything
        if filters.contains("*") { return nil }
        return { eventType in
            filters.contains { filter in typeFilterMatches(filter: filter, eventType: eventType) }
        }
    }

    /// Current subscriber count
    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    /// Recent event count
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recentEvents.count
    }

    // MARK: - NSWorkspace Notifications

    private func observeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidDeactivate(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event = CUAEvent(
            type: CUAEventType.appLaunched.rawValue,
            app: app.localizedName,
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier
        )
        publish(event)
        // Start AX observer for the new app
        addAXObserver(for: app)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event = CUAEvent(
            type: CUAEventType.appTerminated.rawValue,
            app: app.localizedName,
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier
        )
        publish(event)
        // Remove AX observer
        removeAXObserver(for: app.processIdentifier)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event = CUAEvent(
            type: CUAEventType.appActivated.rawValue,
            app: app.localizedName,
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier
        )
        publish(event)
    }

    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let event = CUAEvent(
            type: CUAEventType.appDeactivated.rawValue,
            app: app.localizedName,
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier
        )
        publish(event)
    }

    // MARK: - Screen State Events (wired from ScreenState)

    /// Call this from ScreenState.onChange to publish screen events
    public func publishScreenEvent(_ eventName: String, state: ScreenState.State) {
        let type: String
        switch eventName {
        case "screen_locked": type = CUAEventType.screenLocked.rawValue
        case "screen_unlocked": type = CUAEventType.screenUnlocked.rawValue
        case "display_sleep": type = CUAEventType.displaySleep.rawValue
        case "display_wake": type = CUAEventType.displayWake.rawValue
        default: type = "screen.\(eventName)"
        }

        let event = CUAEvent(
            type: type,
            details: [
                "screen": AnyCodable(state.screen),
                "display": AnyCodable(state.display),
                "frontmost_app": AnyCodable(state.frontmostApp),
            ]
        )
        publish(event)
    }

    // MARK: - AX Observers

    /// Setup AX observers for all currently running apps
    private func observeRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        for app in apps {
            addAXObserver(for: app)
        }
    }

    private func addAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        lock.lock()
        guard axObservers[pid] == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axNotificationCallback, &observer)
        guard result == .success, let observer = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)

        // Observe focus changes
        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Observe value changes
        AXObserverAddNotification(observer, appElement, kAXValueChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Observe window created
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        // Observe element destroyed
        AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        lock.lock()
        axObservers[pid] = observer
        lock.unlock()
    }

    private func removeAXObserver(for pid: pid_t) {
        lock.lock()
        guard let observer = axObservers.removeValue(forKey: pid) else {
            lock.unlock()
            return
        }
        lock.unlock()

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }

    /// Handle an AX notification callback (called from C callback)
    func handleAXNotification(element: AXUIElement, notification: String, pid: pid_t) {
        let type: String
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            type = CUAEventType.focusChanged.rawValue
        case kAXValueChangedNotification:
            type = CUAEventType.valueChanged.rawValue
        case kAXWindowCreatedNotification:
            type = CUAEventType.windowCreated.rawValue
        case kAXUIElementDestroyedNotification:
            type = CUAEventType.elementDestroyed.rawValue
        default:
            type = "ax.\(notification)"
        }

        // Try to get app name
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName
        let bundleId = app?.bundleIdentifier

        // Try to get element info
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var details: [String: AnyCodable] = [:]
        if let role = role { details["role"] = AnyCodable(role) }
        if let title = title { details["title"] = AnyCodable(title) }

        let event = CUAEvent(
            type: type,
            app: appName,
            bundleId: bundleId,
            pid: pid,
            details: details.isEmpty ? nil : details
        )
        publish(event)
    }
}

// MARK: - AX Observer C Callback

/// C-convention callback for AXObserver notifications
private func axNotificationCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let bus = Unmanaged<EventBus>.fromOpaque(refcon).takeUnretainedValue()

    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)

    bus.handleAXNotification(
        element: element,
        notification: notification as String,
        pid: pid
    )
}
