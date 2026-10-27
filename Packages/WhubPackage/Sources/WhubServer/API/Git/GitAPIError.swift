import Foundation
import Hummingbird
import WhubGit

enum GitAPIError: String, Error {
    case notRepository = "not_repository"
    case watchExpired = "watch_expired"
    case watchLimitReached = "watch_limit_reached"
    case watchFailed = "watch_failed"

    var response: Response {
        let status: HTTPResponse.Status
        let message: String
        switch self {
        case .notRepository:
            status = .unprocessableContent
            message = "Gitリポジトリではありません。"
        case .watchExpired:
            status = .gone
            message = "監視の有効期限が切れました。再登録してください。"
        case .watchLimitReached:
            status = .serviceUnavailable
            message = "OSのファイル監視枠が不足しています。"
        case .watchFailed:
            status = .serviceUnavailable
            message = "ファイル監視に失敗しました。"
        }
        let data = try! JSONEncoder().encode(["error": ["code": rawValue, "message": message]])
        return Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }

    static func response(for error: any Error) -> Response {
        #if os(Linux)
        if let error = error as? LinuxGitWatchStore.WatchError {
            switch error {
            case .expired: return GitAPIError.watchExpired.response
            case .limitReached: return GitAPIError.watchLimitReached.response
            case .failed: return GitAPIError.watchFailed.response
            }
        }
        #endif
        if let error = error as? FilesAPIError { return error.response }
        if let error = error as? FilesError { return FilesAPIError(error).response }
        if case GitError.notRepository = error { return GitAPIError.notRepository.response }
        return FilesAPIError.readFailed.response
    }
}
