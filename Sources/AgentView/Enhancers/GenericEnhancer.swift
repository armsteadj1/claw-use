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

        // For WebArea (Electron/browser content): recurse DEEP to extract all meaningful content
        if role == "AXWebArea" {
            let webContent = collectWebContent(node)
            if !webContent.isEmpty {
                // Create a synthetic section-level node with the extracted content as children
                let webSection = RawAXNode(
                    role: "AXWebArea",
                    roleDescription: node.roleDescription,
                    title: node.title,
                    value: node.value,
                    axDescription: node.axDescription,
                    identifier: node.identifier,
                    placeholder: node.placeholder,
                    position: node.position,
                    size: node.size,
                    enabled: node.enabled,
                    focused: node.focused,
                    selected: node.selected,
                    url: node.url,
                    actions: node.actions,
                    children: webContent,
                    childCount: webContent.count,
                    domId: node.domId,
                    domClasses: node.domClasses
                )
                result.append(webSection)
            }
            return result
        }

        // If this is a section-level container, add it directly
        let sectionRoles: Set<String> = [
            "AXToolbar", "AXTabGroup", "AXTable", "AXList", "AXOutline",
            "AXSheet", "AXDialog", "AXPopover",
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

        // Groups with titles: keep them as labels but ALSO recurse into children
        // (Electron apps wrap content in titled groups far above the actual WebArea)
        if role == "AXGroup" && node.title != nil && !node.title!.isEmpty {
            // Only keep as a leaf if it has no deeper meaningful content
            let hasDeepContent = node.children.contains(where: { hasWebArea($0) || hasMeaningfulContent($0) })
            if !hasDeepContent {
                result.append(node)
                return result
            }
            // Otherwise fall through to recurse
        }

        // Otherwise recurse into children
        for child in node.children {
            result.append(contentsOf: collectMeaningfulNodes(child))
        }

        return result
    }

    /// Check if any descendant contains a WebArea
    private func hasWebArea(_ node: RawAXNode) -> Bool {
        if node.role == "AXWebArea" { return true }
        return node.children.contains(where: { hasWebArea($0) })
    }

    /// Check if a node or its descendants have meaningful interactive content
    private func hasMeaningfulContent(_ node: RawAXNode) -> Bool {
        if let role = node.role, RefAssigner.interactiveRoles.contains(role) { return true }
        if node.role == "AXStaticText", let val = node.value?.value as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, val != "\u{200b}" { return true }
        return node.children.contains(where: { hasMeaningfulContent($0) })
    }

    /// Recursively extract meaningful content from inside a WebArea (Electron/browser)
    private func collectWebContent(_ node: RawAXNode) -> [RawAXNode] {
        var result: [RawAXNode] = []
        guard let role = node.role else { return result }

        // Keep interactive elements
        if RefAssigner.interactiveRoles.contains(role) {
            result.append(node)
            return result
        }

        // Keep static text with real content (not just zero-width spaces)
        if role == "AXStaticText" {
            if let val = node.value?.value as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               val != "\u{200b}" {
                result.append(node)
                return result
            }
        }

        // Keep headings
        if role == "AXHeading" {
            result.append(node)
            return result
        }

        // Keep images with descriptions
        if role == "AXImage" && (node.title != nil || node.axDescription != nil) {
            result.append(node)
            return result
        }

        // Keep lists and tables
        if ["AXTable", "AXList", "AXOutline"].contains(role) {
            result.append(node)
            return result
        }

        // Recurse into everything else
        for child in node.children {
            result.append(contentsOf: collectWebContent(child))
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
