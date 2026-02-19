import AppKit
import Foundation

public struct ChromeEnhancer: AppEnhancer {
    public var bundleIdentifiers: [String] {
        ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium"]
    }

    public init() {}

    public func enhance(rawTree: RawAXNode, app: NSRunningApplication, refMap: RefMap?) -> AppSnapshot {
        let window = extractWindow(rawTree)
        let meta = extractMeta(rawTree: rawTree)

        let windowNode = rawTree.children.first(where: { $0.role == "AXWindow" }) ?? rawTree
        let (chromeNodes, webArea) = separateChromeAndContent(windowNode)

        let refAssigner = RefAssigner()
        var sections: [Section] = []

        for node in chromeNodes {
            if node.role == "AXToolbar" {
                let elements = Grouper.buildElements(
                    from: collectInteractive(node),
                    refAssigner: refAssigner,
                    refMap: refMap
                )
                if !elements.isEmpty {
                    sections.append(Section(role: "toolbar", label: "Browser Toolbar", elements: elements))
                }
            } else if node.role == "AXTabGroup" {
                let elements = Grouper.buildElements(
                    from: collectInteractive(node),
                    refAssigner: refAssigner,
                    refMap: refMap
                )
                if !elements.isEmpty {
                    sections.append(Section(role: "navigation", label: "Tabs", elements: elements))
                }
            }
        }

        if let webArea = webArea {
            let webSections = processWebContent(webArea, refAssigner: refAssigner, refMap: refMap)
            sections.append(contentsOf: webSections)
        }

        let generic = GenericEnhancer()
        let actions = generic.inferActions(sections: sections)
        let enrichedCount = sections.flatMap(\.elements).filter { !$0.ref.isEmpty }.count

        return AppSnapshot(
            app: app.localizedName ?? "Google Chrome",
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: window,
            meta: meta,
            content: ContentTree(
                summary: generateSummary(window: window, meta: meta, sections: sections),
                sections: sections
            ),
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
        meta["enhancer"] = AnyCodable("chrome")

        let windowNode = rawTree.children.first(where: { $0.role == "AXWindow" }) ?? rawTree

        if let url = extractURL(from: windowNode) {
            meta["url"] = AnyCodable(url)
        }

        let tabs = extractTabs(from: windowNode)
        if !tabs.isEmpty {
            meta["tabs"] = AnyCodable(tabs.map { tab in
                [
                    "title": AnyCodable(tab.title),
                    "index": AnyCodable(tab.index),
                    "selected": AnyCodable(tab.selected),
                ] as [String: AnyCodable]
            })
        }

        return meta
    }

    // MARK: - Window

    private func extractWindow(_ tree: RawAXNode) -> WindowInfo {
        if let window = tree.children.first(where: { $0.role == "AXWindow" }) {
            return WindowInfo(title: window.title, size: window.size, focused: window.focused ?? false)
        }
        return WindowInfo(title: tree.title, size: tree.size, focused: tree.focused ?? false)
    }

    // MARK: - URL Extraction

    func extractURL(from node: RawAXNode) -> String? {
        if node.role == "AXTextField" || node.role == "AXComboBox" {
            if let desc = node.axDescription?.lowercased(),
               desc.contains("address") || desc.contains("url") || desc.contains("search")
            {
                return node.value?.value as? String
            }
            if let identifier = node.identifier?.lowercased(),
               identifier.contains("address") || identifier.contains("omnibox") || identifier.contains("url")
            {
                return node.value?.value as? String
            }
        }
        for child in node.children {
            if let url = extractURL(from: child) { return url }
        }
        return nil
    }

    // MARK: - Chrome vs Content Separation

    func separateChromeAndContent(_ window: RawAXNode) -> (chrome: [RawAXNode], webArea: RawAXNode?) {
        var chromeNodes: [RawAXNode] = []
        var webArea: RawAXNode? = nil

        func find(_ node: RawAXNode) {
            if node.role == "AXWebArea" {
                webArea = node
                return
            }
            if node.role == "AXToolbar" || node.role == "AXTabGroup" {
                chromeNodes.append(node)
            }
            for child in node.children {
                find(child)
            }
        }
        find(window)
        return (chromeNodes, webArea)
    }

    // MARK: - Tab Extraction

    struct TabInfo {
        let title: String
        let index: Int
        let selected: Bool
    }

    func extractTabs(from node: RawAXNode) -> [TabInfo] {
        var tabs: [TabInfo] = []

        func findTabs(_ n: RawAXNode) {
            if n.role == "AXTabGroup" {
                for (i, child) in n.children.enumerated() where child.role == "AXTab" {
                    tabs.append(TabInfo(
                        title: child.title ?? "Tab \(i + 1)",
                        index: i,
                        selected: child.selected ?? false
                    ))
                }
                return
            }
            for child in n.children { findTabs(child) }
        }
        findTabs(node)
        return tabs
    }

    // MARK: - Web Content Processing

    func processWebContent(_ webArea: RawAXNode, refAssigner: RefAssigner, refMap: RefMap?) -> [Section] {
        var sections: [Section] = []

        let meaningful = collectWebElements(webArea)

        let formNodes = meaningful.filter { node in
            guard let role = node.role else { return false }
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXButton"].contains(role)
        }

        if formNodes.count >= 2 {
            let hasInputs = formNodes.contains { ["AXTextField", "AXTextArea", "AXComboBox"].contains($0.role ?? "") }
            if hasInputs {
                let elements = Grouper.buildElements(from: formNodes, refAssigner: refAssigner, refMap: refMap)
                if !elements.isEmpty {
                    sections.append(Section(role: "form", label: nil, elements: elements))
                }
            }
        }

        let contentNodes = meaningful.filter { node in
            guard let role = node.role else { return false }
            return ["AXStaticText", "AXHeading", "AXLink", "AXImage"].contains(role) ||
                   (role == "AXGroup" && node.title != nil)
        }

        if !contentNodes.isEmpty {
            let elements = Grouper.buildElements(from: contentNodes, refAssigner: refAssigner, refMap: refMap)
            if !elements.isEmpty {
                sections.append(Section(role: "content", label: "Page Content", elements: elements))
            }
        }

        let navLinks = meaningful.filter { $0.role == "AXLink" }
        if navLinks.count >= 3 {
            let elements = Grouper.buildElements(from: navLinks, refAssigner: refAssigner, refMap: refMap)
            if !elements.isEmpty {
                sections.append(Section(role: "navigation", label: "Links", elements: elements))
            }
        }

        return sections
    }

    private func collectWebElements(_ node: RawAXNode) -> [RawAXNode] {
        var result: [RawAXNode] = []

        guard let role = node.role else {
            for child in node.children {
                result.append(contentsOf: collectWebElements(child))
            }
            return result
        }

        let meaningfulRoles: Set<String> = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXLink", "AXPopUpButton", "AXComboBox",
            "AXStaticText", "AXHeading", "AXImage",
        ]

        if meaningfulRoles.contains(role) {
            result.append(node)
        }

        for child in node.children {
            result.append(contentsOf: collectWebElements(child))
        }

        return result
    }

    private func collectInteractive(_ node: RawAXNode) -> [RawAXNode] {
        var result: [RawAXNode] = []
        if RefAssigner.interactiveRoles.contains(node.role ?? "") || node.role == "AXStaticText" {
            result.append(node)
        }
        for child in node.children {
            result.append(contentsOf: collectInteractive(child))
        }
        return result
    }

    // MARK: - Summary

    private func generateSummary(window: WindowInfo, meta: [String: AnyCodable], sections: [Section]) -> String {
        var parts: [String] = ["Chrome"]
        if let title = window.title {
            let clean = title.replacingOccurrences(of: " - Google Chrome", with: "")
            if !clean.isEmpty { parts.append("showing \"\(clean)\"") }
        }
        if let url = meta["url"]?.value as? String {
            parts.append("at \(url)")
        }
        let elementCount = sections.flatMap(\.elements).filter { !$0.ref.isEmpty }.count
        if elementCount > 0 { parts.append("\(elementCount) interactive elements") }
        return parts.joined(separator: " — ")
    }
}
