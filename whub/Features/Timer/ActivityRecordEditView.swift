import SwiftData
import SwiftUI
import WhubCore

struct ActivityRecordEditView: View {
    let record: ActivityRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var hasEndTime: Bool
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    init(record: ActivityRecord) {
        self.record = record
        _startedAt = State(initialValue: record.startedAt)
        _endedAt = State(initialValue: record.endedAt ?? .now)
        _hasEndTime = State(initialValue: record.endedAt != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Activity Record")
                .font(.title2)

            Form {
                LabeledContent("Activity") {
                    HStack {
                        Circle().fill(record.category.displayColor)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(record.category.name)
                    }
                }
                DatePicker("Start", selection: $startedAt, displayedComponents: [.date, .hourAndMinute])
                if record.endedAt == nil {
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
                Button("Delete", role: .destructive) { showsDeleteConfirmation = true }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
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
        do {
            try ActivityRecordStore(context: context).edit(
                record,
                category: record.category,
                startedAt: startedAt,
                endedAt: hasEndTime ? endedAt : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try ActivityRecordStore(context: context).delete(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
