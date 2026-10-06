import SwiftData
import SwiftUI
import WhubCore

struct ActivityRecordFormView: View {
    let record: ActivityRecord?
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var hasEndTime: Bool
    @State private var categoryID: UUID?
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    init(record: ActivityRecord? = nil, startedAt: Date = .now) {
        self.record = record
        _startedAt = State(initialValue: record?.startedAt ?? startedAt)
        _endedAt = State(initialValue: record.map { $0.endedAt ?? .now }
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: startedAt)!)
        _hasEndTime = State(initialValue: record == nil || record?.endedAt != nil)
    }

    private var selectedCategory: ActivityCategory? {
        record?.category ?? categories.first { $0.id == categoryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(record == nil ? "Add Activity Record" : "Edit Activity Record")
                .font(.title2)

            Form {
                if let record {
                    LabeledContent("Activity") {
                        HStack {
                            Circle().fill(record.category.displayColor)
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(record.category.name)
                        }
                    }
                } else {
                    Picker("Activity", selection: $categoryID) {
                        Text("Select an activity").tag(nil as UUID?)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
                DatePicker("Start", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                if let record, record.endedAt == nil {
                    Toggle("Set end time", isOn: $hasEndTime)
                    if !hasEndTime {
                        Text("Recording in progress")
                            .foregroundStyle(.secondary)
                    }
                }
                if hasEndTime {
                    DatePicker("End", selection: $endedAt, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.grouped)

            HStack {
                if record != nil {
                    Button("Delete", role: .destructive) { showsDeleteConfirmation = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCategory == nil)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(width: 480)
        .alert("Delete Activity Record?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Delete this activity record? Its category will be kept.")
        }
        .alert("Unable to Update Activity Record", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        guard let category = selectedCategory else { return }
        let store = ActivityRecordStore(context: context)
        do {
            if let record {
                try store.edit(record, category: category, startedAt: startedAt,
                               endedAt: hasEndTime ? endedAt : nil)
            } else {
                try store.add(category: category, startedAt: startedAt, endedAt: endedAt)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let record else { return }
        do {
            try ActivityRecordStore(context: context).delete(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
