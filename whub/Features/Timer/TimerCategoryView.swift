import SwiftData
import SwiftUI
import WhubCore

struct TimerCategoryView: View {
    @Query(sort: \ActivityCategory.name) private var categories: [ActivityCategory]

    var body: some View {
        WidgetFrame {
            VStack(alignment: .leading, spacing: 8) {
                Text("Categories").font(.headline)
                if categories.isEmpty {
                    Text("No categories").foregroundStyle(.secondary)
                }
                ForEach(categories) { category in
                    HStack(spacing: 8) {
                        Circle().fill(category.displayColor).frame(width: 10, height: 10)
                        Text(category.name)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
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
