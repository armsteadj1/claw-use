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

    public func stopObserving() {
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
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        lock.lock()
        lockState = .unlocked
        lock.unlock()
    }

    @objc private func displayDidSleep(_ notification: Notification) {
        lock.lock()
        displayState = .off
        lock.unlock()
    }

    @objc private func displayDidWake(_ notification: Notification) {
        lock.lock()
        displayState = .on
        lock.unlock()
    }
}
