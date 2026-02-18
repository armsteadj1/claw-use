import AppKit
import Foundation

struct GenericEnhancer: AppEnhancer {
    var bundleIdentifiers: [String] { [] }

    func enhance(rawTree: RawAXNode, app: NSRunningApplication, refMap: RefMap?) -> AppSnapshot {
        let window = extractWindow(rawTree)
        let meta = extractMeta(rawTree: rawTree)

        // Prune the tree
        let prunedNodes = flattenTree(rawTree)

        // Group into sections
        let refAssigner = RefAssigner()
        let sections = Grouper.groupWithRefMap(prunedNodes, refAssigner: refAssigner, refMap: refMap)

        // Generate summary
        let summary = generateSummary(app: app, window: window, sections: sections)

        // Infer actions
        let actions = inferActions(sections: sections)

        let enrichedCount = sections.flatMap(\.elements).filter { !$0.ref.isEmpty }.count

        return AppSnapshot(
            app: app.localizedName ?? "Unknown",
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: window,
            meta: meta,
            content: ContentTree(summary: summary, sections: sections),
            actions: actions,
            stats: SnapshotStats(
                totalNodes: 0,
                prunedNodes: 0,
                enrichedElements: enrichedCount,
                walkTimeMs: 0,
                enrichTimeMs: 0
            )
        )
    }

    func extractMeta(rawTree: RawAXNode) -> [String: AnyCodable] {
        var meta: [String: AnyCodable] = [:]
        meta["enhancer"] = AnyCodable("generic")
        return meta
    }

    // MARK: - Window extraction

    func extractWindow(_ tree: RawAXNode) -> WindowInfo {
        // Find the first AXWindow child
        if let window = tree.children.first(where: { $0.role == "AXWindow" }) {
            return WindowInfo(
                title: window.title,
                size: window.size,
                focused: window.focused ?? false
            )
        }
        return WindowInfo(title: tree.title, size: tree.size, focused: tree.focused ?? false)
    }

    // MARK: - Tree Flattening

    /// Flatten the tree keeping only meaningful nodes, respecting the pruner
    func flattenTree(_ tree: RawAXNode) -> [RawAXNode] {
        // Start from the window level
        let window = tree.children.first(where: { $0.role == "AXWindow" }) ?? tree
        return collectMeaningfulNodes(window)
    }

    private func collectMeaningfulNodes(_ node: RawAXNode) -> [RawAXNode] {
        var result: [RawAXNode] = []

        guard let role = node.role else {
            for child in node.children {
                result.append(contentsOf: collectMeaningfulNodes(child))
            }
            return result
        }

        // If this is a section-level container, add it directly
        let sectionRoles: Set<String> = [
            "AXToolbar", "AXTabGroup", "AXTable", "AXList", "AXOutline",
            "AXSheet", "AXDialog", "AXPopover", "AXWebArea",
        ]
        if sectionRoles.contains(role) {
            result.append(node)
            return result
        }

        // If this is a meaningful leaf element, collect it
        if Pruner.shouldKeep(node) && RefAssigner.interactiveRoles.contains(role) {
            result.append(node)
            return result
        }

        // If it's static text, keep it
        if role == "AXStaticText" {
            if let val = node.value?.value as? String, !val.isEmpty {
                result.append(node)
                return result
            }
        }

        // If this is a group with title, treat as a section container
        if role == "AXGroup" && node.title != nil {
            result.append(node)
            return result
        }

        // Otherwise recurse into children
        for child in node.children {
            result.append(contentsOf: collectMeaningfulNodes(child))
        }

        return result
    }

    // MARK: - Summary

    func generateSummary(app: NSRunningApplication, window: WindowInfo, sections: [Section]) -> String {
        var parts: [String] = []
        let appName = app.localizedName ?? "Unknown"
        parts.append(appName)

        if let title = window.title, !title.isEmpty, title != appName {
            parts.append("showing \"\(title)\"")
        }

        let formCount = sections.filter { $0.role == SectionRole.form.rawValue }.count
        let buttonCount = sections.flatMap(\.elements).filter { $0.role == "button" && !$0.ref.isEmpty }.count
        let linkCount = sections.flatMap(\.elements).filter { $0.role == "link" }.count
        let textFieldCount = sections.flatMap(\.elements).filter { $0.role == "textfield" || $0.role == "textarea" }.count

        if formCount > 0 { parts.append("with \(formCount) form(s)") }
        if buttonCount > 0 { parts.append("\(buttonCount) buttons") }
        if linkCount > 0 { parts.append("\(linkCount) links") }
        if textFieldCount > 0 { parts.append("\(textFieldCount) text fields") }

        return parts.joined(separator: " — ")
    }

    // MARK: - Action Inference

    func inferActions(sections: [Section]) -> [InferredAction] {
        var actions: [InferredAction] = []

        for section in sections {
            if section.role == SectionRole.form.rawValue || section.role == "form" {
                // Form with submit button
                if let submit = section.elements.first(where: { $0.role == "button" && !$0.ref.isEmpty }) {
                    let fields = section.elements.filter {
                        ($0.role == "textfield" || $0.role == "textarea" || $0.role == "combobox") && !$0.ref.isEmpty
                    }
                    let name = "submit_\(section.label?.slugified ?? "form")"
                    actions.append(InferredAction(
                        name: name,
                        description: "Submit \(section.label ?? "form")",
                        ref: submit.ref,
                        requires: fields.isEmpty ? nil : fields.map(\.ref),
                        options: nil
                    ))
                }
            }

            if section.role == SectionRole.navigation.rawValue || section.role == "navigation" {
                let opts = section.elements
                    .filter { !$0.ref.isEmpty }
                    .map { ActionOption(label: $0.label ?? $0.ref, ref: $0.ref) }
                if !opts.isEmpty {
                    actions.append(InferredAction(
                        name: "navigate",
                        description: "Navigate between sections",
                        ref: nil,
                        requires: nil,
                        options: opts
                    ))
                }
            }
        }

        return actions
    }
}

// MARK: - String Helpers

extension String {
    var slugified: String {
        self.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
