import AppKit
import ApplicationServices
import Foundation

struct ActionExecutor {
    let refMap: RefMap

    enum ActionType: String {
        case click
        case focus
        case fill
        case clear
        case toggle
        case select
    }

    func execute(
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
        // Verify element is a text field type
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

        // Focus first
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.1)

        // Set value
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if error != .success {
            return ActionResultOutput(
                success: false,
                error: "Failed to set value: AX error \(error.rawValue). The field may be read-only.",
                snapshot: nil
            )
        }

        Thread.sleep(forTimeInterval: 0.2)

        // Verify
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
            // Tabs just need a press
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
            // Try AXPress as fallback
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
        // Press to open the dropdown
        let pressErr = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if pressErr != .success {
            return ActionResultOutput(success: false, error: "Failed to open dropdown: code \(pressErr.rawValue)", snapshot: nil)
        }

        Thread.sleep(forTimeInterval: 0.3)

        guard let label = optionLabel else {
            // Just opened the dropdown, no specific option requested
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        }

        // Find the menu that appeared
        if let menuItem = findMenuItem(in: element, label: label) {
            let selectErr = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
            if selectErr != .success {
                // Close menu with Cancel
                AXUIElementPerformAction(element, kAXCancelAction as CFString)
                return ActionResultOutput(success: false, error: "Failed to select option '\(label)'", snapshot: nil)
            }
            Thread.sleep(forTimeInterval: 0.3)
            return ActionResultOutput(success: true, error: nil, snapshot: nil)
        }

        // Option not found, close menu
        AXUIElementPerformAction(element, kAXCancelAction as CFString)
        return ActionResultOutput(
            success: false,
            error: "Option '\(label)' not found in dropdown",
            snapshot: nil
        )
    }

    private func findMenuItem(in element: AXUIElement, label: String) -> AXUIElement? {
        // Look for AXMenu child, then AXMenuItem matching label
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
            // Recurse in case menu is nested
            if let found = findMenuItem(in: child, label: label) {
                return found
            }
        }
        return nil
    }
}
