import AppKit
import ApplicationServices
import Foundation

public struct ActionExecutor {
    public let refMap: RefMap

    public init(refMap: RefMap) {
        self.refMap = refMap
    }

    public enum ActionType: String {
        case click
        case focus
        case fill
        case clear
        case toggle
        case select
        case eval
    }

    public func execute(
        action: ActionType,
        ref: String,
        value: String?,
        on app: NSRunningApplication,
        enricher: Enricher
    ) -> ActionResultOutput {
        guard let element = refMap.element(for: ref) else {
            return ActionResultOutput(
                success: false,
                error: "Element \(ref) not found. Try re-running 'snapshot' to get updated refs.",
                snapshot: nil
            )
        }

        let result: ActionResultOutput
        switch action {
        case .click:
            result = performClick(element: element)
        case .focus:
            result = performFocus(element: element)
        case .fill:
            guard let value = value else {
                return ActionResultOutput(success: false, error: "Fill action requires --value", snapshot: nil)
            }
            result = performFill(element: element, value: value)
        case .clear:
            result = performFill(element: element, value: "")
        case .toggle:
            result = performToggle(element: element)
        case .select:
            result = performSelect(element: element, optionLabel: value)
        case .eval:
            result = ActionResultOutput(success: false, error: "eval is handled at command level, not in ActionExecutor", snapshot: nil)
        }

        guard result.success else { return result }

        // Re-snapshot to return updated state
        let newRefMap = RefMap()
        let snapshot = enricher.snapshot(app: app, refMap: newRefMap)
        return ActionResultOutput(success: true, error: nil, snapshot: snapshot)
    }

    // MARK: - Click

    private func performClick(element: AXUIElement) -> ActionResultOutput {
        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = (actionNames as? [String]) ?? []

        guard actions.contains(kAXPressAction as String) else {
            return ActionResultOutput(
                success: false,
                error: "Element does not support press action. Available: \(actions)",
                snapshot: nil
            )
        }

        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if error != .success {
            return ActionResultOutput(success: false, error: "AXPress failed with code \(error.rawValue)", snapshot: nil)
        }

        Thread.sleep(forTimeInterval: 0.3)
        return ActionResultOutput(success: true, error: nil, snapshot: nil)
    }

    // MARK: - Focus

    private func performFocus(element: AXUIElement) -> ActionResultOutput {
        let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        if error != .success {
            return ActionResultOutput(success: false, error: "Focus failed with code \(error.rawValue)", snapshot: nil)
        }
        Thread.sleep(forTimeInterval: 0.1)
        return ActionResultOutput(success: true, error: nil, snapshot: nil)
    }

    // MARK: - Fill

    private func performFill(element: AXUIElement, value: String) -> ActionResultOutput {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        guard textRoles.contains(roleStr) else {
            return ActionResultOutput(
                success: false,
                error: "Element role '\(roleStr)' is not a text field. Fill only works on text fields, text areas, and combo boxes.",
                snapshot: nil
            )
        }

        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.1)

        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if error != .success {
            return ActionResultOutput(
                success: false,
                error: "Failed to set value: AX error \(error.rawValue). The field may be read-only.",
                snapshot: nil
            )
        }

        Thread.sleep(forTimeInterval: 0.2)

        var newValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &newValue)

        return ActionResultOutput(success: true, error: nil, snapshot: nil)
    }

    // MARK: - Toggle

    private func performToggle(element: AXUIElement) -> ActionResultOutput {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        guard roleStr == "AXCheckBox" || roleStr == "AXRadioButton" else {
            return ActionResultOutput(
                success: false,
                error: "Toggle only works on checkboxes and radio buttons, not '\(roleStr)'",
                snapshot: nil
            )
        }

        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if error != .success {
            return ActionResultOutput(success: false, error: "Toggle failed with code \(error.rawValue)", snapshot: nil)
        }

        Thread.sleep(forTimeInterval: 0.2)
        return ActionResultOutput(success: true, error: nil, snapshot: nil)
    }

    // MARK: - Select

    private func performSelect(element: AXUIElement, optionLabel: String?) -> ActionResultOutput {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        switch roleStr {
        case "AXPopUpButton":
            return selectDropdownOption(element: element, optionLabel: optionLabel)
        case "AXTab":
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if error != .success {
                return ActionResultOutput(success: false, error: "Tab select failed with code \(error.rawValue)", snapshot: nil)
            }
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        case "AXRadioButton":
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if error != .success {
                return ActionResultOutput(success: false, error: "Radio select failed with code \(error.rawValue)", snapshot: nil)
            }
            Thread.sleep(forTimeInterval: 0.2)
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        default:
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if error != .success {
                return ActionResultOutput(
                    success: false,
                    error: "Select not supported for role '\(roleStr)'",
                    snapshot: nil
                )
            }
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        }
    }

    private func selectDropdownOption(element: AXUIElement, optionLabel: String?) -> ActionResultOutput {
        let pressErr = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressErr != .success {
            return ActionResultOutput(success: false, error: "Failed to open dropdown: code \(pressErr.rawValue)", snapshot: nil)
        }

        Thread.sleep(forTimeInterval: 0.3)

        guard let label = optionLabel else {
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        }

        if let menuItem = findMenuItem(in: element, label: label) {
            let selectErr = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            if selectErr != .success {
                AXUIElementPerformAction(element, kAXCancelAction as CFString)
                return ActionResultOutput(success: false, error: "Failed to select option '\(label)'", snapshot: nil)
            }
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        }

        AXUIElementPerformAction(element, kAXCancelAction as CFString)
        return ActionResultOutput(
            success: false,
            error: "Option '\(label)' not found in dropdown",
            snapshot: nil
        )
    }

    // MARK: - Select Row by Index (#11)

    /// Select row by index using AXUIElement tree traversal.
    /// Fires AXSelect on the Nth AXRow element and returns its label.
    public static func selectRowByIndex(index: Int, app: NSRunningApplication) -> ActionResultOutput {
        let axApp = AXBridge.appElement(for: app)
        let rows = findAllRows(element: axApp, depth: 0, maxDepth: 20)
        guard index >= 0 && index < rows.count else {
            return ActionResultOutput(success: false, error: "Row index \(index) out of range (have \(rows.count) rows)", snapshot: nil)
        }
        let row = rows[index]
        let rowLabel = readRowLabel(row)

        // Fire AXSelect action
        if AXUIElementPerformAction(row, "AXSelect" as CFString) == .success {
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil, label: rowLabel)
        }
        // Fall back to setting kAXSelectedAttribute
        let err = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, true as CFTypeRef)
        if err == .success {
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil, label: rowLabel)
        }
        return ActionResultOutput(success: false, error: "Failed to select row \(index): AX error \(err.rawValue)", snapshot: nil)
    }

    /// Extract a human-readable label from an AXRow element by checking title,
    /// description, and recursively bubbling up text from children.
    static func readRowLabel(_ element: AXUIElement) -> String? {
        if let title = AXTreeWalker.readString(element, kAXTitleAttribute), !title.isEmpty {
            return title
        }
        if let desc = AXTreeWalker.readString(element, kAXDescriptionAttribute), !desc.isEmpty {
            return desc
        }
        return bubbleRowLabel(element, depth: 0, maxDepth: 6)
    }

    private static func bubbleRowLabel(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        let role = AXTreeWalker.readString(element, kAXRoleAttribute) ?? ""
        if role == "AXStaticText" || role == "AXButton" || role == "AXLink" {
            if let title = AXTreeWalker.readString(element, kAXTitleAttribute), !title.isEmpty { return title }
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val) == .success,
               let str = val as? String, !str.isEmpty {
                return str
            }
        }
        guard let children = AXTreeWalker.readChildren(element) else { return nil }
        for child in children {
            if let found = bubbleRowLabel(child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private static func findAllRows(element: AXUIElement, depth: Int, maxDepth: Int) -> [AXUIElement] {
        guard depth < maxDepth else { return [] }
        var rows: [AXUIElement] = []
        let role = AXTreeWalker.readString(element, kAXRoleAttribute)
        if role == "AXRow" {
            rows.append(element)
        }
        if let children = AXTreeWalker.readChildren(element) {
            for child in children {
                rows.append(contentsOf: findAllRows(element: child, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return rows
    }

    // MARK: - Coordinate Click (#2)

    /// Click at absolute screen coordinates using CGEvent
    public static func clickAtCoordinate(x: Double, y: Double) -> ActionResultOutput {
        let point = CGPoint(x: x, y: y)
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return ActionResultOutput(success: false, error: "Failed to create CGEvent for click", snapshot: nil)
        }
        mouseDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)
        return ActionResultOutput(success: true, error: nil, snapshot: nil)
    }

    /// Click at window-relative coordinates by adding window origin offset
    public static func clickAtRelativeCoordinate(x: Double, y: Double, app: NSRunningApplication) -> ActionResultOutput {
        let axApp = AXBridge.appElement(for: app)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef) == .success else {
            return ActionResultOutput(success: false, error: "Cannot find main window for coordinate offset", snapshot: nil)
        }
        let window = windowRef as! AXUIElement
        guard let pos = AXTreeWalker.readPosition(window) else {
            return ActionResultOutput(success: false, error: "Cannot read window position", snapshot: nil)
        }
        return clickAtCoordinate(x: pos.x + x, y: pos.y + y)
    }

    private func findMenuItem(in element: AXUIElement, label: String) -> AXUIElement? {
        guard let children = AXTreeWalker.readChildren(element) else { return nil }
        for child in children {
            let childRole = AXTreeWalker.readString(child, kAXRoleAttribute)
            if childRole == "AXMenu" {
                if let menuChildren = AXTreeWalker.readChildren(child) {
                    for item in menuChildren {
                        let itemTitle = AXTreeWalker.readString(item, kAXTitleAttribute)
                        if itemTitle?.lowercased() == label.lowercased() {
                            return item
                        }
                    }
                }
            }
            if let found = findMenuItem(in: child, label: label) {
                return found
            }
        }
        return nil
    }
}
