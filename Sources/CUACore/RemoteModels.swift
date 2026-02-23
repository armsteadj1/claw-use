import CryptoKit
import Foundation

// MARK: - Remote Peer

public struct RemotePeer: Codable {
    public let id: String
    public var name: String
    public var lastSeen: Date?
    public var status: String  // "active", "inactive"

    public init(id: String, name: String, lastSeen: Date?, status: String) {
        self.id = id; self.name = name; self.lastSeen = lastSeen; self.status = status
    }
}

// MARK: - Remote Snapshot Record

/// A single snapshot record stored as one JSONL line on the receiver
public struct RemoteSnapshotRecord: Codable {
    public let timestamp: Date
    public let peerId: String
    public let peerName: String
    public let snapshot: AppSnapshot
    public let appList: [String]  // Running app names (pre-scrubbed)

    public init(timestamp: Date, peerId: String, peerName: String,
                snapshot: AppSnapshot, appList: [String]) {
        self.timestamp = timestamp; self.peerId = peerId; self.peerName = peerName
        self.snapshot = snapshot; self.appList = appList
    }
}

// MARK: - Remote Session

/// Active pairing session (after handshake completes)
public struct RemoteSession: Codable {
    public let peerId: String
    public var peerName: String
    public let sessionToken: String
    public var lastUsed: Date
    public let createdAt: Date

    public init(peerId: String, peerName: String, sessionToken: String,
                lastUsed: Date, createdAt: Date = Date()) {
        self.peerId = peerId; self.peerName = peerName; self.sessionToken = sessionToken
        self.lastUsed = lastUsed; self.createdAt = createdAt
    }
}

// MARK: - Remote Config

public struct RemoteConfig: Codable {
    public var port: Int
    public var retainSeconds: Int

    public init(port: Int = 9876, retainSeconds: Int = 86400) {
        self.port = port; self.retainSeconds = retainSeconds
    }

    /// Parse duration strings: "1d", "7d", "1h", "30m", "5s", bare seconds
    public static func parseDuration(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("d"), let n = Int(t.dropLast()) { return n * 86400 }
        if t.hasSuffix("h"), let n = Int(t.dropLast()) { return n * 3600 }
        if t.hasSuffix("m"), let n = Int(t.dropLast()) { return n * 60 }
        if t.hasSuffix("s"), let n = Int(t.dropLast()) { return n }
        return Int(t) ?? 86400
    }
}

// MARK: - Sender State

/// Persisted on the sender machine after a successful handshake
public struct RemoteSenderState: Codable {
    public let host: String
    public let port: Int
    public let peerId: String
    public let sessionToken: String
    public let intervalSeconds: Int

    public init(host: String, port: Int, peerId: String,
                sessionToken: String, intervalSeconds: Int) {
        self.host = host; self.port = port; self.peerId = peerId
        self.sessionToken = sessionToken; self.intervalSeconds = intervalSeconds
    }
}

// MARK: - HMAC Helpers

public enum RemoteCrypto {
    /// Generate a random 32-byte key; returns (raw bytes, base64-encoded string)
    public static func generateKey() -> (Data, String) {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return (data, data.base64EncodedString())
    }

    /// Compute HMAC-SHA256 over `message` using `secret`, returns lowercase hex
    public static func hmacSHA256(message: String, secret: Data) -> String {
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a HMAC-SHA256 tag
    public static func verifyHMAC(message: String, secret: Data, expectedHex: String) -> Bool {
        hmacSHA256(message: message, secret: secret) == expectedHex
    }
}
