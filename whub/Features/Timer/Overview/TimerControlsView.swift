import SwiftData
import SwiftUI
import WhubCore

struct TimerControlsView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @Query(filter: #Predicate<ActivityRecord> { $0.endedAt == nil }) private var records: [ActivityRecord]
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?
    @State private var errorMessage: String?

    private var current: ActivityRecord? { records.first }
    private var selectedCategory: ActivityCategory? {
        categories.first { $0.id == selection }
    }

    var body: some View {
        WidgetFrame {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: start) {
                            Image(systemName: "play.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .offset(x: 2)
                                .frame(width: 36, height: 36)
                                .accessibilityLabel(current == nil ? "Start" : "Switch")
                        }
                            .disabled(selectedCategory == nil || selectedCategory?.id == current?.category.id)
                            .help(current == nil ? "Start" : "Switch category")
                        Button(action: stop) {
                            Image(systemName: "stop.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .frame(width: 36, height: 36)
                                .accessibilityLabel("Stop")
                        }
                            .disabled(current == nil)
                            .help("Stop")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    TimelineView(.animation(minimumInterval: 1, paused: !isActive)) { timeline in
                        let elapsed = current.map { max(0, timeline.date.timeIntervalSince($0.startedAt)) } ?? 0
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityLabel("Elapsed time")
                    }
                }
                .frame(width: 168)

                categoryList
                    .frame(height: 180)
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

    private var categoryList: some View {
        List(selection: $selection) {
            ForEach(categories) { category in
                HStack(spacing: 8) {
                    Circle().fill(category.displayColor).frame(width: 10, height: 10)
                    Text(category.name).font(.system(size: 16)).lineLimit(1)
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .tag(category.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if categories.isEmpty {
                Text("No categories").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Category")
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
