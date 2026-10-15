import Foundation
import Hummingbird

enum FilesAPIError: String, Error {
    case invalidPath = "invalid_path"
    case symlinkForbidden = "symlink_forbidden"
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
    case notDirectory = "not_directory"
    case listingTooLarge = "listing_too_large"
    case readFailed = "read_failed"

    init(_ error: FilesError) {
        switch error {
        case .invalidPath: self = .invalidPath
        case .symlinkForbidden: self = .symlinkForbidden
        case .permissionDenied: self = .permissionDenied
        case .notFound: self = .notFound
        case .notDirectory: self = .notDirectory
        case .readFailed: self = .readFailed
        }
    }

    var response: Response {
        let status: HTTPResponse.Status
        let message: String
        switch self {
        case .invalidPath:
            status = .badRequest
            message = "パスまたはクエリが不正です。"
        case .symlinkForbidden:
            status = .forbidden
            message = "シンボリックリンクは辿れません。"
        case .permissionDenied:
            status = .forbidden
            message = "閲覧する権限がありません。"
        case .notFound:
            status = .notFound
            message = "対象が存在しません。"
        case .notDirectory:
            status = .unprocessableContent
            message = "ディレクトリではありません。"
        case .listingTooLarge:
            status = .unprocessableContent
            message = "取得結果が8 MiBの上限を超えています。"
        case .readFailed:
            status = .internalServerError
            message = "一覧を取得できません。"
        }
        let data = try! JSONEncoder().encode(["error": ["code": rawValue, "message": message]])
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }

}
