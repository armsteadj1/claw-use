import AppKit
import ApplicationServices

struct AXBridge {
    /// Check if the process is trusted for accessibility
    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant accessibility permission
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Find app by name (case-insensitive, partial match)
    static func findApp(named query: String) -> NSRunningApplication? {
        let q = query.lowercased()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .first { app in
                app.localizedName?.lowercased().contains(q) ?? false
            }
    }

    /// Find app by PID
    static func findApp(pid: pid_t) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
    }

    /// Get AXUIElement for an app
    static func appElement(for app: NSRunningApplication) -> AXUIElement {
        AXUIElementCreateApplication(app.processIdentifier)
    }

    /// List all GUI apps
    static func listApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { AppInfo(name: $0.localizedName ?? "Unknown", pid: $0.processIdentifier, bundleId: $0.bundleIdentifier) }
    }

    /// Resolve an app from a name or PID, printing errors as needed
    static func resolveApp(name: String?, pid: Int32?) -> NSRunningApplication? {
        if let pid = pid {
            guard let app = findApp(pid: pid) else {
                fputs("Error: No app found with PID \(pid)\n", stderr)
                return nil
            }
            return app
        }

        guard let name = name else {
            fputs("Error: Provide an app name or --pid\n", stderr)
            return nil
        }

        guard let app = findApp(named: name) else {
            let allApps = listApps()
            fputs("Error: No app found matching \"\(name)\"\n", stderr)
            let suggestions = allApps.filter {
                $0.name.lowercased().contains(name.prefix(3).lowercased())
            }.prefix(5)
            if !suggestions.isEmpty {
                fputs("Did you mean: \(suggestions.map(\.name).joined(separator: ", "))?\n", stderr)
            }
            return nil
        }
        return app
    }
}
