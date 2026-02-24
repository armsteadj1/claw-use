import Foundation

/// Sender-side scrubbing and app-blocking logic, shared by the CUA CLI and the remote HTTP server.
public enum RemoteScrubber {

    /// Bundle IDs that must never be stored in remote snapshots.
    public static let blockedBundleIds: Set<String> = [
        "com.agilebits.onepassword",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.apple.MobileSMS",
        "org.whispersystems.signal-desktop",
        "com.apple.keychainaccess",
    ]

    /// Returns true when `bundleId` belongs to a privacy-sensitive app.
    public static func isBlocked(bundleId: String) -> Bool {
        blockedBundleIds.contains(bundleId.lowercased())
    }

    /// Scrub sensitive data from a snapshot before it is stored or transmitted.
    ///
    /// Currently blanks the value of secure-text-field elements
    /// (`AXSecureTextField`, `secureTextField`, `passwordField`).
    public static func scrub(_ snapshot: AppSnapshot) -> AppSnapshot {
        let sections = snapshot.content.sections.map { section in
            Section(
                role: section.role,
                label: section.label,
                elements: section.elements.map { element in
                    if element.role == "secureTextField"
                        || element.role == "AXSecureTextField"
                        || element.role == "passwordField" {
                        return Element(
                            ref: element.ref, role: element.role,
                            label: element.label, value: AnyCodable(""),
                            placeholder: element.placeholder,
                            enabled: element.enabled, focused: element.focused,
                            selected: element.selected, actions: element.actions
                        )
                    }
                    return element
                }
            )
        }
        return AppSnapshot(
            app: snapshot.app,
            bundleId: snapshot.bundleId,
            pid: snapshot.pid,
            timestamp: snapshot.timestamp,
            window: snapshot.window,
            meta: snapshot.meta,
            content: ContentTree(summary: snapshot.content.summary, sections: sections),
            actions: snapshot.actions,
            stats: snapshot.stats
        )
    }
}
