import Foundation

// MARK: - WaitResult

/// Result of a `WaitEngine.wait` poll.
public struct WaitResult {
    public let found: Bool
    public let ref: String?
    public let label: String?
    public let elapsedSeconds: Double

    public init(found: Bool, ref: String?, label: String?, elapsedSeconds: Double) {
        self.found = found
        self.ref = ref
        self.label = label
        self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - WaitEngine

/// Testable polling engine for `cua wait`.
///
/// Accepts a snapshot-provider closure so tests can inject mock snapshots
/// without needing real Accessibility API access.
public enum WaitEngine {
    public typealias SnapshotProvider = () -> AppSnapshot

    /// Poll until an element fuzzy-matching `match` appears, or until `timeout` seconds elapse.
    ///
    /// - Parameters:
    ///   - match: String to fuzzy-match against element labels/values (same algorithm as `pipe --match`).
    ///   - timeout: Maximum seconds to wait before giving up.
    ///   - intervalMs: Milliseconds between polls. Defaults to 200.
    ///   - snapshotProvider: Closure that returns the current app snapshot on each poll.
    /// - Returns: `WaitResult` indicating whether the element was found, and the matched ref/label.
    public static func wait(
        match: String,
        timeout: Double,
        intervalMs: Int = 200,
        snapshotProvider: SnapshotProvider
    ) -> WaitResult {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let intervalSec = Double(intervalMs) / 1000.0
        let needle = match.lowercased()

        while Date() < deadline {
            let snapshot = snapshotProvider()
            var best: (ref: String, score: Int, label: String)?

            for section in snapshot.content.sections {
                for element in section.elements {
                    let score = fuzzyScore(needle: needle, element: element, sectionLabel: section.label)
                    if score > 0 {
                        let lbl = element.label ?? element.role
                        if best == nil || score > best!.score {
                            best = (ref: element.ref, score: score, label: lbl)
                        }
                    }
                }
            }

            if let matched = best {
                let elapsed = Date().timeIntervalSince(start)
                return WaitResult(found: true, ref: matched.ref, label: matched.label, elapsedSeconds: elapsed)
            }

            Thread.sleep(forTimeInterval: intervalSec)
        }

        let elapsed = Date().timeIntervalSince(start)
        return WaitResult(found: false, ref: nil, label: nil, elapsedSeconds: elapsed)
    }

    // MARK: - Fuzzy scoring (mirrors Pipe / Router.handlePipe)

    public static func fuzzyScore(needle: String, element: Element, sectionLabel: String?) -> Int {
        var score = 0
        let label = (element.label ?? "").lowercased()
        let role = element.role.lowercased()
        let valStr: String = {
            guard let val = element.value?.value else { return "" }
            if let s = val as? String { return s }
            return "\(val)"
        }().lowercased()
        let secLabel = (sectionLabel ?? "").lowercased()

        if label == needle { score += 100 }
        else if label.contains(needle) { score += 80 }
        else if !label.isEmpty && needle.contains(label) { score += 40 }
        if role.contains(needle) { score += 30 }
        if valStr.contains(needle) { score += 20 }
        if secLabel.contains(needle) { score += 10 }
        if !element.actions.isEmpty && score > 0 { score += 5 }

        return score
    }
}
