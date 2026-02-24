import Foundation

/// AX Element Matcher — fuzzy element matching for native macOS accessibility tree
///
/// Used by `cua pipe --match` and `cua assert --match` to score elements from AX snapshots.
/// Scoring mirrors `Pipe.fuzzyScore` so both commands produce consistent results.
public struct AXElementMatcher {

    /// Calculate fuzzy match score between a needle and an accessibility element.
    ///
    /// - Parameters:
    ///   - needle: Lowercased search string
    ///   - element: The `Element` to score
    ///   - sectionLabel: Optional label of the section containing the element
    /// - Returns: Score ≥ 0; higher means better match; 0 means no match
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
