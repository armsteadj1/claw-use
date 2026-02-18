import AppKit
import ApplicationServices
import Foundation

// MARK: - Enricher

public struct Enricher {
    public let enhancerRegistry: EnhancerRegistry

    public init() {
        var registry = EnhancerRegistry()
        registry.register(ChromeEnhancer())
        self.enhancerRegistry = registry
    }

    /// Build a full enriched snapshot from an app
    public func snapshot(
        app: NSRunningApplication,
        maxDepth: Int = 50,
        refMap: RefMap
    ) -> AppSnapshot {
        let walkStart = DispatchTime.now()

        let axApp = AXBridge.appElement(for: app)
        var visited = Set<UInt>()
        let rawTree = AXTreeWalker.walk(axApp, maxDepth: maxDepth, visited: &visited, refMap: refMap)

        let walkEnd = DispatchTime.now()
        let walkMs = Int((walkEnd.uptimeNanoseconds - walkStart.uptimeNanoseconds) / 1_000_000)

        guard let tree = rawTree else {
            return emptySnapshot(app: app, walkMs: walkMs)
        }

        let enrichStart = DispatchTime.now()

        let enhancer = enhancerRegistry.enhancer(for: app.bundleIdentifier)
        let result = enhancer.enhance(rawTree: tree, app: app, refMap: refMap)

        let enrichEnd = DispatchTime.now()
        let enrichMs = Int((enrichEnd.uptimeNanoseconds - enrichStart.uptimeNanoseconds) / 1_000_000)

        let totalNodes = countNodes(tree)
        let stats = SnapshotStats(
            totalNodes: totalNodes,
            prunedNodes: totalNodes - result.stats.enrichedElements,
            enrichedElements: result.stats.enrichedElements,
            walkTimeMs: walkMs,
            enrichTimeMs: enrichMs
        )

        return AppSnapshot(
            app: result.app,
            bundleId: result.bundleId,
            pid: result.pid,
            timestamp: result.timestamp,
            window: result.window,
            meta: result.meta,
            content: result.content,
            actions: result.actions,
            stats: stats
        )
    }

    private func emptySnapshot(app: NSRunningApplication, walkMs: Int) -> AppSnapshot {
        AppSnapshot(
            app: app.localizedName ?? "Unknown",
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: WindowInfo(title: nil, size: nil, focused: false),
            meta: [:],
            content: ContentTree(summary: "No accessibility tree available", sections: []),
            actions: [],
            stats: SnapshotStats(totalNodes: 0, prunedNodes: 0, enrichedElements: 0, walkTimeMs: walkMs, enrichTimeMs: 0)
        )
    }

    private func countNodes(_ node: RawAXNode) -> Int {
        1 + node.children.reduce(0) { $0 + countNodes($1) }
    }
}

// MARK: - Pruning

public struct Pruner {
    public static let alwaysPruneRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXMatte",
        "AXRuler", "AXRulerMarker", "AXUnknown",
        "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
    ]

    public static let alwaysKeepRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXLink", "AXPopUpButton", "AXComboBox",
        "AXSlider", "AXMenuButton",
        "AXTab", "AXTable", "AXRow", "AXCell",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
    ]

    public static func shouldPrune(_ node: RawAXNode) -> Bool {
        guard let role = node.role else { return true }
        if role.isEmpty { return true }
        if alwaysPruneRoles.contains(role) { return true }

        if role == "AXGroup" && node.title == nil && node.value == nil && node.children.count <= 1 {
            let interactiveActions: Set<String> = ["AXPress", "AXConfirm", "AXPick"]
            if !node.actions.contains(where: { interactiveActions.contains($0) }) {
                return true
            }
        }

        if role == "AXScrollArea" || role == "AXSplitGroup" {
            return true
        }

        return false
    }

    public static func shouldKeep(_ node: RawAXNode) -> Bool {
        guard let role = node.role else { return false }
        if alwaysKeepRoles.contains(role) { return true }

        let interactiveActions: Set<String> = ["AXPress", "AXConfirm", "AXPick"]
        if node.actions.contains(where: { interactiveActions.contains($0) }) {
            return true
        }

        if role == "AXStaticText" {
            if let val = node.value?.value as? String, !val.isEmpty { return true }
            if let title = node.title, !title.isEmpty { return true }
        }

        if role == "AXImage" {
            if node.title != nil || node.axDescription != nil { return true }
        }

        if role == "AXGroup" && (node.title != nil || node.axDescription != nil) { return true }

        if ["AXTabGroup", "AXToolbar", "AXWebArea", "AXList", "AXOutline"].contains(role) {
            return true
        }

        if ["AXSheet", "AXDialog", "AXPopover"].contains(role) {
            return true
        }

        return false
    }

    public static func prune(_ node: RawAXNode) -> [RawAXNode] {
        if shouldPrune(node) {
            return node.children.flatMap { prune($0) }
        }
        if shouldKeep(node) {
            return [node]
        }
        return node.children.flatMap { prune($0) }
    }
}

// MARK: - Ref Assignment

public class RefAssigner {
    private var counter = 0

    public init() {}

    public func nextRef() -> String {
        counter += 1
        return "e\(counter)"
    }

    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXPopUpButton",
        "AXComboBox", "AXSlider", "AXTab",
        "AXIncrementor", "AXColorWell", "AXDisclosureTriangle",
        "AXMenuButton",
    ]

    public func shouldAssignRef(_ node: RawAXNode) -> Bool {
        guard let role = node.role else { return false }
        if Self.interactiveRoles.contains(role) { return true }
        if role == "AXGroup" && node.actions.contains("AXPress") { return true }
        return false
    }
}

// MARK: - Role Simplification

public let roleMap: [String: String] = [
    "AXButton": "button",
    "AXTextField": "textfield",
    "AXTextArea": "textarea",
    "AXCheckBox": "checkbox",
    "AXRadioButton": "radio",
    "AXLink": "link",
    "AXPopUpButton": "dropdown",
    "AXComboBox": "combobox",
    "AXSlider": "slider",
    "AXStaticText": "text",
    "AXImage": "image",
    "AXTable": "table",
    "AXRow": "row",
    "AXCell": "cell",
    "AXTab": "tab",
    "AXMenuItem": "menuitem",
    "AXMenuButton": "menubutton",
    "AXList": "list",
    "AXGroup": "group",
    "AXWebArea": "webarea",
    "AXToolbar": "toolbar",
    "AXTabGroup": "tabgroup",
    "AXOutline": "outline",
    "AXDisclosureTriangle": "disclosure",
    "AXIncrementor": "stepper",
    "AXColorWell": "colorwell",
    "AXSheet": "sheet",
    "AXDialog": "dialog",
    "AXPopover": "popover",
]

public func simplifyRole(_ role: String?) -> String {
    guard let role = role else { return "unknown" }
    return roleMap[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
}

// MARK: - Section Detection

public enum SectionRole: String, Codable {
    case form
    case navigation
    case toolbar
    case content
    case list
    case table
    case sidebar
    case dialog
    case other
}

// MARK: - Grouping

public struct Grouper {
    public static func group(_ nodes: [RawAXNode]) -> [Section] {
        var sections: [Section] = []
        var currentElements: [RawAXNode] = []
        var currentRole: SectionRole = .other
        var currentLabel: String? = nil

        let refAssigner = RefAssigner()

        for node in nodes {
            let detectedRole = detectSectionRole(node)

            if detectedRole != currentRole && !currentElements.isEmpty {
                let elements = buildElements(from: currentElements, refAssigner: refAssigner, refMap: nil)
                if !elements.isEmpty {
                    sections.append(Section(role: currentRole.rawValue, label: currentLabel, elements: elements))
                }
                currentElements = []
                currentLabel = nil
            }

            currentRole = detectedRole
            if currentLabel == nil { currentLabel = node.title }

            currentElements.append(node)
            if node.role == "AXWebArea" {
                currentElements.append(contentsOf: node.children)
            } else {
                let pruned = node.children.flatMap { Pruner.prune($0) }
                currentElements.append(contentsOf: pruned)
            }
        }

        if !currentElements.isEmpty {
            let elements = buildElements(from: currentElements, refAssigner: refAssigner, refMap: nil)
            if !elements.isEmpty {
                sections.append(Section(role: currentRole.rawValue, label: currentLabel, elements: elements))
            }
        }

        return sections
    }

    public static func groupWithRefMap(_ nodes: [RawAXNode], refAssigner: RefAssigner, refMap: RefMap?) -> [Section] {
        var sections: [Section] = []
        var currentElements: [RawAXNode] = []
        var currentRole: SectionRole = .other
        var currentLabel: String? = nil

        for node in nodes {
            let detectedRole = detectSectionRole(node)

            if detectedRole != currentRole && !currentElements.isEmpty {
                let elements = buildElements(from: currentElements, refAssigner: refAssigner, refMap: refMap)
                if !elements.isEmpty {
                    sections.append(Section(role: currentRole.rawValue, label: currentLabel, elements: elements))
                }
                currentElements = []
                currentLabel = nil
            }

            currentRole = detectedRole
            if currentLabel == nil { currentLabel = node.title }

            currentElements.append(node)
            if node.role == "AXWebArea" {
                currentElements.append(contentsOf: node.children)
            } else {
                let pruned = node.children.flatMap { Pruner.prune($0) }
                currentElements.append(contentsOf: pruned)
            }
        }

        if !currentElements.isEmpty {
            let elements = buildElements(from: currentElements, refAssigner: refAssigner, refMap: refMap)
            if !elements.isEmpty {
                sections.append(Section(role: currentRole.rawValue, label: currentLabel, elements: elements))
            }
        }

        return sections
    }

    public static func detectSectionRole(_ node: RawAXNode) -> SectionRole {
        guard let role = node.role else { return .other }
        switch role {
        case "AXToolbar": return .toolbar
        case "AXTabGroup": return .navigation
        case "AXTable": return .table
        case "AXList", "AXOutline": return .list
        case "AXSheet", "AXDialog", "AXPopover": return .dialog
        case "AXWebArea": return .content
        case "AXGroup":
            let hasInputs = node.children.contains { child in
                guard let r = child.role else { return false }
                return ["AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton"].contains(r)
            }
            let hasButton = node.children.contains { $0.role == "AXButton" }
            if hasInputs && hasButton { return .form }

            let linkCount = node.children.filter { $0.role == "AXLink" || $0.role == "AXButton" }.count
            if linkCount >= 3 { return .navigation }

            return .other
        default:
            return .other
        }
    }

    public static func buildElements(from nodes: [RawAXNode], refAssigner: RefAssigner, refMap: RefMap?) -> [Element] {
        var elements: [Element] = []
        var seen = Set<String>()

        for node in nodes {
            guard let role = node.role else { continue }
            let simplified = simplifyRole(role)

            if role == "AXStaticText" {
                let textKey = "\(simplified):\(node.value?.value as? String ?? node.title ?? "")"
                if seen.contains(textKey) { continue }
                seen.insert(textKey)
            }

            let label = node.title.flatMap({ $0.isEmpty ? nil : $0 }) ?? node.axDescription.flatMap({ $0.isEmpty ? nil : $0 }) ?? node.placeholder ?? (node.value?.value as? String).flatMap { role == "AXStaticText" ? $0 : nil }

            if refAssigner.shouldAssignRef(node) {
                let ref = refAssigner.nextRef()

                if let refMap = refMap, let tempId = node.tempId {
                    refMap.promoteTemp(tempId, to: ref)
                }

                var simplifiedActions: [String] = []
                if node.actions.contains("AXPress") { simplifiedActions.append("click") }
                if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) { simplifiedActions.append("fill") }
                if ["AXCheckBox"].contains(role) { simplifiedActions.append("toggle") }
                if ["AXPopUpButton", "AXRadioButton", "AXTab"].contains(role) { simplifiedActions.append("select") }

                elements.append(Element(
                    ref: ref,
                    role: simplified,
                    label: node.title.flatMap({ $0.isEmpty ? nil : $0 }) ?? node.axDescription.flatMap({ $0.isEmpty ? nil : $0 }) ?? node.placeholder,
                    value: node.value,
                    placeholder: node.placeholder,
                    enabled: node.enabled ?? true,
                    focused: node.focused ?? false,
                    selected: node.selected ?? false,
                    actions: simplifiedActions
                ))
            } else if Pruner.shouldKeep(node) || role == "AXStaticText" || role == "AXHeading" {
                let textValue: AnyCodable? = (role == "AXStaticText" || role == "AXTextArea" || role == "AXHeading") ? node.value : nil
                elements.append(Element(
                    ref: "",
                    role: simplified,
                    label: label,
                    value: textValue,
                    placeholder: nil,
                    enabled: node.enabled ?? true,
                    focused: false,
                    selected: false,
                    actions: []
                ))
            }
        }

        return elements
    }
}

// MARK: - Enhancer Registry

public struct EnhancerRegistry {
    private var enhancers: [String: AppEnhancer] = [:]
    private let generic = GenericEnhancer()

    public init() {}

    public mutating func register(_ enhancer: AppEnhancer) {
        for id in enhancer.bundleIdentifiers {
            enhancers[id] = enhancer
        }
    }

    public func enhancer(for bundleId: String?) -> AppEnhancer {
        guard let id = bundleId else { return generic }
        return enhancers[id] ?? generic
    }
}
