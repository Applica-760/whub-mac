import SwiftUI

private struct TodoPreview: Identifiable {
    var id: String { title }

    let title: String
    let dueDate: String?
}

struct TodoView: View {
    var body: some View {
        TodoWidget()
            .padding()
            .navigationTitle("Todo")
    }
}

struct TodoWidget: View {
    private let todos = [
        TodoPreview(title: "SwiftUIの基本を確認する", dueDate: "今日"),
        TodoPreview(title: "Vault Explorerを作る", dueDate: "明日"),
        TodoPreview(title: "Resource Statusを接続する", dueDate: nil),
    ]

    var body: some View {
        WidgetFrame {
            VStack(spacing: 0) {
                ForEach(Array(todos.enumerated()), id: \.element.id) { index, todo in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(todo.title)

                            if let dueDate = todo.dueDate {
                                Label(dueDate, systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 10)

                    if index < todos.count - 1 {
                        Divider()
                            .padding(.leading, 28)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    TodoView()
}
