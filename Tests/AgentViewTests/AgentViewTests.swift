import Foundation
import Testing
@testable import agentview

// MARK: - AnyCodable Tests

@Test func anyCodableString() throws {
    let val = AnyCodable("hello")
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? String == "hello")
}

@Test func anyCodableBool() throws {
    let val = AnyCodable(true)
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Bool == true)
}

@Test func anyCodableInt() throws {
    let val = AnyCodable(42)
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Int == 42)
}

@Test func anyCodableDouble() throws {
    let val = AnyCodable(3.14)
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(decoded.value as? Double == 3.14)
}

@Test func anyCodableNil() throws {
    let val = AnyCodable(nil)
    let data = try JSONEncoder().encode(val)
    let json = String(data: data, encoding: .utf8)
    #expect(json == "null")
}

@Test func anyCodableArray() throws {
    let val = AnyCodable([AnyCodable("a"), AnyCodable(1)])
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    let arr = decoded.value as? [AnyCodable]
    #expect(arr != nil)
    #expect(arr?.count == 2)
}

@Test func anyCodableDict() throws {
    let val = AnyCodable(["key": AnyCodable("value")])
    let data = try JSONEncoder().encode(val)
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
    let dict = decoded.value as? [String: AnyCodable]
    #expect(dict != nil)
    #expect(dict?["key"]?.value as? String == "value")
}

// MARK: - Model Codable Tests

@Test func rawAXNodeRoundTrip() throws {
    let node = RawAXNode(
        role: "AXButton",
        roleDescription: "button",
        title: "Click Me",
        value: AnyCodable("pressed"),
        description: "A button",
        identifier: "btn1",
        placeholder: nil,
        position: RawAXNode.Position(x: 10.0, y: 20.0),
        size: RawAXNode.Size(width: 100.0, height: 30.0),
        enabled: true,
        focused: false,
        selected: false,
        url: nil,
        actions: ["AXPress"],
        children: [],
        childCount: 0,
        domId: nil,
        domClasses: nil
    )

    let data = try JSONOutput.encoder.encode(node)
    #expect(data.count > 0)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("AXButton"))
    #expect(json.contains("Click Me"))
}

@Test func appSnapshotEncoding() throws {
    let snapshot = AppSnapshot(
        app: "TestApp",
        bundleId: "com.test.app",
        pid: 12345,
        timestamp: "2024-01-01T00:00:00Z",
        window: WindowInfo(title: "Test Window", size: RawAXNode.Size(width: 800, height: 600), focused: true),
        meta: ["key": AnyCodable("value")],
        content: ContentTree(
            summary: "TestApp showing \"Test Window\"",
            sections: [
                Section(
                    role: "toolbar",
                    label: "Main Toolbar",
                    elements: [
                        Element(
                            ref: "e1",
                            role: "button",
                            label: "Save",
                            value: nil,
                            placeholder: nil,
                            enabled: true,
                            focused: false,
                            selected: false,
                            actions: ["click"]
                        ),
                    ]
                ),
            ]
        ),
        actions: [
            InferredAction(
                name: "save",
                description: "Save the document",
                ref: "e1",
                requires: nil,
                options: nil
            ),
        ],
        stats: SnapshotStats(totalNodes: 100, prunedNodes: 80, enrichedElements: 5, walkTimeMs: 50, enrichTimeMs: 10)
    )

    let data = try JSONOutput.prettyEncoder.encode(snapshot)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("TestApp"))
    #expect(json.contains("toolbar"))
    #expect(json.contains("e1"))
    #expect(json.contains("save"))
}

// MARK: - Role Simplification Tests

@Test func roleSimplification() {
    #expect(simplifyRole("AXButton") == "button")
    #expect(simplifyRole("AXTextField") == "textfield")
    #expect(simplifyRole("AXCheckBox") == "checkbox")
    #expect(simplifyRole("AXPopUpButton") == "dropdown")
    #expect(simplifyRole(nil) == "unknown")
}

// MARK: - Pruner Tests

@Test func prunerKeepsButtons() {
    let node = RawAXNode(
        role: "AXButton", roleDescription: nil, title: "OK",
        value: nil, description: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: ["AXPress"], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(Pruner.shouldKeep(node) == true)
    #expect(Pruner.shouldPrune(node) == false)
}

@Test func prunerRemovesLayoutGroups() {
    let node = RawAXNode(
        role: "AXGroup", roleDescription: nil, title: nil,
        value: nil, description: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(Pruner.shouldPrune(node) == true)
}

@Test func prunerKeepsGroupWithTitle() {
    let node = RawAXNode(
        role: "AXGroup", roleDescription: nil, title: "Settings",
        value: nil, description: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [
            RawAXNode(
                role: "AXButton", roleDescription: nil, title: "OK",
                value: nil, description: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: true, focused: false, selected: false,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
            RawAXNode(
                role: "AXButton", roleDescription: nil, title: "Cancel",
                value: nil, description: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: true, focused: false, selected: false,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
        ], childCount: 2,
        domId: nil, domClasses: nil
    )
    #expect(Pruner.shouldPrune(node) == false)
    #expect(Pruner.shouldKeep(node) == true)
}

// MARK: - RefAssigner Tests

@Test func refAssignment() {
    let assigner = RefAssigner()
    #expect(assigner.nextRef() == "e1")
    #expect(assigner.nextRef() == "e2")
    #expect(assigner.nextRef() == "e3")
}

@Test func refAssignerRoles() {
    let assigner = RefAssigner()

    let button = RawAXNode(
        role: "AXButton", roleDescription: nil, title: nil,
        value: nil, description: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(assigner.shouldAssignRef(button) == true)

    let staticText = RawAXNode(
        role: "AXStaticText", roleDescription: nil, title: nil,
        value: AnyCodable("Hello"), description: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(assigner.shouldAssignRef(staticText) == false)
}

// MARK: - String Helpers

@Test func slugified() {
    #expect("Hello World".slugified == "hello_world")
    #expect("Search Flights!".slugified == "search_flights")
}

// MARK: - AppInfo Tests

@Test func appInfoEncoding() throws {
    let info = AppInfo(name: "Finder", pid: 123, bundleId: "com.apple.finder")
    let data = try JSONOutput.encoder.encode(info)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("Finder"))
    #expect(json.contains("com.apple.finder"))
}

// MARK: - ActionResultOutput Tests

@Test func actionResultEncoding() throws {
    let result = ActionResultOutput(success: true, error: nil, snapshot: nil)
    let data = try JSONOutput.encoder.encode(result)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("true"))
}

@Test func actionResultWithError() throws {
    let result = ActionResultOutput(success: false, error: "Element not found", snapshot: nil)
    let data = try JSONOutput.prettyEncoder.encode(result)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("Element not found"))
    #expect(json.contains("false"))
}
