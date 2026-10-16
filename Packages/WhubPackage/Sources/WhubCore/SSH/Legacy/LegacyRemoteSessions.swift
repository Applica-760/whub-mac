import Foundation

// Removed with the Python file transport after the HTTP migration.
@MainActor
final class LegacyRemoteSessions {
    private var sessions: [ObjectIdentifier: RemoteSession] = [:]
    private var jobs: [ObjectIdentifier: (id: UUID, task: Task<RemoteSession, Error>)] = [:]

    func session(for connection: SSHConnectionService) async throws -> RemoteSession {
        let key = ObjectIdentifier(connection)
        guard connection.isConnected else { throw SSHError.disconnected }
        if let session = sessions[key], session.disconnectionError == nil { return session }
        if let job = jobs[key] { return try await job.task.value }
        let previous = sessions.removeValue(forKey: key)
        let id = UUID()
        let task = Task {
            await previous?.close()
            try Task.checkCancellation()
            return try await RemoteSession.connect(using: connection)
        }
        jobs[key] = (id, task)
        do {
            let session = try await task.value
            guard jobs[key]?.id == id, connection.isConnected else {
                await session.close()
                throw SSHError.disconnected
            }
            sessions[key] = session
            jobs.removeValue(forKey: key)
            return session
        } catch {
            if jobs[key]?.id == id { jobs.removeValue(forKey: key) }
            throw error
        }
    }

    func close(for connection: SSHConnectionService) async {
        let key = ObjectIdentifier(connection)
        let job = jobs.removeValue(forKey: key)
        job?.task.cancel()
        await sessions.removeValue(forKey: key)?.close()
        if let session = try? await job?.task.value { await session.close() }
    }
}

extension RemoteConnectionStore {
    public func legacySession(for host: RemoteHost) async throws -> RemoteSession {
        guard let connection = connection(for: host) else { throw SSHError.disconnected }
        let session = try await legacySessions.session(for: connection)
        try Task.checkCancellation()
        guard self.connection(for: host) === connection else { throw SSHError.disconnected }
        return session
    }
}
