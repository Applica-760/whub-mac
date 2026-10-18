import Foundation
import Hummingbird

enum ManagerAPIError: String, Error {
    case unauthorized
    case invalidRequest = "invalid_request"
    case invalidRef = "invalid_ref"
    case invalidCommit = "invalid_commit"
    case invalidBuild = "invalid_build"
    case invalidID = "invalid_id"
    case invalidOffset = "invalid_offset"
    case notFound = "not_found"
    case updateLocked = "update_locked"
    case launchFailed = "launch_failed"
    case responseTooLarge = "response_too_large"
    case operationFailed = "operation_failed"

    init(_ error: ReleaseError) {
        self = Self(rawValue: error.code) ?? .operationFailed
    }

    init(_ error: BuildError) {
        self = Self(rawValue: error.code) ?? .operationFailed
    }

    var response: Response {
        let status: HTTPResponse.Status
        let message: String
        switch self {
        case .unauthorized:
            status = .unauthorized; message = "Manager APIの認証が必要です。"
        case .invalidRequest:
            status = .badRequest; message = "リクエストが不正です。操作に対応したフィールドだけを含む4 KiB以下のJSONを指定してください。"
        case .invalidRef:
            status = .badRequest; message = "devは有効なrefの指定が必要です。prodはorigin/main固定です。"
        case .invalidCommit:
            status = .badRequest; message = "DevのBuildには完全なcommit IDを指定してください。"
        case .invalidBuild:
            status = .conflict; message = "ビルド成果物と保存情報が一致しません。履歴と成果物を確認してください。"
        case .invalidID:
            status = .badRequest; message = "更新IDが不正です。"
        case .invalidOffset:
            status = .badRequest; message = "ログのoffsetが範囲外です。"
        case .notFound:
            status = .notFound; message = "更新が見つかりません。"
        case .updateLocked:
            status = .conflict; message = "別の更新が実行中、または中断した更新の確認が必要です。"
        case .launchFailed:
            status = .serviceUnavailable; message = "更新プロセスの起動を確認できませんでした。更新履歴とログを確認してください。"
        case .responseTooLarge:
            status = .contentTooLarge; message = "取得結果が8 MiBの上限を超えています。"
        case .operationFailed:
            status = .internalServerError; message = "Managerの処理に失敗しました。"
        }
        let data = try! JSONEncoder().encode(["error": ["code": rawValue, "message": message]])
        var response = Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                                body: .init(byteBuffer: .init(bytes: data)))
        if self == .unauthorized { response.headers[.wwwAuthenticate] = "Bearer" }
        return response
    }
}
