#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum FilesError: Error {
    case invalidPath, symlinkForbidden, permissionDenied, notFound, notDirectory, readFailed
    case notRegularFile, textTooLarge, binaryTooLarge, binaryFile, invalidUTF8, conflict, writeFailed, unsupportedMetadata
    case alreadyExists, operationFailed

    static func system(_ number: Int32) -> Self {
        switch number {
        case ENOENT: .notFound
        case EACCES, EPERM: .permissionDenied
        case ENOTDIR: .notDirectory
        case ELOOP: .symlinkForbidden
        case EEXIST: .alreadyExists
        default: .readFailed
        }
    }
}
