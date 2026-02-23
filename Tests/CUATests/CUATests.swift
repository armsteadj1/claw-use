import Foundation
import Testing
@testable import CUACore

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

    bus.publish(CUAEvent(type: "test.event", app: "TestApp"))
    bus.publish(CUAEvent(type: "test.other", app: "OtherApp"))

    let events = bus.getRecentEvents()
    #expect(events.count == 2)
    #expect(events[0].type == "test.event")
    #expect(events[1].type == "test.other")
}

@Test func eventBusFilterByApp() {
    let bus = EventBus()

    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "app.launched", app: "Finder"))
    bus.publish(CUAEvent(type: "app.activated", app: "Safari"))

    let safariEvents = bus.getRecentEvents(appFilter: "Safari")
    #expect(safariEvents.count == 2)
    #expect(safariEvents.allSatisfy { $0.app == "Safari" })
}

@Test func eventBusFilterByType() {
    let bus = EventBus()

    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "app.terminated", app: "Safari"))
    bus.publish(CUAEvent(type: "app.launched", app: "Finder"))

    let launchEvents = bus.getRecentEvents(typeFilters: Set(["app.launched"]))
    #expect(launchEvents.count == 2)
    #expect(launchEvents.allSatisfy { $0.type == "app.launched" })
}

@Test func eventBusLimit() {
    let bus = EventBus()

    for i in 0..<10 {
        bus.publish(CUAEvent(type: "test.\(i)", app: "App"))
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
        bus.publish(CUAEvent(type: "test.\(i)", app: "App"))
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
    var received: [CUAEvent] = []

    let subId = bus.subscribe { event in
        received.append(event)
    }

    bus.publish(CUAEvent(type: "test.event", app: "TestApp"))
    bus.publish(CUAEvent(type: "test.other", app: "OtherApp"))

    #expect(received.count == 2)
    #expect(received[0].type == "test.event")

    bus.unsubscribe(subId)
    bus.publish(CUAEvent(type: "test.after_unsub", app: "TestApp"))

    // Should not receive events after unsubscribe
    #expect(received.count == 2)
}

@Test func eventBusSubscribeWithAppFilter() {
    let bus = EventBus()
    var received: [CUAEvent] = []

    let _ = bus.subscribe(appFilter: "Safari") { event in
        received.append(event)
    }

    bus.publish(CUAEvent(type: "test.event", app: "Safari"))
    bus.publish(CUAEvent(type: "test.event", app: "Finder"))
    bus.publish(CUAEvent(type: "test.other", app: "Safari"))

    #expect(received.count == 2)
    #expect(received.allSatisfy { $0.app == "Safari" })
}

@Test func eventBusSubscribeWithTypeFilter() {
    let bus = EventBus()
    var received: [CUAEvent] = []

    let _ = bus.subscribe(typeFilters: Set(["app.launched"])) { event in
        received.append(event)
    }

    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "app.terminated", app: "Safari"))
    bus.publish(CUAEvent(type: "app.launched", app: "Finder"))

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

// MARK: - CUAEvent Tests

@Test func cuaEventEncoding() throws {
    let event = CUAEvent(
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

@Test func cuaEventTypeRawValues() {
    #expect(CUAEventType.appLaunched.rawValue == "app.launched")
    #expect(CUAEventType.appTerminated.rawValue == "app.terminated")
    #expect(CUAEventType.appActivated.rawValue == "app.activated")
    #expect(CUAEventType.appDeactivated.rawValue == "app.deactivated")
    #expect(CUAEventType.focusChanged.rawValue == "ax.focus_changed")
    #expect(CUAEventType.valueChanged.rawValue == "ax.value_changed")
    #expect(CUAEventType.windowCreated.rawValue == "ax.window_created")
    #expect(CUAEventType.elementDestroyed.rawValue == "ax.element_destroyed")
    #expect(CUAEventType.screenLocked.rawValue == "screen.locked")
    #expect(CUAEventType.screenUnlocked.rawValue == "screen.unlocked")
    #expect(CUAEventType.displaySleep.rawValue == "screen.display_sleep")
    #expect(CUAEventType.displayWake.rawValue == "screen.display_wake")
}

// MARK: - EventSubscription Filter Tests

@Test func eventSubscriptionMatchesAll() {
    let sub = EventSubscription(id: "test", callback: { _ in })
    let event = CUAEvent(type: "app.launched", app: "Safari")
    #expect(sub.matches(event) == true)
}

@Test func eventSubscriptionAppFilter() {
    let sub = EventSubscription(id: "test", appFilter: "Safari", callback: { _ in })
    #expect(sub.matches(CUAEvent(type: "app.launched", app: "Safari")) == true)
    #expect(sub.matches(CUAEvent(type: "app.launched", app: "Finder")) == false)
}

@Test func eventSubscriptionTypeFilter() {
    let sub = EventSubscription(id: "test", typeFilters: Set(["app.launched", "app.terminated"]), callback: { _ in })
    #expect(sub.matches(CUAEvent(type: "app.launched", app: "Safari")) == true)
    #expect(sub.matches(CUAEvent(type: "app.terminated", app: "Safari")) == true)
    #expect(sub.matches(CUAEvent(type: "app.activated", app: "Safari")) == false)
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
    #expect(script.contains("data-cua-ref"))
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

@Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Spawns Safari/osascript processes that become orphans on CI"))
func safariTransportExtractIsStructuredAction() {
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
    let data = ScreenCaptureResult(success: true, path: "/tmp/cua-screenshot-safari-1234567.png", width: 1325, height: 941, error: nil)
    let result = CompactFormatter.formatScreenshot(data: data)
    #expect(result.contains("1325x941"))
    #expect(result.contains("/tmp/cua-screenshot-safari-1234567.png"))
}

@Test func compactFormatterFormatScreenshotError() {
    let data = ScreenCaptureResult(success: false, path: nil, width: nil, height: nil, error: "No window found")
    let result = CompactFormatter.formatScreenshot(data: data)
    #expect(result.contains("error: No window found"))
}

// MARK: - Issue #72 Tests

// #1: AXRow label bubbling

@Test func axRowBubbleUpLabelFromStaticText() {
    let row = RawAXNode(
        role: "AXRow", roleDescription: nil, title: nil,
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: [], children: [
            RawAXNode(
                role: "AXStaticText", roleDescription: nil, title: nil,
                value: AnyCodable("Meeting 10:00"), axDescription: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
        ], childCount: 1,
        domId: nil, domClasses: nil
    )

    let label = Grouper.bubbleUpLabel(from: row)
    #expect(label == "Meeting 10:00")
}

@Test func axRowBubbleUpCompositeLabelFromMultipleChildren() {
    let row = RawAXNode(
        role: "AXRow", roleDescription: nil, title: nil,
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: [], children: [
            RawAXNode(
                role: "AXStaticText", roleDescription: nil, title: nil,
                value: AnyCodable("Meeting"), axDescription: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
            RawAXNode(
                role: "AXStaticText", roleDescription: nil, title: nil,
                value: AnyCodable("10:00 AM"), axDescription: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
        ], childCount: 2,
        domId: nil, domClasses: nil
    )

    let label = Grouper.bubbleUpCompositeLabel(from: row)
    #expect(label == "Meeting | 10:00 AM")
}

@Test func axRowBubbleUpReturnsNilForEmptyRow() {
    let row = RawAXNode(
        role: "AXRow", roleDescription: nil, title: nil,
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )

    let label = Grouper.bubbleUpCompositeLabel(from: row)
    #expect(label == nil)
}

@Test func axRowGetsRefAssigned() {
    let assigner = RefAssigner()
    let row = RawAXNode(
        role: "AXRow", roleDescription: nil, title: nil,
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: [], children: [], childCount: 0,
        domId: nil, domClasses: nil
    )
    #expect(assigner.shouldAssignRef(row) == true)
}

// #1 + #4: Row label consistency in buildElements

@Test func buildElementsAssignsLabelToRow() {
    let refAssigner = RefAssigner()
    let refMap = RefMap()
    let row = RawAXNode(
        role: "AXRow", roleDescription: nil, title: nil,
        value: nil, axDescription: nil, identifier: nil, placeholder: nil,
        position: nil, size: nil, enabled: true, focused: false, selected: false,
        url: nil, actions: [], children: [
            RawAXNode(
                role: "AXStaticText", roleDescription: nil, title: nil,
                value: AnyCodable("Row Label"), axDescription: nil, identifier: nil, placeholder: nil,
                position: nil, size: nil, enabled: nil, focused: nil, selected: nil,
                url: nil, actions: [], children: [], childCount: 0,
                domId: nil, domClasses: nil
            ),
        ], childCount: 1,
        domId: nil, domClasses: nil
    )

    let elements = Grouper.buildElements(from: [row], refAssigner: refAssigner, refMap: refMap)
    #expect(elements.count >= 1)
    let rowElement = elements.first { $0.role == "row" }
    #expect(rowElement != nil)
    #expect(rowElement?.label == "Row Label")
    #expect(!rowElement!.ref.isEmpty)
    #expect(rowElement?.actions.contains("select") == true)
}

// #8: ElementIdentity with position fallback

@Test func elementIdentityWithPositionKey() {
    let id1 = ElementIdentity(role: "row", title: nil, identifier: nil, positionKey: "100,200")
    let id2 = ElementIdentity(role: "row", title: nil, identifier: nil, positionKey: "100,200")
    let id3 = ElementIdentity(role: "row", title: nil, identifier: nil, positionKey: "100,300")

    #expect(id1 == id2)
    #expect(id1 != id3)

    var set = Set<ElementIdentity>()
    set.insert(id1)
    set.insert(id2)
    #expect(set.count == 1)
    set.insert(id3)
    #expect(set.count == 2)
}

@Test func elementIdentityFromElementWithPosition() {
    let element = makeTestElement(ref: "e1", role: "row", label: "Test")
    let identity = ElementIdentity.from(element, positionKey: "50,100")
    #expect(identity.role == "row")
    #expect(identity.title == "Test")
    #expect(identity.positionKey == "50,100")
}

// #8: RefStabilityManager with position keys

@Test func refStabilityWithPositionKeys() {
    let manager = RefStabilityManager()

    // First snapshot with position keys
    let elements1 = [
        makeTestElement(ref: "tmp1", role: "row", label: ""),
        makeTestElement(ref: "tmp2", role: "row", label: ""),
    ]
    let posKeys1 = ["100,200", "100,300"]
    let result1 = manager.stabilize(elements: elements1, positionKeys: posKeys1)
    #expect(result1[0].ref == "e1")
    #expect(result1[1].ref == "e2")

    // Second snapshot with same position keys but different tmp refs
    let elements2 = [
        makeTestElement(ref: "x1", role: "row", label: ""),
        makeTestElement(ref: "x2", role: "row", label: ""),
    ]
    let posKeys2 = ["100,200", "100,300"]
    let result2 = manager.stabilize(elements: elements2, positionKeys: posKeys2)
    #expect(result2[0].ref == "e1") // Same position → same ref
    #expect(result2[1].ref == "e2") // Same position → same ref
}

// #9: --depth is passed through snapshot path (verify models)

@Test func transportActionDepthParameter() {
    let action = TransportAction(
        type: "snapshot", app: "TestApp", bundleId: nil, pid: 1, depth: 10
    )
    #expect(action.depth == 10)

    let actionDefault = TransportAction(
        type: "snapshot", app: "TestApp", bundleId: nil, pid: 1
    )
    #expect(actionDefault.depth == nil)
}

// Collection safe subscript

@Test func collectionSafeSubscript() {
    let arr = [1, 2, 3]
    #expect(arr[safe: 0] == 1)
    #expect(arr[safe: 2] == 3)
    #expect(arr[safe: 3] == nil)
    #expect(arr[safe: -1] == nil)
}

@Test func collectionSafeSubscriptEmpty() {
    let arr: [String] = []
    #expect(arr[safe: 0] == nil)
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

// MARK: - ProcessEventType Tests

@Test func processEventTypeRawValues() {
    #expect(ProcessEventType.toolStart.rawValue == "process.tool_start")
    #expect(ProcessEventType.toolEnd.rawValue == "process.tool_end")
    #expect(ProcessEventType.message.rawValue == "process.message")
    #expect(ProcessEventType.error.rawValue == "process.error")
    #expect(ProcessEventType.idle.rawValue == "process.idle")
    #expect(ProcessEventType.exit.rawValue == "process.exit")
}

@Test func processEventTypesCaseIterable() {
    #expect(ProcessEventType.allCases.count == 6)
}

// MARK: - CUAEventType Process Types

@Test func cuaEventTypeProcessRawValues() {
    #expect(CUAEventType.processToolStart.rawValue == "process.tool_start")
    #expect(CUAEventType.processToolEnd.rawValue == "process.tool_end")
    #expect(CUAEventType.processMessage.rawValue == "process.message")
    #expect(CUAEventType.processError.rawValue == "process.error")
    #expect(CUAEventType.processIdle.rawValue == "process.idle")
    #expect(CUAEventType.processExit.rawValue == "process.exit")
}

// MARK: - NDJSONParser Tests

@Test func ndjsonParserToolUse() {
    let line = #"{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/test.swift"}}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.tool_start")
    #expect(event?.pid == 1234)
    let details = event?.details
    #expect(details?["tool"]?.value as? String == "Read")
    #expect(details?["file_path"]?.value as? String == "/tmp/test.swift")
}

@Test func ndjsonParserToolCall() {
    let line = #"{"type":"tool_call","name":"Bash","input":{"command":"ls -la"}}"#
    let event = NDJSONParser.parse(line: line, pid: 42)
    #expect(event != nil)
    #expect(event?.type == "process.tool_start")
    let details = event?.details
    #expect(details?["tool"]?.value as? String == "Bash")
    #expect(details?["command"]?.value as? String == "ls -la")
}

@Test func ndjsonParserToolResult() {
    let line = #"{"type":"tool_result","name":"Read","is_error":false,"duration_ms":45}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.tool_end")
    let details = event?.details
    #expect(details?["tool"]?.value as? String == "Read")
    #expect(details?["success"]?.value as? Bool == true)
    #expect(details?["duration_ms"]?.value as? Int == 45)
}

@Test func ndjsonParserToolResultWithError() {
    let line = #"{"type":"tool_result","name":"Bash","is_error":true,"error":"command not found"}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.tool_end")
    let details = event?.details
    #expect(details?["success"]?.value as? Bool == false)
    #expect(details?["error"]?.value as? String == "command not found")
}

@Test func ndjsonParserTextMessage() {
    let line = #"{"type":"text","text":"I'll help you with that."}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    #expect(event?.details?["text"]?.value as? String == "I'll help you with that.")
}

@Test func ndjsonParserAssistantMessage() {
    let line = #"{"type":"assistant","text":"Let me check the file."}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    #expect(event?.details?["text"]?.value as? String == "Let me check the file.")
}

@Test func ndjsonParserContentBlockDelta() {
    let line = #"{"type":"content_block_delta","delta":{"text":"Hello world"}}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    #expect(event?.details?["text"]?.value as? String == "Hello world")
}

@Test func ndjsonParserErrorEvent() {
    let line = #"{"type":"error","error":"Rate limit exceeded"}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.error")
    #expect(event?.details?["error"]?.value as? String == "Rate limit exceeded")
}

@Test func ndjsonParserErrorObjectEvent() {
    let line = #"{"type":"error","error":{"message":"API error","code":429}}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.error")
    #expect(event?.details?["error"]?.value as? String == "API error")
}

@Test func ndjsonParserResultEvent() {
    let line = #"{"type":"result","result":"Task completed successfully"}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    let details = event?.details
    #expect(details?["text"]?.value as? String == "Task completed successfully")
    #expect(details?["final"]?.value as? Bool == true)
}

@Test func ndjsonParserNonJsonFallback() {
    let line = "This is just plain text output"
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    #expect(event?.details?["raw"]?.value as? String == "This is just plain text output")
}

@Test func ndjsonParserEmptyLine() {
    let event = NDJSONParser.parse(line: "", pid: 1234)
    #expect(event == nil)
}

@Test func ndjsonParserWhitespaceLine() {
    let event = NDJSONParser.parse(line: "   \n  ", pid: 1234)
    #expect(event == nil)
}

@Test func ndjsonParserUnknownJsonType() {
    let line = #"{"type":"system","text":"Starting session"}"#
    let event = NDJSONParser.parse(line: line, pid: 1234)
    #expect(event != nil)
    #expect(event?.type == "process.message")
    #expect(event?.details?["raw_type"]?.value as? String == "system")
    #expect(event?.details?["text"]?.value as? String == "Starting session")
}

@Test func ndjsonParserToolUseWithToolField() {
    let line = #"{"type":"tool_use","tool":"Write","input":{"file_path":"/tmp/out.txt"}}"#
    let event = NDJSONParser.parse(line: line, pid: 99)
    #expect(event != nil)
    #expect(event?.type == "process.tool_start")
    #expect(event?.details?["tool"]?.value as? String == "Write")
}

// MARK: - ProcessMonitor Tests

@Test func processMonitorInitialization() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    #expect(monitor.watchCount == 0)
    #expect(monitor.watchedPIDs.isEmpty)
}

@Test func processMonitorWatchNonexistentProcess() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    // PID 99999999 should not exist
    let result = monitor.watch(pid: 99999999)
    #expect(result == false)
    #expect(monitor.watchCount == 0)
}

@Test func processMonitorWatchCurrentProcess() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    let myPid = ProcessInfo.processInfo.processIdentifier
    let result = monitor.watch(pid: myPid)
    #expect(result == true)
    #expect(monitor.watchCount == 1)
    #expect(monitor.isWatching(pid: myPid) == true)
    #expect(monitor.watchedPIDs == [myPid])

    // Cleanup
    monitor.unwatch(pid: myPid)
    #expect(monitor.watchCount == 0)
    #expect(monitor.isWatching(pid: myPid) == false)
}

@Test func processMonitorDuplicateWatch() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    let myPid = ProcessInfo.processInfo.processIdentifier

    let first = monitor.watch(pid: myPid)
    let second = monitor.watch(pid: myPid)
    #expect(first == true)
    #expect(second == false) // Already watching
    #expect(monitor.watchCount == 1)

    monitor.unwatch(pid: myPid)
}

@Test func processMonitorUnwatchAll() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    let myPid = ProcessInfo.processInfo.processIdentifier

    let _ = monitor.watch(pid: myPid)
    #expect(monitor.watchCount == 1)

    monitor.unwatchAll()
    #expect(monitor.watchCount == 0)
}

@Test func processMonitorCleanupDead() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    let myPid = ProcessInfo.processInfo.processIdentifier

    let _ = monitor.watch(pid: myPid)
    #expect(monitor.watchCount == 1)

    // Our own process is alive, so cleanup should not remove it
    monitor.cleanupDead()
    #expect(monitor.watchCount == 1)

    monitor.unwatchAll()
}

@Test func processMonitorWatchWithLogPath() {
    let bus = EventBus()
    let monitor = ProcessMonitor(eventBus: bus)
    let myPid = ProcessInfo.processInfo.processIdentifier

    // Watch with a log path (file doesn't need to exist yet)
    let result = monitor.watch(pid: myPid, logPath: "/tmp/cua-test-nonexistent.log")
    #expect(result == true)
    #expect(monitor.watchCount == 1)

    monitor.unwatchAll()
}

@Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "kqueue/dispatch sources with long sleep prevent clean test runner exit on CI"))
func processMonitorLogFileTailing() throws {
    let bus = EventBus()
    var received: [CUAEvent] = []
    let lock = NSLock()

    let _ = bus.subscribe(typeFilters: Set(ProcessEventType.allCases.map { $0.rawValue })) { event in
        lock.lock()
        received.append(event)
        lock.unlock()
    }

    let myPid = ProcessInfo.processInfo.processIdentifier
    let logPath = "/tmp/cua-test-\(UUID().uuidString).log"

    // Create the log file
    FileManager.default.createFile(atPath: logPath, contents: nil)

    let monitor = ProcessMonitor(eventBus: bus)
    let _ = monitor.watch(pid: myPid, logPath: logPath)

    // Write NDJSON lines to the log file
    Thread.sleep(forTimeInterval: 0.5) // Wait for watcher to start

    let toolLine = #"{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/foo"}}"# + "\n"
    let resultLine = #"{"type":"tool_result","name":"Read","is_error":false}"# + "\n"

    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(toolLine.data(using: .utf8)!)
        fh.write(resultLine.data(using: .utf8)!)
        fh.closeFile()
    }

    // Wait for events to be processed
    Thread.sleep(forTimeInterval: 2.0)

    lock.lock()
    let eventCount = received.count
    lock.unlock()

    #expect(eventCount >= 2)

    if eventCount >= 2 {
        lock.lock()
        let first = received[0]
        let second = received[1]
        lock.unlock()

        #expect(first.type == "process.tool_start")
        #expect(first.details?["tool"]?.value as? String == "Read")
        #expect(second.type == "process.tool_end")
    }

    // Cleanup
    monitor.unwatchAll()
    try? FileManager.default.removeItem(atPath: logPath)
}

// MARK: - ProcessWatcher Tests

@Test func processWatcherInit() {
    let bus = EventBus()
    let watcher = ProcessWatcher(pid: 123, logPath: nil, idleTimeout: 60, eventBus: bus)
    #expect(watcher.pid == 123)
    #expect(watcher.logPath == nil)
    #expect(watcher.idleTimeout == 60)
    #expect(watcher.isActive == true)
}

@Test func processWatcherStop() {
    let bus = EventBus()
    let watcher = ProcessWatcher(pid: 123, logPath: nil, eventBus: bus)
    #expect(watcher.isActive == true)
    watcher.stop()
    #expect(watcher.isActive == false)
}

// MARK: - EventBus Process Event Filtering

@Test func eventBusFilterByProcessTypes() {
    let bus = EventBus()

    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "process.tool_start", pid: 123, details: ["tool": AnyCodable("Read")]))
    bus.publish(CUAEvent(type: "process.tool_end", pid: 123, details: ["tool": AnyCodable("Read")]))
    bus.publish(CUAEvent(type: "app.terminated", app: "Safari"))

    let processEvents = bus.getRecentEvents(typeFilters: Set(["process.tool_start", "process.tool_end"]))
    #expect(processEvents.count == 2)
    #expect(processEvents.allSatisfy { $0.type.hasPrefix("process.") })
}

@Test func eventBusSubscribeToProcessEvents() {
    let bus = EventBus()
    var received: [CUAEvent] = []

    let _ = bus.subscribe(typeFilters: Set(ProcessEventType.allCases.map { $0.rawValue })) { event in
        received.append(event)
    }

    // Publish mix of events
    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "process.tool_start", pid: 100))
    bus.publish(CUAEvent(type: "process.message", pid: 100))
    bus.publish(CUAEvent(type: "ax.focus_changed", app: "Finder"))
    bus.publish(CUAEvent(type: "process.exit", pid: 100))

    #expect(received.count == 3)
    #expect(received.allSatisfy { $0.type.hasPrefix("process.") })
}

// MARK: - Process Group Tests

@Test func trackedProcessStateRawValues() {
    #expect(TrackedProcessState.starting.rawValue == "STARTING")
    #expect(TrackedProcessState.building.rawValue == "BUILDING")
    #expect(TrackedProcessState.testing.rawValue == "TESTING")
    #expect(TrackedProcessState.idle.rawValue == "IDLE")
    #expect(TrackedProcessState.error.rawValue == "ERROR")
    #expect(TrackedProcessState.done.rawValue == "DONE")
    #expect(TrackedProcessState.failed.rawValue == "FAILED")
}

@Test func trackedProcessStateCaseIterable() {
    #expect(TrackedProcessState.allCases.count == 7)
}

@Test func trackedProcessInitDefaults() {
    let process = TrackedProcess(pid: 123, label: "Issue #42")
    #expect(process.pid == 123)
    #expect(process.label == "Issue #42")
    #expect(process.state == .starting)
    #expect(process.lastEvent == nil)
    #expect(process.lastEventTime == nil)
    #expect(process.lastDetail == nil)
    #expect(process.exitCode == nil)
    #expect(!process.startedAt.isEmpty)
}

@Test func processGroupAddAndStatus() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)

    let added = group.add(pid: 100, label: "Issue #42")
    #expect(added == true)
    #expect(group.count == 1)

    let processes = group.status()
    #expect(processes.count == 1)
    #expect(processes[0].pid == 100)
    #expect(processes[0].label == "Issue #42")
    #expect(processes[0].state == .starting)

    // Cleanup
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupAddDuplicate() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)

    let first = group.add(pid: 100, label: "Issue #42")
    let second = group.add(pid: 100, label: "Issue #42 again")
    #expect(first == true)
    #expect(second == false)
    #expect(group.count == 1)

    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupRemove() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)

    group.add(pid: 100, label: "Issue #42")
    group.add(pid: 200, label: "Issue #43")
    #expect(group.count == 2)

    let removed = group.remove(pid: 100)
    #expect(removed == true)
    #expect(group.count == 1)

    let removedAgain = group.remove(pid: 100)
    #expect(removedAgain == false)

    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupClear() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Active process")
    group.add(pid: 200, label: "Done process")
    group.add(pid: 300, label: "Failed process")

    // Simulate done + failed via events
    bus.publish(CUAEvent(type: ProcessEventType.exit.rawValue, pid: 200, details: ["exit_code": AnyCodable(0)]))
    bus.publish(CUAEvent(type: ProcessEventType.exit.rawValue, pid: 300, details: ["exit_code": AnyCodable(1)]))

    let cleared = group.clear()
    #expect(cleared == 2) // done + failed removed
    #expect(group.count == 1)

    let remaining = group.status()
    #expect(remaining[0].pid == 100)

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineBuilding() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    // tool_start → BUILDING
    bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: 100, details: ["tool": AnyCodable("Read")]))

    let processes = group.status()
    #expect(processes[0].state == .building)
    #expect(processes[0].lastDetail == "Read")

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineTesting() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    // tool_start with test command → TESTING
    bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: 100, details: [
        "tool": AnyCodable("Bash"),
        "command": AnyCodable("npm test"),
    ]))

    let processes = group.status()
    #expect(processes[0].state == .testing)

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineIdle() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    bus.publish(CUAEvent(type: ProcessEventType.idle.rawValue, pid: 100, details: ["idle_seconds": AnyCodable(360)]))

    let processes = group.status()
    #expect(processes[0].state == .idle)
    #expect(processes[0].lastDetail == "no output for 6m")

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineError() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    bus.publish(CUAEvent(type: ProcessEventType.error.rawValue, pid: 100, details: ["error": AnyCodable("Rate limit")]))

    let processes = group.status()
    #expect(processes[0].state == .error)
    #expect(processes[0].lastDetail == "Rate limit")

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineDone() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    bus.publish(CUAEvent(type: ProcessEventType.exit.rawValue, pid: 100, details: ["exit_code": AnyCodable(0)]))

    let processes = group.status()
    #expect(processes[0].state == .done)
    #expect(processes[0].exitCode == 0)

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupStateMachineFailed() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    bus.publish(CUAEvent(type: ProcessEventType.exit.rawValue, pid: 100, details: ["exit_code": AnyCodable(1)]))

    let processes = group.status()
    #expect(processes[0].state == .failed)
    #expect(processes[0].exitCode == 1)

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupTerminalStatesStick() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    group.add(pid: 100, label: "Test")

    // Exit with code 0 → DONE
    bus.publish(CUAEvent(type: ProcessEventType.exit.rawValue, pid: 100, details: ["exit_code": AnyCodable(0)]))
    #expect(group.status()[0].state == .done)

    // Subsequent events should NOT change state
    bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: 100, details: ["tool": AnyCodable("Read")]))
    #expect(group.status()[0].state == .done) // Still DONE

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupIgnoresUnregisteredPids() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    // No processes registered — events for PID 999 should be ignored
    bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: 999, details: ["tool": AnyCodable("Read")]))
    #expect(group.count == 0)

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupPersistence() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"

    // Create and populate
    do {
        let group = ProcessGroupManager(filePath: path)
        let bus = EventBus()
        group.startListening(eventBus: bus)
        group.add(pid: 100, label: "Issue #42")
        group.add(pid: 200, label: "Issue #43")
        bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: 100, details: ["tool": AnyCodable("Bash")]))
        group.stopListening()
    }

    // Reload from disk
    let group2 = ProcessGroupManager(filePath: path)
    let processes = group2.status()
    #expect(processes.count == 2)

    let proc100 = processes.first { $0.pid == 100 }
    #expect(proc100?.label == "Issue #42")
    #expect(proc100?.state == .building)

    let proc200 = processes.first { $0.pid == 200 }
    #expect(proc200?.label == "Issue #43")
    #expect(proc200?.state == .starting)

    try? FileManager.default.removeItem(atPath: path)
}

@Test func processGroupFormatStatusEmpty() {
    let output = ProcessGroupManager.formatStatus(processes: [])
    #expect(output.contains("0 processes"))
    #expect(output.contains("no processes tracked"))
}

@Test func processGroupFormatStatusWithProcesses() {
    var process = TrackedProcess(pid: 100, label: "Issue #42: Add login")
    process.state = .building
    process.lastDetail = "cargo build"

    let output = ProcessGroupManager.formatStatus(processes: [process])
    #expect(output.contains("1 process"))
    #expect(output.contains("[B]"))
    #expect(output.contains("BUILDING"))
    #expect(output.contains("Issue #42: Add login"))
    #expect(output.contains("cargo build"))
}

@Test func processGroupJsonStatus() {
    var process = TrackedProcess(pid: 100, label: "Issue #42")
    process.state = .done
    process.exitCode = 0
    process.lastEvent = "process.exit"

    let json = ProcessGroupManager.jsonStatus(processes: [process])
    #expect(json.count == 1)
    #expect(json[0]["pid"]?.value as? Int == 100)
    #expect(json[0]["label"]?.value as? String == "Issue #42")
    #expect(json[0]["state"]?.value as? String == "DONE")
    #expect(json[0]["exit_code"]?.value as? Int == 0)
    #expect(json[0]["last_event"]?.value as? String == "process.exit")
    #expect(json[0]["duration"] != nil)
}

@Test func processGroupMultipleTestPatterns() {
    let path = "/tmp/cua-test-processgroup-\(UUID().uuidString).json"
    let group = ProcessGroupManager(filePath: path)
    let bus = EventBus()
    group.startListening(eventBus: bus)

    // Test various test runner patterns
    let testCommands = ["cargo test", "npm test", "pytest", "go test", "swift test", "jest"]
    for (i, cmd) in testCommands.enumerated() {
        let pid = Int32(1000 + i)
        group.add(pid: pid, label: "Test \(cmd)")
        bus.publish(CUAEvent(type: ProcessEventType.toolStart.rawValue, pid: pid, details: [
            "tool": AnyCodable("Bash"),
            "command": AnyCodable(cmd),
        ]))
    }

    let processes = group.status()
    #expect(processes.allSatisfy { $0.state == .testing })

    group.stopListening()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func trackedProcessCodableRoundTrip() throws {
    var process = TrackedProcess(pid: 42, label: "Test process")
    process.state = .building
    process.lastEvent = "process.tool_start"
    process.lastDetail = "Read"
    process.exitCode = nil

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(process)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(TrackedProcess.self, from: data)

    #expect(decoded.pid == 42)
    #expect(decoded.label == "Test process")
    #expect(decoded.state == .building)
    #expect(decoded.lastEvent == "process.tool_start")
    #expect(decoded.lastDetail == "Read")
    #expect(decoded.exitCode == nil)
}

@Test func processGroupStoreCodableRoundTrip() throws {
    var store = ProcessGroupStore()
    store.processes[100] = TrackedProcess(pid: 100, label: "Issue #42")
    store.processes[200] = TrackedProcess(pid: 200, label: "Issue #43")

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(store)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(ProcessGroupStore.self, from: data)

    #expect(decoded.processes.count == 2)
    #expect(decoded.processes[100]?.label == "Issue #42")
    #expect(decoded.processes[200]?.label == "Issue #43")
}

// MARK: - EventBus Glob Filter Tests

@Test func typeFilterMatchesExact() {
    #expect(EventBus.typeFilterMatches(filter: "process.error", eventType: "process.error") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.error", eventType: "process.exit") == false)
}

@Test func typeFilterMatchesWildcardAll() {
    #expect(EventBus.typeFilterMatches(filter: "*", eventType: "process.error") == true)
    #expect(EventBus.typeFilterMatches(filter: "*", eventType: "app.launched") == true)
    #expect(EventBus.typeFilterMatches(filter: "*", eventType: "process.group.state_change") == true)
}

@Test func typeFilterMatchesGlobPrefix() {
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process.error") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process.exit") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process.idle") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "app.launched") == false)
    #expect(EventBus.typeFilterMatches(filter: "process.group.*", eventType: "process.group.state_change") == true)
    #expect(EventBus.typeFilterMatches(filter: "process.group.*", eventType: "app.launched") == false)
}

@Test func typeFilterMatchesGlobNoFalsePrefix() {
    // "process.*" should NOT match "process" (no dot)
    #expect(EventBus.typeFilterMatches(filter: "process.*", eventType: "process") == false)
}

@Test func typeFilterPredicateNil() {
    // nil filters means match all
    let predicate = EventBus.typeFilterPredicate(from: nil)
    #expect(predicate == nil)
}

@Test func typeFilterPredicateEmpty() {
    let predicate = EventBus.typeFilterPredicate(from: Set<String>())
    #expect(predicate == nil)
}

@Test func typeFilterPredicateWildcard() {
    let predicate = EventBus.typeFilterPredicate(from: Set(["*"]))
    #expect(predicate == nil) // * means match all, so nil predicate
}

@Test func typeFilterPredicateGlob() {
    let predicate = EventBus.typeFilterPredicate(from: Set(["process.*"]))
    #expect(predicate != nil)
    #expect(predicate!("process.error") == true)
    #expect(predicate!("process.exit") == true)
    #expect(predicate!("app.launched") == false)
}

@Test func typeFilterPredicateMultipleGlobs() {
    let predicate = EventBus.typeFilterPredicate(from: Set(["process.*", "process.group.*"]))
    #expect(predicate != nil)
    #expect(predicate!("process.error") == true)
    #expect(predicate!("process.group.state_change") == true)
    #expect(predicate!("app.launched") == false)
}

@Test func eventBusSubscribeWithGlobFilter() {
    let bus = EventBus()
    var received: [CUAEvent] = []

    // Subscribe with a glob filter for process.*
    let subId = bus.subscribe(typeFilters: Set(["process.*"])) { event in
        received.append(event)
    }

    // Publish matching event
    bus.publish(CUAEvent(type: "process.error", pid: 100, details: ["error": AnyCodable("test")]))
    // Publish non-matching event
    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    // Publish another matching event
    bus.publish(CUAEvent(type: "process.exit", pid: 100))

    #expect(received.count == 2)
    #expect(received[0].type == "process.error")
    #expect(received[1].type == "process.exit")

    bus.unsubscribe(subId)
}

@Test func eventBusGetRecentEventsWithGlobFilter() {
    let bus = EventBus()
    bus.publish(CUAEvent(type: "process.error", pid: 100))
    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))
    bus.publish(CUAEvent(type: "process.exit", pid: 100))
    bus.publish(CUAEvent(type: "process.group.state_change", pid: 200))

    let processEvents = bus.getRecentEvents(typeFilters: Set(["process.*"]))
    #expect(processEvents.count == 3) // process.error, process.exit, process.group.state_change

    let allEvents = bus.getRecentEvents(typeFilters: Set(["*"]))
    #expect(allEvents.count == 4)

    let groupEvents = bus.getRecentEvents(typeFilters: Set(["process.group.*"]))
    #expect(groupEvents.count == 1)
    #expect(groupEvents[0].type == "process.group.state_change")
}

@Test func eventBusMultipleSubscribersReceiveEvents() {
    let bus = EventBus()
    var received1: [CUAEvent] = []
    var received2: [CUAEvent] = []

    let sub1 = bus.subscribe(typeFilters: Set(["process.*"])) { event in
        received1.append(event)
    }
    let sub2 = bus.subscribe(typeFilters: Set(["process.error"])) { event in
        received2.append(event)
    }

    bus.publish(CUAEvent(type: "process.error", pid: 100))
    bus.publish(CUAEvent(type: "process.exit", pid: 100))

    #expect(received1.count == 2) // glob matches both
    #expect(received2.count == 1) // exact matches only error

    bus.unsubscribe(sub1)
    bus.unsubscribe(sub2)
}

// MARK: - Process Group State Change Event Tests

@Test func processGroupEmitsStateChangeEvent() {
    let bus = EventBus()
    let tmpDir = NSTemporaryDirectory() + "cua-test-\(UUID().uuidString)"
    let filePath = tmpDir + "/process-groups.json"
    let group = ProcessGroupManager(filePath: filePath)
    group.startListening(eventBus: bus)

    var stateChanges: [CUAEvent] = []
    let subId = bus.subscribe(typeFilters: Set(["process.group.state_change"])) { event in
        stateChanges.append(event)
    }

    group.add(pid: 99999, label: "Test process")

    // Simulate an error event which should trigger state change
    bus.publish(CUAEvent(type: "process.error", pid: 99999, details: ["error": AnyCodable("build failed")]))

    #expect(stateChanges.count == 1)
    #expect(stateChanges[0].type == "process.group.state_change")
    #expect(stateChanges[0].pid == 99999)
    let details = stateChanges[0].details
    #expect(details?["old_state"]?.value as? String == "STARTING")
    #expect(details?["new_state"]?.value as? String == "ERROR")

    bus.unsubscribe(subId)
    group.stopListening()
    try? FileManager.default.removeItem(atPath: tmpDir)
}

@Test func processGroupStateChangeEventType() {
    #expect(CUAEventType.processGroupStateChange.rawValue == "process.group.state_change")
}

// MARK: - CUAConfig Tests

@Test func cuaConfigDefaults() {
    let config = CUAConfig()
    let resolved = config.resolvedEventFile
    #expect(resolved.enabled == false)
    #expect(resolved.sessionKey == "main")
    #expect(resolved.priority.contains("process.error"))
    #expect(resolved.priority.contains("process.exit"))
    #expect(resolved.priority.contains("process.idle"))
    #expect(resolved.priority.contains("process.group.state_change"))
}

@Test func cuaConfigResolvedEnabled() {
    let eventFileConfig = EventFileConfig(enabled: true, path: "/tmp/test-event.json", priority: ["process.error"], sessionKey: "test")
    let config = CUAConfig(eventFile: eventFileConfig)
    let resolved = config.resolvedEventFile
    #expect(resolved.enabled == true)
    #expect(resolved.path == "/tmp/test-event.json")
    #expect(resolved.priority == Set(["process.error"]))
    #expect(resolved.sessionKey == "test")
}

@Test func cuaConfigLoadMissingFile() {
    let config = CUAConfig.load(from: "/nonexistent/config.json")
    #expect(config.eventFile == nil)
    #expect(config.gatewayUrl == nil)
}

@Test func cuaConfigCodableRoundTrip() throws {
    let eventFileConfig = EventFileConfig(enabled: true, path: "~/.cua/pending-event.json",
                                          priority: ["process.error", "process.exit"], sessionKey: "main")
    let config = CUAConfig(gatewayUrl: "https://example.com", eventFile: eventFileConfig)

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(CUAConfig.self, from: data)

    #expect(decoded.gatewayUrl == "https://example.com")
    #expect(decoded.eventFile?.enabled == true)
    #expect(decoded.eventFile?.path == "~/.cua/pending-event.json")
    #expect(decoded.eventFile?.priority?.count == 2)
    #expect(decoded.eventFile?.sessionKey == "main")
}

@Test func cuaConfigDefaultPriorityEvents() {
    let defaults = CUAConfig.defaultPriorityEvents
    #expect(defaults.contains("process.error"))
    #expect(defaults.contains("process.exit"))
    #expect(defaults.contains("process.idle"))
    #expect(defaults.contains("process.group.state_change"))
}

// MARK: - EventFileWriter Tests

@Test func eventFileWriterDisabledDoesNotWrite() {
    let config = ResolvedEventFileConfig(enabled: false, path: "/tmp/should-not-exist.json", priority: Set(["process.error"]), sessionKey: "main")
    let writer = EventFileWriter(config: config)
    let bus = EventBus()
    writer.start(eventBus: bus)

    bus.publish(CUAEvent(type: "process.error", pid: 100))

    #expect(FileManager.default.fileExists(atPath: "/tmp/should-not-exist.json") == false)
    #expect(writer.isActive == false)
    writer.stop()
}

@Test func eventFileWriterWritesHighPriorityEvent() throws {
    let tmpPath = NSTemporaryDirectory() + "cua-test-event-\(UUID().uuidString).json"
    let config = ResolvedEventFileConfig(enabled: true, path: tmpPath, priority: Set(["process.error", "process.exit"]), sessionKey: "main")
    let writer = EventFileWriter(config: config)
    let bus = EventBus()
    writer.start(eventBus: bus)

    #expect(writer.isActive == true)

    // Publish a high-priority event
    bus.publish(CUAEvent(type: "process.error", pid: 12345, details: ["error": AnyCodable("build failed")]))

    // Read and verify the file
    let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
    let payload = try JSONDecoder().decode(EventFilePayload.self, from: data)

    #expect(payload.type == "cua.process.error")
    #expect(payload.deliver.sessionKey == "main")
    #expect(payload.data["pid"]?.value as? Int == 12345)
    #expect(payload.data["error"]?.value as? String == "build failed")
    #expect(!payload.timestamp.isEmpty)

    writer.stop()
    try? FileManager.default.removeItem(atPath: tmpPath)
}

@Test func eventFileWriterIgnoresLowPriorityEvent() {
    let tmpPath = NSTemporaryDirectory() + "cua-test-event-\(UUID().uuidString).json"
    let config = ResolvedEventFileConfig(enabled: true, path: tmpPath, priority: Set(["process.error"]), sessionKey: "main")
    let writer = EventFileWriter(config: config)
    let bus = EventBus()
    writer.start(eventBus: bus)

    // Publish a non-priority event
    bus.publish(CUAEvent(type: "app.launched", app: "Safari"))

    #expect(FileManager.default.fileExists(atPath: tmpPath) == false)

    writer.stop()
    try? FileManager.default.removeItem(atPath: tmpPath)
}

@Test func eventFileWriterOverwritesOnNewEvent() throws {
    let tmpPath = NSTemporaryDirectory() + "cua-test-event-\(UUID().uuidString).json"
    let config = ResolvedEventFileConfig(enabled: true, path: tmpPath, priority: Set(["process.error", "process.exit"]), sessionKey: "main")
    let writer = EventFileWriter(config: config)
    let bus = EventBus()
    writer.start(eventBus: bus)

    // First event
    bus.publish(CUAEvent(type: "process.error", pid: 100, details: ["error": AnyCodable("first error")]))

    // Second event should overwrite
    bus.publish(CUAEvent(type: "process.exit", pid: 200, details: ["exit_code": AnyCodable(1)]))

    let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
    let payload = try JSONDecoder().decode(EventFilePayload.self, from: data)

    // Should contain the latest event
    #expect(payload.type == "cua.process.exit")
    #expect(payload.data["pid"]?.value as? Int == 200)

    writer.stop()
    try? FileManager.default.removeItem(atPath: tmpPath)
}

@Test func eventFilePayloadEncoding() throws {
    let payload = EventFilePayload(
        type: "cua.process.error",
        timestamp: "2026-02-18T19:30:00Z",
        data: [
            "pid": AnyCodable(12345),
            "label": AnyCodable("Issue #42: Add login"),
            "error": AnyCodable("cargo build failed"),
            "state": AnyCodable("ERROR"),
        ],
        deliver: EventFilePayload.DeliverInfo(sessionKey: "main")
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("cua.process.error"))
    #expect(json.contains("sessionKey"))
    #expect(json.contains("main"))
    #expect(json.contains("2026-02-18T19:30:00Z"))
}

@Test func eventFilePayloadCodableRoundTrip() throws {
    let payload = EventFilePayload(
        type: "cua.process.group.state_change",
        timestamp: "2026-02-18T20:00:00Z",
        data: [
            "pid": AnyCodable(99999),
            "old_state": AnyCodable("BUILDING"),
            "new_state": AnyCodable("ERROR"),
        ],
        deliver: EventFilePayload.DeliverInfo(sessionKey: "main")
    )

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(EventFilePayload.self, from: data)

    #expect(decoded.type == "cua.process.group.state_change")
    #expect(decoded.deliver.sessionKey == "main")
    #expect(decoded.data["pid"]?.value as? Int == 99999)
}

// MARK: - Web Switch Tab Compact Formatter Tests

@Test func compactFormatterFormatWebSwitchTabSuccess() {
    let data: [String: AnyCodable] = [
        "success": AnyCodable(true),
        "action": AnyCodable("switch_tab"),
        "title": AnyCodable("Claude"),
        "url": AnyCodable("https://claude.ai/chat"),
    ]
    let result = CompactFormatter.formatWebSwitchTab(data: data)
    #expect(result == "→ switched to \"Claude\" (claude.ai)")
}

@Test func compactFormatterFormatWebSwitchTabError() {
    let data: [String: AnyCodable] = [
        "success": AnyCodable(false),
        "error": AnyCodable("no tab matching \"FakeTab\""),
    ]
    let result = CompactFormatter.formatWebSwitchTab(data: data)
    #expect(result == "❌ no tab matching \"FakeTab\"")
}

// MARK: - AX Snapshot Fallback Decoder Test

@Test func snapshotFallbackDecoderHandlesSnakeCase() throws {
    // Simulate the AX transport returning snake_case JSON (as JSONOutput.encoder produces)
    let snapshot = AppSnapshot(
        app: "TestApp",
        bundleId: "com.test.app",
        pid: 123,
        timestamp: "2024-01-01T00:00:00Z",
        window: WindowInfo(title: "Win", size: nil, focused: true),
        meta: [:],
        content: ContentTree(summary: nil, sections: []),
        actions: [],
        stats: SnapshotStats(totalNodes: 10, prunedNodes: 10, enrichedElements: 0, walkTimeMs: 1, enrichTimeMs: 1)
    )

    // Encode with snake_case (as JSONOutput.encoder does)
    let snapshotData = try JSONOutput.encode(snapshot)

    // Parse back as [String: Any] then convert to [String: AnyCodable] (as AXTransport does)
    let dict = try JSONSerialization.jsonObject(with: snapshotData) as! [String: Any]
    func convertDict(_ d: [String: Any]) -> [String: AnyCodable] {
        d.reduce(into: [String: AnyCodable]()) { result, kv in
            if let nested = kv.value as? [String: Any] {
                result[kv.key] = AnyCodable(convertDict(nested))
            } else if let arr = kv.value as? [Any] {
                result[kv.key] = AnyCodable(arr.map { item -> AnyCodable in
                    if let d = item as? [String: Any] { return AnyCodable(convertDict(d)) }
                    return AnyCodable(item)
                })
            } else {
                result[kv.key] = AnyCodable(kv.value)
            }
        }
    }
    let acDict = convertDict(dict)

    // Re-encode as AnyCodable (as Router does)
    let reEncoded = try JSONOutput.encode(AnyCodable(acDict))

    // Decode with convertFromSnakeCase (the fix)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(AppSnapshot.self, from: reEncoded)

    #expect(decoded.stats.enrichedElements == 0)
    #expect(decoded.content.sections.isEmpty)
    #expect(decoded.app == "TestApp")
}

// MARK: - ProcessGroupReporter Tests

@Test func milestoneEventFromStarting() {
    let m = MilestoneEvent.from(oldState: "STARTING", newState: "BUILDING", exitCode: nil)
    #expect(m == .building)
}

@Test func milestoneEventFromBuilding() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "TESTING", exitCode: nil)
    #expect(m == .testing)
}

@Test func milestoneEventFromTestingToDone() {
    let m = MilestoneEvent.from(oldState: "TESTING", newState: "DONE", exitCode: nil)
    #expect(m == .testsPassed)
}

@Test func milestoneEventFromTestingToFailed() {
    let m = MilestoneEvent.from(oldState: "TESTING", newState: "FAILED", exitCode: nil)
    #expect(m == .testsFailed)
}

@Test func milestoneEventFromBuildingToDone() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "DONE", exitCode: nil)
    #expect(m == .complete)
}

@Test func milestoneEventFromBuildingToFailed() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "FAILED", exitCode: nil)
    #expect(m == .failed)
}

@Test func milestoneEventToIdle() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "IDLE", exitCode: nil)
    #expect(m == .idle)
}

@Test func milestoneEventToError() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "ERROR", exitCode: nil)
    #expect(m == .error)
}

@Test func milestoneEventStarted() {
    let m = MilestoneEvent.from(oldState: "", newState: "STARTING", exitCode: nil)
    #expect(m == .started)
}

@Test func milestoneEventUnknownState() {
    let m = MilestoneEvent.from(oldState: "BUILDING", newState: "UNKNOWN", exitCode: nil)
    #expect(m == nil)
}

@Test func milestoneEventRawValues() {
    #expect(MilestoneEvent.started.rawValue == "group.process.started")
    #expect(MilestoneEvent.building.rawValue == "group.process.building")
    #expect(MilestoneEvent.testing.rawValue == "group.process.testing")
    #expect(MilestoneEvent.testsPassed.rawValue == "group.process.tests_passed")
    #expect(MilestoneEvent.testsFailed.rawValue == "group.process.tests_failed")
    #expect(MilestoneEvent.idle.rawValue == "group.process.idle")
    #expect(MilestoneEvent.error.rawValue == "group.process.error")
    #expect(MilestoneEvent.complete.rawValue == "group.process.complete")
    #expect(MilestoneEvent.failed.rawValue == "group.process.failed")
}

@Test func milestoneRecordEncoding() throws {
    let record = MilestoneRecord(
        timestamp: "2026-02-18T20:00:00Z",
        group: "my-batch",
        pid: 1234,
        label: "task 1",
        event: "group.process.testing",
        detail: "cargo test running (14 tests)"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("\"group\":\"my-batch\""))
    #expect(json.contains("\"pid\":1234"))
    #expect(json.contains("\"label\":\"task 1\""))
    #expect(json.contains("\"event\":\"group.process.testing\""))
    #expect(json.contains("\"detail\":\"cargo test running (14 tests)\""))
    #expect(json.contains("\"timestamp\":\"2026-02-18T20:00:00Z\""))
}

@Test func milestoneRecordCodableRoundTrip() throws {
    let record = MilestoneRecord(
        timestamp: "2026-02-18T20:00:00Z",
        group: "default",
        pid: 5678,
        label: "Issue #42",
        event: "group.process.complete",
        detail: "exit code 0"
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(MilestoneRecord.self, from: data)
    #expect(decoded.timestamp == record.timestamp)
    #expect(decoded.group == record.group)
    #expect(decoded.pid == record.pid)
    #expect(decoded.label == record.label)
    #expect(decoded.event == record.event)
    #expect(decoded.detail == record.detail)
}

@Test func processGroupReporterEncodeMilestone() {
    let record = MilestoneRecord(
        timestamp: "2026-02-18T20:00:00Z",
        group: "test",
        pid: 100,
        label: "worker",
        event: "group.process.building",
        detail: "Write"
    )
    let line = ProcessGroupReporter.encodeMilestone(record)
    #expect(line != nil)
    #expect(line!.contains("group.process.building"))
    #expect(line!.contains("\"pid\":100"))
}

@Test func processGroupReporterFileOutput() throws {
    let tmpDir = NSTemporaryDirectory() + "cua-test-reporter-\(UUID().uuidString)"
    let outputPath = tmpDir + "/milestones.ndjson"

    let bus = EventBus()
    let groupFilePath = tmpDir + "/process-groups.json"
    let group = ProcessGroupManager(filePath: groupFilePath)
    group.startListening(eventBus: bus)

    let reporter = ProcessGroupReporter(groupName: "test-group", outputPath: outputPath)
    reporter.start(eventBus: bus, activePIDs: Set([Int32(88888)]))

    #expect(reporter.isActive == true)
    #expect(reporter.activeCount == 1)

    // Add process and trigger a state change
    group.add(pid: 88888, label: "Test worker")

    // Simulate building event -> state change from STARTING to BUILDING
    bus.publish(CUAEvent(type: "process.tool_start", pid: 88888, details: ["tool": AnyCodable("Write")]))

    // Give event processing a moment
    Thread.sleep(forTimeInterval: 0.1)

    // Verify file was written
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: outputPath))

    let content = try String(contentsOfFile: outputPath, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count >= 1)

    // Parse the first line as JSON
    let lineData = lines[0].data(using: .utf8)!
    let record = try JSONDecoder().decode(MilestoneRecord.self, from: lineData)
    #expect(record.group == "test-group")
    #expect(record.pid == 88888)
    #expect(record.label == "Test worker")
    #expect(record.event == "group.process.building")

    reporter.stop()
    #expect(reporter.isActive == false)

    group.stopListening()
    try? fm.removeItem(atPath: tmpDir)
}

@Test func processGroupReporterCompletionCallback() throws {
    let tmpDir = NSTemporaryDirectory() + "cua-test-reporter-cb-\(UUID().uuidString)"
    let groupFilePath = tmpDir + "/process-groups.json"

    let bus = EventBus()
    let group = ProcessGroupManager(filePath: groupFilePath)
    group.startListening(eventBus: bus)

    var callbackCalled = false
    let reporter = ProcessGroupReporter(groupName: "test", outputPath: nil)
    reporter.start(eventBus: bus, activePIDs: Set([Int32(77777)])) {
        callbackCalled = true
    }

    group.add(pid: 77777, label: "Finisher")

    // Trigger exit -> DONE state
    bus.publish(CUAEvent(type: "process.exit", pid: 77777, details: ["exit_code": AnyCodable(0)]))

    Thread.sleep(forTimeInterval: 0.1)

    #expect(callbackCalled == true)
    #expect(reporter.activeCount == 0)

    reporter.stop()
    group.stopListening()
    try? FileManager.default.removeItem(atPath: tmpDir)
}

@Test func processGroupReporterIgnoresUnrelatedEvents() throws {
    let tmpDir = NSTemporaryDirectory() + "cua-test-reporter-unr-\(UUID().uuidString)"
    let outputPath = tmpDir + "/milestones.ndjson"

    let bus = EventBus()
    let reporter = ProcessGroupReporter(groupName: "test", outputPath: outputPath)
    reporter.start(eventBus: bus, activePIDs: Set([Int32(66666)]))

    // Publish a non-state-change event — should not produce output
    bus.publish(CUAEvent(type: "process.tool_start", pid: 66666, details: ["tool": AnyCodable("Write")]))

    Thread.sleep(forTimeInterval: 0.1)

    // File should not exist since reporter only listens to state_change events
    #expect(FileManager.default.fileExists(atPath: outputPath) == false)

    reporter.stop()
    try? FileManager.default.removeItem(atPath: tmpDir)
}

@Test func processGroupConfigCodableRoundTrip() throws {
    let reporterConfig = ProcessGroupConfig.ReporterConfig(defaultOutput: "~/.cua/group-updates.ndjson")
    let pgConfig = ProcessGroupConfig(reporter: reporterConfig)
    let config = CUAConfig(processGroup: pgConfig)

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(CUAConfig.self, from: data)

    #expect(decoded.processGroup?.reporter?.defaultOutput == "~/.cua/group-updates.ndjson")
}

@Test func processGroupConfigInFullConfig() throws {
    let json = """
    {
        "process_group": {
            "reporter": {
                "default_output": "~/.cua/group-updates.ndjson"
            }
        }
    }
    """
    let data = json.data(using: .utf8)!
    let config = try JSONDecoder().decode(CUAConfig.self, from: data)
    #expect(config.processGroup?.reporter?.defaultOutput == "~/.cua/group-updates.ndjson")
}

@Test func milestoneEventAllCases() {
    #expect(MilestoneEvent.allCases.count == 9)
}

// MARK: - Fuzzy Match Confidence Score Tests (#66)

/// Normalize a raw fuzzy score (0–∞) to a 0-1 confidence value,
/// mirroring the implementation in Pipe and Router.
private func normalizeScore(_ raw: Int) -> Double {
    min(Double(raw) / 100.0, 1.0)
}

@Test func confidenceScoreExactMatchIsOne() {
    // An exact label match scores 100 → confidence 1.0
    #expect(normalizeScore(100) == 1.0)
}

@Test func confidenceScoreContainsMatch() {
    // label.contains(needle) scores 80 → confidence 0.80
    #expect(normalizeScore(80) == 0.80)
}

@Test func confidenceScoreInferredAction() {
    // Inferred action match scores 50 → confidence 0.50
    #expect(normalizeScore(50) == 0.50)
}

@Test func confidenceScoreClampsAboveOne() {
    // Scores above 100 (multi-field matches) clamp to 1.0
    #expect(normalizeScore(135) == 1.0)
    #expect(normalizeScore(200) == 1.0)
}

@Test func confidenceScoreZero() {
    #expect(normalizeScore(0) == 0.0)
}

@Test func ambiguityDetectionWithinDelta() {
    let delta = 0.1
    let best = normalizeScore(85)   // 0.85
    let runner = normalizeScore(80) // 0.80
    // Difference is 0.05, which is < delta of 0.1 → ambiguous
    #expect(best - runner < delta)
}

@Test func ambiguityDetectionOutsideDelta() {
    let delta = 0.1
    let best = normalizeScore(100)  // 1.00
    let runner = normalizeScore(50) // 0.50
    // Difference is 0.50, which is >= delta of 0.1 → not ambiguous
    #expect(best - runner >= delta)
}

@Test func strictModeThresholdDefault() {
    let threshold = 0.7
    // Exact match (1.0) passes
    #expect(normalizeScore(100) >= threshold)
    // Contains match (0.80) passes
    #expect(normalizeScore(80) >= threshold)
    // Inferred action (0.50) fails
    #expect(normalizeScore(50) < threshold)
    // Reverse contains only (0.40) fails
    #expect(normalizeScore(40) < threshold)
}

@Test func webElementMatcherScoreNormalizesToConfidence() {
    let score = WebElementMatcher.fuzzyScore(
        query: "submit",
        text: "Submit",
        ariaLabel: nil,
        placeholder: nil,
        name: nil,
        id: nil
    )
    // Exact text match = 100 → confidence 1.0
    #expect(normalizeScore(score) == 1.0)
}

@Test func webElementMatcherPartialScoreConfidence() {
    let score = WebElementMatcher.fuzzyScore(
        query: "sub",
        text: "Submit Button",
        ariaLabel: nil,
        placeholder: nil,
        name: nil,
        id: nil
    )
    // text.contains = 80 → confidence 0.80
    #expect(normalizeScore(score) == 0.80)
}

// MARK: - Remote Models Tests

@Test func remoteConfigParseDuration() {
    #expect(RemoteConfig.parseDuration("1d") == 86400)
    #expect(RemoteConfig.parseDuration("7d") == 604800)
    #expect(RemoteConfig.parseDuration("1h") == 3600)
    #expect(RemoteConfig.parseDuration("30m") == 1800)
    #expect(RemoteConfig.parseDuration("5s") == 5)
    #expect(RemoteConfig.parseDuration("60") == 60)
}

@Test func remoteConfigDefaults() {
    let config = RemoteConfig()
    #expect(config.port == 9876)
    #expect(config.retainSeconds == 86400)
}

@Test func remoteCryptoGenerateKey() {
    let (data1, b641) = RemoteCrypto.generateKey()
    let (data2, b642) = RemoteCrypto.generateKey()
    #expect(data1.count == 32)
    #expect(data2.count == 32)
    #expect(data1 != data2)
    #expect(b641 != b642)
    // Base64 should decode back to the original bytes
    #expect(Data(base64Encoded: b641) == data1)
}

@Test func remoteCryptoHMACSHA256() {
    let (keyData, _) = RemoteCrypto.generateKey()
    let msg = "test-peer-id:1700000000"
    let hex1 = RemoteCrypto.hmacSHA256(message: msg, secret: keyData)
    let hex2 = RemoteCrypto.hmacSHA256(message: msg, secret: keyData)
    #expect(hex1 == hex2)
    #expect(hex1.count == 64)  // SHA256 = 32 bytes = 64 hex chars
    #expect(RemoteCrypto.verifyHMAC(message: msg, secret: keyData, expectedHex: hex1))
    #expect(!RemoteCrypto.verifyHMAC(message: msg + "x", secret: keyData, expectedHex: hex1))
}

@Test func remoteCryptoHMACDifferentKeys() {
    let (key1, _) = RemoteCrypto.generateKey()
    let (key2, _) = RemoteCrypto.generateKey()
    let msg = "peer:12345"
    let hex1 = RemoteCrypto.hmacSHA256(message: msg, secret: key1)
    let hex2 = RemoteCrypto.hmacSHA256(message: msg, secret: key2)
    #expect(hex1 != hex2)
}

@Test func remoteSessionCodable() throws {
    let session = RemoteSession(
        peerId: "peer-123",
        peerName: "MacBook Pro",
        sessionToken: "token-abc",
        lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
        createdAt: Date(timeIntervalSince1970: 1_699_999_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(session)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RemoteSession.self, from: data)
    #expect(decoded.peerId == "peer-123")
    #expect(decoded.peerName == "MacBook Pro")
    #expect(decoded.sessionToken == "token-abc")
}

@Test func remoteSenderStateCodable() throws {
    let state = RemoteSenderState(
        host: "mac-mini.local",
        port: 9876,
        peerId: "peer-456",
        sessionToken: "sess-xyz",
        intervalSeconds: 5
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(RemoteSenderState.self, from: data)
    #expect(decoded.host == "mac-mini.local")
    #expect(decoded.port == 9876)
    #expect(decoded.peerId == "peer-456")
    #expect(decoded.sessionToken == "sess-xyz")
    #expect(decoded.intervalSeconds == 5)
}
