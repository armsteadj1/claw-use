import AppKit
import Foundation

/// Screen state detection using CGSessionCopyCurrentDictionary and NSWorkspace notifications
public final class ScreenState {
    public enum LockState: String, Codable {
        case unlocked
        case locked
        case unknown
    }

    public enum DisplayState: String, Codable {
        case on
        case off
        case unknown
    }

    public struct State: Codable {
        public let screen: String
        public let display: String
        public let frontmostApp: String?

        public init(screen: String, display: String, frontmostApp: String?) {
            self.screen = screen; self.display = display; self.frontmostApp = frontmostApp
        }
    }

    private var lockState: LockState = .unknown
    private var displayState: DisplayState = .unknown
    private let lock = NSLock()
    private var pollTimer: Timer?

    /// Called when screen state changes. Args: (event: String, newState: State)
    public var onChange: ((String, State) -> Void)?

    public init() {}

    /// Start observing screen state changes via NSWorkspace notifications
    public func startObserving() {
        // Get initial state
        updateLockState()
        displayState = .on

        let center = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Screen lock/unlock via distributed notifications
        dnc.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // Display sleep/wake
        center.addObserver(
            self,
            selector: #selector(displayDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(displayDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    /// Start polling screen state as fallback (for non-GUI-session daemons)
    public func startPolling(interval: TimeInterval = 2.0) {
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollScreenState()
        }
    }

    private func pollScreenState() {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let isLocked = dict["CGSSessionScreenIsLocked"] as? Bool ?? false
        let newState: LockState = isLocked ? .locked : .unlocked

        lock.lock()
        let oldState = lockState
        if newState != oldState {
            lockState = newState
            lock.unlock()
            let event = newState == .locked ? "screen_locked" : "screen_unlocked"
            onChange?(event, currentState())
        } else {
            lock.unlock()
        }
    }

    public func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Get current screen state snapshot
    public func currentState() -> State {
        lock.lock()
        defer { lock.unlock() }

        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName

        return State(
            screen: lockState.rawValue,
            display: displayState.rawValue,
            frontmostApp: frontmost
        )
    }

    /// Update lock state from CGSessionCopyCurrentDictionary
    private func updateLockState() {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            lock.lock()
            lockState = .unknown
            lock.unlock()
            return
        }
        let isLocked = dict["CGSSessionScreenIsLocked"] as? Bool ?? false
        lock.lock()
        lockState = isLocked ? .locked : .unlocked
        lock.unlock()
    }

    @objc private func screenDidLock(_ notification: Notification) {
        lock.lock()
        lockState = .locked
        lock.unlock()
        onChange?("screen_locked", currentState())
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        lock.lock()
        lockState = .unlocked
        lock.unlock()
        onChange?("screen_unlocked", currentState())
    }

    @objc private func displayDidSleep(_ notification: Notification) {
        lock.lock()
        displayState = .off
        lock.unlock()
        onChange?("display_sleep", currentState())
    }

    @objc private func displayDidWake(_ notification: Notification) {
        lock.lock()
        displayState = .on
        lock.unlock()
        onChange?("display_wake", currentState())
    }
}
