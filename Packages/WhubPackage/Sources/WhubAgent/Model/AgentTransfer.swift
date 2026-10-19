import Foundation

/// Small enough for session lists and polling; conversation bodies are fetched through a snapshot.
public struct AgentSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: AgentKind
    public let directory: String
    public let createdAt: Date
    public let revision: UInt64
    public let conversationID: String?
    public let isRunning: Bool
    public let isClosed: Bool

    init(_ state: AgentSessionState) {
        id = state.id
        kind = state.kind
        directory = state.directory
        createdAt = state.createdAt
        revision = state.revision
        conversationID = state.conversationID
        isRunning = state.isRunning
        isClosed = state.isClosed
    }
}

/// Owns the frozen snapshot and the subsequent change feed, independently of the remote session.
public struct AgentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: UInt64
    public let byteCount: Int
}

/// `data` is a slice of a UTF-8 JSON document, encoded as base64 by Codable.
/// Concatenate all pages before decoding: a page may split a character or JSON token.
public struct AgentTransferPage: Codable, Sendable, Equatable {
    public let fromRevision: UInt64
    public let toRevision: UInt64
    public let cursor: Int
    public let nextCursor: Int?
    public let data: Data
}

/// Paths address object keys or decimal array indices in the snapshot's JSON document.
/// Apply a complete revision atomically, in order. `append` extends a string or array.
public struct AgentStateChange: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case set, remove, append }
    public let operation: Operation
    public let path: [String]
    public let value: AgentJSONValue?
}

public enum AgentJSONValue: Codable, Sendable, Equatable {
    case object([String: AgentJSONValue]), array([AgentJSONValue]), string(String)
    case number(Decimal), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let array = try? value.decode([AgentJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: AgentJSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public struct AgentImagePage: Codable, Sendable, Equatable {
    public let id: UUID
    public let mediaType: String
    public let byteCount: Int
    public let cursor: Int
    public let nextCursor: Int?
    public let data: Data
}

extension CodingUserInfoKey {
    /// Image bytes fetched separately, keyed by the immutable attachment ID.
    public static let agentImageData = CodingUserInfoKey(rawValue: "WhubAgent.imageData")!

    static let agentImageReferences = CodingUserInfoKey(rawValue: "WhubAgent.imageReferences")!
}
