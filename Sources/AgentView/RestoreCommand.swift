import AppKit
import ArgumentParser
import Foundation

// MARK: - CDP Helper

struct CDPHelper {
    let port: Int

    struct PageInfo: Decodable {
        let id: String
        let title: String
        let url: String
        let webSocketDebuggerUrl: String?
    }

    /// GET /json — list all CDP targets
    func listPages() throws -> [PageInfo] {
        let url = URL(string: "http://localhost:\(port)/json")!
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[PageInfo], Error>?

        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error {
                result = .failure(error)
            } else if let data = data {
                do {
                    let pages = try JSONDecoder().decode([PageInfo].self, from: data)
                    result = .success(pages)
                } catch {
                    result = .failure(error)
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        guard let r = result else {
            throw RestoreError.timeout("CDP /json request timed out")
        }
        return try r.get()
    }

    /// Send a Runtime.evaluate command via websocket and return the result
    func evaluate(pageWsUrl: String, expression: String) throws -> String? {
        guard let url = URL(string: pageWsUrl) else {
            throw RestoreError.invalidUrl(pageWsUrl)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultValue: String?
        var wsError: Error?

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        // Send Runtime.evaluate
        let msg: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: msg)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        wsTask.send(.string(jsonString)) { error in
            if let error = error {
                wsError = error
                semaphore.signal()
                return
            }

            // Receive response
            wsTask.receive { result in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        // Parse the CDP response to extract the value
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let resultObj = json["result"] as? [String: Any],
                           let innerResult = resultObj["result"] as? [String: Any] {
                            resultValue = innerResult["value"] as? String
                        }
                    default:
                        break
                    }
                case .failure(let error):
                    wsError = error
                }
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 10)
        wsTask.cancel(with: .goingAway, reason: nil)

        if let error = wsError {
            throw error
        }
        return resultValue
    }

    enum RestoreError: Error, CustomStringConvertible {
        case timeout(String)
        case invalidUrl(String)
        case noPages
        case noWebSocket
        case vaultNotOpened

        var description: String {
            switch self {
            case .timeout(let msg): return msg
            case .invalidUrl(let url): return "Invalid websocket URL: \(url)"
            case .noPages: return "No CDP pages found"
            case .noWebSocket: return "Page has no webSocketDebuggerUrl"
            case .vaultNotOpened: return "Vault did not open after click"
            }
        }
    }
}

// MARK: - Restore Command

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore Electron app windows via CDP (e.g., reopen Obsidian vault)"
    )

    @Argument(help: "App name (default: Obsidian)")
    var app: String = "Obsidian"

    @Option(name: .long, help: "CDP remote debugging port (default: 9222)")
    var port: Int = 9222

    @Option(name: .long, help: "Vault name to open (default: first available)")
    var vault: String?

    @Flag(name: .long, help: "Launch app if not running")
    var launch: Bool = false

    @Flag(name: .long, help: "Pretty print JSON output")
    var pretty: Bool = false

    func run() throws {
        let workspace = NSWorkspace.shared

        // Step 1: Check if app is running
        var runningApp = workspace.runningApplications.first {
            $0.localizedName?.lowercased().contains(app.lowercased()) ?? false
        }

        if runningApp == nil {
            if launch {
                fputs("App '\(app)' not running. Launching with CDP on port \(port)...\n", stderr)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", app, "--args", "--remote-debugging-port=\(port)"]
                try proc.run()
                proc.waitUntilExit()

                // Wait for app to start
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1.0)
                    runningApp = workspace.runningApplications.first {
                        $0.localizedName?.lowercased().contains(app.lowercased()) ?? false
                    }
                    if runningApp != nil { break }
                }

                guard runningApp != nil else {
                    fputs("Error: Failed to launch '\(app)'\n", stderr)
                    throw ExitCode.failure
                }
            } else {
                fputs("Error: '\(app)' is not running. Use --launch to start it.\n", stderr)
                throw ExitCode.failure
            }
        }

        fputs("Found \(runningApp!.localizedName ?? app) (pid \(runningApp!.processIdentifier))\n", stderr)

        // Step 2: Connect to CDP
        let cdp = CDPHelper(port: port)

        // Retry CDP connection (app may still be starting)
        var pages: [CDPHelper.PageInfo] = []
        for attempt in 1...5 {
            do {
                pages = try cdp.listPages()
                if !pages.isEmpty { break }
            } catch {
                if attempt == 5 {
                    fputs("Error: Cannot connect to CDP on port \(port). Is --remote-debugging-port=\(port) set?\n", stderr)
                    fputs("Relaunch with: open -a \(app) --args --remote-debugging-port=\(port)\n", stderr)
                    throw ExitCode.failure
                }
                fputs("CDP not ready, retrying (\(attempt)/5)...\n", stderr)
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        guard let page = pages.first else {
            fputs("Error: No CDP pages found\n", stderr)
            throw ExitCode.failure
        }

        fputs("CDP page: \(page.title) → \(page.url)\n", stderr)

        // Step 3: Check if we're on the vault picker (starter.html)
        if page.url.contains("starter.html") {
            fputs("On vault picker. Attempting to open vault...\n", stderr)

            guard let wsUrl = page.webSocketDebuggerUrl else {
                fputs("Error: No websocket URL available for CDP page\n", stderr)
                throw ExitCode.failure
            }

            // Find the vault to click
            let selector: String
            if let vaultName = vault {
                // Click specific vault by name
                selector = "document.querySelector('.recent-vaults-list-item-name')?.closest('.recent-vaults-list-item')?.click() || document.querySelectorAll('.recent-vaults-list-item').forEach(el => { if (el.textContent.includes('\(vaultName)')) el.click() })"
            } else {
                // Click first vault
                selector = "document.querySelector('.recent-vaults-list-item').click()"
            }

            // Execute click
            _ = try cdp.evaluate(pageWsUrl: wsUrl, expression: selector)
            fputs("Clicked vault. Waiting for load...\n", stderr)

            // Wait and verify
            Thread.sleep(forTimeInterval: 3.0)

            // Re-check pages to see if URL changed
            let newPages = try cdp.listPages()
            let mainPage = newPages.first { !$0.url.contains("starter.html") } ?? newPages.first

            let success = mainPage != nil && !mainPage!.url.contains("starter.html")

            let result: [String: AnyCodable] = [
                "success": AnyCodable(success),
                "app": AnyCodable(runningApp!.localizedName ?? app),
                "pid": AnyCodable(runningApp!.processIdentifier),
                "action": AnyCodable("vault_opened"),
                "page_url": AnyCodable(mainPage?.url ?? "unknown"),
                "page_title": AnyCodable(mainPage?.title ?? "unknown"),
            ]
            try JSONOutput.print(result, pretty: pretty)

            if !success {
                fputs("Warning: Vault may not have opened. Page still on starter.\n", stderr)
            }
        } else {
            // Already in a vault — just report status
            fputs("Already in vault, no restore needed.\n", stderr)
            let result: [String: AnyCodable] = [
                "success": AnyCodable(true),
                "app": AnyCodable(runningApp!.localizedName ?? app),
                "pid": AnyCodable(runningApp!.processIdentifier),
                "action": AnyCodable("already_open"),
                "page_url": AnyCodable(page.url),
                "page_title": AnyCodable(page.title),
            ]
            try JSONOutput.print(result, pretty: pretty)
        }
    }
}
