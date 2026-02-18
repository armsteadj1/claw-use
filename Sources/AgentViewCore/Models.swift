import Foundation

// MARK: - AnyCodable

/// Type-erased Codable wrapper for mixed AX values
public struct AnyCodable: Codable {
    public let value: Any?

    public init(_ value: Any?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else {
            value = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int as Int32:
            try container.encode(Int(int))
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Raw Layer

/// Raw AX tree node — direct representation of what the Accessibility API returns
public struct RawAXNode: Codable {
    public let role: String?
    public let roleDescription: String?
    public let title: String?
    public let value: AnyCodable?
    public let axDescription: String?
    public let identifier: String?
    public let placeholder: String?
    public let position: Position?
    public let size: Size?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let url: String?
    public let actions: [String]
    public let children: [RawAXNode]
    public let childCount: Int
    public let domId: String?
    public let domClasses: [String]?
    public let tempId: String?

    enum CodingKeys: String, CodingKey {
        case role, roleDescription, title, value, axDescription, identifier, placeholder
        case position, size, enabled, focused, selected, url, actions, children, childCount
        case domId, domClasses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        roleDescription = try c.decodeIfPresent(String.self, forKey: .roleDescription)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        value = try c.decodeIfPresent(AnyCodable.self, forKey: .value)
        axDescription = try c.decodeIfPresent(String.self, forKey: .axDescription)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        position = try c.decodeIfPresent(Position.self, forKey: .position)
        size = try c.decodeIfPresent(Size.self, forKey: .size)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        children = try c.decodeIfPresent([RawAXNode].self, forKey: .children) ?? []
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount) ?? 0
        domId = try c.decodeIfPresent(String.self, forKey: .domId)
        domClasses = try c.decodeIfPresent([String].self, forKey: .domClasses)
        tempId = nil
    }

    public init(role: String?, roleDescription: String?, title: String?, value: AnyCodable?,
         axDescription: String?, identifier: String?, placeholder: String?,
         position: Position?, size: Size?, enabled: Bool?, focused: Bool?,
         selected: Bool?, url: String?, actions: [String], children: [RawAXNode],
         childCount: Int, domId: String?, domClasses: [String]?, tempId: String? = nil) {
        self.role = role; self.roleDescription = roleDescription; self.title = title
        self.value = value; self.axDescription = axDescription; self.identifier = identifier
        self.placeholder = placeholder; self.position = position; self.size = size
        self.enabled = enabled; self.focused = focused; self.selected = selected
        self.url = url; self.actions = actions; self.children = children
        self.childCount = childCount; self.domId = domId; self.domClasses = domClasses
        self.tempId = tempId
    }

    public struct Position: Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Size: Codable {
        public let width: Double
        public let height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
    }
}

// MARK: - Enriched Layer

/// Enriched snapshot — what the agent actually sees
public struct AppSnapshot: Codable {
    public let app: String
    public let bundleId: String?
    public let pid: Int32
    public let timestamp: String
    public let window: WindowInfo
    public let meta: [String: AnyCodable]
    public let content: ContentTree
    public let actions: [InferredAction]
    public let stats: SnapshotStats

    public init(app: String, bundleId: String?, pid: Int32, timestamp: String,
                window: WindowInfo, meta: [String: AnyCodable], content: ContentTree,
                actions: [InferredAction], stats: SnapshotStats) {
        self.app = app; self.bundleId = bundleId; self.pid = pid; self.timestamp = timestamp
        self.window = window; self.meta = meta; self.content = content
        self.actions = actions; self.stats = stats
    }
}

public struct WindowInfo: Codable {
    public let title: String?
    public let size: RawAXNode.Size?
    public let focused: Bool
    public init(title: String?, size: RawAXNode.Size?, focused: Bool) {
        self.title = title; self.size = size; self.focused = focused
    }
}

public struct ContentTree: Codable {
    public let summary: String?
    public let sections: [Section]
    public init(summary: String?, sections: [Section]) {
        self.summary = summary; self.sections = sections
    }
}

public struct Section: Codable {
    public let role: String
    public let label: String?
    public let elements: [Element]
    public init(role: String, label: String?, elements: [Element]) {
        self.role = role; self.label = label; self.elements = elements
    }
}

public struct Element: Codable {
    public let ref: String
    public let role: String
    public let label: String?
    public let value: AnyCodable?
    public let placeholder: String?
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool
    public let actions: [String]
    public init(ref: String, role: String, label: String?, value: AnyCodable?,
                placeholder: String?, enabled: Bool, focused: Bool, selected: Bool, actions: [String]) {
        self.ref = ref; self.role = role; self.label = label; self.value = value
        self.placeholder = placeholder; self.enabled = enabled; self.focused = focused
        self.selected = selected; self.actions = actions
    }
}

public struct InferredAction: Codable {
    public let name: String
    public let description: String
    public let ref: String?
    public let requires: [String]?
    public let options: [ActionOption]?
    public init(name: String, description: String, ref: String?, requires: [String]?, options: [ActionOption]?) {
        self.name = name; self.description = description; self.ref = ref
        self.requires = requires; self.options = options
    }
}

public struct ActionOption: Codable {
    public let label: String
    public let ref: String
    public init(label: String, ref: String) { self.label = label; self.ref = ref }
}

public struct SnapshotStats: Codable {
    public let totalNodes: Int
    public let prunedNodes: Int
    public let enrichedElements: Int
    public let walkTimeMs: Int
    public let enrichTimeMs: Int
    public init(totalNodes: Int, prunedNodes: Int, enrichedElements: Int, walkTimeMs: Int, enrichTimeMs: Int) {
        self.totalNodes = totalNodes; self.prunedNodes = prunedNodes
        self.enrichedElements = enrichedElements; self.walkTimeMs = walkTimeMs; self.enrichTimeMs = enrichTimeMs
    }
}

// MARK: - App Listing

public struct AppInfo: Codable {
    public let name: String
    public let pid: Int32
    public let bundleId: String?
    public init(name: String, pid: Int32, bundleId: String?) {
        self.name = name; self.pid = pid; self.bundleId = bundleId
    }
}

// MARK: - Action Result

public struct ActionResultOutput: Codable {
    public let success: Bool
    public let error: String?
    public let snapshot: AppSnapshot?
    public init(success: Bool, error: String?, snapshot: AppSnapshot?) {
        self.success = success; self.error = error; self.snapshot = snapshot
    }
}

// MARK: - JSON Output

public struct JSONOutput {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public static func print<T: Encodable>(_ value: T, pretty: Bool = false) throws {
        let enc = pretty ? prettyEncoder : encoder
        let data = try enc.encode(value)
        Swift.print(String(data: data, encoding: .utf8)!)
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let enc = pretty ? prettyEncoder : encoder
        return try enc.encode(value)
    }
}

// MARK: - JSON-RPC

public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodable]?
    public let id: AnyCodable?

    public init(method: String, params: [String: AnyCodable]? = nil, id: AnyCodable? = AnyCodable(1)) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}

public struct JSONRPCResponse: Codable {
    public let jsonrpc: String
    public let result: AnyCodable?
    public let error: JSONRPCError?
    public let id: AnyCodable?

    public init(result: AnyCodable?, id: AnyCodable?) {
        self.jsonrpc = "2.0"
        self.result = result
        self.error = nil
        self.id = id
    }

    public init(error: JSONRPCError, id: AnyCodable?) {
        self.jsonrpc = "2.0"
        self.result = nil
        self.error = error
        self.id = id
    }
}

public struct JSONRPCError: Codable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code; self.message = message
    }

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

// MARK: - String Helpers

extension String {
    public var slugified: String {
        self.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
