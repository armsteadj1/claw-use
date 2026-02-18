import Foundation
import Testing
@testable import AgentViewCore

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
        axDescription: "A button",
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
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
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
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(Pruner.shouldPrune(node) == true)
}

@Test func prunerKeepsGroupWithTitle() {
    let node = RawAXNode(
        role: "AXGroup", roleDescription: nil, title: "Settings",
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [
            RawAXNode(
                role: "AXButton", roleDescription: nil, title: "OK",
                value: nil, axDescription: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: true, focused: false, selected: false,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
            RawAXNode(
                role: "AXButton", roleDescription: nil, title: "Cancel",
                value: nil, axDescription: nil, identifier: nil, placeholder: nil,
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
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(assigner.shouldAssignRef(button) == true)

    let staticText = RawAXNode(
        role: "AXStaticText", roleDescription: nil, title: nil,
        value: AnyCodable("Hello"), axDescription: nil, identifier: nil, placeholder: nil,
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

// MARK: - JSON-RPC Tests

@Test func jsonRPCRequestEncoding() throws {
    let request = JSONRPCRequest(method: "ping")
    let data = try JSONOutput.encoder.encode(request)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("ping"))
    #expect(json.contains("2.0"))
}

@Test func jsonRPCResponseEncoding() throws {
    let response = JSONRPCResponse(result: AnyCodable(["pong": AnyCodable(true)] as [String: AnyCodable]), id: AnyCodable(1))
    let data = try JSONOutput.encoder.encode(response)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("2.0"))
    #expect(json.contains("pong"))
}

@Test func jsonRPCErrorResponse() throws {
    let response = JSONRPCResponse(error: .methodNotFound, id: AnyCodable(1))
    let data = try JSONOutput.encoder.encode(response)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("-32601"))
    #expect(json.contains("Method not found"))
}

// MARK: - Transport Health Tests

@Test func transportHealthRawValues() {
    #expect(TransportHealth.healthy.rawValue == "healthy")
    #expect(TransportHealth.degraded.rawValue == "degraded")
    #expect(TransportHealth.reconnecting.rawValue == "reconnecting")
    #expect(TransportHealth.dead.rawValue == "dead")
    #expect(TransportHealth.unknown.rawValue == "unknown")
}

@Test func transportResultCreation() {
    let result = TransportResult(
        success: true,
        data: ["key": AnyCodable("value")],
        error: nil,
        transportUsed: "ax"
    )
    #expect(result.success == true)
    #expect(result.transportUsed == "ax")
    #expect(result.error == nil)
    #expect(result.data?["key"]?.value as? String == "value")
}

@Test func transportResultFailure() {
    let result = TransportResult(
        success: false,
        data: nil,
        error: "Connection refused",
        transportUsed: "cdp"
    )
    #expect(result.success == false)
    #expect(result.transportUsed == "cdp")
    #expect(result.error == "Connection refused")
}

@Test func transportActionCreation() {
    let action = TransportAction(
        type: "snapshot",
        app: "Finder",
        bundleId: "com.apple.finder",
        pid: 123,
        depth: 30
    )
    #expect(action.type == "snapshot")
    #expect(action.app == "Finder")
    #expect(action.bundleId == "com.apple.finder")
    #expect(action.pid == 123)
    #expect(action.depth == 30)
    #expect(action.ref == nil)
    #expect(action.value == nil)
}

@Test func transportActionWithAllFields() {
    let action = TransportAction(
        type: "fill",
        app: "Safari",
        bundleId: "com.apple.Safari",
        pid: 456,
        ref: "e5",
        value: "hello",
        expr: nil,
        port: 9222,
        timeout: 5,
        depth: nil
    )
    #expect(action.type == "fill")
    #expect(action.ref == "e5")
    #expect(action.value == "hello")
    #expect(action.port == 9222)
    #expect(action.timeout == 5)
}

// MARK: - Transport Stats Tests

@Test func transportStatsInitial() {
    let stats = TransportStats()
    #expect(stats.successRate == 1.0)  // No attempts = 100% default
    #expect(stats.totalAttempts == 0)
    #expect(stats.lastUsed == nil)
}

@Test func transportStatsTracking() {
    let stats = TransportStats()
    stats.recordSuccess()
    stats.recordSuccess()
    stats.recordFailure()
    #expect(stats.totalAttempts == 3)
    #expect(stats.successRate > 0.66)
    #expect(stats.successRate < 0.67)
    #expect(stats.lastUsed != nil)
}

@Test func transportStatsAllFailures() {
    let stats = TransportStats()
    stats.recordFailure()
    stats.recordFailure()
    stats.recordFailure()
    #expect(stats.successRate == 0.0)
    #expect(stats.totalAttempts == 3)
}

@Test func transportStatsReset() {
    let stats = TransportStats()
    stats.recordSuccess()
    stats.recordFailure()
    #expect(stats.totalAttempts == 2)

    stats.reset()
    #expect(stats.totalAttempts == 0)
    #expect(stats.successRate == 1.0)
    #expect(stats.lastUsed == nil)
}

// MARK: - Transport Preference Tests

@Test func transportPreferenceMatchByName() {
    let pref = TransportPreference(
        appNamePattern: "Obsidian",
        preferredOrder: ["cdp", "ax", "applescript"]
    )
    #expect(pref.matches(app: "Obsidian", bundleId: nil) == true)
    #expect(pref.matches(app: "obsidian", bundleId: nil) == true)
    #expect(pref.matches(app: "Finder", bundleId: nil) == false)
}

@Test func transportPreferenceMatchByBundleId() {
    let pref = TransportPreference(
        appNamePattern: "Chrome",
        bundleIdPattern: "com.google.Chrome",
        preferredOrder: ["cdp", "ax"]
    )
    #expect(pref.matches(app: "Google Chrome", bundleId: "com.google.Chrome") == true)
    #expect(pref.matches(app: "SomeApp", bundleId: "com.google.Chrome.canary") == true)
    #expect(pref.matches(app: "SomeApp", bundleId: "com.apple.finder") == false)
}

// MARK: - AppTransportHealth Tests

@Test func appTransportHealthEncoding() throws {
    let health = AppTransportHealth(
        name: "Obsidian",
        bundleId: "md.obsidian",
        availableTransports: ["cdp", "ax", "applescript"],
        currentHealth: ["cdp": "healthy", "ax": "healthy", "applescript": "healthy"],
        lastUsedTransport: "cdp",
        successRate: ["cdp": 0.95, "ax": 1.0, "applescript": 1.0]
    )
    let data = try JSONOutput.prettyEncoder.encode(health)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("Obsidian"))
    #expect(json.contains("md.obsidian"))
    #expect(json.contains("cdp"))
}

// MARK: - Mock Transport for Router Tests

final class MockTransport: Transport {
    let name: String
    let _canHandle: Bool
    let _health: TransportHealth
    var executeResult: TransportResult
    var executeCalled = false

    init(name: String, canHandle: Bool = true, health: TransportHealth = .healthy,
         result: TransportResult? = nil) {
        self.name = name
        self._canHandle = canHandle
        self._health = health
        self.executeResult = result ?? TransportResult(
            success: true, data: ["mock": AnyCodable(true)], error: nil, transportUsed: name
        )
    }

    func canHandle(app: String, bundleId: String?) -> Bool { _canHandle }
    func health() -> TransportHealth { _health }
    func execute(action: TransportAction) -> TransportResult {
        executeCalled = true
        return executeResult
    }
}

// MARK: - TransportRouter Tests

@Test func transportRouterExecutesBestTransport() {
    let router = TransportRouter()
    let mockAX = MockTransport(name: "ax")
    let mockCDP = MockTransport(name: "cdp")
    router.register(transport: mockAX)
    router.register(transport: mockCDP)

    let action = TransportAction(type: "snapshot", app: "Finder", bundleId: "com.apple.finder", pid: 123)
    let result = router.execute(action: action)

    #expect(result.success == true)
    #expect(mockAX.executeCalled == true)
    #expect(mockCDP.executeCalled == false) // AX is first in default order
}

@Test func transportRouterFallsBackOnFailure() {
    let router = TransportRouter()
    let failingFirst = MockTransport(
        name: "primary",
        result: TransportResult(success: false, data: nil, error: "primary failed", transportUsed: "primary")
    )
    let mockSecond = MockTransport(name: "secondary")
    router.register(transport: failingFirst)
    router.register(transport: mockSecond)

    // Use a custom action type that passes isCompatible for unknown transport names
    let action = TransportAction(type: "custom", app: "TestApp", bundleId: nil, pid: 1)
    let result = router.execute(action: action)

    #expect(result.success == true)
    #expect(failingFirst.executeCalled == true)
    #expect(mockSecond.executeCalled == true) // Fallback to secondary
}

@Test func transportRouterSkipsDeadTransports() {
    let router = TransportRouter()
    let deadFirst = MockTransport(name: "primary", health: .dead)
    let mockSecond = MockTransport(name: "secondary")
    router.register(transport: deadFirst)
    router.register(transport: mockSecond)

    let action = TransportAction(type: "custom", app: "TestApp", bundleId: nil, pid: 1)
    let result = router.execute(action: action)

    #expect(result.success == true)
    #expect(deadFirst.executeCalled == false) // Skipped because dead
    #expect(mockSecond.executeCalled == true)
}

@Test func transportRouterRespectsPreferences() {
    let router = TransportRouter()
    let mockPrimary = MockTransport(name: "primary")
    let mockSecondary = MockTransport(name: "secondary")
    router.register(transport: mockPrimary)
    router.register(transport: mockSecondary)

    // Prefer secondary for Obsidian
    router.addPreference(TransportPreference(
        appNamePattern: "Obsidian",
        preferredOrder: ["secondary", "primary"]
    ))

    let action = TransportAction(type: "custom", app: "Obsidian", bundleId: "md.obsidian", pid: 1)
    let result = router.execute(action: action)

    #expect(result.success == true)
    #expect(mockSecondary.executeCalled == true) // secondary tried first due to preference
    #expect(mockPrimary.executeCalled == false) // Not needed since secondary succeeded
}

@Test func transportRouterReturnsErrorWhenAllFail() {
    let router = TransportRouter()
    let failingAX = MockTransport(
        name: "ax",
        result: TransportResult(success: false, data: nil, error: "AX failed", transportUsed: "ax")
    )
    let failingCDP = MockTransport(
        name: "cdp",
        result: TransportResult(success: false, data: nil, error: "CDP failed", transportUsed: "cdp")
    )
    router.register(transport: failingAX)
    router.register(transport: failingCDP)

    let action = TransportAction(type: "snapshot", app: "TestApp", bundleId: nil, pid: 1)
    let result = router.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("All transports failed") == true)
}

@Test func transportRouterNoTransportsAvailable() {
    let router = TransportRouter()
    let action = TransportAction(type: "snapshot", app: "TestApp", bundleId: nil, pid: 1)
    let result = router.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("No transport available") == true)
}

@Test func transportRouterTransportChainFiltering() {
    let router = TransportRouter()
    let mockAX = MockTransport(name: "ax")
    let mockCDP = MockTransport(name: "cdp")
    let mockAS = MockTransport(name: "applescript")
    router.register(transport: mockAX)
    router.register(transport: mockCDP)
    router.register(transport: mockAS)

    // For "eval" action, only CDP should be in chain
    let evalChain = router.transportChain(for: "TestApp", bundleId: nil, actionType: "eval")
    #expect(evalChain.count == 1)
    #expect(evalChain.first?.name == "cdp")

    // For "script" action, only AppleScript should be in chain
    let scriptChain = router.transportChain(for: "TestApp", bundleId: nil, actionType: "script")
    #expect(scriptChain.count == 1)
    #expect(scriptChain.first?.name == "applescript")

    // For "snapshot" action, only AX should be in chain (CDP and AppleScript don't handle snapshot)
    let snapshotChain = router.transportChain(for: "TestApp", bundleId: nil, actionType: "snapshot")
    #expect(snapshotChain.count == 1)
    #expect(snapshotChain.first?.name == "ax")

    // For "click" action, only AX should be in chain
    let clickChain = router.transportChain(for: "TestApp", bundleId: nil, actionType: "click")
    #expect(clickChain.count == 1)
    #expect(clickChain.first?.name == "ax")
}

@Test func transportRouterHealthSummary() {
    let router = TransportRouter()
    router.register(transport: MockTransport(name: "ax", health: .healthy))
    router.register(transport: MockTransport(name: "cdp", health: .reconnecting))
    router.register(transport: MockTransport(name: "applescript", health: .dead))

    let summary = router.transportHealthSummary()
    #expect(summary["ax"] == "healthy")
    #expect(summary["cdp"] == "reconnecting")
    #expect(summary["applescript"] == "dead")
}

@Test func transportRouterAppTransportHealths() {
    let router = TransportRouter()
    router.register(transport: MockTransport(name: "ax"))
    router.register(transport: MockTransport(name: "cdp"))

    let apps = [
        AppInfo(name: "Finder", pid: 100, bundleId: "com.apple.finder"),
        AppInfo(name: "Safari", pid: 200, bundleId: "com.apple.Safari"),
    ]

    let healthInfos = router.appTransportHealths(apps: apps)
    #expect(healthInfos.count == 2)
    #expect(healthInfos[0].name == "Finder")
    #expect(healthInfos[0].availableTransports.contains("ax"))
    #expect(healthInfos[1].name == "Safari")
}

// MARK: - CDPTransport Tests

@Test func cdpTransportCanHandleElectronApps() {
    let pool = CDPConnectionPool()
    let transport = CDPTransport(pool: pool)

    #expect(transport.canHandle(app: "Obsidian", bundleId: "md.obsidian") == true)
    #expect(transport.canHandle(app: "Visual Studio Code", bundleId: "com.microsoft.VSCode") == true)
    #expect(transport.canHandle(app: "Google Chrome", bundleId: "com.google.Chrome") == true)
    #expect(transport.canHandle(app: "Finder", bundleId: "com.apple.finder") == false)
    #expect(transport.canHandle(app: "Notes", bundleId: "com.apple.Notes") == false)
}

@Test func cdpTransportRejectsNonEvalActions() {
    let pool = CDPConnectionPool()
    let transport = CDPTransport(pool: pool)

    let action = TransportAction(type: "snapshot", app: "Obsidian", bundleId: "md.obsidian", pid: 1)
    let result = transport.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("only supports 'eval'") == true)
}

@Test func cdpTransportRequiresExpr() {
    let pool = CDPConnectionPool()
    let transport = CDPTransport(pool: pool)

    let action = TransportAction(type: "eval", app: "Obsidian", bundleId: "md.obsidian", pid: 1)
    let result = transport.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("requires --expr") == true)
}

// MARK: - AppleScriptTransport Tests

@Test func appleScriptTransportCanHandleAnyApp() {
    let transport = AppleScriptTransport()
    #expect(transport.canHandle(app: "Finder", bundleId: "com.apple.finder") == true)
    #expect(transport.canHandle(app: "Notes", bundleId: "com.apple.Notes") == true)
    #expect(transport.canHandle(app: "Obsidian", bundleId: "md.obsidian") == true)
}

@Test func appleScriptTransportRejectsNonScriptActions() {
    let transport = AppleScriptTransport()
    let action = TransportAction(type: "snapshot", app: "Finder", bundleId: "com.apple.finder", pid: 1)
    let result = transport.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("only supports 'script'") == true)
}

@Test func appleScriptTransportRequiresExpr() {
    let transport = AppleScriptTransport()
    let action = TransportAction(type: "script", app: "Finder", bundleId: "com.apple.finder", pid: 1)
    let result = transport.execute(action: action)

    #expect(result.success == false)
    #expect(result.error?.contains("requires --expr") == true)
}

@Test func appleScriptTransportHealthDegrades() {
    let transport = AppleScriptTransport()
    // Health starts healthy
    #expect(transport.health() == .healthy)

    // After many failures, health should degrade
    for _ in 0..<6 {
        transport.stats.recordFailure()
    }
    #expect(transport.health() == .dead)
}

// MARK: - AXTransport Tests

@Test func axTransportName() {
    let transport = AXTransport()
    #expect(transport.name == "ax")
}

@Test func axTransportRejectsUnsupportedActions() {
    let transport = AXTransport()
    let action = TransportAction(type: "eval", app: "Finder", bundleId: "com.apple.finder", pid: 1)
    let result = transport.execute(action: action)

    #expect(result.success == false)
    // Either "does not support" (if AX permission granted) or accessibility error
    #expect(result.error != nil)
}
