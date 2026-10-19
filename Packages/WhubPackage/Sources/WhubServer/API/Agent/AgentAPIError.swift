import Foundation
import Hummingbird
import WhubAgent

enum AgentAPIError: Error {
    case invalidRequest, responseTooLarge, operationFailed

    var response: Response {
        let status: HTTPResponse.Status
        let body: String
        switch self {
        case .invalidRequest:
            status = .badRequest
            body = #"{"error":{"code":"invalid_request","message":"Agentの要求形式が不正です。"}}"#
        case .responseTooLarge:
            status = .contentTooLarge
            body = #"{"error":{"code":"response_too_large","message":"取得結果が8 MiBの上限を超えています。"}}"#
        case .operationFailed:
            status = .internalServerError
            body = #"{"error":{"code":"operation_failed","message":"Agentの要求を処理できませんでした。"}}"#
        }
        return Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: body.utf8)))
    }

    static func status(for error: AgentError) -> HTTPResponse.Status {
        switch error.code {
        case .invalidInput: .badRequest
        case .notFound: .notFound
        case .conflict: .conflict
        case .unsupported: .unprocessableContent
        case .closed, .resyncRequired: .gone
        case .adapterFailed: .badGateway
        }
    }
}
