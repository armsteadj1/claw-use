import CoreGraphics
import Foundation

public struct ScreenCaptureResult: Codable {
    public let success: Bool
    public let path: String?
    public let width: Int?
    public let height: Int?
    public let error: String?
}

public enum ScreenCapture {

    /// Capture a window screenshot for the given app name, save as PNG.
    /// Uses CGWindowListCopyWindowInfo to find the window, then the macOS
    /// `screencapture` CLI tool with `-l <windowid>` to capture it.
    public static func capture(appName: String, outputPath: String? = nil) -> ScreenCaptureResult {
        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] else {
            return ScreenCaptureResult(success: false, path: nil, width: nil, height: nil, error: "Failed to list windows")
        }

        let lowerApp = appName.lowercased()

        // Find a window matching the app name
        var matchedWindowID: CGWindowID?
        var matchedBounds: CGRect?
        var matchedOwner: String?

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName] as? String else { continue }
            guard ownerName.lowercased().contains(lowerApp) else { continue }
            // Skip tiny windows (like menu bar items)
            guard let boundsDict = window[kCGWindowBounds] as? [String: Any] else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds) else { continue }
            if bounds.width < 50 || bounds.height < 50 { continue }

            guard let windowID = window[kCGWindowNumber] as? CGWindowID else { continue }
            matchedWindowID = windowID
            matchedBounds = bounds
            matchedOwner = ownerName
            break
        }

        guard let windowID = matchedWindowID, let bounds = matchedBounds, let owner = matchedOwner else {
            return ScreenCaptureResult(success: false, path: nil, width: nil, height: nil,
                                       error: "No window found for app '\(appName)'")
        }

        // Build output path
        let safeName = owner.lowercased().replacingOccurrences(of: " ", with: "-")
        let timestamp = Int(Date().timeIntervalSince1970)
        let path = outputPath ?? "/tmp/cua-screenshot-\(safeName)-\(timestamp).png"

        // Use macOS screencapture CLI to capture the window by ID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", "\(windowID)", "-o", "-x", path]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ScreenCaptureResult(success: false, path: nil, width: nil, height: nil,
                                       error: "Failed to run screencapture: \(error)")
        }

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            return ScreenCaptureResult(success: false, path: nil, width: nil, height: nil,
                                       error: "screencapture failed: \(errStr.isEmpty ? "exit \(process.terminationStatus)" : errStr)")
        }

        // Verify the file was created
        guard FileManager.default.fileExists(atPath: path) else {
            return ScreenCaptureResult(success: false, path: nil, width: nil, height: nil,
                                       error: "Screenshot file not created at '\(path)'")
        }

        return ScreenCaptureResult(
            success: true,
            path: path,
            width: Int(bounds.width),
            height: Int(bounds.height),
            error: nil
        )
    }
}
