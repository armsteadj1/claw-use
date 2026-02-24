import AppKit
import Foundation

/// The result of launching a path-based application or binary.
public struct PathLaunchResult {
    public let app: String
    public let pid: Int32
    public let bundleId: String
    public let path: String

    public init(app: String, pid: Int32, bundleId: String, path: String) {
        self.app = app
        self.pid = pid
        self.bundleId = bundleId
        self.path = path
    }
}

public enum PathLaunchError: Error, Equatable {
    case fileNotFound(String)
    case notExecutable(String)
    case launchFailed(String)
}

extension PathLaunchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):   return "File not found: \(p)"
        case .notExecutable(let p):  return "File is not executable: \(p)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        }
    }
}

/// Launches a file-system path as an application or bare binary.
public struct PathLauncher {

    /// Launch a path-based app or binary.
    /// - Parameters:
    ///   - path: Absolute path (already tilde-expanded) to a `.app` bundle or executable.
    ///   - extraArgs: Arguments forwarded to the binary, or passed after `--args` for `.app`.
    ///   - wait: If `true`, wait for the process to exit before returning.
    public static func launch(
        path: String,
        extraArgs: [String] = [],
        wait: Bool = false
    ) throws -> PathLaunchResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw PathLaunchError.fileNotFound(path)
        }

        if path.hasSuffix(".app") {
            return try launchAppBundle(path: path, extraArgs: extraArgs, wait: wait)
        } else {
            return try launchBinary(path: path, args: extraArgs, wait: wait)
        }
    }

    // MARK: - .app bundle

    private static func launchAppBundle(
        path: String,
        extraArgs: [String],
        wait: Bool
    ) throws -> PathLaunchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        var args: [String] = []
        if wait { args.append("-W") }
        args.append(path)
        if !extraArgs.isEmpty {
            args.append("--args")
            args.append(contentsOf: extraArgs)
        }
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PathLaunchError.launchFailed(errorStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let basename = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        let runningApp = pollRunningApp(
            matching: { $0.localizedName?.lowercased().contains(basename.lowercased()) ?? false },
            timeout: 2.0
        )

        return PathLaunchResult(
            app: runningApp?.localizedName ?? basename,
            pid: runningApp?.processIdentifier ?? 0,
            bundleId: runningApp?.bundleIdentifier ?? "",
            path: path
        )
    }

    // MARK: - Raw binary

    private static func launchBinary(
        path: String,
        args: [String],
        wait: Bool
    ) throws -> PathLaunchResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw PathLaunchError.notExecutable(path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        if wait {
            process.waitUntilExit()
            let basename = (path as NSString).lastPathComponent
            return PathLaunchResult(app: basename, pid: pid, bundleId: "", path: path)
        }

        // Background launch: poll up to 2s for the process to appear in NSWorkspace
        let basename = (path as NSString).lastPathComponent
        let runningApp = pollRunningApp(
            matching: { $0.processIdentifier == pid },
            timeout: 2.0
        )

        return PathLaunchResult(
            app: runningApp?.localizedName ?? basename,
            pid: runningApp?.processIdentifier ?? pid,
            bundleId: runningApp?.bundleIdentifier ?? "",
            path: path
        )
    }

    // MARK: - Helpers

    /// Poll `NSWorkspace.shared.runningApplications` until `predicate` matches or timeout expires.
    private static func pollRunningApp(
        matching predicate: (NSRunningApplication) -> Bool,
        timeout: TimeInterval
    ) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = NSWorkspace.shared.runningApplications.first(where: predicate) {
                return app
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }
}
