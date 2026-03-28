import CryptoKit
import Foundation
import Testing
@testable import CUACore
@testable import CUADaemonLib

// MARK: - Server / HTTP Helpers (scoped to this file)

private func makeServerConfig(
    secret: String = "test-secret",
    tokenTtl: Int = 3600,
    blockedApps: [String] = []
) -> RemoteServerConfig {
    RemoteServerConfig(enabled: true, port: 0, bind: "0.0.0.0", secret: secret,
                       tokenTtl: tokenTtl, blockedApps: blockedApps)
}

private func startRemoteServer(config: RemoteServerConfig) async throws -> (RemoteServer, UInt16) {
    let server = RemoteServer(config: config)
    return try await withCheckedThrowingContinuation { continuation in
        server.onReady = { port in continuation.resume(returning: (server, port)) }
        do { try server.start() } catch { continuation.resume(throwing: error) }
    }
}

private func httpRequest(
    method: String, url: URL,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (Int, [String: Any]) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 10
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let body = body {
        req.httpBody = body
        if req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as! HTTPURLResponse).statusCode
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (status, json)
}

private func computeSig(secret: String, challenge: String, ts: Int) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let msg = Data("\(challenge):\(ts)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: msg, using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
}

private func fullAuth(port: UInt16, secret: String) async throws -> (Int, [String: Any]) {
    let hsURL = URL(string: "http://127.0.0.1:\(port)/handshake")!
    let (hsStatus, hsBody) = try await httpRequest(method: "GET", url: hsURL)
    guard hsStatus == 200, let challenge = hsBody["challenge"] as? String else {
        return (hsStatus, hsBody)
    }
    let ts = Int(Date().timeIntervalSince1970)
    let sig = computeSig(secret: secret, challenge: challenge, ts: ts)
    let authBody = try JSONSerialization.data(withJSONObject: ["sig": sig, "challenge": challenge, "ts": ts])
    let authURL = URL(string: "http://127.0.0.1:\(port)/auth")!
    return try await httpRequest(method: "POST", url: authURL, body: authBody)
}

// MARK: - Helpers

private func makeStreamConfig(
    enabled: Bool = true,
    pushTo: String = "http://127.0.0.1:4567",
    secret: String = "test-stream-secret",
    flushInterval: Int = 5,
    appLevels: [String: Int] = ["Safari": 2, "Terminal": 2, "Slack": 1, "*": 0],
    blockedApps: [String] = ["1Password", "Signal"]
) -> StreamConfig {
    StreamConfig(
        enabled: enabled,
        pushTo: pushTo,
        secret: secret,
        flushInterval: flushInterval,
        appLevels: appLevels,
        blockedApps: blockedApps
    )
}

private func makeFilter(_ config: StreamConfig? = nil) -> EventStreamFilter {
    EventStreamFilter(config: config ?? makeStreamConfig())
}

private func makeEvent(
    type: String,
    app: String? = nil,
    pid: Int32? = nil,
    details: [String: AnyCodable]? = nil
) -> CUAEvent {
    CUAEvent(type: type, app: app, pid: pid, details: details)
}

// MARK: - EventStreamFilter.levelFor

@Test func levelForExplicitApp() {
    let filter = makeFilter()
    #expect(filter.levelFor(app: "Safari") == 2)
    #expect(filter.levelFor(app: "Slack") == 1)
}

@Test func levelForWildcardFallback() {
    let filter = makeFilter()
    // "Finder" is not in appLevels, should fall back to "*" = 0
    #expect(filter.levelFor(app: "Finder") == 0)
    #expect(filter.levelFor(app: "TextEdit") == 0)
}

@Test func levelForDefaultWhenNoWildcard() {
    let config = StreamConfig(
        enabled: true, pushTo: "", secret: "",
        flushInterval: 5,
        appLevels: ["Safari": 2],   // no "*" key
        blockedApps: []
    )
    let filter = EventStreamFilter(config: config)
    #expect(filter.levelFor(app: "Finder") == 0)   // defaultLevel = appLevels["*"] ?? 0
}

// MARK: - EventStreamFilter.isBlocked

@Test func isBlockedCaseInsensitive() {
    let filter = makeFilter()
    #expect(filter.isBlocked(app: "1Password"))
    #expect(filter.isBlocked(app: "1password"))
    #expect(filter.isBlocked(app: "1PASSWORD"))
    #expect(filter.isBlocked(app: "signal"))
    #expect(!filter.isBlocked(app: "Safari"))
}

@Test func isBlockedReturnsFalseForUnlisted() {
    let filter = makeFilter()
    #expect(!filter.isBlocked(app: "Terminal"))
    #expect(!filter.isBlocked(app: "Finder"))
}

// MARK: - EventStreamFilter.filter

@Test func filterLevel0AppActivatedPassesThrough() {
    let filter = makeFilter()
    let event = makeEvent(type: "app.activated", app: "Finder", pid: 1234)
    let result = filter.filter(event)
    #expect(result != nil)
    #expect(result?.type == "app.activated")
    #expect(result?.app == "Finder")
    #expect(result?.level == 0)
}

@Test func filterLevel0ScreenEventPassesEvenWithNoApp() {
    let filter = makeFilter()
    let event = makeEvent(type: "screen.locked")
    let result = filter.filter(event)
    #expect(result != nil)
    #expect(result?.type == "screen.locked")
    #expect(result?.level == 0)
    #expect(result?.app == nil)
}

@Test func filterBlockedAppReturnsNil() {
    let filter = makeFilter()
    // "1Password" is in blockedApps — nothing emitted at any level
    let event = makeEvent(type: "app.activated", app: "1Password", pid: 999)
    let result = filter.filter(event)
    #expect(result == nil)
}

@Test func filterLevel2AppDeactivatedWithLevel0Config() {
    // Finder has level 0 — app.deactivated requires level >= 1, should return nil
    let filter = makeFilter()
    let event = makeEvent(type: "app.deactivated", app: "Finder", pid: 1234)
    let result = filter.filter(event)
    #expect(result == nil)
}

@Test func filterLevel1AppDeactivatedWithLevel1Config() {
    // Slack has level 1 — app.deactivated should emit
    let filter = makeFilter()
    let event = makeEvent(type: "app.deactivated", app: "Slack", pid: 5678)
    let result = filter.filter(event)
    #expect(result != nil)
    #expect(result?.level == 1)
}

@Test func filterAXWindowCreatedMapsToWindowFocused() {
    let filter = makeFilter()
    let event = makeEvent(
        type: "ax.window_created",
        app: "Safari",
        details: ["title": AnyCodable("My Document")]
    )
    let result = filter.filter(event)
    #expect(result != nil)
    #expect(result?.type == "window.focused")
    #expect(result?.title == "My Document")
    #expect(result?.level == 1)
}

@Test func filterAXWindowCreatedSkippedForLevel0App() {
    let filter = makeFilter()
    // Finder is level 0 — ax.window_created requires level >= 1
    let event = makeEvent(type: "ax.window_created", app: "Finder")
    let result = filter.filter(event)
    #expect(result == nil)
}

@Test func filterProcessEventsSkipped() {
    let filter = makeFilter()
    let processTypes = ["process.tool_start", "process.message", "process.error", "process.exit"]
    for t in processTypes {
        let event = makeEvent(type: t, app: "Terminal")
        #expect(filter.filter(event) == nil, "Expected \(t) to be skipped")
    }
}

@Test func filterAXFocusChangedSkipped() {
    let filter = makeFilter()
    let event = makeEvent(type: "ax.focus_changed", app: "Safari")
    #expect(filter.filter(event) == nil)
}

// MARK: - EventStreamFilter.scrubSnapshot (password field scrubbing)

@Test func scrubSnapshotOmitsSecureTextFieldSummary() {
    let secureElement = Element(
        ref: "r1", role: "AXSecureTextField", label: "Password",
        value: AnyCodable("hunter2"), placeholder: nil,
        enabled: true, focused: false, selected: false, actions: []
    )
    let normalElement = Element(
        ref: "r2", role: "AXTextField", label: "Username",
        value: AnyCodable("alice"), placeholder: nil,
        enabled: true, focused: false, selected: false, actions: []
    )
    let snapshot = AppSnapshot(
        app: "MyApp", bundleId: nil, pid: 1234, timestamp: "2026-02-24T09:47:00Z",
        window: WindowInfo(title: "Login", size: nil, focused: true),
        meta: [:],
        content: ContentTree(summary: nil, sections: [
            Section(role: "form", label: nil, elements: [secureElement, normalElement])
        ]),
        actions: [],
        stats: SnapshotStats(totalNodes: 2, prunedNodes: 0, enrichedElements: 2, walkTimeMs: 1, enrichTimeMs: 1)
    )

    let filter = makeFilter()
    let summary = filter.scrubSnapshot(snapshot, level: 2)

    // Summary must mention password fields are omitted
    #expect(summary.contains("[password fields omitted]"))
    // Summary must NOT contain the actual password value
    #expect(!summary.contains("hunter2"))
}

@Test func scrubSnapshotNoSecureFields() {
    let element = Element(
        ref: "r1", role: "AXTextField", label: "Search",
        value: AnyCodable("hello"), placeholder: nil,
        enabled: true, focused: false, selected: false, actions: []
    )
    let snapshot = AppSnapshot(
        app: "Safari", bundleId: nil, pid: 1234, timestamp: "2026-02-24T09:47:00Z",
        window: WindowInfo(title: "Google", size: nil, focused: true),
        meta: [:],
        content: ContentTree(summary: nil, sections: [
            Section(role: "main", label: nil, elements: [element])
        ]),
        actions: [],
        stats: SnapshotStats(totalNodes: 1, prunedNodes: 0, enrichedElements: 1, walkTimeMs: 1, enrichTimeMs: 1)
    )

    let filter = makeFilter()
    let summary = filter.scrubSnapshot(snapshot, level: 2)

    #expect(!summary.contains("[password fields omitted]"))
    #expect(summary.contains("Google"))
    #expect(summary.contains("1 elements"))
}

// MARK: - StreamConfig default level

@Test func streamConfigDefaultLevelFallback() {
    let config = StreamConfig(
        enabled: true, pushTo: "", secret: "",
        flushInterval: 5,
        appLevels: ["Safari": 2, "*": 1],
        blockedApps: []
    )
    #expect(config.defaultLevel == 1)

    let config2 = StreamConfig(
        enabled: true, pushTo: "", secret: "",
        flushInterval: 5,
        appLevels: ["Safari": 2],   // no wildcard
        blockedApps: []
    )
    #expect(config2.defaultLevel == 0)
}

// MARK: - NDJSON roundtrip

@Test func streamEventNDJSONRoundtrip() throws {
    let events: [StreamEvent] = [
        StreamEvent(ts: "2026-02-24T09:47:00Z", type: "app.activated", app: "Safari", pid: 1234, level: 0),
        StreamEvent(ts: "2026-02-24T09:47:01Z", type: "screen.locked", level: 0),
        StreamEvent(ts: "2026-02-24T09:47:02Z", type: "window.focused", app: "Terminal",
                    pid: 5678, level: 1, title: "bash"),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for original in events {
        let data = try encoder.encode(original)
        let roundtripped = try decoder.decode(StreamEvent.self, from: data)
        #expect(roundtripped.ts == original.ts)
        #expect(roundtripped.type == original.type)
        #expect(roundtripped.app == original.app)
        #expect(roundtripped.pid == original.pid)
        #expect(roundtripped.level == original.level)
        #expect(roundtripped.title == original.title)
    }
}

@Test func streamEventNDJSONOmitsNilFields() throws {
    let event = StreamEvent(ts: "2026-02-24T09:00:00Z", type: "screen.locked", level: 0)
    let data = try JSONEncoder().encode(event)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let dict = try #require(json)

    // app, pid, domain, title, summary, element_count, page_type, duration are nil → omitted
    #expect(dict["app"] == nil)
    #expect(dict["pid"] == nil)
    #expect(dict["title"] == nil)
    #expect(dict["ts"] as? String == "2026-02-24T09:00:00Z")
    #expect(dict["type"] as? String == "screen.locked")
    #expect(dict["level"] as? Int == 0)
}

// MARK: - /stream/push endpoint

@Test func streamPushRequiresAuth() async throws {
    let (server, port) = try await startRemoteServer(config: makeServerConfig())
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(port)/stream/push")!
    let (status, _) = try await httpRequest(method: "POST", url: url, body: Data())
    #expect(status == 401)
}

@Test func streamPushAcceptsNDJSONWithValidToken() async throws {
    let secret = "stream-test-secret"
    let (server, port) = try await startRemoteServer(config: makeServerConfig(secret: secret))
    defer { server.stop() }

    // Authenticate
    let (authStatus, authBody) = try await fullAuth(port: port, secret: secret)
    #expect(authStatus == 200)
    let token = try #require(authBody["token"] as? String)

    // Build NDJSON payload
    let events: [StreamEvent] = [
        StreamEvent(ts: "2026-02-24T09:47:00Z", type: "app.activated", app: "Safari", pid: 1234, level: 0),
        StreamEvent(ts: "2026-02-24T09:47:01Z", type: "screen.locked", level: 0),
    ]
    let encoder = JSONEncoder()
    let lines = events.compactMap { e -> String? in
        guard let d = try? encoder.encode(e) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    let body = Data(lines.joined(separator: "\n").utf8)

    let url = URL(string: "http://127.0.0.1:\(port)/stream/push")!
    let (status, resp) = try await httpRequest(
        method: "POST", url: url,
        headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/x-ndjson"],
        body: body
    )

    #expect(status == 200)
    #expect(resp["received"] as? Int == 2)
}
