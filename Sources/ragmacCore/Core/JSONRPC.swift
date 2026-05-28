import Foundation

/// JSON-RPC 2.0 types for the MCP stdio server.
public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let method: String
    public let params: JSONRPCParams?

    public init(jsonrpc: String = "2.0", id: JSONRPCId? = nil, method: String, params: JSONRPCParams? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONRPCId: Codable, Equatable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let n = try? container.decode(Int.self) { self = .number(n); return }
        throw DecodingError.typeMismatch(JSONRPCId.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

/// Flexible parameter container (either named or positional).
public struct JSONRPCParams: Codable {
    public let value: [String: AnyCodable]

    public init(_ dict: [String: AnyCodable]) { self.value = dict }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = (try? container.decode([String: AnyCodable].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public subscript(key: String) -> AnyCodable? { value[key] }
}

public struct JSONRPCResponse: Codable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let result: AnyCodable?
    public let error: JSONRPCError?

    public init(id: JSONRPCId?, result: AnyCodable) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCId?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct JSONRPCError: Codable {
    public let code: Int
    public let message: String

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static func internalError(_ msg: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: msg)
    }

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// Type-erased Codable value for heterogeneous JSON structures.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.value = NSNull(); return }
        if let b = try? container.decode(Bool.self) { self.value = b; return }
        if let i = try? container.decode(Int.self) { self.value = i; return }
        if let d = try? container.decode(Double.self) { self.value = d; return }
        if let s = try? container.decode(String.self) { self.value = s; return }
        if let a = try? container.decode([AnyCodable].self) { self.value = a.map { $0.value }; return }
        if let o = try? container.decode([String: AnyCodable].self) {
            self.value = o.mapValues { $0.value }; return
        }
        self.value = NSNull()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [Any]: try container.encode(a.map { AnyCodable($0) })
        case let o as [String: Any]: try container.encode(o.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}
