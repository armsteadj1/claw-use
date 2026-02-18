import ApplicationServices
import Foundation

/// Maintains mapping from snapshot refs to AXUIElements for action execution
class RefMap {
    private var refs: [String: AXUIElement] = [:]
    private var elementToTempId: [String: AXUIElement] = [:]
    private var tempIdCounter = 0

    func registerTemp(element: AXUIElement) -> String {
        let id = "tmp_\(tempIdCounter)"
        tempIdCounter += 1
        elementToTempId[id] = element
        return id
    }

    func promoteTemp(_ tempId: String, to ref: String) {
        if let el = elementToTempId[tempId] {
            refs[ref] = el
        }
    }

    func register(ref: String, element: AXUIElement) {
        refs[ref] = element
    }

    func element(for ref: String) -> AXUIElement? {
        refs[ref]
    }

    func clear() {
        refs.removeAll()
        elementToTempId.removeAll()
        tempIdCounter = 0
    }
}

struct AXTreeWalker {
    /// Walk the full AX tree from an element, returning a RawAXNode tree
    static func walk(
        _ element: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 50,
        visited: inout Set<UInt>,
        refMap: RefMap? = nil
    ) -> RawAXNode? {
        guard depth < maxDepth else { return nil }

        let hash = CFHash(element)
        guard !visited.contains(hash) else { return nil }
        visited.insert(hash)

        let role = readString(element, kAXRoleAttribute)
        let roleDescription = readString(element, kAXRoleDescriptionAttribute)
        let title = readString(element, kAXTitleAttribute)
        let value = readValue(element, kAXValueAttribute)
        let desc = readString(element, kAXDescriptionAttribute)
        let identifier = readString(element, kAXIdentifierAttribute)
        let placeholder = readString(element, kAXPlaceholderValueAttribute)
        let enabled = readBool(element, kAXEnabledAttribute)
        let focused = readBool(element, kAXFocusedAttribute)
        let selected = readBool(element, kAXSelectedAttribute)
        let url = readString(element, kAXURLAttribute) ?? readURLString(element)
        let domId = readString(element, "AXDOMIdentifier")
        let domClasses = readStringArray(element, "AXDOMClassList")

        let position = readPosition(element)
        let size = readSize(element)

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = (actionNames as? [String]) ?? []

        // Register element in refMap for later action execution
        var tempId: String? = nil
        if let refMap = refMap {
            tempId = refMap.registerTemp(element: element)
        }

        // Recurse into children
        var children: [RawAXNode] = []
        let childCount: Int
        if let childElements = readChildren(element) {
            childCount = childElements.count
            for child in childElements {
                if let childNode = walk(child, depth: depth + 1, maxDepth: maxDepth, visited: &visited, refMap: refMap) {
                    children.append(childNode)
                }
            }
        } else {
            childCount = 0
        }

        let node = RawAXNode(
            role: role,
            roleDescription: roleDescription,
            title: title,
            value: value,
            description: desc,
            identifier: identifier,
            placeholder: placeholder,
            position: position,
            size: size,
            enabled: enabled,
            focused: focused,
            selected: selected,
            url: url,
            actions: actions,
            children: children,
            childCount: childCount,
            domId: domId,
            domClasses: domClasses
        )

        // Store tempId in a side-channel for ref mapping
        if let tempId = tempId {
            _tempIdMap[ObjectIdentifier(node as AnyObject)] = tempId
        }

        return node
    }

    // MARK: - Attribute Readers

    static func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    static func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        if let num = ref as? NSNumber {
            return num.boolValue
        }
        return ref as? Bool
    }

    static func readValue(_ element: AXUIElement, _ attribute: String) -> AnyCodable? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success, let val = ref else { return nil }

        if let s = val as? String { return AnyCodable(s) }
        if let n = val as? NSNumber {
            // Distinguish bool from number
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return AnyCodable(n.boolValue)
            }
            if n.doubleValue == Double(n.intValue) {
                return AnyCodable(n.intValue)
            }
            return AnyCodable(n.doubleValue)
        }
        if let arr = val as? [Any] {
            return AnyCodable(arr.map { AnyCodable($0) })
        }
        return AnyCodable(String(describing: val))
    }

    static func readPosition(_ element: AXUIElement) -> RawAXNode.Position? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref)
        guard err == .success, let val = ref else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(val as! AXValue, .cgPoint, &point) {
            return RawAXNode.Position(x: Double(point.x), y: Double(point.y))
        }
        return nil
    }

    static func readSize(_ element: AXUIElement) -> RawAXNode.Size? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref)
        guard err == .success, let val = ref else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(val as! AXValue, .cgSize, &size) {
            return RawAXNode.Size(width: Double(size.width), height: Double(size.height))
        }
        return nil
    }

    static func readChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? [AXUIElement]
    }

    static func readURLString(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &ref)
        guard err == .success, let val = ref else { return nil }
        if let url = val as? URL { return url.absoluteString }
        if let url = val as? NSURL { return url.absoluteString }
        return nil
    }

    static func readStringArray(_ element: AXUIElement, _ attribute: String) -> [String]? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? [String]
    }
}

// Side-channel for temp ID mapping (struct can't store mutable state easily)
// This is used during enrichment to connect RawAXNode back to AXUIElement
var _tempIdMap: [ObjectIdentifier: String] = [:]
