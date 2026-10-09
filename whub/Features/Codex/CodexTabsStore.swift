import Combine
import SwiftData

@MainActor
final class CodexTabsStore: ObservableObject {
    @Published private(set) var sessions: [CodexStore]
    @Published private(set) var selectedSessionID: CodexStore.ID
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        let session = CodexStore(context: context)
        sessions = [session]
        selectedSessionID = session.id
    }

    var selectedSession: CodexStore {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = CodexStore(context: context)
        sessions.append(session)
        selectedSessionID = session.id
    }

    func select(_ id: CodexStore.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
    }

    func remove(_ id: CodexStore.ID) {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].disconnect()
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = sessions[min(index, sessions.count - 1)].id
        }
    }

    func move(_ id: CodexStore.ID, before target: CodexStore.ID?) {
        guard let reordered = reorderedTabs(sessions, moving: id, before: target, identifiedBy: \.id) else { return }
        sessions = reordered
    }

    func disconnect() {
        for session in sessions { session.disconnect() }
    }
}
