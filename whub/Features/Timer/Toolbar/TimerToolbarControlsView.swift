import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct TimerToolbarControlsView: View {
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @Query(sort: \ActivityRecord.startedAt, order: .reverse) private var records: [ActivityRecord]
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?
    @State private var errorMessage: String?

    private var current: ActivityRecord? { records.first { $0.endedAt == nil } }
    private var selectedCategory: ActivityCategory? {
        categories.first { $0.id == selection } ?? current?.category ?? records.first?.category
    }
    private var showsStop: Bool {
        current != nil && selectedCategory?.id == current?.category.id
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                if categories.isEmpty {
                    Text("No categories")
                } else {
                    Picker("Activity", selection: Binding(
                        get: { selectedCategory?.id },
                        set: { selection = $0 }
                    )) {
                        ForEach(categories) { category in
                            Label {
                                Text(category.name)
                            } icon: {
                                categoryIcon(category)
                            }
                            .tag(Optional(category.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .labelStyle(.titleAndIcon)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help(selectedCategory?.name ?? "Select an activity")
            .accessibilityLabel("Activity: \(selectedCategory?.name ?? "Not selected")")

            Button {
                if showsStop { stop() } else { start() }
            } label: {
                Image(systemName: showsStop ? "stop.fill" : "play.fill")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedCategory == nil)
            .help(showsStop ? "Stop" : current == nil ? "Start" : "Switch category")
            .accessibilityLabel(showsStop ? "Stop" : current == nil ? "Start" : "Switch category")
        }
        .padding(.leading, 4)
        .labelStyle(.iconOnly)
        .onChange(of: current?.category.id) { _, id in
            if let id { selection = id }
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

    private func categoryIcon(_ category: ActivityCategory) -> Image {
        let color = NSColor(category.displayColor)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image).renderingMode(.original)
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
