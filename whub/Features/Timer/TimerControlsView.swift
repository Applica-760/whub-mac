import SwiftData
import SwiftUI
import WhubCore

struct TimerControlsView: View {
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @Query(filter: #Predicate<ActivityRecord> { $0.endedAt == nil }) private var records: [ActivityRecord]
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?
    @State private var errorMessage: String?

    private var current: ActivityRecord? { records.first }
    private var selectedCategory: ActivityCategory? {
        categories.first { $0.id == selection } ?? current?.category ?? categories.first
    }

    var body: some View {
        WidgetFrame {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Category", selection: Binding(
                    get: { selectedCategory?.id },
                    set: { selection = $0 }
                )) {
                    if categories.isEmpty {
                        Text("No categories").tag(nil as UUID?)
                    }
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(categories.isEmpty)

                HStack(spacing: 12) {
                    Button(current == nil ? "Start" : "Switch", systemImage: "play.fill", action: start)
                        .disabled(selectedCategory == nil || selectedCategory?.id == current?.category.id)
                        .help(current == nil ? "Start" : "Switch category")
                    Button("Stop", systemImage: "stop.fill", action: stop)
                        .disabled(current == nil)
                        .help("Stop")
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let elapsed = current.map { max(0, timeline.date.timeIntervalSince($0.startedAt)) } ?? 0
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityLabel("Elapsed time")
                    }
                }
                .labelStyle(.iconOnly)
            }
            .padding()
        }
        .alert("Unable to Update Timer", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func start() {
        guard let category = selectedCategory else { return }
        do {
            try ActivityRecordStore(context: context).start(category: category)
            selection = category.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stop() {
        do {
            try ActivityRecordStore(context: context).stop()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
