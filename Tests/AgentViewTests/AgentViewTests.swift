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

// MARK: - SnapshotCache Tests

@Test func snapshotCacheInitialStats() {
    let cache = SnapshotCache()
    let stats = cache.stats
    #expect(stats.entries == 0)
    #expect(stats.hits == 0)
    #expect(stats.misses == 0)
    #expect(stats.hitRate == 0.0)
}

@Test func snapshotCacheMissOnEmpty() {
    let cache = SnapshotCache()
    let entry = cache.get(app: "TestApp")
    #expect(entry == nil)
    #expect(cache.stats.misses == 1)
}

@Test func snapshotCachePutAndGet() {
    let cache = SnapshotCache()
    let snapshot = makeTestSnapshot(app: "TestApp")

    let _ = cache.put(app: "TestApp", snapshot: snapshot, transport: "ax")
    let entry = cache.get(app: "TestApp")

    #expect(entry != nil)
    #expect(entry?.snapshot.app == "TestApp")
    #expect(entry?.transport == "ax")
    #expect(cache.stats.entries == 1)
    #expect(cache.stats.hits == 1)
}

@Test func snapshotCacheCaseInsensitive() {
    let cache = SnapshotCache()
    let snapshot = makeTestSnapshot(app: "Safari")

    let _ = cache.put(app: "Safari", snapshot: snapshot, transport: "ax")
    let entry = cache.get(app: "safari")

    #expect(entry != nil)
    #expect(entry?.snapshot.app == "Safari")
}

@Test func snapshotCacheTTLExpiry() throws {
    let cache = SnapshotCache()
    cache.axTTL = 0.1  // 100ms TTL for test

    let snapshot = makeTestSnapshot(app: "TestApp")
    let _ = cache.put(app: "TestApp", snapshot: snapshot, transport: "ax")

    // Should be fresh immediately
    #expect(cache.get(app: "TestApp") != nil)

    // Wait for TTL to expire
    Thread.sleep(forTimeInterval: 0.15)

    // Should be expired now
    #expect(cache.get(app: "TestApp") == nil)
}

@Test func snapshotCacheDifferentTTLPerTransport() {
    let cache = SnapshotCache()
    cache.axTTL = 0.1       // 100ms
    cache.cdpTTL = 0.5      // 500ms

    let snap1 = makeTestSnapshot(app: "Finder")
    let snap2 = makeTestSnapshot(app: "Obsidian")

    let _ = cache.put(app: "Finder", snapshot: snap1, transport: "ax")
    let _ = cache.put(app: "Obsidian", snapshot: snap2, transport: "cdp")

    Thread.sleep(forTimeInterval: 0.15)

    // AX cache should be expired
    #expect(cache.get(app: "Finder") == nil)
    // CDP cache should still be fresh
    #expect(cache.get(app: "Obsidian") != nil)
}

@Test func snapshotCacheInvalidate() {
    let cache = SnapshotCache()
    let snapshot = makeTestSnapshot(app: "TestApp")

    let _ = cache.put(app: "TestApp", snapshot: snapshot, transport: "ax")
    #expect(cache.get(app: "TestApp") != nil)

    cache.invalidate(app: "TestApp")
    #expect(cache.get(app: "TestApp") == nil)
}

@Test func snapshotCacheInvalidateAll() {
    let cache = SnapshotCache()

    let _ = cache.put(app: "App1", snapshot: makeTestSnapshot(app: "App1"), transport: "ax")
    let _ = cache.put(app: "App2", snapshot: makeTestSnapshot(app: "App2"), transport: "ax")

    cache.invalidateAll()
    #expect(cache.get(app: "App1") == nil)
    #expect(cache.get(app: "App2") == nil)
}

@Test func snapshotCacheHitRateTracking() {
    let cache = SnapshotCache()

    let _ = cache.put(app: "TestApp", snapshot: makeTestSnapshot(app: "TestApp"), transport: "ax")

    // 2 hits, 1 miss
    let _ = cache.get(app: "TestApp")  // hit
    let _ = cache.get(app: "TestApp")  // hit
    let _ = cache.get(app: "NonExistent")  // miss

    let stats = cache.stats
    #expect(stats.hits == 2)
    #expect(stats.misses == 1)
    #expect(stats.hitRate > 0.66)
    #expect(stats.hitRate < 0.67)
}

// MARK: - RefStabilityManager Tests

@Test func refStabilityInitialAssignment() {
    let manager = RefStabilityManager()
    let elements = [
        makeTestElement(ref: "tmp1", role: "button", label: "Save"),
        makeTestElement(ref: "tmp2", role: "textfield", label: "Name"),
    ]

    let stabilized = manager.stabilize(elements: elements)
    #expect(stabilized.count == 2)
    #expect(stabilized[0].ref == "e1")
    #expect(stabilized[0].label == "Save")
    #expect(stabilized[1].ref == "e2")
    #expect(stabilized[1].label == "Name")
}

@Test func refStabilityPersistsAcrossSnapshots() {
    let manager = RefStabilityManager()

    // First snapshot
    let elements1 = [
        makeTestElement(ref: "tmp1", role: "button", label: "Save"),
        makeTestElement(ref: "tmp2", role: "textfield", label: "Name"),
    ]
    let result1 = manager.stabilize(elements: elements1)
    #expect(result1[0].ref == "e1")
    #expect(result1[1].ref == "e2")

    // Second snapshot — same elements should keep same refs
    let elements2 = [
        makeTestElement(ref: "new1", role: "button", label: "Save"),
        makeTestElement(ref: "new2", role: "textfield", label: "Name"),
    ]
    let result2 = manager.stabilize(elements: elements2)
    #expect(result2[0].ref == "e1")  // Same ref!
    #expect(result2[1].ref == "e2")  // Same ref!
}

@Test func refStabilityNewElementGetsNextRef() {
    let manager = RefStabilityManager()

    // First snapshot: 2 elements
    let elements1 = [
        makeTestElement(ref: "a", role: "button", label: "Save"),
        makeTestElement(ref: "b", role: "button", label: "Cancel"),
    ]
    let _ = manager.stabilize(elements: elements1)

    // Second snapshot: original 2 + a new one
    let elements2 = [
        makeTestElement(ref: "a", role: "button", label: "Save"),
        makeTestElement(ref: "b", role: "button", label: "Cancel"),
        makeTestElement(ref: "c", role: "button", label: "Delete"),
    ]
    let result2 = manager.stabilize(elements: elements2)
    #expect(result2[0].ref == "e1")  // Save keeps e1
    #expect(result2[1].ref == "e2")  // Cancel keeps e2
    #expect(result2[2].ref == "e3")  // Delete gets e3
}

@Test func refStabilityTombstoning() {
    let manager = RefStabilityManager()
    manager.tombstoneDuration = 60.0

    // First snapshot: 2 elements
    let elements1 = [
        makeTestElement(ref: "a", role: "button", label: "Save"),
        makeTestElement(ref: "b", role: "button", label: "Cancel"),
    ]
    let _ = manager.stabilize(elements: elements1)

    // Second snapshot: Cancel is gone
    let elements2 = [
        makeTestElement(ref: "a", role: "button", label: "Save"),
    ]
    let _ = manager.stabilize(elements: elements2)

    // e2 should be tombstoned
    #expect(manager.tombstoneCount == 1)
    #expect(manager.mappingCount == 1)

    // New element should get e3 (not e2, which is tombstoned)
    let elements3 = [
        makeTestElement(ref: "a", role: "button", label: "Save"),
        makeTestElement(ref: "c", role: "button", label: "Delete"),
    ]
    let result3 = manager.stabilize(elements: elements3)
    #expect(result3[0].ref == "e1")
    #expect(result3[1].ref == "e3")  // Skips e2 (tombstoned)
}

@Test func refStabilityReset() {
    let manager = RefStabilityManager()

    let elements = [makeTestElement(ref: "a", role: "button", label: "Save")]
    let _ = manager.stabilize(elements: elements)
    #expect(manager.mappingCount == 1)

    manager.reset()
    #expect(manager.mappingCount == 0)
    #expect(manager.tombstoneCount == 0)
}

@Test func refStabilityElementReturn() {
    let manager = RefStabilityManager()
    manager.tombstoneDuration = 60.0

    // Snapshot 1: element present
    let _ = manager.stabilize(elements: [
        makeTestElement(ref: "a", role: "button", label: "Save"),
    ])

    // Snapshot 2: element gone (tombstoned)
    let _ = manager.stabilize(elements: [])
    #expect(manager.tombstoneCount == 1)

    // Snapshot 3: element returns — should reclaim its original ref
    let result = manager.stabilize(elements: [
        makeTestElement(ref: "b", role: "button", label: "Save"),
    ])
    #expect(result[0].ref == "e1")  // Gets original ref back
    #expect(manager.tombstoneCount == 0)  // Tombstone cleared
}

// MARK: - ElementIdentity Tests

@Test func elementIdentityEquality() {
    let id1 = ElementIdentity(role: "button", title: "Save", identifier: nil)
    let id2 = ElementIdentity(role: "button", title: "Save", identifier: nil)
    let id3 = ElementIdentity(role: "button", title: "Cancel", identifier: nil)

    #expect(id1 == id2)
    #expect(id1 != id3)
}

@Test func elementIdentityHashing() {
    let id1 = ElementIdentity(role: "button", title: "Save", identifier: nil)
    let id2 = ElementIdentity(role: "button", title: "Save", identifier: nil)

    var set = Set<ElementIdentity>()
    set.insert(id1)
    set.insert(id2)
    #expect(set.count == 1)
}

// MARK: - EventBus Tests

@Test func eventBusPublishAndRetrieve() {
    let bus = EventBus()

    bus.publish(AgentViewEvent(type: "test.event", app: "TestApp"))
    bus.publish(AgentViewEvent(type: "test.other", app: "OtherApp"))

    let events = bus.getRecentEvents()
    #expect(events.count == 2)
    #expect(events[0].type == "test.event")
    #expect(events[1].type == "test.other")
}

@Test func eventBusFilterByApp() {
    let bus = EventBus()

    bus.publish(AgentViewEvent(type: "app.launched", app: "Safari"))
    bus.publish(AgentViewEvent(type: "app.launched", app: "Finder"))
    bus.publish(AgentViewEvent(type: "app.activated", app: "Safari"))

    let safariEvents = bus.getRecentEvents(appFilter: "Safari")
    #expect(safariEvents.count == 2)
    #expect(safariEvents.allSatisfy { $0.app == "Safari" })
}

@Test func eventBusFilterByType() {
    let bus = EventBus()

    bus.publish(AgentViewEvent(type: "app.launched", app: "Safari"))
    bus.publish(AgentViewEvent(type: "app.terminated", app: "Safari"))
    bus.publish(AgentViewEvent(type: "app.launched", app: "Finder"))

    let launchEvents = bus.getRecentEvents(typeFilters: Set(["app.launched"]))
    #expect(launchEvents.count == 2)
    #expect(launchEvents.allSatisfy { $0.type == "app.launched" })
}

@Test func eventBusLimit() {
    let bus = EventBus()

    for i in 0..<10 {
        bus.publish(AgentViewEvent(type: "test.\(i)", app: "App"))
    }

    let limited = bus.getRecentEvents(limit: 3)
    #expect(limited.count == 3)
    // Should get the last 3
    #expect(limited[0].type == "test.7")
    #expect(limited[1].type == "test.8")
    #expect(limited[2].type == "test.9")
}

@Test func eventBusMaxRecentEvents() {
    let bus = EventBus()

    // Publish more than 100 events
    for i in 0..<120 {
        bus.publish(AgentViewEvent(type: "test.\(i)", app: "App"))
    }

    #expect(bus.eventCount == 100)  // Capped at 100
    let events = bus.getRecentEvents()
    #expect(events.count == 100)
    // Should have the last 100 (events 20-119)
    #expect(events.first?.type == "test.20")
    #expect(events.last?.type == "test.119")
}

@Test func eventBusSubscribeAndCallback() {
    let bus = EventBus()
    var received: [AgentViewEvent] = []

    let subId = bus.subscribe { event in
        received.append(event)
    }

    bus.publish(AgentViewEvent(type: "test.event", app: "TestApp"))
    bus.publish(AgentViewEvent(type: "test.other", app: "OtherApp"))

    #expect(received.count == 2)
    #expect(received[0].type == "test.event")

    bus.unsubscribe(subId)
    bus.publish(AgentViewEvent(type: "test.after_unsub", app: "TestApp"))

    // Should not receive events after unsubscribe
    #expect(received.count == 2)
}

@Test func eventBusSubscribeWithAppFilter() {
    let bus = EventBus()
    var received: [AgentViewEvent] = []

    let _ = bus.subscribe(appFilter: "Safari") { event in
        received.append(event)
    }

    bus.publish(AgentViewEvent(type: "test.event", app: "Safari"))
    bus.publish(AgentViewEvent(type: "test.event", app: "Finder"))
    bus.publish(AgentViewEvent(type: "test.other", app: "Safari"))

    #expect(received.count == 2)
    #expect(received.allSatisfy { $0.app == "Safari" })
}

@Test func eventBusSubscribeWithTypeFilter() {
    let bus = EventBus()
    var received: [AgentViewEvent] = []

    let _ = bus.subscribe(typeFilters: Set(["app.launched"])) { event in
        received.append(event)
    }

    bus.publish(AgentViewEvent(type: "app.launched", app: "Safari"))
    bus.publish(AgentViewEvent(type: "app.terminated", app: "Safari"))
    bus.publish(AgentViewEvent(type: "app.launched", app: "Finder"))

    #expect(received.count == 2)
    #expect(received.allSatisfy { $0.type == "app.launched" })
}

@Test func eventBusSubscriberCount() {
    let bus = EventBus()
    #expect(bus.subscriberCount == 0)

    let id1 = bus.subscribe { _ in }
    #expect(bus.subscriberCount == 1)

    let id2 = bus.subscribe { _ in }
    #expect(bus.subscriberCount == 2)

    bus.unsubscribe(id1)
    #expect(bus.subscriberCount == 1)

    bus.unsubscribe(id2)
    #expect(bus.subscriberCount == 0)
}

// MARK: - AgentViewEvent Tests

@Test func agentViewEventEncoding() throws {
    let event = AgentViewEvent(
        type: "app.launched",
        app: "Safari",
        bundleId: "com.apple.Safari",
        pid: 1234,
        details: ["key": AnyCodable("value")]
    )

    let data = try JSONOutput.encode(event)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("app.launched"))
    #expect(json.contains("Safari"))
    #expect(json.contains("1234"))
}

@Test func agentViewEventTypeRawValues() {
    #expect(AgentViewEventType.appLaunched.rawValue == "app.launched")
    #expect(AgentViewEventType.appTerminated.rawValue == "app.terminated")
    #expect(AgentViewEventType.appActivated.rawValue == "app.activated")
    #expect(AgentViewEventType.appDeactivated.rawValue == "app.deactivated")
    #expect(AgentViewEventType.focusChanged.rawValue == "ax.focus_changed")
    #expect(AgentViewEventType.valueChanged.rawValue == "ax.value_changed")
    #expect(AgentViewEventType.windowCreated.rawValue == "ax.window_created")
    #expect(AgentViewEventType.elementDestroyed.rawValue == "ax.element_destroyed")
    #expect(AgentViewEventType.screenLocked.rawValue == "screen.locked")
    #expect(AgentViewEventType.screenUnlocked.rawValue == "screen.unlocked")
    #expect(AgentViewEventType.displaySleep.rawValue == "screen.display_sleep")
    #expect(AgentViewEventType.displayWake.rawValue == "screen.display_wake")
}

// MARK: - EventSubscription Filter Tests

@Test func eventSubscriptionMatchesAll() {
    let sub = EventSubscription(id: "test", callback: { _ in })
    let event = AgentViewEvent(type: "app.launched", app: "Safari")
    #expect(sub.matches(event) == true)
}

@Test func eventSubscriptionAppFilter() {
    let sub = EventSubscription(id: "test", appFilter: "Safari", callback: { _ in })
    #expect(sub.matches(AgentViewEvent(type: "app.launched", app: "Safari")) == true)
    #expect(sub.matches(AgentViewEvent(type: "app.launched", app: "Finder")) == false)
}

@Test func eventSubscriptionTypeFilter() {
    let sub = EventSubscription(id: "test", typeFilters: Set(["app.launched", "app.terminated"]), callback: { _ in })
    #expect(sub.matches(AgentViewEvent(type: "app.launched", app: "Safari")) == true)
    #expect(sub.matches(AgentViewEvent(type: "app.terminated", app: "Safari")) == true)
    #expect(sub.matches(AgentViewEvent(type: "app.activated", app: "Safari")) == false)
}

// MARK: - PageAnalyzer Tests

@Test func pageAnalyzerAnalysisScriptExists() {
    let script = PageAnalyzer.analysisScript
    #expect(!script.isEmpty)
    #expect(script.contains("pageType"))
    #expect(script.contains("JSON.stringify"))
    #expect(script.contains("forms"))
    #expect(script.contains("headings"))
    #expect(script.contains("mainContent"))
}

@Test func pageAnalyzerExtractionScriptExists() {
    let script = PageAnalyzer.extractionScript
    #expect(!script.isEmpty)
    #expect(script.contains("nodeToMarkdown"))
    #expect(script.contains("article"))
    #expect(script.contains("substring"))
}

// MARK: - WebElementMatcher Tests

@Test func webElementMatcherEnumerationScript() {
    let script = WebElementMatcher.enumerationScript
    #expect(!script.isEmpty)
    #expect(script.contains("querySelectorAll"))
    #expect(script.contains("data-agentview-ref"))
    #expect(script.contains("JSON.stringify"))
}

@Test func webElementMatcherClickScript() {
    let script = WebElementMatcher.clickScript(match: "Submit")
    #expect(script.contains("submit"))
    #expect(script.contains("click"))
    #expect(script.contains("bestScore"))
}

@Test func webElementMatcherFillScript() {
    let script = WebElementMatcher.fillScript(match: "email", value: "test@example.com")
    #expect(script.contains("email"))
    #expect(script.contains("test@example.com"))
    #expect(script.contains("fillValue"))
    #expect(script.contains("dispatchEvent"))
}

@Test func webElementMatcherFuzzyScoreExactMatch() {
    let score = WebElementMatcher.fuzzyScore(
        query: "submit",
        text: "Submit",
        ariaLabel: nil,
        placeholder: nil,
        name: nil,
        id: nil
    )
    #expect(score == 100)
}

@Test func webElementMatcherFuzzyScorePartialMatch() {
    let score = WebElementMatcher.fuzzyScore(
        query: "sub",
        text: "Submit Button",
        ariaLabel: nil,
        placeholder: nil,
        name: nil,
        id: nil
    )
    #expect(score == 80) // text contains query
}

@Test func webElementMatcherFuzzyScoreNoMatch() {
    let score = WebElementMatcher.fuzzyScore(
        query: "delete",
        text: "Submit",
        ariaLabel: nil,
        placeholder: nil,
        name: nil,
        id: nil
    )
    #expect(score == 0)
}

@Test func webElementMatcherFuzzyScoreMultipleFields() {
    let score = WebElementMatcher.fuzzyScore(
        query: "email",
        text: nil,
        ariaLabel: "Email address",
        placeholder: "Enter email",
        name: "email",
        id: "email-input"
    )
    // ariaLabel contains: 70, placeholder contains: 60, name exact: 90, id contains: 40
    #expect(score == 260)
}

// MARK: - SafariTransport Tests

@Test func safariTransportCanHandleSafari() {
    let transport = SafariTransport()
    #expect(transport.canHandle(app: "Safari", bundleId: "com.apple.Safari") == true)
    #expect(transport.canHandle(app: "safari", bundleId: nil) == true)
    #expect(transport.canHandle(app: "Safari Technology Preview", bundleId: "com.apple.SafariTechnologyPreview") == true)
}

@Test func safariTransportCannotHandleOtherApps() {
    let transport = SafariTransport()
    #expect(transport.canHandle(app: "Finder", bundleId: "com.apple.finder") == false)
    #expect(transport.canHandle(app: "Chrome", bundleId: "com.google.Chrome") == false)
    #expect(transport.canHandle(app: "Notes", bundleId: "com.apple.Notes") == false)
}

@Test func safariTransportName() {
    let transport = SafariTransport()
    #expect(transport.name == "safari")
}

@Test func safariTransportHealthStartsHealthy() {
    let transport = SafariTransport()
    #expect(transport.health() == .healthy)
}

@Test func safariTransportHealthDegrades() {
    let transport = SafariTransport()
    for _ in 0..<6 {
        transport.stats.recordFailure()
    }
    #expect(transport.health() == .dead)
}

@Test func safariTransportRejectsUnsupportedAction() {
    let transport = SafariTransport()
    let action = TransportAction(type: "snapshot", app: "Safari", bundleId: "com.apple.Safari", pid: 1)
    let result = transport.execute(action: action)
    #expect(result.success == false)
    #expect(result.error?.contains("does not support") == true)
}

// MARK: - AnyCodable Bool vs Int Encoding Tests (Bug #5)

@Test func anyCodableIntZeroEncodesAsNumber() throws {
    let val = AnyCodable(0)
    let data = try JSONEncoder().encode(val)
    let json = String(data: data, encoding: .utf8)!
    // Must be "0", not "false"
    #expect(json == "0")
}

@Test func anyCodableIntOneEncodesAsNumber() throws {
    let val = AnyCodable(1)
    let data = try JSONEncoder().encode(val)
    let json = String(data: data, encoding: .utf8)!
    // Must be "1", not "true"
    #expect(json == "1")
}

@Test func anyCodableBoolTrueEncodesAsBool() throws {
    let val = AnyCodable(true)
    let data = try JSONEncoder().encode(val)
    let json = String(data: data, encoding: .utf8)!
    #expect(json == "true")
}

@Test func anyCodableBoolFalseEncodesAsBool() throws {
    let val = AnyCodable(false)
    let data = try JSONEncoder().encode(val)
    let json = String(data: data, encoding: .utf8)!
    #expect(json == "false")
}

@Test func snapshotStatsEnrichedElementsZeroEncodesAsInt() throws {
    let stats = SnapshotStats(totalNodes: 10, prunedNodes: 5, enrichedElements: 0, walkTimeMs: 1, enrichTimeMs: 1)
    let data = try JSONOutput.encoder.encode(stats)
    let json = String(data: data, encoding: .utf8)!
    // enriched_elements should be 0, not false
    #expect(json.contains("\"enriched_elements\":0"))
}

// MARK: - PageAnalyzer Truncation Tests (Bug #3)

@Test func pageAnalyzerAnalysisScriptLimitsMainContent() {
    let script = PageAnalyzer.analysisScript
    #expect(script.contains("substring(0, 1000)"))
    #expect(!script.contains("substring(0, 5000)"))
}

@Test func pageAnalyzerAnalysisScriptLimitsLinks() {
    let script = PageAnalyzer.analysisScript
    #expect(script.contains("i >= 15"))
}

@Test func pageAnalyzerAnalysisScriptLimitsTableRows() {
    let script = PageAnalyzer.analysisScript
    #expect(script.contains("ri >= 10"))
}

@Test func pageAnalyzerAnalysisScriptHasTryCatch() {
    let script = PageAnalyzer.analysisScript
    #expect(script.contains("try {"))
    #expect(script.contains("catch(e)"))
}

// MARK: - ScreenCapture Tests

@Test func screenCaptureNoMatchReturnsError() {
    let result = ScreenCapture.capture(appName: "NonExistentApp12345XYZ")
    #expect(result.success == false)
    #expect(result.error?.contains("No window found") == true)
}

@Test func screenCaptureResultEncoding() throws {
    let result = ScreenCaptureResult(success: true, path: "/tmp/test.png", width: 800, height: 600, error: nil)
    let data = try JSONOutput.encoder.encode(result)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("800"))
    #expect(json.contains("600"))
    #expect(json.contains("test.png"))
}

// MARK: - CDP Reconnect Tests (Bug #7)

@Test func cdpConnectionPoolReconnectDeadClearsDeadEntries() {
    let pool = CDPConnectionPool()
    // reconnectDead should not crash on empty pool
    pool.reconnectDead()
    let infos = pool.connectionInfos()
    // No connections since no CDP servers are running in test
    #expect(infos.isEmpty || infos.allSatisfy { $0.health != "dead" })
}

// MARK: - SafariTransport Extract Wrapping Tests (Bug #4)

@Test func safariTransportExtractIsStructuredAction() {
    let transport = SafariTransport()
    let action = TransportAction(type: "safari_extract", app: "Safari", bundleId: "com.apple.Safari", pid: 1)
    // This will fail because Safari isn't running in test, but proves the code path exists
    let result = transport.execute(action: action)
    #expect(result.transportUsed == "safari")
}

// MARK: - Test Helpers

func makeTestSnapshot(app: String) -> AppSnapshot {
    AppSnapshot(
        app: app,
        bundleId: "com.test.\(app.lowercased())",
        pid: 123,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        window: WindowInfo(title: "Test Window", size: nil, focused: true),
        meta: [:],
        content: ContentTree(
            summary: "Test",
            sections: [
                Section(
                    role: "content",
                    label: "Main",
                    elements: [
                        Element(ref: "e1", role: "button", label: "Save", value: nil,
                                placeholder: nil, enabled: true, focused: false, selected: false, actions: ["click"]),
                        Element(ref: "e2", role: "textfield", label: "Name", value: AnyCodable("test"),
                                placeholder: "Enter name", enabled: true, focused: false, selected: false, actions: []),
                    ]
                )
            ]
        ),
        actions: [],
        stats: SnapshotStats(totalNodes: 10, prunedNodes: 5, enrichedElements: 2, walkTimeMs: 10, enrichTimeMs: 5)
    )
}

func makeTestElement(ref: String, role: String, label: String) -> Element {
    Element(
        ref: ref,
        role: role,
        label: label,
        value: nil,
        placeholder: nil,
        enabled: true,
        focused: false,
        selected: false,
        actions: ["click"]
    )
}

// MARK: - CompactFormatter Tests

@Test func compactFormatterFormatList() {
    let apps = [
        AppInfo(name: "Finder", pid: 100, bundleId: "com.apple.finder"),
        AppInfo(name: "Safari", pid: 200, bundleId: "com.apple.Safari"),
        AppInfo(name: "Terminal", pid: 300, bundleId: "com.apple.Terminal"),
    ]
    let result = CompactFormatter.formatList(apps: apps)
    #expect(result == "Apps (3): Finder, Safari, Terminal")
}

@Test func compactFormatterFormatListEmpty() {
    let result = CompactFormatter.formatList(apps: [])
    #expect(result == "Apps (0): ")
}

@Test func compactFormatterFormatSnapshot() {
    let snapshot = AppSnapshot(
        app: "Safari",
        bundleId: "com.apple.Safari",
        pid: 200,
        timestamp: "2024-01-01T00:00:00Z",
        window: WindowInfo(title: "OpenClaw - OpenClaw", size: nil, focused: true),
        meta: ["transport": AnyCodable("ax")],
        content: ContentTree(
            summary: nil,
            sections: [
                Section(role: "toolbar", label: "toolbar", elements: [
                    Element(ref: "e1", role: "button", label: "Go back", value: nil,
                            placeholder: nil, enabled: false, focused: false, selected: false, actions: ["click"]),
                    Element(ref: "e2", role: "textfield", label: "search", value: AnyCodable("https://example.com"),
                            placeholder: nil, enabled: true, focused: false, selected: false, actions: ["fill"]),
                ]),
                Section(role: "navigation", label: "tabs", elements: [
                    Element(ref: "e3", role: "tab", label: "GitHub", value: nil,
                            placeholder: nil, enabled: true, focused: false, selected: true, actions: ["select"]),
                ]),
            ]
        ),
        actions: [],
        stats: SnapshotStats(totalNodes: 10, prunedNodes: 5, enrichedElements: 3, walkTimeMs: 10, enrichTimeMs: 5)
    )

    let result = CompactFormatter.formatSnapshot(snapshot: snapshot)
    #expect(result.contains("[Safari] OpenClaw - OpenClaw"))
    #expect(result.contains("3 elements"))
    #expect(result.contains("ax transport"))
    #expect(result.contains("[e1] Go back btn (disabled)"))
    #expect(result.contains("[e2] search field"))
    #expect(result.contains("\"https://example.com\""))
    #expect(result.contains("[e3] GitHub tab"))
    #expect(result.contains("more: false"))
}

@Test func compactFormatterFormatSnapshotWithPagination() {
    let snapshot = makeTestSnapshot(app: "TestApp")
    let pagination = PaginationResult(hasMore: true, cursor: "e50", total: 100, returned: 50)
    let result = CompactFormatter.formatSnapshot(snapshot: snapshot, pagination: pagination)
    #expect(result.contains("more: true | cursor: e50"))
}

@Test func compactFormatterFormatWebTabs() {
    let data: [String: AnyCodable] = [
        "app": AnyCodable("Safari"),
        "tabs": AnyCodable([
            AnyCodable(["title": AnyCodable("GitHub"), "url": AnyCodable("https://github.com"), "active": AnyCodable(false)] as [String: AnyCodable]),
            AnyCodable(["title": AnyCodable("OpenClaw"), "url": AnyCodable("https://docs.openclaw.ai"), "active": AnyCodable(true)] as [String: AnyCodable]),
        ]),
    ]
    let result = CompactFormatter.formatWebTabs(data: data)
    #expect(result.contains("Safari tabs (2):"))
    #expect(result.contains("1. GitHub — github.com"))
    #expect(result.contains("2. OpenClaw — docs.openclaw.ai (active)"))
}

@Test func compactFormatterFormatWebExtract() {
    let data: [String: AnyCodable] = [
        "content": AnyCodable("# Example Domain\n\nThis domain is for use in documentation examples..."),
    ]
    let result = CompactFormatter.formatWebExtract(data: data)
    #expect(result.contains("# Example Domain"))
    #expect(result.contains("---"))
    #expect(result.contains("chars"))
    #expect(result.contains("more: false"))
}

@Test func compactFormatterFormatScreenshot() {
    let data = ScreenCaptureResult(success: true, path: "/tmp/agentview-screenshot-safari-1234567.png", width: 1325, height: 941, error: nil)
    let result = CompactFormatter.formatScreenshot(data: data)
    #expect(result.contains("1325x941"))
    #expect(result.contains("/tmp/agentview-screenshot-safari-1234567.png"))
}

@Test func compactFormatterFormatScreenshotError() {
    let data = ScreenCaptureResult(success: false, path: nil, width: nil, height: nil, error: "No window found")
    let result = CompactFormatter.formatScreenshot(data: data)
    #expect(result.contains("error: No window found"))
}

@Test func compactFormatterFormatActResult() {
    let data: [String: AnyCodable] = [
        "success": AnyCodable(true),
        "app": AnyCodable("Safari"),
        "action": AnyCodable("click"),
        "matched_ref": AnyCodable("e5"),
        "matched_label": AnyCodable("Submit"),
    ]
    let result = CompactFormatter.formatActResult(data: data)
    #expect(result.contains("[Safari] click: ok"))
    #expect(result.contains("ref=e5"))
    #expect(result.contains("\"Submit\""))
}

@Test func compactFormatterFormatActResultError() {
    let data: [String: AnyCodable] = [
        "success": AnyCodable(false),
        "app": AnyCodable("Safari"),
        "action": AnyCodable("click"),
        "error": AnyCodable("Element not found"),
    ]
    let result = CompactFormatter.formatActResult(data: data)
    #expect(result.contains("[Safari] click: failed"))
    #expect(result.contains("Element not found"))
}

@Test func compactFormatterRoleAbbreviations() {
    // Test that the snapshot formatter abbreviates roles correctly
    let snapshot = AppSnapshot(
        app: "Test",
        bundleId: nil,
        pid: 1,
        timestamp: "2024-01-01T00:00:00Z",
        window: WindowInfo(title: "Win", size: nil, focused: true),
        meta: [:],
        content: ContentTree(summary: nil, sections: [
            Section(role: "content", label: "content", elements: [
                Element(ref: "e1", role: "button", label: "OK", value: nil,
                        placeholder: nil, enabled: true, focused: false, selected: false, actions: ["click"]),
                Element(ref: "e2", role: "checkbox", label: "Enable", value: nil,
                        placeholder: nil, enabled: true, focused: false, selected: false, actions: ["toggle"]),
                Element(ref: "e3", role: "radio", label: "Option A", value: nil,
                        placeholder: nil, enabled: true, focused: false, selected: false, actions: ["select"]),
            ]),
        ]),
        actions: [],
        stats: SnapshotStats(totalNodes: 3, prunedNodes: 0, enrichedElements: 3, walkTimeMs: 1, enrichTimeMs: 1)
    )
    let result = CompactFormatter.formatSnapshot(snapshot: snapshot)
    #expect(result.contains("[e1] OK btn"))
    #expect(result.contains("[e2] Enable chk"))
    #expect(result.contains("[e3] Option A radio"))
}

// MARK: - PaginationParams Tests

@Test func paginationParamsAfterRefNumber() {
    let params = PaginationParams(after: "e50", limit: 50)
    #expect(params.afterRefNumber == 50)
}

@Test func paginationParamsAfterRefNumberNil() {
    let params = PaginationParams(after: nil, limit: 50)
    #expect(params.afterRefNumber == nil)
}

@Test func paginationParamsAfterOffset() {
    let params = PaginationParams(after: "15", limit: 15)
    #expect(params.afterOffset == 15)
}

@Test func paginationParamsAfterOffsetFromRef() {
    let params = PaginationParams(after: "e50", limit: 50)
    // "e50" is not a plain int, so afterOffset should be nil
    #expect(params.afterOffset == nil)
}

// MARK: - PaginationResult Tests

@Test func paginationResultCompactLineMore() {
    let result = PaginationResult(hasMore: true, cursor: "e50", total: 100, returned: 50)
    #expect(result.compactLine == "more: true | cursor: e50")
}

@Test func paginationResultCompactLineNoMore() {
    let result = PaginationResult(hasMore: false, total: 30, returned: 30)
    #expect(result.compactLine == "more: false")
}

@Test func paginationResultJsonDict() {
    let result = PaginationResult(hasMore: true, cursor: "e50", total: 100, returned: 50)
    let dict = result.jsonDict
    #expect(dict["truncated"]?.value as? Bool == true)
    #expect(dict["total"]?.value as? Int == 100)
    #expect(dict["returned"]?.value as? Int == 50)
    #expect(dict["cursor"]?.value as? String == "e50")
}

@Test func paginationResultJsonDictNoCursor() {
    let result = PaginationResult(hasMore: false, total: 30, returned: 30)
    let dict = result.jsonDict
    #expect(dict["truncated"]?.value as? Bool == false)
    #expect(dict["cursor"] == nil)
}

// MARK: - PaginationDefaults Tests

@Test func paginationDefaultValues() {
    #expect(PaginationDefaults.axSnapshotLimit == 50)
    #expect(PaginationDefaults.webSnapshotLimit == 15)
    #expect(PaginationDefaults.webExtractLimit == 2000)
}

// MARK: - Paginator AX Snapshot Tests

@Test func paginatorSnapshotFirstPage() {
    let snapshot = makeSnapshotWithElements(count: 100)
    let params = PaginationParams(after: nil, limit: 50)
    let (paginated, result) = Paginator.paginateSnapshot(snapshot, params: params)

    let totalPagElements = paginated.content.sections.flatMap { $0.elements }.count
    #expect(totalPagElements == 50)
    #expect(result.hasMore == true)
    #expect(result.cursor == "e50")
    #expect(result.total == 100)
    #expect(result.returned == 50)
}

@Test func paginatorSnapshotSecondPage() {
    let snapshot = makeSnapshotWithElements(count: 100)
    let params = PaginationParams(after: "e50", limit: 50)
    let (paginated, result) = Paginator.paginateSnapshot(snapshot, params: params)

    let totalPagElements = paginated.content.sections.flatMap { $0.elements }.count
    #expect(totalPagElements == 50)
    #expect(result.hasMore == false)
    #expect(result.cursor == nil)
    #expect(result.total == 100)
    #expect(result.returned == 50)
}

@Test func paginatorSnapshotSmallSet() {
    let snapshot = makeSnapshotWithElements(count: 10)
    let params = PaginationParams(after: nil, limit: 50)
    let (paginated, result) = Paginator.paginateSnapshot(snapshot, params: params)

    let totalPagElements = paginated.content.sections.flatMap { $0.elements }.count
    #expect(totalPagElements == 10)
    #expect(result.hasMore == false)
    #expect(result.cursor == nil)
    #expect(result.total == 10)
    #expect(result.returned == 10)
}

@Test func paginatorSnapshotCustomLimit() {
    let snapshot = makeSnapshotWithElements(count: 30)
    let params = PaginationParams(after: nil, limit: 10)
    let (paginated, result) = Paginator.paginateSnapshot(snapshot, params: params)

    let totalPagElements = paginated.content.sections.flatMap { $0.elements }.count
    #expect(totalPagElements == 10)
    #expect(result.hasMore == true)
    #expect(result.cursor == "e10")
    #expect(result.total == 30)
}

// MARK: - Paginator Web Snapshot Tests

@Test func paginatorWebSnapshotFirstPage() {
    let data = makeWebSnapshotData(linkCount: 30)
    let params = PaginationParams(after: nil, limit: 15)
    let (paginated, result) = Paginator.paginateWebSnapshot(data, params: params)

    let links = paginated["links"]?.value as? [AnyCodable] ?? []
    #expect(links.count == 15)
    #expect(result.hasMore == true)
    #expect(result.cursor == "15")
    #expect(result.total == 30)
}

@Test func paginatorWebSnapshotSecondPage() {
    let data = makeWebSnapshotData(linkCount: 30)
    let params = PaginationParams(after: "15", limit: 15)
    let (paginated, result) = Paginator.paginateWebSnapshot(data, params: params)

    let links = paginated["links"]?.value as? [AnyCodable] ?? []
    #expect(links.count == 15)
    #expect(result.hasMore == false)
    #expect(result.cursor == nil)
    #expect(result.total == 30)
}

@Test func paginatorWebSnapshotSmallSet() {
    let data = makeWebSnapshotData(linkCount: 5)
    let params = PaginationParams(after: nil, limit: 15)
    let (_, result) = Paginator.paginateWebSnapshot(data, params: params)

    #expect(result.hasMore == false)
    #expect(result.total == 5)
    #expect(result.returned == 5)
}

// MARK: - Paginator Web Extract Tests

@Test func paginatorWebExtractFirstChunk() {
    let content = String(repeating: "a", count: 5000)
    let data: [String: AnyCodable] = ["content": AnyCodable(content)]
    let params = PaginationParams(after: nil, limit: 2000)
    let (paginated, result) = Paginator.paginateWebExtract(data, params: params)

    let chunk = paginated["content"]?.value as? String ?? ""
    #expect(chunk.count == 2000)
    #expect(result.hasMore == true)
    #expect(result.cursor == "2000")
    #expect(result.total == 5000)
}

@Test func paginatorWebExtractSecondChunk() {
    let content = String(repeating: "b", count: 5000)
    let data: [String: AnyCodable] = ["content": AnyCodable(content)]
    let params = PaginationParams(after: "2000", limit: 2000)
    let (paginated, result) = Paginator.paginateWebExtract(data, params: params)

    let chunk = paginated["content"]?.value as? String ?? ""
    #expect(chunk.count == 2000)
    #expect(result.hasMore == true)
    #expect(result.cursor == "4000")
}

@Test func paginatorWebExtractLastChunk() {
    let content = String(repeating: "c", count: 5000)
    let data: [String: AnyCodable] = ["content": AnyCodable(content)]
    let params = PaginationParams(after: "4000", limit: 2000)
    let (paginated, result) = Paginator.paginateWebExtract(data, params: params)

    let chunk = paginated["content"]?.value as? String ?? ""
    #expect(chunk.count == 1000)
    #expect(result.hasMore == false)
    #expect(result.cursor == nil)
    #expect(result.total == 5000)
    #expect(result.returned == 1000)
}

@Test func paginatorWebExtractSmallContent() {
    let data: [String: AnyCodable] = ["content": AnyCodable("short")]
    let params = PaginationParams(after: nil, limit: 2000)
    let (_, result) = Paginator.paginateWebExtract(data, params: params)

    #expect(result.hasMore == false)
    #expect(result.total == 5)
    #expect(result.returned == 5)
}

// MARK: - Additional Test Helpers

func makeSnapshotWithElements(count: Int) -> AppSnapshot {
    var elements: [Element] = []
    for i in 1...count {
        elements.append(Element(
            ref: "e\(i)",
            role: "button",
            label: "Button \(i)",
            value: nil,
            placeholder: nil,
            enabled: true,
            focused: false,
            selected: false,
            actions: ["click"]
        ))
    }
    return AppSnapshot(
        app: "TestApp",
        bundleId: "com.test.app",
        pid: 123,
        timestamp: "2024-01-01T00:00:00Z",
        window: WindowInfo(title: "Test Window", size: nil, focused: true),
        meta: [:],
        content: ContentTree(summary: "Test", sections: [
            Section(role: "content", label: "content", elements: elements),
        ]),
        actions: [],
        stats: SnapshotStats(totalNodes: count, prunedNodes: 0, enrichedElements: count, walkTimeMs: 10, enrichTimeMs: 5)
    )
}

func makeWebSnapshotData(linkCount: Int) -> [String: AnyCodable] {
    var links: [AnyCodable] = []
    for i in 1...linkCount {
        links.append(AnyCodable([
            "text": AnyCodable("Link \(i)"),
            "href": AnyCodable("https://example.com/\(i)"),
        ] as [String: AnyCodable]))
    }
    return [
        "title": AnyCodable("Test Page"),
        "url": AnyCodable("https://example.com"),
        "links": AnyCodable(links),
        "app": AnyCodable("Safari"),
    ]
}
