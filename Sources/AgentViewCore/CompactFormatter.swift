import Foundation

/// Compact text formatter for agent-friendly output.
/// Produces ~6.5x fewer tokens than JSON for the same data.
public enum CompactFormatter {

    // MARK: - List

    /// Format app list: `Apps (N): Name1, Name2, ...`
    public static func formatList(apps: [AppInfo]) -> String {
        let names = apps.map { $0.name }.joined(separator: ", ")
        return "Apps (\(apps.count)): \(names)"
    }

    // MARK: - AX Snapshot

    /// Format enriched snapshot in compact form.
    public static func formatSnapshot(snapshot: AppSnapshot, pagination: PaginationResult? = nil) -> String {
        var lines: [String] = []

        // Header
        let transport = snapshot.meta["transport"]?.value as? String ?? "ax"
        let totalElements = snapshot.content.sections.flatMap { $0.elements }.count
        lines.append("[\(snapshot.app)] \(snapshot.window.title ?? "untitled") | \(totalElements) elements | \(transport) transport")

        // Sections
        for section in snapshot.content.sections {
            if section.elements.isEmpty { continue }
            let sectionLabel = section.label ?? section.role
            let elementStrs = section.elements.map { formatElement($0) }
            lines.append("\(sectionLabel): \(elementStrs.joined(separator: " | "))")
        }

        // Pagination
        if let pag = pagination {
            lines.append(pag.compactLine)
        } else {
            lines.append("more: false")
        }

        return lines.joined(separator: "\n")
    }

    /// Format a single element for compact output
    private static func formatElement(_ el: Element) -> String {
        var parts: [String] = []

        // Ref in brackets (only if assigned)
        if !el.ref.isEmpty {
            parts.append("[\(el.ref)]")
        }

        // Label + abbreviated role
        let abbrevRole = abbreviateRole(el.role)
        if let label = el.label, !label.isEmpty {
            parts.append("\(label) \(abbrevRole)")
        } else {
            parts.append(abbrevRole)
        }

        // Value inline
        if let val = el.value?.value {
            let valStr: String
            if let s = val as? String { valStr = s }
            else if let b = val as? Bool { valStr = b ? "true" : "false" }
            else { valStr = "\(val)" }
            if !valStr.isEmpty {
                let truncated = valStr.count > 60 ? String(valStr.prefix(60)) + "..." : valStr
                parts.append("=\"\(truncated)\"")
            }
        }

        // Disabled
        if !el.enabled {
            parts.append("(disabled)")
        }

        return parts.joined(separator: " ")
    }

    /// Abbreviate roles for compact output
    private static func abbreviateRole(_ role: String) -> String {
        switch role {
        case "button": return "btn"
        case "menubutton": return "menu"
        case "textfield", "textarea": return "field"
        case "checkbox": return "chk"
        case "radio": return "radio"
        case "dropdown": return "dropdown"
        case "combobox": return "combo"
        case "slider": return "slider"
        case "tab": return "tab"
        case "link": return "link"
        case "text": return "text"
        case "image": return "img"
        case "disclosure": return "disclosure"
        case "stepper": return "stepper"
        default: return role
        }
    }

    // MARK: - Web Snapshot

    /// Format web snapshot data from daemon JSON.
    public static func formatWebSnapshot(data: [String: AnyCodable], pagination: PaginationResult? = nil) -> String {
        var lines: [String] = []

        let url = data["url"]?.value as? String ?? ""
        let pageType = data["page_type"]?.value as? String ?? data["pageType"]?.value as? String ?? "generic"
        let transport = data["transport"]?.value as? String ?? "safari"
        let host = extractHost(from: url)

        lines.append("[\(data["app"]?.value as? String ?? "Safari")] \(host) | \(pageType) | \(transport) transport")

        // Forms
        if let forms = data["forms"]?.value as? [AnyCodable] {
            for formVal in forms {
                guard let form = formVal.value as? [String: AnyCodable] else { continue }
                let fields = form["fields"]?.value as? [AnyCodable] ?? []
                let fieldDescs = fields.compactMap { f -> String? in
                    guard let fd = f.value as? [String: AnyCodable] else { return nil }
                    let name = fd["name"]?.value as? String ?? fd["id"]?.value as? String ?? ""
                    let fType = fd["type"]?.value as? String ?? ""
                    return name.isEmpty ? nil : "\(name) (\(fType))"
                }
                let action = form["action"]?.value as? String ?? ""
                let actionHost = extractHost(from: action)
                if !fieldDescs.isEmpty {
                    lines.append("form: \(fieldDescs.joined(separator: ", ")) → \(actionHost)")
                }
            }
        }

        lines.append("---")

        // Links
        if let links = data["links"]?.value as? [AnyCodable] {
            for (i, linkVal) in links.enumerated() {
                guard let link = linkVal.value as? [String: AnyCodable] else { continue }
                let text = link["text"]?.value as? String ?? ""
                let href = link["href"]?.value as? String ?? ""
                let linkHost = extractHost(from: href)
                if !text.isEmpty {
                    lines.append("\(i + 1). \(text) (\(linkHost))")
                }
            }
        }

        lines.append("---")

        // Navigation / headings summary
        if let headings = data["headings"]?.value as? [AnyCodable] {
            let headingTexts = headings.compactMap { h -> String? in
                guard let hd = h.value as? [String: AnyCodable] else { return nil }
                return hd["text"]?.value as? String
            }
            if !headingTexts.isEmpty {
                lines.append("headings: \(headingTexts.joined(separator: " | "))")
            }
        }

        let wordCount = data["word_count"]?.value as? Int ?? data["wordCount"]?.value as? Int ?? 0

        // Pagination
        if let pag = pagination {
            lines.append("\(pag.compactLine) | \(wordCount) words")
        } else {
            lines.append("more: false | \(wordCount) words")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Web Tabs

    /// Format web tabs list.
    public static func formatWebTabs(data: [String: AnyCodable]) -> String {
        var lines: [String] = []

        let browser = data["app"]?.value as? String ?? "Safari"
        let tabs: [[String: AnyCodable]]
        if let tabArray = data["tabs"]?.value as? [AnyCodable] {
            tabs = tabArray.compactMap { $0.value as? [String: AnyCodable] }
        } else {
            tabs = []
        }

        lines.append("\(browser) tabs (\(tabs.count)):")

        for (i, tab) in tabs.enumerated() {
            let tabTitle = tab["title"]?.value as? String ?? "Untitled"
            let tabUrl = tab["url"]?.value as? String ?? ""
            let host = extractHost(from: tabUrl)
            let active = tab["active"]?.value as? Bool == true ? " (active)" : ""
            lines.append("\(i + 1). \(tabTitle) — \(host)\(active)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Web Extract

    /// Format extracted markdown content.
    public static func formatWebExtract(data: [String: AnyCodable], pagination: PaginationResult? = nil) -> String {
        var lines: [String] = []

        let content = data["content"]?.value as? String ?? data["markdown"]?.value as? String ?? ""
        lines.append(content)
        lines.append("---")

        let charCount = content.count
        if let pag = pagination {
            lines.append("\(charCount) chars | \(pag.compactLine)")
        } else {
            lines.append("\(charCount) chars | more: false")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Status

    /// Format system status.
    public static func formatStatus(data: [String: AnyCodable]) -> String {
        var lines: [String] = []

        // Daemon info
        let daemonStatus = data["daemon"]?.value as? String
            ?? (data["daemon"]?.value as? [String: AnyCodable])?["status"]?.value as? String
            ?? "unknown"
        let pid = data["pid"]?.value as? Int ?? 0
        lines.append("daemon: \(daemonStatus) (pid \(pid))")

        // Screen state
        let screen = data["screen"]?.value as? [String: AnyCodable]
        let locked = screen?["locked"]?.value as? Bool == true ? "locked" : "unlocked"
        let display = screen?["display_on"]?.value as? Bool == true ? "on" : "off"
        lines.append("screen: \(locked) | display: \(display)")

        // Cache stats
        let cache = data["cache"]?.value as? [String: AnyCodable]
        let cacheEntries = cache?["entries"]?.value as? Int ?? 0
        let hitRate = cache?["hit_rate"]?.value as? Double ?? 0
        let hitPct = Int(hitRate * 100)
        let appCount = data["app_count"]?.value as? Int ?? 0
        lines.append("apps: \(appCount) | cache: \(cacheEntries) entries (\(hitPct)% hit rate)")

        // Transport health
        let transports = data["transports"]?.value as? [String: AnyCodable]
        if let transports = transports {
            let tParts = transports.map { key, val in
                "\(key)=\(val.value as? String ?? "unknown")"
            }.sorted()
            lines.append("transports: \(tParts.joined(separator: " "))")
        }

        // Per-app transports
        if let appHealths = data["app_transports"]?.value as? [AnyCodable] {
            let appParts = appHealths.compactMap { ah -> String? in
                guard let dict = ah.value as? [String: AnyCodable] else { return nil }
                let name = dict["name"]?.value as? String ?? ""
                let available = dict["available_transports"]?.value as? [AnyCodable] ?? []
                let transportNames = available.compactMap { $0.value as? String }
                return name.isEmpty ? nil : "\(name): \(transportNames.joined(separator: "+"))"
            }
            if !appParts.isEmpty {
                lines.append(appParts.joined(separator: " | "))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Screenshot

    /// Format screenshot result.
    public static func formatScreenshot(data: ScreenCaptureResult) -> String {
        if !data.success {
            return "error: \(data.error ?? "screenshot failed")"
        }
        let w = data.width ?? 0
        let h = data.height ?? 0
        let path = data.path ?? "unknown"
        let app = path.split(separator: "-").dropFirst(2).first.map(String.init) ?? "app"
        return "📸 \(app) \(w)x\(h) → \(path)"
    }

    /// Format screenshot from dict (daemon response).
    public static func formatScreenshotDict(data: [String: AnyCodable]) -> String {
        let success = data["success"]?.value as? Bool ?? false
        if !success {
            return "error: \(data["error"]?.value as? String ?? "screenshot failed")"
        }
        let w = data["width"]?.value as? Int ?? 0
        let h = data["height"]?.value as? Int ?? 0
        let path = data["path"]?.value as? String ?? "unknown"
        let app = data["app"]?.value as? String ?? "app"
        return "📸 \(app) \(w)x\(h) → \(path)"
    }

    // MARK: - Act / Pipe result

    /// Format action result.
    public static func formatActResult(data: [String: AnyCodable]) -> String {
        let success = data["success"]?.value as? Bool ?? false
        let app = data["app"]?.value as? String ?? ""
        let action = data["action"]?.value as? String ?? ""

        if !success {
            let error = data["error"]?.value as? String ?? "unknown error"
            return "[\(app)] \(action): failed — \(error)"
        }

        var parts = ["[\(app)] \(action): ok"]
        if let ref = data["matched_ref"]?.value as? String {
            parts.append("ref=\(ref)")
        }
        if let label = data["matched_label"]?.value as? String {
            parts.append("\"\(label)\"")
        }
        if let result = data["result"]?.value as? String, !result.isEmpty {
            let truncated = result.count > 100 ? String(result.prefix(100)) + "..." : result
            parts.append("→ \(truncated)")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Web Navigate

    /// Format web navigate result: `→ Example Domain (https://example.com/)`
    public static func formatWebNavigate(data: [String: AnyCodable]) -> String {
        let success = data["success"]?.value as? Bool ?? false
        if !success {
            let error = data["error"]?.value as? String ?? "navigation failed"
            return "❌ \(error)"
        }
        let title = data["title"]?.value as? String ?? ""
        let url = data["url"]?.value as? String ?? ""
        return "→ \(title) (\(url))"
    }

    // MARK: - Web Click

    /// Format web click result: `✅ clicked "Learn more" (score: 100)`
    public static func formatWebClick(data: [String: AnyCodable]) -> String {
        let success = data["success"]?.value as? Bool ?? false
        if !success {
            let error = data["error"]?.value as? String ?? "click failed"
            return "❌ \(error)"
        }
        let matched = data["matched"]?.value as? String ?? ""
        let score = data["score"]?.value as? Int ?? 0
        return "✅ clicked \"\(matched)\" (score: \(score))"
    }

    // MARK: - Web Fill

    /// Format web fill result: `✅ filled "q" = "search term" (score: 100)`
    public static func formatWebFill(data: [String: AnyCodable]) -> String {
        let success = data["success"]?.value as? Bool ?? false
        if !success {
            let error = data["error"]?.value as? String ?? "fill failed"
            return "❌ \(error)"
        }
        let matched = data["matched"]?.value as? String ?? ""
        let filledValue = data["value"]?.value as? String ?? ""
        let score = data["score"]?.value as? Int ?? 0
        return "✅ filled \"\(matched)\" = \"\(filledValue)\" (score: \(score))"
    }

    // MARK: - Helpers

    private static func extractHost(from urlString: String) -> String {
        guard !urlString.isEmpty else { return "" }
        if let url = URL(string: urlString), let host = url.host {
            return host
        }
        // Fallback: strip protocol
        var s = urlString
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        if let slashIndex = s.firstIndex(of: "/") {
            s = String(s[..<slashIndex])
        }
        return s
    }
}
