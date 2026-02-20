import Foundation

// MARK: - CDP Helper

public struct CDPHelper {
    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public struct PageInfo: Codable {
        public let id: String
        public let title: String
        public let url: String
        public let webSocketDebuggerUrl: String?
    }

    /// GET /json — list all CDP targets
    public func listPages() throws -> [PageInfo] {
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
            throw CDPError.timeout("CDP /json request timed out")
        }
        return try r.get()
    }

    /// Send a Runtime.evaluate command via websocket and return the result.
    ///
    /// Wraps the expression to produce JSON-serialized return values:
    /// - Primitives are JSON-serialized
    /// - Promises are awaited (`awaitPromise: true`)
    /// - Errors include message and stack trace
    public func evaluate(pageWsUrl: String, expression: String) throws -> String? {
        guard let url = URL(string: pageWsUrl) else {
            throw CDPError.invalidUrl(pageWsUrl)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultValue: String?
        var wsError: Error?

        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        // Wrap expression for proper JSON serialization of return values.
        // Handles: async/await, promises, objects, primitives.
        let wrappedExpression = """
        (async () => {
            try {
                const __cua_result = await (async () => { return (\(expression)); })();
                if (__cua_result === undefined) return 'undefined';
                if (__cua_result === null) return 'null';
                if (typeof __cua_result === 'string') return __cua_result;
                try { return JSON.stringify(__cua_result); } catch { return String(__cua_result); }
            } catch (__cua_err) {
                return 'CUA_JS_ERROR:' + (__cua_err.message || String(__cua_err)) + (__cua_err.stack ? '\\nStack: ' + __cua_err.stack : '');
            }
        })()
        """

        let msg: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": wrappedExpression,
                "awaitPromise": true,
                "returnByValue": true,
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: msg)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        wsTask.send(.string(jsonString)) { error in
            if let error = error {
                wsError = error
                semaphore.signal()
                return
            }

            wsTask.receive { result in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // Check for CDP-level exception
                            if let exceptionDetails = json["exceptionDetails"] as? [String: Any] {
                                let exText = exceptionDetails["text"] as? String ?? "Unknown error"
                                if let exception = exceptionDetails["exception"] as? [String: Any],
                                   let desc = exception["description"] as? String {
                                    wsError = CDPError.jsError("\(exText): \(desc)")
                                } else {
                                    wsError = CDPError.jsError(exText)
                                }
                            } else if let resultObj = json["result"] as? [String: Any],
                                      let innerResult = resultObj["result"] as? [String: Any] {
                                // Extract the value — prefer string, fall back to JSON serialization
                                if let strVal = innerResult["value"] as? String {
                                    resultValue = strVal
                                } else if let val = innerResult["value"] {
                                    if let valData = try? JSONSerialization.data(withJSONObject: val),
                                       let valStr = String(data: valData, encoding: .utf8) {
                                        resultValue = valStr
                                    } else {
                                        resultValue = "\(val)"
                                    }
                                }
                            }
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

    public enum CDPError: Error, CustomStringConvertible {
        case timeout(String)
        case invalidUrl(String)
        case noPages
        case noWebSocket
        case vaultNotOpened
        case jsError(String)

        public var description: String {
            switch self {
            case .timeout(let msg): return msg
            case .invalidUrl(let url): return "Invalid websocket URL: \(url)"
            case .noPages: return "No CDP pages found"
            case .noWebSocket: return "Page has no webSocketDebuggerUrl"
            case .vaultNotOpened: return "Vault did not open after click"
            case .jsError(let msg): return "JS Error: \(msg)"
            }
        }
    }
}
