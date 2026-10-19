import Foundation

public struct AgentError: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidInput, notFound, conflict, unsupported, closed, adapterFailed
    }

    public let code: Code
    public let message: String
    public var errorDescription: String? { message }

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    static func wrapping(_ error: any Error) -> AgentError {
        error as? AgentError ?? AgentError(.adapterFailed, error.localizedDescription)
    }
}
