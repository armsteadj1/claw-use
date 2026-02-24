import Foundation

// Package-internal log helper — mirrors the function in CUADaemon/Server.swift.
func log(_ message: String) {
    fputs("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n", stderr)
}
