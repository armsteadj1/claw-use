import Foundation
import Testing
@testable import CUACore

// MARK: - PathLauncher Tests

@Test func pathLauncherFileNotFound() {
    let nonexistent = "/nonexistent/\(UUID().uuidString)/binary"
    var caught = false
    do {
        _ = try PathLauncher.launch(path: nonexistent)
        Issue.record("Expected PathLaunchError.fileNotFound but no error was thrown")
    } catch PathLaunchError.fileNotFound(let p) {
        #expect(p == nonexistent)
        caught = true
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
    #expect(caught)
}

@Test func pathLauncherNotExecutable() throws {
    // Create a temp file that exists but is not executable
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cua_test_\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tmp.path, contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: tmp) }

    var caught = false
    do {
        _ = try PathLauncher.launch(path: tmp.path)
        Issue.record("Expected PathLaunchError.notExecutable but no error was thrown")
    } catch PathLaunchError.notExecutable {
        caught = true
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
    #expect(caught)
}

@Test func pathLauncherLaunchEcho() throws {
    // /bin/echo exits immediately — use wait:true so there's no 2s poll
    let result = try PathLauncher.launch(path: "/bin/echo", extraArgs: ["hello"], wait: true)
    #expect(result.path == "/bin/echo")
    #expect(result.pid > 0)
    #expect(result.app == "echo")
    #expect(result.bundleId == "")
}

@Test func pathLauncherLaunchScript() throws {
    // Write a tiny shell script, make it executable, run it
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cua_test_\(UUID().uuidString).sh")
    try "#!/bin/sh\nexit 0\n".write(to: tmp, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = try PathLauncher.launch(path: tmp.path, wait: true)
    #expect(result.path == tmp.path)
    #expect(result.pid > 0)
}
