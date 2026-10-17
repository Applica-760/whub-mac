import Foundation
import Hummingbird

enum FilesAPIError: String, Error {
    case invalidPath = "invalid_path"
    case symlinkForbidden = "symlink_forbidden"
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
    case notDirectory = "not_directory"
    case listingTooLarge = "listing_too_large"
    case notRegularFile = "not_regular_file"
    case textTooLarge = "text_too_large"
    case binaryFile = "binary_file"
    case invalidUTF8 = "invalid_utf8"
    case readFailed = "read_failed"
    case conflict = "conflict"
    case writeFailed = "write_failed"
    case invalidRequest = "invalid_request"
    case unsupportedMetadata = "unsupported_metadata"

    init(_ error: FilesError) {
        switch error {
        case .invalidPath: self = .invalidPath
        case .symlinkForbidden: self = .symlinkForbidden
        case .permissionDenied: self = .permissionDenied
        case .notFound: self = .notFound
        case .notDirectory: self = .notDirectory
        case .notRegularFile: self = .notRegularFile
        case .textTooLarge: self = .textTooLarge
        case .binaryFile: self = .binaryFile
        case .invalidUTF8: self = .invalidUTF8
        case .readFailed: self = .readFailed
        case .conflict: self = .conflict
        case .writeFailed: self = .writeFailed
        case .unsupportedMetadata: self = .unsupportedMetadata
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
            message = "ファイルにアクセスする権限がありません。"
        case .notFound:
            status = .notFound
            message = "対象が存在しません。"
        case .notDirectory:
            status = .unprocessableContent
            message = "ディレクトリではありません。"
        case .listingTooLarge:
            status = .unprocessableContent
            message = "取得結果が8 MiBの上限を超えています。"
        case .conflict:
            status = .conflict
            message = "ファイルが外部で変更されています。保存を拒否しました。"
        case .unsupportedMetadata:
            status = .unprocessableContent
            message = "ファイルの追加設定を保持できないか、確認できないため保存を拒否しました。元のファイルは変更していません。"
        case .writeFailed:
            status = .internalServerError
            message = "ファイルを保存できません。"
        case .invalidRequest:
            status = .badRequest
            message = "保存要求が不正です。"
        case .readFailed:
            status = .internalServerError
            message = "ファイルを取得できません。"
        case .notRegularFile:
            status = .unprocessableContent
            message = "通常のファイルではありません。"
        case .textTooLarge:
            status = .unprocessableContent
            message = "本文が1 MiBの上限を超えています。"
        case .binaryFile:
            status = .unprocessableContent
            message = "バイナリファイルは表示できません。"
        case .invalidUTF8:
            status = .unprocessableContent
            message = "UTF-8テキストとして読み込めません。"
        }
        let data = try! JSONEncoder().encode(["error": ["code": rawValue, "message": message]])
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }

}
