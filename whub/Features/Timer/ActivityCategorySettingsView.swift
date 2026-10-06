import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct ActivityCategorySettingsView: View {
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]
    @Environment(\.modelContext) private var context
    @State private var selection: UUID?

    var body: some View {
        EditableTable(
            rows: categories.map { CategoryRow($0) },
            columns: [
                .init(id: "name", title: "Name", value: { $0.name }, text: \.name),
                .init(id: "color", title: "Color", value: { _ in "" }, content: { row in
                    AnyView(ColorPicker("Color", selection: row.color, supportsOpacity: false).labelsHidden())
                }),
            ],
            selection: $selection,
            addTitle: "Add Category",
            errorTitle: "Unable to Save Category",
            onAdd: { CategoryRow() },
            onSave: save
        )
    }

    private func save(_ row: CategoryRow) throws -> UUID {
        let store = ActivityCategoryStore(context: context)
        if let category = row.category {
            try store.edit(category, name: row.name, colorRGB: row.colorRGB)
            return category.id
        }
        return try store.add(name: row.name, colorRGB: row.colorRGB).id
    }
}

extension ActivityCategory {
    var displayColor: Color {
        Color(.sRGB,
              red: Double((colorRGB >> 16) & 0xFF) / 255,
              green: Double((colorRGB >> 8) & 0xFF) / 255,
              blue: Double(colorRGB & 0xFF) / 255)
    }
}

private struct CategoryRow: Identifiable {
    let id: UUID
    let category: ActivityCategory?
    var name: String
    var colorRGB: Int

    var color: Color {
        get {
            Color(.sRGB,
                  red: Double((colorRGB >> 16) & 0xFF) / 255,
                  green: Double((colorRGB >> 8) & 0xFF) / 255,
                  blue: Double(colorRGB & 0xFF) / 255)
        }
        set {
            guard let color = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
                .map { Int((min(1, max(0, $0)) * 255).rounded()) }
            colorRGB = (components[0] << 16) | (components[1] << 8) | components[2]
        }
    }

    init(_ category: ActivityCategory? = nil) {
        id = category?.id ?? UUID()
        self.category = category
        name = category?.name ?? ""
        colorRGB = category?.colorRGB ?? 0x007AFF
    }
}
