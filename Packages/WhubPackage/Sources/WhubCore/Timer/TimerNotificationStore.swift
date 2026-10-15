import Foundation
import SwiftData

public enum TimerNotificationStoreError: LocalizedError {
    case nameRequired
    case invalidTime

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Notification name is required."
        case .invalidTime:
            "Hour must be between 0 and 23, and minute between 0 and 59."
        }
    }
}

@MainActor
public struct TimerNotificationStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchNotifications() throws -> [TimerNotification] {
        try context.fetch(FetchDescriptor(sortBy: [
            SortDescriptor(\TimerNotification.hour),
            SortDescriptor(\TimerNotification.minute),
            SortDescriptor(\TimerNotification.name),
        ]))
    }

    @discardableResult
    public func add(name: String, hour: Int, minute: Int) throws -> TimerNotification {
        let name = try validate(name: name, hour: hour, minute: minute)
        let notification = TimerNotification(name: name, hour: hour, minute: minute)
        context.insert(notification)
        do {
            try context.save()
        } catch {
            context.delete(notification)
            throw error
        }
        return notification
    }

    public func edit(_ notification: TimerNotification, name: String, hour: Int, minute: Int) throws {
        let name = try validate(name: name, hour: hour, minute: minute)
        let previous = (notification.name, notification.hour, notification.minute)
        notification.name = name
        notification.hour = hour
        notification.minute = minute
        do {
            try context.save()
        } catch {
            notification.name = previous.0
            notification.hour = previous.1
            notification.minute = previous.2
            throw error
        }
    }

    public func delete(_ notification: TimerNotification) throws {
        context.delete(notification)
        try context.save()
    }

    private func validate(name rawName: String, hour: Int, minute: Int) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TimerNotificationStoreError.nameRequired }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw TimerNotificationStoreError.invalidTime
        }
        return name
    }
}
