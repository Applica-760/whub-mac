import Foundation
import SwiftData

public enum ActivityRecordStoreError: LocalizedError {
    case invalidInterval
    case overlappingRecord
    case multipleActiveRecords

    public var errorDescription: String? {
        switch self {
        case .invalidInterval:
            "End time must be later than start time."
        case .overlappingRecord:
            "This time interval overlaps another activity record."
        case .multipleActiveRecords:
            "Only one activity record can be active."
        }
    }
}

@MainActor
public struct ActivityRecordStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchRecords() throws -> [ActivityRecord] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\ActivityRecord.startedAt)]))
    }

    public func fetchCurrentRecord() throws -> ActivityRecord? {
        let active = try fetchRecords().filter { $0.endedAt == nil }
        guard active.count <= 1 else { throw ActivityRecordStoreError.multipleActiveRecords }
        return active.first
    }

    @discardableResult
    public func start(category: ActivityCategory, at date: Date = .now) throws -> ActivityRecord {
        let current = try fetchCurrentRecord()
        if let current {
            try validate(startedAt: current.startedAt, endedAt: date, excluding: current)
        }
        try validate(startedAt: date, endedAt: nil, excluding: current)

        let record = ActivityRecord(category: category, startedAt: date)
        current?.endedAt = date
        context.insert(record)
        do {
            try context.save()
        } catch {
            current?.endedAt = nil
            context.delete(record)
            throw error
        }
        return record
    }

    public func stop(at date: Date = .now) throws {
        guard let current = try fetchCurrentRecord() else { return }
        try edit(current, category: current.category, startedAt: current.startedAt, endedAt: date)
    }

    public func edit(
        _ record: ActivityRecord,
        category: ActivityCategory,
        startedAt: Date,
        endedAt: Date?
    ) throws {
        try validate(startedAt: startedAt, endedAt: endedAt, excluding: record)
        let previous = (record.category, record.startedAt, record.endedAt)
        record.category = category
        record.startedAt = startedAt
        record.endedAt = endedAt
        do {
            try context.save()
        } catch {
            record.category = previous.0
            record.startedAt = previous.1
            record.endedAt = previous.2
            throw error
        }
    }

    public func delete(_ record: ActivityRecord) throws {
        context.delete(record)
        try context.save()
    }

    private func validate(
        startedAt: Date,
        endedAt: Date?,
        excluding record: ActivityRecord? = nil
    ) throws {
        if let endedAt, endedAt <= startedAt {
            throw ActivityRecordStoreError.invalidInterval
        }
        let others = try fetchRecords().filter { $0.persistentModelID != record?.persistentModelID }
        if endedAt == nil, others.contains(where: { $0.endedAt == nil }) {
            throw ActivityRecordStoreError.multipleActiveRecords
        }
        guard !others.contains(where: {
            (endedAt == nil || $0.startedAt < endedAt!) &&
            ($0.endedAt == nil || startedAt < $0.endedAt!)
        }) else {
            throw ActivityRecordStoreError.overlappingRecord
        }
    }
}
