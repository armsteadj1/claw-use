import Foundation
import Testing
@testable import CUACore
@testable import CUADaemonLib

// MARK: - Shared Helpers

/// Start a RemoteHTTPServer on an ephemeral port and return (server, port).
private func startServer(store: RemoteStore) async throws -> (RemoteHTTPServer, UInt16) {
    let server = RemoteHTTPServer(store: store)
    return try await withCheckedThrowingContinuation { continuation in
        server.onReady = { port in
            continuation.resume(returning: (server, port))
        }
        do {
            try server.start(port: 0)
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

/// Make an HTTP request and return (statusCode, body as [String: Any]).
private func httpRequest(
    method: String,
    url: URL,
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

/// Build a minimal AppSnapshot for testing.
private func makeSnapshot(
    app: String = "TestApp",
    bundleId: String? = "com.example.testapp",
    elements: [Element] = []
) -> AppSnapshot {
    AppSnapshot(
        app: app,
        bundleId: bundleId,
        pid: 1234,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        window: WindowInfo(title: "Test Window", size: nil, focused: true),
        meta: [:],
        content: ContentTree(
            summary: "Test",
            sections: [Section(role: "AXWindow", label: "Main", elements: elements)]
        ),
        actions: [],
        stats: SnapshotStats(
            totalNodes: 1, prunedNodes: 0,
            enrichedElements: elements.count,
            walkTimeMs: 0, enrichTimeMs: 0
        )
    )
}

/// Build a RemoteSnapshotRecord ready to POST to /remote-ingest.
private func makeRecord(
    peerId: String,
    snapshot: AppSnapshot
) -> Data {
    let record = RemoteSnapshotRecord(
        timestamp: Date(),
        peerId: peerId,
        peerName: "TestMachine",
        snapshot: snapshot,
        appList: [snapshot.app]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try! encoder.encode(record)
}

/// Perform the full handshake and return the session token.
private func handshake(
    peerId: String,
    secretBase64: String,
    port: UInt16,
    peerName: String = "TestPeer",
    timestampOverride: Int? = nil
) async throws -> (Int, [String: Any]) {
    let secretData = Data(base64Encoded: secretBase64)!
    let timestamp = timestampOverride ?? Int(Date().timeIntervalSince1970)
    let message = "\(peerId):\(timestamp)"
    let hmac = RemoteCrypto.hmacSHA256(message: message, secret: secretData)

    let body: [String: Any] = [
        "peer_id": peerId,
        "peer_name": peerName,
        "timestamp": timestamp,
        "hmac": hmac,
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let url = URL(string: "http://127.0.0.1:\(port)/remote-handshake")!
    return try await httpRequest(method: "POST", url: url, body: bodyData)
}

/// Returns a temp directory unique to this test run.
private func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "remote-e2e-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Happy Path

@Test func remoteHappyPathPing() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let url = URL(string: "http://127.0.0.1:\(port)/remote-ping")!
    let (status, json) = try await httpRequest(method: "GET", url: url)

    #expect(status == 200)
    #expect(json["ok"] as? Bool == true)
}

@Test func remoteHappyPathFullFlow() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    // 1. Register pairing key
    let (peerId, secretBase64) = server.registerPairingKey()

    // 2. Handshake
    let (hsStatus, hsJSON) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(hsStatus == 200)
    let sessionToken = try #require(hsJSON["session_token"] as? String)
    #expect(!sessionToken.isEmpty)
    #expect(hsJSON["peer_id"] as? String == peerId)

    // 3. Ingest a snapshot
    let snapshot = makeSnapshot()
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)
    let ingestURL = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (ingestStatus, ingestJSON) = try await httpRequest(
        method: "POST",
        url: ingestURL,
        headers: ["Authorization": "Bearer \(sessionToken)"],
        body: recordData
    )
    #expect(ingestStatus == 200)
    #expect(ingestJSON["ok"] as? Bool == true)

    // 4. Verify the snapshot was persisted
    let stored = store.latestSnapshot(forPeer: peerId)
    #expect(stored != nil)
    #expect(stored?.snapshot.app == "TestApp")
}

// MARK: - Auth Error Cases

@Test func remoteHandshakeBadHMAC() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, _) = server.registerPairingKey()
    let timestamp = Int(Date().timeIntervalSince1970)
    let body: [String: Any] = [
        "peer_id": peerId,
        "peer_name": "BadActor",
        "timestamp": timestamp,
        "hmac": String(repeating: "a", count: 64),  // wrong HMAC
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let url = URL(string: "http://127.0.0.1:\(port)/remote-handshake")!
    let (status, _) = try await httpRequest(method: "POST", url: url, body: bodyData)

    #expect(status == 401)
}

@Test func remoteHandshakeExpiredTimestamp() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    // Timestamp 10 minutes in the past (> 5-minute window)
    let oldTimestamp = Int(Date().timeIntervalSince1970) - 601
    let (status, _) = try await handshake(
        peerId: peerId, secretBase64: secretBase64, port: port,
        timestampOverride: oldTimestamp
    )

    #expect(status == 401)
}

@Test func remoteHandshakeReplayRejected() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()

    // First handshake succeeds
    let (status1, _) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(status1 == 200)

    // Second attempt with the same (now-consumed) key must fail
    // We need a fresh key data copy but simulate re-use: the key was consumed,
    // so registering the same peerId again would require a new key.
    // The server consumed pendingKeys[peerId] on the first success, so a second
    // attempt with the same request body hits "unknown peer or key expired" → 401.
    let (status2, _) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(status2 == 401)
}

@Test func remoteIngestMissingToken() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    // Complete handshake first
    let (peerId, secretBase64) = server.registerPairingKey()
    let (hsStatus, _) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(hsStatus == 200)

    let snapshot = makeSnapshot()
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)
    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!

    // No Authorization header at all
    let (status, _) = try await httpRequest(method: "POST", url: url, body: recordData)
    #expect(status == 401)
}

@Test func remoteIngestWrongToken() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    let (hsStatus, _) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(hsStatus == 200)

    let snapshot = makeSnapshot()
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)
    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, _) = try await httpRequest(
        method: "POST",
        url: url,
        headers: ["Authorization": "Bearer totally-wrong-token"],
        body: recordData
    )
    #expect(status == 401)
}

@Test func remoteIngestBeforeHandshake() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    // No handshake at all — try to ingest directly
    let peerId = UUID().uuidString
    let snapshot = makeSnapshot()
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)
    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, _) = try await httpRequest(
        method: "POST",
        url: url,
        headers: ["Authorization": "Bearer some-random-token"],
        body: recordData
    )
    #expect(status == 401)
}

// MARK: - Scrubbing

@Test func remoteScrubbingSecureTextField() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    let (hsStatus, hsJSON) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    #expect(hsStatus == 200)
    let sessionToken = try #require(hsJSON["session_token"] as? String)

    // Build a snapshot with a sensitive password field
    let sensitiveElement = Element(
        ref: "e1", role: "AXSecureTextField",
        label: "Password", value: AnyCodable("hunter2"),
        placeholder: nil, enabled: true, focused: false,
        selected: false, actions: ["AXSetValue"]
    )
    let snapshot = makeSnapshot(elements: [sensitiveElement])
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)

    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, _) = try await httpRequest(
        method: "POST",
        url: url,
        headers: ["Authorization": "Bearer \(sessionToken)"],
        body: recordData
    )
    #expect(status == 200)

    // The stored snapshot must have the value blanked
    let stored = try #require(store.latestSnapshot(forPeer: peerId))
    let storedElements = stored.snapshot.content.sections.flatMap { $0.elements }
    let passwordElement = try #require(storedElements.first { $0.role == "AXSecureTextField" })
    #expect(passwordElement.value?.value as? String == "")
}

@Test func remoteScrubbingNonSensitiveFieldUntouched() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    let (_, hsJSON) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    let sessionToken = try #require(hsJSON["session_token"] as? String)

    let textElement = Element(
        ref: "e2", role: "AXTextField",
        label: "Username", value: AnyCodable("alice"),
        placeholder: nil, enabled: true, focused: false,
        selected: false, actions: ["AXSetValue"]
    )
    let snapshot = makeSnapshot(elements: [textElement])
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)

    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, _) = try await httpRequest(
        method: "POST", url: url,
        headers: ["Authorization": "Bearer \(sessionToken)"],
        body: recordData
    )
    #expect(status == 200)

    let stored = try #require(store.latestSnapshot(forPeer: peerId))
    let storedElements = stored.snapshot.content.sections.flatMap { $0.elements }
    let usernameEl = try #require(storedElements.first { $0.role == "AXTextField" })
    // Non-sensitive field must be preserved
    #expect(usernameEl.value?.value as? String == "alice")
}

// MARK: - Blocked App

@Test func remoteBlockedAppNotStored() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    let (_, hsJSON) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    let sessionToken = try #require(hsJSON["session_token"] as? String)

    // Snapshot from 1Password (blocked)
    let snapshot = makeSnapshot(app: "1Password", bundleId: "com.agilebits.onepassword")
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)

    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, json) = try await httpRequest(
        method: "POST", url: url,
        headers: ["Authorization": "Bearer \(sessionToken)"],
        body: recordData
    )
    // Server must respond 200 (not an error) but must NOT store the snapshot
    #expect(status == 200)
    #expect(json["blocked"] as? Bool == true)

    // Nothing stored for this peer
    let stored = store.latestSnapshot(forPeer: peerId)
    #expect(stored == nil)
}

@Test func remoteBlockedAppBundleIdsContainOnePassword() {
    #expect(RemoteScrubber.blockedBundleIds.contains("com.agilebits.onepassword"))
    #expect(RemoteScrubber.blockedBundleIds.contains("com.agilebits.onepassword7"))
    #expect(RemoteScrubber.blockedBundleIds.contains("com.agilebits.onepassword-osx"))
    #expect(RemoteScrubber.isBlocked(bundleId: "com.agilebits.onepassword"))
    #expect(RemoteScrubber.isBlocked(bundleId: "COM.AGILEBITS.ONEPASSWORD"))  // case-insensitive
}

@Test func remoteNonBlockedAppIsStored() async throws {
    let store = RemoteStore(baseDir: tempDir())
    let (server, port) = try await startServer(store: store)
    defer { server.stop() }

    let (peerId, secretBase64) = server.registerPairingKey()
    let (_, hsJSON) = try await handshake(peerId: peerId, secretBase64: secretBase64, port: port)
    let sessionToken = try #require(hsJSON["session_token"] as? String)

    let snapshot = makeSnapshot(app: "Safari", bundleId: "com.apple.safari")
    let recordData = makeRecord(peerId: peerId, snapshot: snapshot)

    let url = URL(string: "http://127.0.0.1:\(port)/remote-ingest")!
    let (status, json) = try await httpRequest(
        method: "POST", url: url,
        headers: ["Authorization": "Bearer \(sessionToken)"],
        body: recordData
    )
    #expect(status == 200)
    #expect(json["ok"] as? Bool == true)
    #expect(json["blocked"] == nil)

    let stored = store.latestSnapshot(forPeer: peerId)
    #expect(stored != nil)
    #expect(stored?.snapshot.app == "Safari")
}

// MARK: - RemoteScrubber Unit Tests

@Test func remoteScrubberBlanksPasswordFields() {
    let passwordEl = Element(
        ref: "p1", role: "passwordField",
        label: "Password", value: AnyCodable("secret"),
        placeholder: nil, enabled: true, focused: false,
        selected: false, actions: []
    )
    let secureEl = Element(
        ref: "s1", role: "AXSecureTextField",
        label: "Master Password", value: AnyCodable("masterpassword"),
        placeholder: nil, enabled: true, focused: false,
        selected: false, actions: []
    )
    let normalEl = Element(
        ref: "n1", role: "AXTextField",
        label: "Email", value: AnyCodable("user@example.com"),
        placeholder: nil, enabled: true, focused: false,
        selected: false, actions: []
    )

    let snapshot = makeSnapshot(elements: [passwordEl, secureEl, normalEl])
    let scrubbed = RemoteScrubber.scrub(snapshot)
    let elements = scrubbed.content.sections.flatMap { $0.elements }

    #expect(elements.first { $0.ref == "p1" }?.value?.value as? String == "")
    #expect(elements.first { $0.ref == "s1" }?.value?.value as? String == "")
    #expect(elements.first { $0.ref == "n1" }?.value?.value as? String == "user@example.com")
}
