import AppKit
import Foundation

public struct GenericEnhancer: AppEnhancer {
    public var bundleIdentifiers: [String] { [] }

    public init() {}

    public func enhance(rawTree: RawAXNode, app: NSRunningApplication, refMap: RefMap?) -> AppSnapshot {
        let window = extractWindow(rawTree)
        let meta = extractMeta(rawTree: rawTree)

        let prunedNodes = flattenTree(rawTree)

        let refAssigner = RefAssigner()
        let sections = Grouper.groupWithRefMap(prunedNodes, refAssigner: refAssigner, refMap: refMap)

        let summary = generateSummary(app: app, window: window, sections: sections)

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

    public func extractMeta(rawTree: RawAXNode) -> [String: AnyCodable] {
        var meta: [String: AnyCodable] = [:]
        meta["enhancer"] = AnyCodable("generic")
        return meta
    }

    // MARK: - Window extraction

    public func extractWindow(_ tree: RawAXNode) -> WindowInfo {
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

    public func flattenTree(_ tree: RawAXNode) -> [RawAXNode] {
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

        if role == "AXWebArea" {
            let webContent = collectWebContent(node)
            if !webContent.isEmpty {
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

        let sectionRoles: Set<String> = [
            "AXToolbar", "AXTabGroup", "AXTable", "AXList", "AXOutline",
            "AXSheet", "AXDialog", "AXPopover",
        ]
        if sectionRoles.contains(role) {
            result.append(node)
            return result
        }

        if Pruner.shouldKeep(node) && RefAssigner.interactiveRoles.contains(role) {
            result.append(node)
            return result
        }

        if role == "AXStaticText" {
            if let val = node.value?.value as? String, !val.isEmpty {
                result.append(node)
                return result
            }
        }

        if role == "AXGroup" && node.title != nil && !node.title!.isEmpty {
            let hasDeepContent = node.children.contains(where: { hasWebArea($0) || hasMeaningfulContent($0) })
            if !hasDeepContent {
                result.append(node)
                return result
            }
        }

        for child in node.children {
            result.append(contentsOf: collectMeaningfulNodes(child))
        }

        return result
    }

    private func hasWebArea(_ node: RawAXNode) -> Bool {
        if node.role == "AXWebArea" { return true }
        return node.children.contains(where: { hasWebArea($0) })
    }

    private func hasMeaningfulContent(_ node: RawAXNode) -> Bool {
        if let role = node.role, RefAssigner.interactiveRoles.contains(role) { return true }
        if node.role == "AXStaticText", let val = node.value?.value as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, val != "\u{200b}" { return true }
        return node.children.contains(where: { hasMeaningfulContent($0) })
    }

    private func collectWebContent(_ node: RawAXNode) -> [RawAXNode] {
        var result: [RawAXNode] = []
        guard let role = node.role else { return result }

        if RefAssigner.interactiveRoles.contains(role) {
            result.append(node)
            return result
        }

        if role == "AXStaticText" {
            if let val = node.value?.value as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               val != "\u{200b}" {
                result.append(node)
                return result
            }
        }

        if role == "AXHeading" {
            result.append(node)
            return result
        }

        if role == "AXImage" && (node.title != nil || node.axDescription != nil) {
            result.append(node)
            return result
        }

        if ["AXTable", "AXList", "AXOutline"].contains(role) {
            result.append(node)
            return result
        }

        for child in node.children {
            result.append(contentsOf: collectWebContent(child))
        }

        return result
    }

    // MARK: - Summary

    public func generateSummary(app: NSRunningApplication, window: WindowInfo, sections: [Section]) -> String {
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

    public func inferActions(sections: [Section]) -> [InferredAction] {
        var actions: [InferredAction] = []

        for section in sections {
            if section.role == SectionRole.form.rawValue || section.role == "form" {
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
